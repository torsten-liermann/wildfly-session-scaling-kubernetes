#!/usr/bin/env bash
#
# leave-cycles.sh <label> <image> <cycles> <seconds to observe after each leave> [docker run arguments for all members...]
#
# Diagnostics for the latency of session requests after a cluster member leaves. Runs plain Docker
# containers of the demo image, no Kubernetes:
#
#   - members a and b stay for the whole experiment; 25 sessions are created on them
#   - a background loop reads every session on a and on b, about five reads per second, and checks the
#     request counters (reads.tsv: time, member, session, HTTP status, seconds, ok/WRONG)
#   - in every cycle a new member (c1, c2, ...) joins with a new IP address, as a new pod would, and is
#     stopped with SIGTERM (graceful shutdown) while the reads go on
#   - UNICAST3 retransmissions and unacknowledged messages of a and b are sampled before and after each
#     leave (unicast3.tsv), TCP sockets in state SYN-SENT of a and b are sampled after each leave
#     (syn-sent.txt), and in the first cycle three thread dumps of a are taken (a.log)
#
# Members discover each other with DNS_PING through the Docker network alias wssk-discovery.
# Requires docker, curl, jq, nsenter and ss on the host, and the Docker network wssk-diag-net
# (docker network create --subnet 172.31.250.0/24 wssk-diag-net).

set -u
LABEL=$1; IMAGE=$2; CYCLES=$3; OBSERVE=$4; shift 4
EXTRA=("$@")
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
OUT=${OUT_ROOT:-$DIR/out}/$LABEL
mkdir -p "$OUT"; : > "$OUT/reads.tsv"; : > "$OUT/unicast3.tsv"; : > "$OUT/syn-sent.txt"; rm -f "$OUT/stop"
NET=172.31.250
declare -A IP=([a]=$NET.11 [b]=$NET.12)

ts() { date -u +%H:%M:%S.%3N; }
log() { echo "$(ts) $*" | tee -a "$OUT/exp.log"; }

# start <member> <ip>
start() {
  docker run -d --name "wssk-diag-$1" --network wssk-diag-net --ip "$2" --network-alias wssk-discovery \
    --memory 768m --read-only --tmpfs /tmp:rw,size=256m,mode=1777 \
    -e "POD_NAME=wssk-diag-$1" -e "NODE_NAME=rack-$1" -e JGROUPS_DNS_QUERY=wssk-discovery "${EXTRA[@]}" \
    "$IMAGE" -b=0.0.0.0 -bmanagement=0.0.0.0 "-bprivate=$2" "-Djboss.node.name=wssk-diag-$1" >/dev/null
}

# cli <member> <operation>: management operation through the CLI module of the image (local authentication)
cli() {
  timeout 60 docker exec "wssk-diag-$1" java -Duser.home=/tmp -jar /opt/server/jboss-modules.jar \
    -mp /opt/server/modules org.jboss.as.cli -c --controller=localhost:9990 --command="$2" 2>/dev/null
}

# unicast3 <member> <tag>: UNICAST3 counters (time, tag, member, retransmissions, unacknowledged, send connections)
unicast3() {
  local r
  r=$(cli "$1" "/subsystem=jgroups/channel=ee/protocol=UNICAST3:read-resource(include-runtime=true)")
  printf '%s\t%s\t%s\t%s\t%s\t%s\n' "$(ts)" "$2" "$1" \
    "$(sed -n 's/.*"num_xmits" => "\([0-9]*\)".*/\1/p' <<<"$r")" \
    "$(sed -n 's/.*"num_unacked_messages" => \([0-9]*\).*/\1/p' <<<"$r")" \
    "$(sed -n 's/.*"num_send_connections" => \([0-9]*\).*/\1/p' <<<"$r")" >>"$OUT/unicast3.tsv"
}

# syn_sent <tag>: five samples of the TCP sockets of a and b that wait for a connection to be established
syn_sent() {
  local m pid n
  for m in a b; do
    pid=$(docker inspect -f '{{.State.Pid}}' "wssk-diag-$m")
    for n in 1 2 3 4 5; do
      echo "$(ts) $1 member $m"
      nsenter -t "$pid" -n ss -tn state syn-sent | tail -n +2
      sleep 0.1
    done
  done >>"$OUT/syn-sent.txt" 2>&1
}

members() {
  curl -sf --max-time 5 "http://${IP[a]}:8080/cluster" \
    | jq -r '.distributedCaches[] | select(.name == "ROOT.war") | if .stable then .members else 0 end' 2>/dev/null
}

