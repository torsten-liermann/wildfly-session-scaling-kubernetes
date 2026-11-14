#!/usr/bin/env bash
#
# End-to-end check on a throw-away k3d cluster (one server, three agents):
#
#   1  two replicas; servlet sessions and Faces order forms are started through the ingress
#   2  CPU load: the HorizontalPodAutoscaler scales up to four replicas
#   3  the node with the most replicas is drained (PodDisruptionBudget: one eviction at a time)
#   4  the node with the most replicas is stopped with "docker kill" (every process on it dies at
#      once, without shutdown) and started again
#   5  without load, the HorizontalPodAutoscaler scales down to two replicas, one pod per minute
#   6  rolling update of the Deployment (to UPDATE_IMAGE, or a restart with the same image)
#   7  one pod is deleted (SIGTERM, graceful shutdown)
#   8  the JVM of the replica that served the last postback of an order form is killed with
#      SIGKILL; the form is continued through the ingress at once; the container restarts. The line
#      added by that last postback may be missing (its session write to the other owner happens after
#      the response); this is recorded as last-change-lost, every other difference is a failure
#   9  every order form is reviewed and submitted through the ingress and read back from the database
#
# After every step, on every ready replica (through kubectl port-forward):
#   - every servlet session is read with its original cookie: same session ID, same token in the
#     session attribute and in the @SessionScoped bean, request counters that have seen every
#     earlier request, whichever replica served it
#   - every order form receives one PrimeFaces Ajax postback with its current view state: the
#     @ViewScoped bean must be the original instance with every line entered so far, and the new
#     line must carry the current price of product 1
#   - second-level cache: every replica reads product 1 twice, and the second read must report the
#     entry in its cache; the first replica changes the price, every other replica must then have lost
#     the entry and read the new price
#   - the JGroups rack of each replica is its node, and the two owners of every session segment are
#     on different nodes (while the replicas run on two or more nodes)
# During all steps, one more servlet session is read through the ingress twice a second, and CPU and
# memory of every pod and the status of the HorizontalPodAutoscaler are sampled about every five seconds.
# At the end, every submitted order is read back from the database with SQL.
#
# Requires docker (or a compatible CLI, see DOCKER), k3d, kubectl, curl and jq.
# Build the image first: ./mvnw package jib:dockerBuild
#
# Settings (environment variables): CLUSTER, K3S_IMAGE, IMAGE, UPDATE_IMAGE, API_PORT, HTTP_PORT,
# SESSIONS, FLOWS, LOAD_WORKERS, KEEP_CLUSTER=true (keep the cluster after the run), RUN_DIR
# (output directory), DOCKER (container CLI, default docker).

set -Eeuo pipefail

CLUSTER="${CLUSTER:-session-scaling}"
K3S_IMAGE="${K3S_IMAGE:-rancher/k3s:v1.37.1-k3s1}"
IMAGE="${IMAGE:-wildfly-session-scaling:1.0.0-SNAPSHOT}"
UPDATE_IMAGE="${UPDATE_IMAGE:-}"
API_PORT="${API_PORT:-16443}"
HTTP_PORT="${HTTP_PORT:-18080}"
SESSIONS="${SESSIONS:-24}"
FLOWS="${FLOWS:-6}"
LOAD_WORKERS="${LOAD_WORKERS:-6}"
KEEP_CLUSTER="${KEEP_CLUSTER:-false}"
DOCKER="${DOCKER:-docker}"

NAMESPACE=session-scaling
DEPLOYMENT=session-scaling
CONTAINER=wildfly
APP_LABEL=app.kubernetes.io/name=session-scaling
SESSION_CACHE=ROOT.war
DB_USER=orders

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
RUN_DIR="${RUN_DIR:-$ROOT_DIR/target/verify-$(date -u +%Y%m%dT%H%M%SZ)}"
mkdir -p "$RUN_DIR/logs" "$RUN_DIR/flows"
RUN_DIR="$(cd "$RUN_DIR" && pwd)"
SHOWN_RUN_DIR="${RUN_DIR#"$ROOT_DIR"/}"
BASE_URL="http://127.0.0.1:${HTTP_PORT}"
DB_IMAGE=$(sed -n 's/^ *image: *\(postgres:[^ ]*\).*/\1/p' "$ROOT_DIR/k8s/database.yaml" | head -n 1)
export KUBECONFIG="$RUN_DIR/kubeconfig"

declare -a COOKIE=() SESSION_ID=() TOKEN=() COUNT=() LOAD_PIDS=() BACKGROUND_PIDS=()
declare -a FLOW_JAR=() FLOW_VS=() FLOW_VIEW=() FLOW_LINES=() FLOW_CENTS=()
declare -A PF_PORT=() PF_PID=()
STEP_ROWS=()
REFETCHED=()
EVENTS=()
FAILURES=0
REPORTED=false
STOPPED_NODE=""
PRICE="6.90"
PRICE_CHANGES=0
CACHE_RESULT="n/a"
ATTEMPTS=0
LOST_LINE_PRICE=""
LAST_CHANGE_LOST=false
FLOW_BODY=""
FLOW_STATE=""
FLOW_CODE=""
FLOW_SECONDS=""
FLOW_CONTAINER="-"
FOLLOWERS="$RUN_DIR/log-followers.pid"
: >"$FOLLOWERS"
# Replicas the script kills without shutdown (node stop, SIGKILL) and the time; written just before the kill
KILLED="$RUN_DIR/killed.txt"
: >"$KILLED"

# --- helpers ---------------------------------------------------------------------------

log() { printf '%s  %s\n' "$(date -u +%H:%M:%S)" "$*" | tee -a "$RUN_DIR/run.log"; }
fail() { log "FAILED: $*"; FAILURES=$((FAILURES + 1)); }
event() { EVENTS+=("$*"); log "$*"; }
kc() { kubectl -n "$NAMESPACE" "$@"; }
now() { date -u +%Y-%m-%dT%H:%M:%S.%3NZ; }
clock() { date -u +%H:%M:%S.%3N; }
epoch() { date -u +%s.%N; }
since() { awk -v a="$1" -v b="$(epoch)" 'BEGIN { printf "%.1f", b - a }'; }
greater() { awk -v a="$1" -v b="$2" 'BEGIN { exit !(a > b) }'; }
same_number() { awk -v a="$1" -v b="$2" 'BEGIN { exit !(a != "" && b != "" && a + 0 == b + 0) }'; }

# wait_until <timeout seconds> <description> <command...>
wait_until() {
  local timeout=$1 what=$2 start=$SECONDS
  shift 2
  until "$@" >/dev/null 2>&1; do
    if (( SECONDS - start > timeout )); then
      log "timeout after ${timeout}s: $what"
      return 1
    fi
    sleep 2
  done
}

# Pods of the application that are ready, not terminating and not on a stopped node
ready_pods() {
  kc get pods -l "$APP_LABEL" -o json | jq -r --arg stopped "$STOPPED_NODE" '.items[]
    | select(.metadata.deletionTimestamp == null and .spec.nodeName != $stopped)
    | select(any(.status.conditions[]?; .type == "Ready" and .status == "True"))
    | .metadata.name' | sort
}
all_pods_count() { kc get pods -l "$APP_LABEL" --no-headers 2>/dev/null | wc -l | tr -d ' '; }
ready_count() { ready_pods | grep -c . || true; }
pod_node() { kc get pod "$1" -o jsonpath='{.spec.nodeName}'; }
short() { echo "${1##*-}"; }
placement() {
  local pod out=""
  for pod in "$@"; do out+="$(short "$pod")@$(pod_node "$pod" | sed 's/^k3d-//') "; done
  echo "${out% }"
}
nodes_of() { local pod; for pod in "$@"; do pod_node "$pod"; echo; done | grep . | sort -u | grep -c . || true; }
hpa_line() { kc get hpa "$DEPLOYMENT" --no-headers 2>/dev/null | tr -s ' '; }
deployment_replicas() { kc get deployment "$DEPLOYMENT" -o jsonpath='{.spec.replicas}'; }

# The Infinispan view of one replica, read through the API server (no cookie needed)
cluster_view() { kubectl get --raw "/api/v1/namespaces/$NAMESPACE/pods/$1:8080/proxy/cluster" 2>/dev/null; }
view_settled() { # <members> <pod>
  cluster_view "$2" | jq -e --arg c "$SESSION_CACHE" --argjson n "$1" \
    '.distributedCaches[] | select(.name == $c) | .stable and .members == $n' >/dev/null
}

# The view of one replica is settled and no longer contains any of the given replicas
view_excludes() { # <pod> <removed pods...>
  local pod=$1
  shift
  cluster_view "$pod" | jq -e --arg c "$SESSION_CACHE" --args '
    ([.distributedCaches[] | select(.name == $c) | .stable] == [true])
    and ([.members[].name] - $ARGS.positional == [.members[].name])' "$@" >/dev/null
}