wait_members() {
  local end=$((SECONDS + 180))
  until [[ "$(members)" == "$1" ]]; do
    if (( SECONDS > end )); then log "timeout: cluster does not have $1 members"; return 1; fi
    sleep 1
  done
}

# Background: reads the sessions 0..23 round robin, each one on a and then on b, until $OUT/stop exists.
# Every session is read on its primary owner and on the other member; only the second read needs a
# remote lock or read.
read_loop() {
  local i=0 m r meta body ok
  local -a n=("${N[@]}")
  until [[ -e "$OUT/stop" ]]; do
    for m in a b; do
      r=$(curl -s -w $'\n%{http_code} %{time_total}' --max-time 10 -H "Cookie: JSESSIONID=${CK[i]}" "http://${IP[$m]}:8080/session")
      meta=${r##*$'\n'}; body=${r%$'\n'*}; n[i]=$((n[i] + 1))
      if jq -e --argjson n "${n[i]}" '.requestCount == $n and .beanVisits == $n' <<<"$body" >/dev/null 2>&1; then
        ok=ok
      else
        ok=WRONG; n[i]=$(jq -r '.requestCount // 0' <<<"$body" 2>/dev/null || echo 0)
      fi
      printf '%s\t%s\t%s\t%s\t%s\t%s\n' "$(ts)" "$m" "$i" "${meta%% *}" "${meta#* }" "$ok" >>"$OUT/reads.tsv"
    done
    i=$(((i + 1) % 24))
    sleep 0.2
  done
}

cleanup() {
  touch "$OUT/stop"
  [[ -n "${READER:-}" ]] && wait "$READER"
  for m in a b; do docker logs "wssk-diag-$m" >"$OUT/$m.log" 2>&1; done
  docker rm -f wssk-diag-a wssk-diag-b >/dev/null 2>&1
  [[ -n "${c:-}" ]] && docker rm -f "wssk-diag-$c" >/dev/null 2>&1
}
trap cleanup EXIT

log "image $IMAGE $(docker image inspect -f '{{.Id}}' "$IMAGE"), docker arguments: ${EXTRA[*]:-none}"
start a "${IP[a]}"; sleep 3; start b "${IP[b]}"
wait_members 2 || exit 1
declare -a CK N
for i in $(seq 0 24); do
  m=$([[ $((i % 2)) == 0 ]] && echo a || echo b)
  CK[i]=$(curl -s -D - -o /dev/null -X POST "http://${IP[$m]}:8080/session" | tr -d '\r' \
    | sed -n 's/^[Ss]et-[Cc]ookie: JSESSIONID=\([^;]*\).*/\1/p')
  N[i]=1
done
log "created 25 sessions on a and b (0..23 for the read loop, 24 for requests during thread dumps)"
read_loop & READER=$!

for k in $(seq 1 "$CYCLES"); do
  c=c$k
  start "$c" "$NET.$((20 + k))"
  wait_members 3 || exit 1
  log "$c joined (${IP[a]%.*}.$((20 + k)))"
  sleep 10
  unicast3 a "$c before"; unicast3 b "$c before"
  log "stopping $c (SIGTERM)"
  docker stop -t 60 "wssk-diag-$c" >/dev/null
  log "$c stopped"
  docker logs "wssk-diag-$c" >"$OUT/$c.log" 2>&1; docker rm "wssk-diag-$c" >/dev/null
  start_obs=$SECONDS
  unicast3 a "$c +1s"; unicast3 b "$c +1s"
  syn_sent "$c +2s"
  if (( k == 1 )); then
    for n in 1 2 3; do
      curl -s -o /dev/null -w '%{time_total}\n' -H "Cookie: JSESSIONID=${CK[24]}" "http://${IP[a]}:8080/session" \
        >>"$OUT/thread-dump-requests.txt" &
      sleep 0.15; docker kill --signal=QUIT wssk-diag-a >/dev/null; wait $!; sleep 0.5
    done
    log "three thread dumps of a (in a.log)"
  fi
  sleep $((start_obs + 15 - SECONDS > 0 ? start_obs + 15 - SECONDS : 0))
  unicast3 a "$c +15s"; unicast3 b "$c +15s"; syn_sent "$c +15s"
  sleep $((start_obs + OBSERVE - SECONDS > 0 ? start_obs + OBSERVE - SECONDS : 0))
  unicast3 a "$c end"; unicast3 b "$c end"
done
cli a "/subsystem=jgroups/channel=ee/protocol=TCP:read-resource(include-runtime=true)" >"$OUT/tcp-a.txt"
log "done"