# Exactly n replicas: ready, nothing starting or terminating, every replica sees a settled view of n members
replicas_settled() {
  local n=$1 pod pods
  pods=$(ready_pods)
  [[ "$(grep -c . <<<"$pods" || true)" == "$n" && "$(all_pods_count)" == "$n" ]] || return 1
  for pod in $pods; do view_settled "$n" "$pod" || return 1; done
}
deployment_settled() { replicas_settled "$(deployment_replicas)"; }

# --- background processes (each one is ended through its remembered PID) ------------------

# Follows the log of every running container until it ends; a restarted container gets its own file
follow_logs() {
  local pod restarts file
  while true; do
    while IFS=$'\t' read -r pod restarts; do
      file="$RUN_DIR/logs/$pod.log"
      if (( restarts > 0 )); then file="$RUN_DIR/logs/$pod.restart-$restarts.log"; fi
      [[ -e "$file" ]] && continue
      kc logs -f "$pod" -c "$CONTAINER" >"$file" 2>&1 &
      echo "$!" >>"$FOLLOWERS"
    done < <(kc get pods -l "$APP_LABEL" -o json 2>/dev/null | jq -r '.items[]
      | select(.status.containerStatuses[0].state.running != null)
      | [.metadata.name, .status.containerStatuses[0].restartCount] | @tsv')
    sleep 2
  done
}

# Samples the pods every second: time, pod, node, phase, ready, restarts, terminating, created,
# container started, last change of the Ready condition (the last three as the API server reports them)
poll_pods() {
  while true; do
    kc get pods -l "$APP_LABEL" -o json 2>/dev/null | jq -r --arg t "$(now)" '.items[]
      | [$t, .metadata.name, (.spec.nodeName // "-"), .status.phase,
         ([.status.conditions[]? | select(.type == "Ready") | .status][0] // "-"),
         (.status.containerStatuses[0].restartCount // 0),
         (if .metadata.deletionTimestamp then "terminating" else "-" end),
         .metadata.creationTimestamp,
         (.status.containerStatuses[0].state.running.startedAt // "-"),
         ([.status.conditions[]? | select(.type == "Ready") | .lastTransitionTime][0] // "-")]
      | @tsv' >>"$RUN_DIR/pods.tsv" || true
    sleep 1
  done
}

# Samples about every five seconds what the HorizontalPodAutoscaler works with: CPU (millicores) and memory
# of every pod from the metrics API (top.tsv: time, pod, CPU, memory), and the status of the HPA
# (hpa-status.tsv: time, current replicas, desired replicas, average CPU utilization in % of the request)
poll_metrics() {
  local t
  while true; do
    t=$(now)
    kc top pods -l "$APP_LABEL" --no-headers 2>/dev/null | awk -v t="$t" 'NF >= 3 { print t "\t" $1 "\t" $2 "\t" $3 }' \
      >>"$RUN_DIR/top.tsv" || true
    kc get hpa "$DEPLOYMENT" -o json 2>/dev/null | jq -r --arg t "$t" '[$t, (.status.currentReplicas // "-"),
      (.status.desiredReplicas // "-"), (.status.currentMetrics[0].resource.current.averageUtilization // "-")] | @tsv' \
      >>"$RUN_DIR/hpa-status.tsv" || true
    sleep 5
  done
}

start_background() {
  follow_logs & BACKGROUND_PIDS+=($!)
  poll_pods & BACKGROUND_PIDS+=($!)
  poll_metrics & BACKGROUND_PIDS+=($!)
}

stop_pids() {
  local pid
  for pid in "$@"; do kill "$pid" 2>/dev/null || true; done
  for pid in "$@"; do wait "$pid" 2>/dev/null || true; done
}

stop_followers() {
  local pid
  if [[ -s "$FOLLOWERS" ]]; then
    while read -r pid; do kill "$pid" 2>/dev/null || true; done <"$FOLLOWERS"
  fi
}

start_load() {
  local worker
  for worker in $(seq "$LOAD_WORKERS"); do
    (while true; do curl -s -o /dev/null --max-time 10 "$BASE_URL/load?ms=250" || sleep 0.5; done) &
    LOAD_PIDS+=($!)
  done
}

stop_load() {
  if (( ${#LOAD_PIDS[@]} > 0 )); then stop_pids "${LOAD_PIDS[@]}"; fi
  LOAD_PIDS=()
}

# kubectl port-forward to every pod given; PF_PORT[pod] is the local port
open_forwards() {
  local pod port pf_log
  for pod in "$@"; do
    pf_log="$RUN_DIR/port-forward-$pod.log"
    kc port-forward "pod/$pod" :8080 --address 127.0.0.1 >"$pf_log" 2>&1 &
    PF_PID[$pod]=$!
    port=""
    for _ in $(seq 50); do
      port=$(sed -n 's/^Forwarding from 127.0.0.1:\([0-9]*\) .*/\1/p' "$pf_log" | head -n 1)
      [[ -n "$port" ]] && break
      sleep 0.2
    done
    if [[ -z "$port" ]]; then
      fail "no port-forward to $pod: $(cat "$pf_log")"
      rm -f "$pf_log"
      return 1
    fi
    rm -f "$pf_log"
    PF_PORT[$pod]=$port
  done
}

close_forwards() {
  if (( ${#PF_PID[@]} > 0 )); then stop_pids "${PF_PID[@]}"; fi
  PF_PID=()
  PF_PORT=()
}

# --- report (also written when the run ends early) -----------------------------------------

graceful_shutdown_report() {
  local file pod stopped
  : >"$RUN_DIR/shutdown.tsv"
  for file in "$RUN_DIR"/logs/*.log; do
    [[ -e "$file" ]] || continue
    grep -q 'WFLYSRV0220' "$file" || continue
    pod=$(basename "$file" .log)
    stopped=$(grep -o 'WFLYSRV0050: .* stopped in [0-9]*ms' "$file" || true)
    printf '%s\t%s\t%s\t%s\n' "$pod" \
      "$(grep -c 'WFLYSRV0211: Suspending server' "$file" || true)" \
      "$(grep -c 'WFLYSRV0220: Server shutdown has been requested via an OS signal' "$file" || true)" \
      "${stopped:-no WFLYSRV0050}" >>"$RUN_DIR/shutdown.tsv"
  done
}

# Start of every container as the API server reports it (created, container started, Ready) and the
# boot time WildFly logs (WFLYSRV0025). One row per pod and container restart.
startup_report() {
  : >"$RUN_DIR/startup.tsv"
  [[ -s "$RUN_DIR/pods.tsv" ]] || return 0
  local pod restarts node created started ready to_ready created_to_ready file boot
  while IFS=$'\t' read -r pod restarts node created started ready to_ready created_to_ready; do
    file="$RUN_DIR/logs/$pod.log"
    if (( restarts > 0 )); then file="$RUN_DIR/logs/$pod.restart-$restarts.log"; fi
    boot=$(grep -o 'started in [0-9]*ms' "$file" 2>/dev/null | head -n 1 | tr -dc '0-9' || true)
    printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' "$pod" "$restarts" "${node#k3d-}" "$created" "$started" "$ready" \
      "$to_ready" "$created_to_ready" "${boot:--}" >>"$RUN_DIR/startup.tsv"
  done < <(jq -R -s -r '
    [split("\n")[] | select(length > 0) | split("\t")
      | {pod: .[1], node: .[2], ready: .[4], restarts: (.[5] | tonumber), created: .[7], started: .[8], changed: .[9]}]
    | map(select(.ready == "True" and .started != "-" and .changed != "-"))
    | group_by([.pod, .restarts]) | map(.[0]) | sort_by(.started) | .[]
    | [.pod, .restarts, .node, .created, .started, .changed,
       ((.changed | fromdateiso8601) - (.started | fromdateiso8601)),
       (if .restarts == 0 then ((.changed | fromdateiso8601) - (.created | fromdateiso8601)) else "-" end)]
    | @tsv' "$RUN_DIR/pods.tsv" 2>/dev/null)
}

# kubectl logs -f can end before the container does. At the end, the complete log of every container
# that still exists replaces the followed one: the current container and, after a restart, the
# previous one (--previous). Containers of pods that no longer exist keep the followed log.
refetch_logs() {
  local pod restarts
  REFETCHED=()
  while IFS=$'\t' read -r pod restarts; do
    fetch_log "$pod" "$restarts"
    if (( restarts > 0 )); then fetch_log "$pod" $((restarts - 1)) --previous; fi
  done < <(kc get pods -l "$APP_LABEL" -o json 2>/dev/null | jq -r '.items[]
    | [.metadata.name, (.status.containerStatuses[0].restartCount // 0)] | @tsv')
}

fetch_log() { # <pod> <restart count of the container> [--previous]
  local file="$RUN_DIR/logs/$1.log"
  if (( $2 > 0 )); then file="$RUN_DIR/logs/$1.restart-$2.log"; fi
  if kc logs "$1" -c "$CONTAINER" ${3:+"$3"} >"$file.tmp" 2>/dev/null && [[ -s "$file.tmp" ]]; then
    mv "$file.tmp" "$file"
    REFETCHED+=("$(basename "$file")")
  else
    rm -f "$file.tmp"
  fi
}

# Probe answers around the moments a replica left the cluster. A leave is the first ISPN100001
# ("Node <member> left the cluster") for a member in any container log (leaves.tsv); the same member
# counts as a new leave only 60 s later (a restarted container keeps its pod name). An answer belongs
# to a leave if its request ran at some time in the 6 s after the leave: it started less than 6 s
# after the leave and ended after it.
leave_report() {
  grep -h 'ISPN100001: Node .* left the cluster' "$RUN_DIR"/logs/*.log 2>/dev/null \
    | sed -E 's/^([0-9-]+) ([0-9:]+),([0-9]+) .*ISPN100001: Node ([^ ]+) left the cluster.*/\1T\2.\3Z\t\4/' \
    | sort >"$RUN_DIR/leaves.tsv" || true
  [[ -s "$RUN_DIR/ingress-probe.tsv" ]] || return 0
  jq -n -r --rawfile leaves "$RUN_DIR/leaves.tsv" --rawfile probe "$RUN_DIR/ingress-probe.tsv" '
    def epoch: capture("(?<s>[0-9-]+T[0-9:]+)[.](?<f>[0-9]+)Z") | (.s + "Z" | fromdateiso8601) + ("0." + .f | tonumber);
    def rows($text): $text | split("\n") | map(select(length > 0) | split("\t"));
    def stats: "\(length) answers, \(map(select(.s > 0.2)) | length) of them slower than 0.2 s, slowest \(map(.s) | max // 0) s";
    (rows($leaves) | map({at: .[0], t: (.[0] | epoch), member: .[1]})
      | reduce .[] as $l ([]; if any(.[]; .member == $l.member and $l.t - .t < 60) then . else . + [$l] end)) as $ls
    | (rows($probe) | map(select(.[3] != "no-answer") | {start: (.[0] | epoch), s: (.[2] | tonumber)})
       | map(. as $a | . + {near: any($ls[]; $a.start < .t + 6 and $a.start + $a.s >= .t)})) as $answers
    | "Leaves (first ISPN100001 per member in the container logs): \($ls | length)",
      "",
      ($ls[] | "    \(.at)\t\(.member)"),
      "",
      "Probe answers whose request ran within 6 s after a leave: \($answers | map(select(.near)) | stats)",
      "",
      "Other probe answers: \($answers | map(select(.near | not)) | stats)"'
}

# Faces requests slower than 0.2 s. The postbacks of the per-replica checks are numbered per container
# (pod#restarts), so that the first postbacks a JVM processes can be told apart.
slow_requests_report() {
  [[ -s "$RUN_DIR/flows.tsv" ]] || return 0
  awk -F'\t' '$4 != "ingress" { n[$11]++; total++
      if ($7 + 0 > 0.2) { slow++; rows = rows sprintf("    %s\t%s\t%s\tpostback %d on this container\t%s s\n", substr($1, 12, 12), $2, $11, n[$11], $7) } }
    END { printf "Faces postbacks of the per-replica checks slower than 0.2 s: %d of %d\n\n%s", slow, total, rows }' "$RUN_DIR/flows.tsv"
  echo
  awk -F'\t' '$4 == "ingress" { total++
      if ($7 + 0 > 0.2) { slow++; rows = rows sprintf("    %s\t%s\tform %s\t%s\t%s\t%s s\n", substr($1, 12, 12), $2, $3, $5, $8, $7) } }
    END { printf "Faces requests through the ingress slower than 0.2 s: %d of %d\n\n%s", slow, total, rows }' "$RUN_DIR/flows.tsv"
}

# WARN and ERROR messages of all container logs, counted by message code (or by logger and text without a code)
log_messages_report() {
  cat "$RUN_DIR"/logs/*.log 2>/dev/null \
    | sed -n -E 's/^[0-9-]+ [0-9:,]+ (WARN|ERROR) +\[([^]]*)\] \(([^()]|\([^()]*\))*\) (.*)$/\1\t\2\t\4/p' \
    | awk -F'\t' '{ if (match($3, /(WFLY[A-Z]*|ISPN)[0-9]+/)) key = substr($3, RSTART, RLENGTH)
        else { m = $3; gsub(/[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+(:[0-9]+)?/, "<address>", m); key = $2 ": " substr(m, 1, 70) }
        n[$1 "\t" key]++ }
      END { for (k in n) printf "    %d\t%s\n", n[k], k }' | sort -k1,1nr -k2
}

# CPU and memory of the pods as the metrics API reported them (top.tsv)
metrics_report() {
  [[ -s "$RUN_DIR/top.tsv" ]] || return 0
  awk -F'\t' '{ c = $3 + 0; m = $4 + 0; if (n == 0 || m < mmin) mmin = m; if (m > mmax) mmax = m; if (c > cmax) cmax = c; n++ }
    END { printf "Pod samples of the metrics API (top.tsv): %d; CPU at most %dm; memory %dMi to %dMi\n", n, cmax, mmin, mmax }' "$RUN_DIR/top.tsv"
}

report() {
  REPORTED=true
  close_forwards
  stop_load
  if (( ${#BACKGROUND_PIDS[@]} > 0 )); then stop_pids "${BACKGROUND_PIDS[@]}"; fi
  BACKGROUND_PIDS=()
  stop_followers
  refetch_logs
  local probe_summary="no requests" probe_wrong
  if [[ -s "$RUN_DIR/ingress-probe.tsv" ]]; then
    probe_wrong=$(awk -F'\t' '$4 == "WRONG"' "$RUN_DIR/ingress-probe.tsv" | wc -l | tr -d ' ')
    probe_summary=$(awk -F'\t' '
      NR == 1 { first = $1 } { last = $1; n++; count[$4]++; if ($4 != "no-answer" && $3 > max) max = $3 }
      END { printf "%d requests from %s to %s: %d correct, %d without answer (no response within 5 s, or 502/503/504 from the ingress), %d without the change of the previous answer of a killed replica, %d wrong; slowest answer %.3f s",
            n, first, last, count["ok"], count["no-answer"], count["last-change-lost"], count["WRONG"], max }' "$RUN_DIR/ingress-probe.tsv")
    if (( probe_wrong > 0 )); then fail "ingress probe: $probe_wrong answers with a wrong or lost session"; fi
  fi
  graceful_shutdown_report
  startup_report
  kc get events --sort-by=.lastTimestamp >"$RUN_DIR/events.txt" 2>&1 || true
  kc get events -o json 2>/dev/null | jq -r '.items[] | select(.involvedObject.kind == "HorizontalPodAutoscaler")
    | [(.lastTimestamp // .eventTime // .firstTimestamp), .reason, .message] | @tsv' >"$RUN_DIR/hpa-events.tsv" || true
  kc describe hpa "$DEPLOYMENT" >"$RUN_DIR/hpa.txt" 2>&1 || true
  kc get pdb "$DEPLOYMENT" -o wide >"$RUN_DIR/pdb.txt" 2>&1 || true
  {
    echo "| Step | Checked (UTC) | Replicas checked | Nodes | Session reads OK | Faces postbacks OK | Cache invalidations seen | Slowest session read (s) | Slowest Faces postback (s) | Segments with owners on different nodes | JGroups rack = node |"
    echo "| --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- |"
    if (( ${#STEP_ROWS[@]} > 0 )); then printf '%s\n' "${STEP_ROWS[@]}"; fi
    echo
    echo "Ingress probe: $probe_summary"
    echo
    echo "Events:"
    echo
    if (( ${#EVENTS[@]} > 0 )); then printf -- '- %s\n' "${EVENTS[@]}"; fi
    echo
    echo "Container starts (pod, restarts, node, created, container started, ready, started to ready in s, created to ready in s, WildFly boot in ms):"
    echo
    sed 's/^/    /' "$RUN_DIR/startup.tsv"
    echo
    echo "Pods stopped with SIGTERM (pod, WFLYSRV0211 suspend, WFLYSRV0220 OS signal, WFLYSRV0050 stopped):"
    echo
    sed 's/^/    /' "$RUN_DIR/shutdown.tsv"
    echo
    echo "HPA events:"
    echo
    sed 's/^/    /' "$RUN_DIR/hpa-events.tsv"
    echo
    metrics_report
    echo
    if [[ -s "$RUN_DIR/orders.tsv" ]]; then
      echo "Submitted orders (form, order, lines added, expected total; form total; confirmation lines and total; database rows in order_line, sum of unit_price * quantity, customer_order.total):"
      echo
      sed 's/^/    /' "$RUN_DIR/orders.tsv"
      echo
    fi
    leave_report
    echo
    slow_requests_report
    echo
    echo "WARN and ERROR messages in the container logs (count, level, message code or logger and text):"
    echo
    log_messages_report
    echo
    echo "Container logs fetched completely at the end (the others are the followed logs): ${REFETCHED[*]:-none}"
    echo
    echo "Failures: $FAILURES"
  } >"$RUN_DIR/summary.md"
  cat "$RUN_DIR/summary.md"
}

cleanup() {
  local status=$?
  stop_load
  close_forwards
  if [[ "$REPORTED" != "true" ]]; then
    fail "run aborted with exit status $status"
    if [[ -s "$KUBECONFIG" ]]; then report || true; fi
    log "RESULT: FAILED (aborted), details in $SHOWN_RUN_DIR"
  fi
  if (( ${#BACKGROUND_PIDS[@]} > 0 )); then stop_pids "${BACKGROUND_PIDS[@]}"; fi
  stop_followers
  if [[ -n "$STOPPED_NODE" ]]; then "$DOCKER" start "$STOPPED_NODE" >/dev/null 2>&1 || true; fi
  if [[ "$KEEP_CLUSTER" == "true" ]]; then
    log "cluster kept: export KUBECONFIG=$SHOWN_RUN_DIR/kubeconfig"
  else
    k3d cluster delete "$CLUSTER" >>"$RUN_DIR/run.log" 2>&1 || true
  fi
  exit "$status"
}
trap cleanup EXIT

# --- servlet sessions ----------------------------------------------------------------------

create_sessions() {
  local i headers body cookie
  for ((i = 0; i < SESSIONS; i++)); do
    headers="$RUN_DIR/create-headers.txt"
    body=$(curl -s -D "$headers" -X POST "$BASE_URL/session")
    cookie=$(tr -d '\r' <"$headers" | sed -n 's/^[Ss]et-[Cc]ookie: JSESSIONID=\([^;]*\).*/\1/p' | head -n 1)
    if [[ -z "$cookie" ]] || ! jq -e '.new == true and .requestCount == 1 and .beanVisits == 1' <<<"$body" >/dev/null; then
      fail "session $i could not be created: $body"
      return 1
    fi
    COOKIE[i]=$cookie
    SESSION_ID[i]=$(jq -r .sessionId <<<"$body")
    TOKEN[i]=$(jq -r .token <<<"$body")
    COUNT[i]=1
    printf '%s\tcreate\t%s\t%s\t201\t-\tok\n' "$(now)" "$i" "$(jq -r .servedBy <<<"$body")" >>"$RUN_DIR/requests.tsv"
  done
  rm -f "$RUN_DIR/create-headers.txt"
  log "created $SESSIONS servlet sessions through the ingress; creating replicas: $(cut -f4 "$RUN_DIR/requests.tsv" | sort | uniq -c | awk '{printf "%s×%s ", $1, $2}')"
}

# Background: reads one more session through the ingress twice a second, like a user would.
# Result per request: ok, no-answer (no response within 5 s, or 502/503/504 from the ingress: the
# request did not reach a working replica), last-change-lost (the counter misses exactly the increment
# of the previous answer, and that answer came from a replica the script killed less than 10 s after
# the answer had started: its session write to the other owner had not ended, see step 8) or WRONG (any
# other missing or outdated session).
# ingress-probe.tsv: start of the request (UTC), HTTP status, seconds, result, replica that answered.
probe_ingress() {
  local headers="$RUN_DIR/probe-headers.txt" body cookie sid token count=1 response meta code seconds result
  local uncertain=false started started_epoch previous_by="" previous_epoch=0
  body=$(curl -s -D "$headers" -X POST "$BASE_URL/session")
  cookie=$(tr -d '\r' <"$headers" | sed -n 's/^[Ss]et-[Cc]ookie: JSESSIONID=\([^;]*\).*/\1/p' | head -n 1)
  rm -f "$headers"
  sid=$(jq -r .sessionId <<<"$body")
  token=$(jq -r .token <<<"$body")
  while true; do
    started=$(now)
    started_epoch=$(epoch)
    response=$(curl -s --max-time 5 -w $'\n%{http_code} %{time_total}' -H "Cookie: JSESSIONID=$cookie" \
      "$BASE_URL/session" || true)
    meta=${response##*$'\n'}
    body=${response%$'\n'*}
    code=${meta% *}
    seconds=${meta#* }
    if [[ "$code" == "000" || "$code" == "502" || "$code" == "503" || "$code" == "504" ]]; then
      # A request without answer may have reached a replica before it failed: the next count may be one higher
      result=no-answer
      uncertain=true
    elif [[ "$code" == "200" ]] && jq -e --arg sid "$sid" --arg token "$token" --argjson n "$((count + 1))" \
        --argjson uncertain "$uncertain" \
        '.sessionId == $sid and .new == false and .token == $token and .beanToken == $token
         and .requestCount == .beanVisits
         and (.requestCount == $n or ($uncertain and .requestCount == $n + 1))' <<<"$body" >/dev/null 2>&1; then
      result=ok
      count=$(jq -r .requestCount <<<"$body")
      uncertain=false
    elif [[ "$code" == "200" && -n "$previous_by" ]] \
        && awk -F'\t' -v p="$previous_by" -v t="$previous_epoch" '$1 == p && $2 > t && $2 - t < 10 { k = 1 } END { exit !k }' "$KILLED" \
        && jq -e --arg sid "$sid" --arg token "$token" --argjson n "$count" \
        '.sessionId == $sid and .new == false and .token == $token and .beanToken == $token
         and .requestCount == .beanVisits and .requestCount == $n' <<<"$body" >/dev/null 2>&1; then
      result=last-change-lost
      uncertain=false
    else
      result=WRONG
      if jq -e '.requestCount | numbers' <<<"$body" >/dev/null 2>&1; then count=$(jq -r .requestCount <<<"$body"); fi
    fi
    if [[ "$result" != no-answer ]]; then
      previous_by=$(jq -r '.servedBy // empty' <<<"$body" 2>/dev/null)
      previous_epoch=$started_epoch
    fi
    printf '%s\t%s\t%s\t%s\t%s\n' "$started" "$code" "$seconds" "$result" \
      "$(jq -r '.servedBy // empty' <<<"$body" 2>/dev/null)" >>"$RUN_DIR/ingress-probe.tsv"
    sleep 0.5
  done
}

# --- Faces order forms ---------------------------------------------------------------------

flow_attr() { sed -n "s/.* data-$2=\"\([^\"]*\)\".*/\1/p" <<<"$1"; }
flow_tag() { grep -o 'id="flow-state"[^>]*' <<<"$1" | head -n 1 || true; }
page_view_state() {
  grep -o 'name="jakarta.faces.ViewState"[^>]*value="[^"]*"' <<<"$1" | sed 's/.*value="\([^"]*\)"/\1/' | head -n 1 || true
}
partial_view_state() {
  grep -o 'jakarta.faces.ViewState:0"><!\[CDATA\[[^]]*' <<<"$1" | sed 's/.*CDATA\[//' | head -n 1 || true
}

# faces_request <flow> <url> <curl arguments...>: a request to order.xhtml with the cookies of the
# order form; sets FLOW_BODY, FLOW_CODE, FLOW_SECONDS and FLOW_STATE
faces_request() {
  local i=$1 url=$2 response meta
  shift 2
  response=$(curl -s --max-time 20 -b "${FLOW_JAR[i]}" -c "${FLOW_JAR[i]}" -w $'\n%{http_code} %{time_total}' \
    "$@" "$url/order.xhtml" || true)
  meta=${response##*$'\n'}
  FLOW_BODY=${response%$'\n'*}
  FLOW_CODE=${meta% *}
  FLOW_SECONDS=${meta#* }
  FLOW_STATE=$(flow_tag "$FLOW_BODY")
}

# faces_ajax <flow> <url> <button> <execute> [field=value...]: a PrimeFaces Ajax postback as the browser sends it
faces_ajax() {
  local i=$1 url=$2 source=$3 execute=$4 field
  shift 4
  local args=(-H 'Faces-Request: partial/ajax' -H 'X-Requested-With: XMLHttpRequest'
    --data-urlencode 'jakarta.faces.partial.ajax=true'
    --data-urlencode "jakarta.faces.source=order:$source"
    --data-urlencode "jakarta.faces.partial.execute=$execute"
    --data-urlencode 'jakarta.faces.partial.render=order:wizard'
    --data-urlencode "order:$source=order:$source"
    --data-urlencode 'order=order')
  for field in "$@"; do args+=(--data-urlencode "$field"); done
  args+=(--data-urlencode "jakarta.faces.ViewState=${FLOW_VS[i]}")
  faces_request "$i" "$url" "${args[@]}"
}

no_answer() { [[ "$FLOW_CODE" == "000" || "$FLOW_CODE" == "502" || "$FLOW_CODE" == "503" || "$FLOW_CODE" == "504" ]]; }

# flows.tsv: end of the request (UTC), step, form, target (ingress or the pod checked), action, HTTP status,
# seconds, result, replica that answered, lines in the form, container checked (pod#restarts, or "-")
flow_record() { # <step> <flow> <target> <action> <result>
  printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' "$(now)" "$1" "$2" "$3" "$4" "$FLOW_CODE" "$FLOW_SECONDS" "$5" \
    "$(flow_attr "$FLOW_STATE" served-by)" "$(flow_attr "$FLOW_STATE" lines)" "$FLOW_CONTAINER" >>"$RUN_DIR/flows.tsv"
}

# Checks common to every response: no Faces error, the expected step, the original view and customer
flow_matches() { # <flow> <step>
  local i=$1 step=$2
  [[ "$FLOW_CODE" == "200" && -n "$FLOW_STATE" ]] || return 1
  if grep -q '<error>' <<<"$FLOW_BODY"; then return 1; fi
  [[ "$(flow_attr "$FLOW_STATE" step)" == "$step" ]] || return 1
  [[ "$(flow_attr "$FLOW_STATE" view)" == "${FLOW_VIEW[i]}" ]] || return 1
  [[ "$(flow_attr "$FLOW_STATE" customer)" == "customer-$i" ]] || return 1
}

start_flows() {
  local i vs
  for ((i = 0; i < FLOWS; i++)); do
    FLOW_JAR[i]="$RUN_DIR/flows/order-form-$i.cookies"
    : >"${FLOW_JAR[i]}"
    # GET: a new view; the @ViewScoped bean is created on the replica that answers
    faces_request "$i" "$BASE_URL" -G
    vs=$(page_view_state "$FLOW_BODY")
    FLOW_VIEW[i]=$(flow_attr "$FLOW_STATE" view)
    if [[ "$FLOW_CODE" != 200 || -z "$vs" || -z "${FLOW_VIEW[i]}" || "$(flow_attr "$FLOW_STATE" step)" != 1 ]]; then
      flow_record "1 two replicas" "$i" ingress open WRONG
      fail "order form $i could not be opened: HTTP $FLOW_CODE $FLOW_STATE"
      return 1
    fi
    flow_record "1 two replicas" "$i" ingress open ok
    FLOW_VS[i]=$vs
    # First step of the form: a full-page postback (command button without Ajax)
    faces_request "$i" "$BASE_URL" --data-urlencode order=order --data-urlencode "order:customer=customer-$i" \
      --data-urlencode order:toItems= --data-urlencode "jakarta.faces.ViewState=${FLOW_VS[i]}"
    if ! flow_matches "$i" 2; then
      flow_record "1 two replicas" "$i" ingress customer WRONG
      fail "order form $i: customer step failed: HTTP $FLOW_CODE $FLOW_STATE"
      return 1
    fi
    flow_record "1 two replicas" "$i" ingress customer ok
    FLOW_VS[i]=$(page_view_state "$FLOW_BODY")
    FLOW_LINES[i]=0
    FLOW_CENTS[i]=0
  done
  log "opened $FLOWS order forms through the ingress (Faces views created on: $(awk -F'\t' '$5 == "open" {print $9}' "$RUN_DIR/flows.tsv" | sort | uniq -c | awk '{printf "%s×%s ", $1, $2}'))"
}

# flow_add_line <flow> <url> <step> <target> [expected pod]: one Ajax postback "Add line" with product 1.
# Returns 2 if the request got no answer (the user may click again), 1 if the answer was wrong.
flow_add_line() {
  local i=$1 url=$2 step=$3 target=$4 pod=${5:-} expected vs
  expected=$((FLOW_LINES[i] + 1))
  faces_ajax "$i" "$url" addLine "order:addLine order:product order:quantity" order:product_input=1 order:quantity=1
  if no_answer; then
    flow_record "$step" "$i" "$target" add-line no-answer
    return 2
  fi
  if flow_matches "$i" 2 \
      && [[ "$(flow_attr "$FLOW_STATE" lines)" == "$expected" ]] \
      && [[ "$(flow_attr "$FLOW_STATE" last-product)" == 1 ]] \
      && same_number "$(flow_attr "$FLOW_STATE" last-price)" "$PRICE" \
      && [[ -z "$pod" || "$(flow_attr "$FLOW_STATE" served-by)" == "$pod" ]]; then
    FLOW_LINES[i]=$expected
    # The expected total of the form: the sum of the prices the script has set (quantity 1 per line)
    FLOW_CENTS[i]=$((FLOW_CENTS[i] + 10#${PRICE/./}))
    FLOW_VS[i]=$(partial_view_state "$FLOW_BODY")
    flow_record "$step" "$i" "$target" add-line ok
    return 0
  fi
  # Only for the continuation after the SIGKILL in step 8 (LOST_LINE_PRICE set): WildFly writes the session
  # changes of a request to the other owner after the response has been sent. If the JVM died before that
  # write ended, the line added by its last answer is missing. The view, every earlier line and the new
  # line must be there; the result is recorded as last-change-lost and reported, not counted as a failure.
  if [[ -n "$LOST_LINE_PRICE" ]] && flow_matches "$i" 2 \
      && [[ "$(flow_attr "$FLOW_STATE" lines)" == "${FLOW_LINES[i]}" ]] \
      && [[ "$(flow_attr "$FLOW_STATE" last-product)" == 1 ]] \
      && same_number "$(flow_attr "$FLOW_STATE" last-price)" "$PRICE" \
      && [[ -z "$pod" || "$(flow_attr "$FLOW_STATE" served-by)" == "$pod" ]]; then
    FLOW_CENTS[i]=$((FLOW_CENTS[i] - 10#${LOST_LINE_PRICE/./} + 10#${PRICE/./}))
    FLOW_VS[i]=$(partial_view_state "$FLOW_BODY")
    flow_record "$step" "$i" "$target" add-line last-change-lost
    LAST_CHANGE_LOST=true
    return 0
  fi
  flow_record "$step" "$i" "$target" add-line WRONG
  fail "$step: order form $i on $target: HTTP $FLOW_CODE, expected step 2, view ${FLOW_VIEW[i]}, $expected lines, price $PRICE; got: $FLOW_STATE $(grep -o '<error>.*</error>' <<<"$FLOW_BODY" | head -c 300 || true)"
  if [[ -n "$(flow_attr "$FLOW_STATE" lines)" ]]; then FLOW_LINES[i]=$(flow_attr "$FLOW_STATE" lines); fi
  vs=$(partial_view_state "$FLOW_BODY")
  if [[ -n "$vs" ]]; then FLOW_VS[i]=$vs; fi
  return 1
}

# Repeats a postback through the ingress while it gets no answer, as a user would click again
flow_add_line_ingress() { # <flow> <step>; sets ATTEMPTS
  local status
  ATTEMPTS=0
  while (( ATTEMPTS < 30 )); do
    ATTEMPTS=$((ATTEMPTS + 1))
    status=0
    flow_add_line "$1" "$BASE_URL" "$2" ingress || status=$?
    (( status == 2 )) || return "$status"
    sleep 1
  done
  fail "$2: order form $1 got no answer through the ingress in $ATTEMPTS attempts"
  return 1
}

# Review and submit through the ingress; the confirmation shows the order as read back from the database
finish_flows() {
  local i ok=0 status action source step order expected db db_lines db_sum db_total
  for ((i = 0; i < FLOWS; i++)); do
    status=0
    for action in toReview:3 submit:4; do
      source=${action%:*}
      step=${action#*:}
      ATTEMPTS=0
      while true; do
        ATTEMPTS=$((ATTEMPTS + 1))
        faces_ajax "$i" "$BASE_URL" "$source" "order:$source"
        if no_answer && (( ATTEMPTS < 30 )); then
          flow_record "9 order forms submitted" "$i" ingress "$source" no-answer
          sleep 1
          continue
        fi
        break
      done
      if flow_matches "$i" "$step" && [[ "$(flow_attr "$FLOW_STATE" lines)" == "${FLOW_LINES[i]}" ]]; then
        flow_record "9 order forms submitted" "$i" ingress "$source" ok
        FLOW_VS[i]=$(partial_view_state "$FLOW_BODY")
      else
        flow_record "9 order forms submitted" "$i" ingress "$source" WRONG
        fail "order form $i: $source failed: HTTP $FLOW_CODE $FLOW_STATE"
        status=1
        break
      fi
    done
    (( status == 0 )) || continue
    # The expected total is the sum of the prices the script set while the lines were added. It must
    # match the total of the form (@ViewScoped bean), the confirmation (the order read back through JPA)
    # and the database, read with SQL: the rows in order_line, the sum of unit_price * quantity over
    # these rows and customer_order.total. The @SessionScoped history must hold one order.
    order=$(flow_attr "$FLOW_STATE" order)
    expected=$(cents "${FLOW_CENTS[i]}")
    db="- - -"
    if [[ "$order" =~ ^[0-9]+$ ]]; then db=$(db_order "$order"); fi
    IFS=$'\t' read -r db_lines db_sum db_total <<<"${db:-- - -}"
    printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' "$i" "${order:--}" "${FLOW_LINES[i]}" "$expected" \
      "$(flow_attr "$FLOW_STATE" total)" "$(flow_attr "$FLOW_STATE" stored-lines)" "$(flow_attr "$FLOW_STATE" stored-total)" \
      "${db_lines:--}" "${db_sum:--}" "${db_total:--}" >>"$RUN_DIR/orders.tsv"
    if [[ -n "$order" && "$(flow_attr "$FLOW_STATE" orders)" == 1 ]] \
        && same_number "$(flow_attr "$FLOW_STATE" total)" "$expected" \
        && [[ "$(flow_attr "$FLOW_STATE" stored-lines)" == "${FLOW_LINES[i]}" ]] \
        && same_number "$(flow_attr "$FLOW_STATE" stored-total)" "$expected" \
        && [[ "$db_lines" == "${FLOW_LINES[i]}" ]] && same_number "$db_sum" "$expected" && same_number "$db_total" "$expected"; then
      ok=$((ok + 1))
    else
      fail "order form $i: expected $order with ${FLOW_LINES[i]} lines and total $expected; form: $FLOW_STATE; database (lines, sum of the lines, total): $db"
    fi
  done
  event "9 order forms submitted through the ingress: $ok/$FLOWS orders in the database with every line and the expected total (lines per form: ${FLOW_LINES[*]})"
}

cents() { printf '%d.%02d' $(($1 / 100)) $(($1 % 100)); }

# One submitted order as the database holds it: rows in order_line, sum of unit_price * quantity, customer_order.total
db_order() {
  kc exec deploy/session-scaling-db -c postgres -- psql -U "$DB_USER" -d orders -At -F $'\t' -c \
    "select count(l.id), sum(l.unit_price * l.quantity), o.total from customer_order o join order_line l on l.order_id = o.id where o.id = $1 group by o.id, o.total" \
    2>/dev/null || true
}

# --- checks per step -----------------------------------------------------------------------

# check_cache <step> <writer> <readers...>: every replica holds product 1 in its second-level cache,
# the writer changes the price, every reader must have lost its entry and read the new price
check_cache() {
  local step=$1 writer=$2 pod response ok=0 total=0 cents
  shift 2
  local readers=("$@")
  for pod in "$writer" "${readers[@]}"; do
    curl -s --max-time 10 "http://127.0.0.1:${PF_PORT[$pod]}/product?id=1" >/dev/null || true
    response=$(curl -s --max-time 10 "http://127.0.0.1:${PF_PORT[$pod]}/product?id=1" || true)
    if ! jq -e '.cachedBeforeRead == true' <<<"$response" >/dev/null 2>&1; then
      fail "$step: product 1 is not in the second-level cache of $pod after a read: $response"
    fi
  done
  PRICE_CHANGES=$((PRICE_CHANGES + 1))
  cents=$((690 + PRICE_CHANGES * 10))
  PRICE=$(printf '%d.%02d' $((cents / 100)) $((cents % 100)))
  response=$(curl -s --max-time 10 -X POST "http://127.0.0.1:${PF_PORT[$writer]}/product?id=1&price=$PRICE" || true)
  if ! jq -e --arg p "$PRICE" '.price == ($p | tonumber)' <<<"$response" >/dev/null 2>&1; then
    fail "$step: price change on $writer failed: $response"
  fi
  for pod in "${readers[@]}"; do
    total=$((total + 1))
    response=$(curl -s --max-time 10 "http://127.0.0.1:${PF_PORT[$pod]}/product?id=1" || true)
    if jq -e --arg p "$PRICE" '.cachedBeforeRead == false and .price == ($p | tonumber)' <<<"$response" >/dev/null 2>&1; then
      ok=$((ok + 1))
      printf '%s\t%s\t%s\t%s\t%s\tok\n' "$(now)" "$step" "$writer" "$pod" "$PRICE" >>"$RUN_DIR/cache.tsv"
    else
      printf '%s\t%s\t%s\t%s\t%s\tWRONG\n' "$(now)" "$step" "$writer" "$pod" "$PRICE" >>"$RUN_DIR/cache.tsv"
      fail "$step: $pod did not see the price change of $writer (expected entry invalidated and price $PRICE): $response"
    fi
  done
  CACHE_RESULT="$ok/$total"
}

# check_step <step name> [pods...]: the checks described at the top, on the given (default: all ready) replicas
check_step() {
  local step=$1 pod i response meta code seconds body expected cluster
  shift
  local pods=("$@")
  if (( ${#pods[@]} == 0 )); then mapfile -t pods < <(ready_pods); fi
  local ok=0 total=0 flows_ok=0 flows_total=0 owners="n/a" racks_ok=0 racks_total=0 slowest_read=0 slowest_postback=0 nodes
  nodes=$(nodes_of "${pods[@]}")
  if ! open_forwards "${pods[@]}"; then
    close_forwards
    return 0
  fi

  for pod in "${pods[@]}"; do
    # The replica's own view: its JGroups rack must be the node it runs on
    cluster=$(curl -s --max-time 5 "http://127.0.0.1:${PF_PORT[$pod]}/cluster" || true)
    racks_total=$((racks_total + 1))
    if [[ "$(jq -r .localMember.rack <<<"$cluster" 2>/dev/null)" == "$(pod_node "$pod")" ]]; then
      racks_ok=$((racks_ok + 1))
    else
      fail "$step: rack of $pod is $(jq -r .localMember.rack <<<"$cluster" 2>/dev/null), node is $(pod_node "$pod")"
    fi
    if [[ "$owners" == "n/a" ]]; then
      owners=$(jq -r --arg c "$SESSION_CACHE" '.distributedCaches[] | select(.name == $c)
        | "\(.segmentsWithOwnersOnDistinctNodes)/\(.segments)"' <<<"$cluster" 2>/dev/null || echo "n/a")
      jq -c --arg step "$step" '. + {step: $step}' <<<"$cluster" >>"$RUN_DIR/cluster-views.jsonl" 2>/dev/null || true
      if (( nodes >= 2 )) && [[ "${owners%/*}" != "${owners#*/}" ]]; then
        fail "$step: only $owners segments have their two owners on different nodes"
      fi
    fi
  done

  CACHE_RESULT="n/a"
  if (( ${#pods[@]} >= 2 )); then check_cache "$step" "${pods[@]}"; fi

  for pod in "${pods[@]}"; do
    for ((i = 0; i < SESSIONS; i++)); do
      expected=$((COUNT[i] + 1))
      response=$(curl -s --max-time 10 -w $'\n%{http_code} %{time_total}' -H "Cookie: JSESSIONID=${COOKIE[i]}" \
        "http://127.0.0.1:${PF_PORT[$pod]}/session" || true)
      meta=${response##*$'\n'}
      body=${response%$'\n'*}
      code=${meta% *}
      seconds=${meta#* }
      if greater "$seconds" "$slowest_read"; then slowest_read=$seconds; fi
      total=$((total + 1))
      if [[ "$code" == "200" ]] && jq -e --arg sid "${SESSION_ID[i]}" --arg token "${TOKEN[i]}" \
          --arg pod "$pod" --argjson n "$expected" \
          '.sessionId == $sid and .new == false and .token == $token and .beanToken == $token
           and .requestCount == $n and .beanVisits == $n and .servedBy == $pod' <<<"$body" >/dev/null 2>&1; then
        ok=$((ok + 1))
        COUNT[i]=$expected
        printf '%s\t%s\t%s\t%s\t%s\t%s\tok\n' "$(now)" "$step" "$i" "$pod" "$code" "$seconds" >>"$RUN_DIR/requests.tsv"
      else
        fail "$step: session $i on $pod: HTTP $code $body"
        printf '%s\t%s\t%s\t%s\t%s\t%s\tWRONG\n' "$(now)" "$step" "$i" "$pod" "$code" "$seconds" >>"$RUN_DIR/requests.tsv"
        if jq -e '.requestCount | numbers' <<<"$body" >/dev/null 2>&1; then
          COUNT[i]=$(jq -r .requestCount <<<"$body")
        fi
      fi
    done
    # flows.tsv names the container (pod and restart count), so that the first postbacks of a JVM can be told apart
    FLOW_CONTAINER="$pod#$(kc get pod "$pod" -o jsonpath='{.status.containerStatuses[0].restartCount}' 2>/dev/null || echo '?')"
    for ((i = 0; i < FLOWS; i++)); do
      flows_total=$((flows_total + 1))
      if flow_add_line "$i" "http://127.0.0.1:${PF_PORT[$pod]}" "$step" "$pod" "$pod"; then
        flows_ok=$((flows_ok + 1))
      fi
      if greater "$FLOW_SECONDS" "$slowest_postback"; then slowest_postback=$FLOW_SECONDS; fi
    done
    FLOW_CONTAINER="-"
  done
  close_forwards
  log "$step: ${#pods[@]} replicas on $nodes nodes [$(placement "${pods[@]}")], session reads $ok/$total, Faces postbacks $flows_ok/$flows_total, cache invalidations seen $CACHE_RESULT (price now $PRICE), slowest read ${slowest_read}s, slowest postback ${slowest_postback}s, owners on different nodes $owners segments, rack = node $racks_ok/$racks_total"
  STEP_ROWS+=("| $step | $(date -u +%H:%M:%S) | ${#pods[@]} | $nodes | $ok/$total | $flows_ok/$flows_total | $CACHE_RESULT | $slowest_read | $slowest_postback | $owners | $racks_ok/$racks_total |")
}

# Waits until the HorizontalPodAutoscaler has set at most n replicas and the replicas have settled
wait_for_scale_down() {
  local n=$1 timeout=$2
  wait_until "$timeout" "HPA scales to $n" bash -c "(( \$(kubectl -n $NAMESPACE get deployment $DEPLOYMENT -o jsonpath='{.spec.replicas}') <= $n ))"
  event "5 HPA set the deployment to $(deployment_replicas) replicas at $(clock)"
  wait_until 300 "replicas settled" deployment_settled
}

node_ready() { [[ "$(kubectl get node "$1" -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}')" == "True" ]]; }
node_not_ready() { ! node_ready "$1"; }
# None of the given pods is a ready endpoint of the application service any more
endpoints_without() {
  local names pod
  names=$(kc get endpointslices -l kubernetes.io/service-name="$DEPLOYMENT" -o json \
    | jq -r '.items[].endpoints[]? | select(.conditions.ready == true) | .targetRef.name')
  for pod in "$@"; do
    if grep -qx "$pod" <<<"$names"; then return 1; fi
  done
}

# --- run -------------------------------------------------------------------------------

for tool in "$DOCKER" k3d kubectl curl jq; do
  command -v "$tool" >/dev/null || { echo "missing tool: $tool" >&2; exit 1; }
done
for image in "$IMAGE" ${UPDATE_IMAGE:+"$UPDATE_IMAGE"}; do
  "$DOCKER" image inspect "$image" >/dev/null 2>&1 || { echo "image $image not found, run ./mvnw package jib:dockerBuild" >&2; exit 1; }
done
"$DOCKER" image inspect "${DB_IMAGE%@*}" >/dev/null 2>&1 || "$DOCKER" pull -q "${DB_IMAGE%@*}" >/dev/null

{
  echo "date: $(now)"
  echo "commit: $(git -C "$ROOT_DIR" rev-parse --short HEAD 2>/dev/null || echo unknown)$(git -C "$ROOT_DIR" status --porcelain 2>/dev/null | grep -q . && echo ' plus uncommitted changes' || true)"
  echo "image: $IMAGE $("$DOCKER" image inspect --format '{{.Id}}' "$IMAGE")"
  if [[ -n "$UPDATE_IMAGE" ]]; then echo "update image: $UPDATE_IMAGE $("$DOCKER" image inspect --format '{{.Id}}' "$UPDATE_IMAGE")"; fi
  echo "database image: $DB_IMAGE"
  echo "k3s image: $K3S_IMAGE"
  echo "container engine: $("$DOCKER" version --format '{{.Server.Version}}' 2>/dev/null || "$DOCKER" --version)"
  k3d version
  kubectl version --client 2>/dev/null | head -n 1
} >"$RUN_DIR/versions.txt"

log "creating k3d cluster $CLUSTER ($K3S_IMAGE): 1 server, 3 agents, ingress on $BASE_URL"
k3d cluster create "$CLUSTER" --image "$K3S_IMAGE" --servers 1 --agents 3 \
  --api-port "127.0.0.1:$API_PORT" -p "127.0.0.1:$HTTP_PORT:80@server:0:direct" \
  --k3s-arg "--node-taint=node-role.kubernetes.io/control-plane=true:NoSchedule@server:0" \
  --kubeconfig-update-default=false --kubeconfig-switch-context=false \
  --wait --timeout 300s >>"$RUN_DIR/run.log" 2>&1
k3d kubeconfig get "$CLUSTER" >"$KUBECONFIG"
kubectl wait --for=condition=Ready nodes --all --timeout=180s >/dev/null
kubectl version 2>/dev/null | grep 'Server Version' >>"$RUN_DIR/versions.txt"

# Step 4 stops a whole agent node. CoreDNS, Traefik and metrics-server run as single replicas in k3s;
# they move to the server node (the database stays there through scripts/k3d), so that stopping an
# agent stops only replicas of the application. In production clusters they run highly available.
wait_until 300 "traefik" kubectl -n kube-system get deployment traefik
for component in coredns metrics-server local-path-provisioner traefik; do
  kubectl -n kube-system patch deployment "$component" --type merge -p '{"spec":{"template":{"spec":{
    "nodeSelector":{"node-role.kubernetes.io/control-plane":"true"},
    "tolerations":[{"key":"node-role.kubernetes.io/control-plane","operator":"Exists","effect":"NoSchedule"},
                   {"key":"CriticalAddonsOnly","operator":"Exists"}]}}}}' >/dev/null
done
for component in coredns metrics-server local-path-provisioner traefik; do
  kubectl -n kube-system rollout status deployment "$component" --timeout=300s >/dev/null
done
wait_until 300 "metrics API" kubectl top nodes

log "importing $IMAGE${UPDATE_IMAGE:+, $UPDATE_IMAGE} and $DB_IMAGE into the cluster"
k3d image import "$IMAGE" ${UPDATE_IMAGE:+"$UPDATE_IMAGE"} -c "$CLUSTER" >>"$RUN_DIR/run.log" 2>&1
# By tag: k3d cannot import a reference with digest. If the nodes do not find the digest, they pull the image.
k3d image import "${DB_IMAGE%@*}" -c "$CLUSTER" >>"$RUN_DIR/run.log" 2>&1 || log "import of ${DB_IMAGE%@*} failed; the nodes pull it"

log "deploying k8s/ (through scripts/k3d: the database runs on the server node)"
kubectl apply -f "$ROOT_DIR/k8s/namespace.yaml" >>"$RUN_DIR/run.log"
# The database credentials exist only in the cluster, not in the repository
kc create secret generic session-scaling-db --from-literal=username="$DB_USER" \
  --from-literal=password="$(head -c 24 /dev/urandom | od -An -tx1 | tr -d ' \n')" >/dev/null
kubectl apply -k "$ROOT_DIR/scripts/k3d" >>"$RUN_DIR/run.log"
start_background
kc rollout status deployment/session-scaling-db --timeout=300s >/dev/null
wait_until 300 "two replicas" replicas_settled 2
kc exec "deploy/$DEPLOYMENT" -c "$CONTAINER" -- java -version 2>&1 | head -n 1 | sed 's/^/java: /' >>"$RUN_DIR/versions.txt"
grep -h -o 'WFLYSRV0025: [^(]*' "$RUN_DIR"/logs/*.log | head -n 1 | sed 's/^/server: /' >>"$RUN_DIR/versions.txt" || true
kc exec deploy/session-scaling-db -- postgres --version | sed 's/^/database: /' >>"$RUN_DIR/versions.txt" || true
wait_until 120 "HPA metrics" bash -c "kubectl -n $NAMESPACE get hpa $DEPLOYMENT -o jsonpath='{.status.currentMetrics[0].resource.current.averageUtilization}' | grep -q '[0-9]'"

# 1. baseline
create_sessions
start_flows
probe_ingress & BACKGROUND_PIDS+=($!)
log "reading one more servlet session through the ingress twice a second until the end (ingress-probe.tsv)"
check_step "1 two replicas"

# 2. scale-up under load
log "starting CPU load with $LOAD_WORKERS workers on /load"
LOAD_START=$(epoch)
start_load
wait_for_up() { [[ "$(deployment_replicas)" == "4" ]]; }
wait_until 300 "HPA scales up to 4" wait_for_up
event "2 HPA set the deployment to 4 replicas $(since "$LOAD_START") s after the load started: $(hpa_line)"
SCALE_UP=$(epoch)
wait_until 300 "four replicas settled" replicas_settled 4
event "2 the two new replicas were ready and members of the cluster $(since "$SCALE_UP") s after the HPA decision was seen"
stop_load
log "load stopped; the scale-down stabilization window (300 s) starts"
check_step "2 HPA scale-up"

# 3. drain the node with the most replicas
mapfile -t PODS < <(ready_pods)
DRAIN_NODE=$(for pod in "${PODS[@]}"; do pod_node "$pod"; echo; done | grep . | sort | uniq -c | sort -rn | awk 'NR==1 {print $2}')
log "draining $DRAIN_NODE ($(for pod in "${PODS[@]}"; do if [[ "$(pod_node "$pod")" == "$DRAIN_NODE" ]]; then echo -n "$pod "; fi; done))"
kubectl drain "$DRAIN_NODE" --pod-selector="$APP_LABEL" --ignore-daemonsets --delete-emptydir-data --timeout=300s \
  2>&1 | while IFS= read -r line; do printf '%s %s\n' "$(now)" "$line"; done >"$RUN_DIR/drain.log"
event "3 drain of $DRAIN_NODE finished: $(grep -c 'disruption budget' "$RUN_DIR/drain.log" || true) evictions refused by the PodDisruptionBudget until a replacement was ready"
wait_until 300 "four replicas settled after drain" replicas_settled 4
check_step "3 node drain"
kubectl uncordon "$DRAIN_NODE" >/dev/null

# 4. stop the node with the most replicas: every process on it is killed at once, nothing shuts down
mapfile -t PODS < <(ready_pods)
STOP_NODE=$(for pod in "${PODS[@]}"; do pod_node "$pod"; echo; done | grep . | sort | uniq -c | sort -rn | awk 'NR==1 {print $2}')
VICTIMS=()
SURVIVORS=()
for pod in "${PODS[@]}"; do
  if [[ "$(pod_node "$pod")" == "$STOP_NODE" ]]; then VICTIMS+=("$pod"); else SURVIVORS+=("$pod"); fi
done
log "stopping node $STOP_NODE with docker kill (the k3d node container): replicas ${VICTIMS[*]} die without shutdown"
for pod in "${VICTIMS[@]}"; do printf '%s\t%s\n' "$pod" "$(epoch)" >>"$KILLED"; done
NODE_STOP=$(epoch)
"$DOCKER" kill "$STOP_NODE" >/dev/null
STOPPED_NODE=$STOP_NODE
event "4 node $STOP_NODE stopped at $(clock) with replicas ${VICTIMS[*]}; the remaining replicas run on $(nodes_of "${SURVIVORS[@]}") node(s): $(placement "${SURVIVORS[@]}")"
wait_until 180 "view of the remaining replicas" view_excludes "${SURVIVORS[0]}" "${VICTIMS[@]}"
event "4 the remaining replicas had a settled view without the stopped replicas $(since "$NODE_STOP") s after the stop"
check_step "4 node stopped" "${SURVIVORS[@]}"
wait_until 300 "node NotReady" node_not_ready "$STOP_NODE"
event "4 Kubernetes reported $STOP_NODE NotReady $(since "$NODE_STOP") s after the stop"
wait_until 300 "endpoints without the stopped replicas" endpoints_without "${VICTIMS[@]}"
event "4 the service had no ready endpoints on the stopped node any more $(since "$NODE_STOP") s after the stop"
log "starting node $STOP_NODE again"
"$DOCKER" start "$STOP_NODE" >/dev/null
STOPPED_NODE=""
NODE_START=$(epoch)
wait_until 300 "node Ready" node_ready "$STOP_NODE"
event "4 node $STOP_NODE Ready again $(since "$NODE_START") s after the start"
wait_until 420 "replicas settled after the node came back" deployment_settled
event "4 all $(deployment_replicas) replicas ready and members of the cluster $(since "$NODE_START") s after the node start, $(since "$NODE_STOP") s after the stop"
check_step "4b node started again"

# 5. scale-down, one pod per minute
log "waiting for the HPA to scale down (stabilization window, then one pod per minute)"
wait_for_scale_down 3 900
check_step "5a HPA scale-down to 3"
wait_for_scale_down 2 900
check_step "5b HPA scale-down to 2"

# 6. rolling update: one new pod at a time (maxSurge 1, maxUnavailable 0)
ROLLOUT_START=$(epoch)
if [[ -n "$UPDATE_IMAGE" ]]; then
  log "rolling update to $UPDATE_IMAGE"
  kc set image "deployment/$DEPLOYMENT" "$CONTAINER=$UPDATE_IMAGE" >/dev/null
else
  log "rolling update (restart with the same image)"
  kc rollout restart "deployment/$DEPLOYMENT" >/dev/null
fi
kc rollout status "deployment/$DEPLOYMENT" --timeout=600s >/dev/null
wait_until 300 "replicas settled after the rolling update" deployment_settled
event "6 rolling update finished after $(since "$ROLLOUT_START") s"
check_step "6 rolling update"

# 7. delete a pod: SIGTERM, graceful shutdown, replacement
VICTIM=$(ready_pods | head -n 1)
log "deleting pod $VICTIM"
DELETE_START=$SECONDS
kc delete pod "$VICTIM" --wait=false >/dev/null
wait_until 120 "pod $VICTIM gone" bash -c "! kubectl -n $NAMESPACE get pod $VICTIM"
event "7 pod $VICTIM gone after $((SECONDS - DELETE_START)) s (terminationGracePeriodSeconds: 60)"
# From here on the HorizontalPodAutoscaler may change the replica count again (CPU of starting pods)
wait_until 300 "replicas settled after pod deletion" deployment_settled
check_step "7 pod deleted"

# 8. kill the JVM of the replica that served the last postback of order form 0
flow_add_line_ingress 0 "8 JVM killed" || true
VICTIM=$(flow_attr "$FLOW_STATE" served-by)
JVM_PID=$(kc exec "$VICTIM" -c "$CONTAINER" -- cat /tmp/wildfly.pid | tr -dc '0-9')
log "order form 0 was last served by $VICTIM; killing its JVM (PID $JVM_PID in the container) with SIGKILL"
printf '%s\t%s\n' "$VICTIM" "$(epoch)" >>"$KILLED"
KILL_START=$(epoch)
KILL_CLOCK=$(clock)
kc exec "$VICTIM" -c "$CONTAINER" -- sh -c "kill -KILL $JVM_PID" || true
event "8 JVM of $VICTIM killed with SIGKILL: kubectl exec started at $KILL_CLOCK and returned at $(clock); the last answer of $VICTIM (order form 0) had arrived at $(awk -F'\t' '$9 != "" { t = $1 } END { print substr(t, 12, 12) }' "$RUN_DIR/flows.tsv")"
LOST_LINE_PRICE=$PRICE
flow_add_line_ingress 0 "8 JVM killed" || true
LOST_LINE_PRICE=""
if [[ "$LAST_CHANGE_LOST" == true ]]; then
  OUTCOME="the line added by the last answer of $VICTIM was missing: its session write to the other owner had not ended when the JVM died; the view and every earlier line were there"
else
  OUTCOME="with every line, including the one added by the last answer of $VICTIM"
fi
event "8 order form 0 continued through the ingress on $(flow_attr "$FLOW_STATE" served-by) $(since "$KILL_START") s after the kill ($ATTEMPTS attempt(s); view $(flow_attr "$FLOW_STATE" view) created by $(flow_attr "$FLOW_STATE" created-by), ${FLOW_LINES[0]} lines, $OUTCOME)"
mapfile -t SURVIVORS < <(ready_pods | grep -vx "$VICTIM" || true)
wait_until 120 "view without the killed replica" view_excludes "${SURVIVORS[0]}" "$VICTIM"
event "8 the remaining replicas had a settled view without $VICTIM $(since "$KILL_START") s after the kill"
check_step "8 JVM killed" "${SURVIVORS[@]}"
wait_until 300 "replicas settled after the restart" deployment_settled
event "8 container of $VICTIM restarted, ready and member of the cluster $(since "$KILL_START") s after the kill"
check_step "8b JVM restarted"

# 9. complete every order form through the ingress
finish_flows

# Without a cookie there is no session
code=$(curl -s -o /dev/null -w '%{http_code}' "$BASE_URL/session")
[[ "$code" == "404" ]] || fail "GET /session without cookie returned $code"

sleep 3
report

if (( FAILURES > 0 )); then
  log "RESULT: FAILED ($FAILURES failures), details in $SHOWN_RUN_DIR"
  exit 1
fi
log "RESULT: PASSED, details in $SHOWN_RUN_DIR"
