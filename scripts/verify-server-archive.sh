#!/usr/bin/env bash
#
# Checks the server archive that the build writes next to the image
# (image/target/wildfly-session-scaling-server-<version>.tar.gz) as an installation without Kubernetes:
#
#   1  the archive holds the start scripts for Linux and Windows (bin/standalone.sh, bin/standalone.bat)
#   2  its files are those of /opt/server in the image, with the same content (SHA-256 of every file)
#   3  unpacked, bin/standalone.sh starts the server until /health/ready returns HTTP 200 (as for the
#      readiness probe on Kubernetes); a servlet session is created and read, the order form answers
#   4  SIGTERM stops the server (WFLYSRV0050)
#
# Step 3 runs the unpacked directory with the JRE of the image's base image in a plain container, so
# that the host needs no Java; the container gets the unpacked directory and nothing of the image. The
# server runs as the calling user (user 1001, as in the image, when the script runs as root) and writes
# its data, temp and log directories into the unpacked directory, as an installation on a host does. No database is started: the session servlet and the
# first page of the order form do not need one.
#
#   scripts/verify-server-archive.sh [image]
#
# Requires docker (or a compatible CLI, see DOCKER), tar, sha256sum, curl and jq. Build first:
#   ./mvnw package jib:dockerBuild
# Settings (environment variables): ARCHIVE, RUN_DIR (output directory), DOCKER (container CLI).

set -Eeuo pipefail

IMAGE="${1:-wildfly-session-scaling:1.0.0-SNAPSHOT}"
DOCKER="${DOCKER:-docker}"
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
VERSION="${IMAGE##*:}"
ARCHIVE="${ARCHIVE:-$ROOT_DIR/image/target/wildfly-session-scaling-server-$VERSION.tar.gz}"
RUN_DIR="${RUN_DIR:-$ROOT_DIR/target/server-archive-$(date -u +%Y%m%dT%H%M%SZ)}"
# The base image of the image (pom.xml, property runtime.image)
JRE_IMAGE=$(sed -n 's:.*<runtime.image>\(.*\)</runtime.image>.*:\1:p' "$ROOT_DIR/pom.xml")

mkdir -p "$RUN_DIR"
RUN_DIR="$(cd "$RUN_DIR" && pwd)"
SHOWN_RUN_DIR="${RUN_DIR#"$ROOT_DIR"/}"
WORK=$(mktemp -d)
CONTAINER_ID=""
FAILURES=0

log() { printf '%s  %s\n' "$(date -u +%H:%M:%S)" "$*" | tee -a "$RUN_DIR/run.log"; }
fail() { log "FAILED: $*"; FAILURES=$((FAILURES + 1)); }

cleanup() {
  local status=$?
  if [[ -n "$CONTAINER_ID" ]]; then "$DOCKER" rm -f "$CONTAINER_ID" >/dev/null 2>&1 || true; fi
  rm -rf "$WORK"
  exit "$status"
}
trap cleanup EXIT

for tool in "$DOCKER" tar sha256sum curl jq; do
  command -v "$tool" >/dev/null || { echo "missing tool: $tool" >&2; exit 1; }
done
[[ -f "$ARCHIVE" ]] || { echo "archive $ARCHIVE not found, run ./mvnw package jib:dockerBuild" >&2; exit 1; }
"$DOCKER" image inspect "$IMAGE" >/dev/null 2>&1 || { echo "image $IMAGE not found" >&2; exit 1; }

{
  echo "date: $(date -u +%Y-%m-%dT%H:%M:%SZ)"
  echo "commit: $(git -C "$ROOT_DIR" rev-parse --short HEAD 2>/dev/null || echo unknown)$(git -C "$ROOT_DIR" status --porcelain 2>/dev/null | grep -q . && echo ' plus uncommitted changes' || true)"
  echo "archive: $(basename "$ARCHIVE") $(sha256sum "$ARCHIVE" | cut -c1-64), $(wc -c <"$ARCHIVE") bytes"
  echo "image: $IMAGE $("$DOCKER" image inspect --format '{{.Id}}' "$IMAGE")"
  echo "JRE image for the start: $JRE_IMAGE"
} >"$RUN_DIR/versions.txt"

# 1. Unpack; the archive has one base directory
mkdir -p "$WORK/archive"
tar -xzf "$ARCHIVE" -C "$WORK/archive"
SERVER=$(find "$WORK/archive" -mindepth 1 -maxdepth 1 -type d | head -n 1)
log "unpacked $(basename "$ARCHIVE") ($(du -sb "$SERVER" | cut -f1) bytes, $(find "$SERVER" -type f | wc -l) files)"
for script in bin/standalone.sh bin/standalone.bat; do
  if [[ -f "$SERVER/$script" ]]; then log "start script $script: present"; else fail "start script $script missing"; fi
done
[[ -x "$SERVER/bin/standalone.sh" ]] || fail "bin/standalone.sh is not executable"
ls "$SERVER/bin" >"$RUN_DIR/bin.txt"

# 2. Same files with the same content as /opt/server in the image
checksums() { (cd "$1" && find . -type f -print0 | sort -z | xargs -0 sha256sum); }
checksums "$SERVER" >"$RUN_DIR/archive.sha256"
container=$("$DOCKER" create "$IMAGE")
mkdir -p "$WORK/image"
"$DOCKER" cp "$container:/opt/server" "$WORK/image/server" >/dev/null
"$DOCKER" rm "$container" >/dev/null
checksums "$WORK/image/server" >"$RUN_DIR/image.sha256"
if diff "$RUN_DIR/archive.sha256" "$RUN_DIR/image.sha256" >"$RUN_DIR/difference.txt"; then
  log "archive and /opt/server in $IMAGE: $(wc -l <"$RUN_DIR/archive.sha256") files, identical names and content"
  rm -f "$RUN_DIR/difference.txt" "$RUN_DIR/image.sha256"
else
  fail "archive and /opt/server in $IMAGE differ, see difference.txt"
fi

# 3. Start: bin/standalone.sh in the unpacked directory, as the calling user
mkdir -p "$WORK/run"
cp -a "$SERVER" "$WORK/run/server"
RUN_USER="$(id -u):$(id -g)"
if [[ "$(id -u)" == 0 ]]; then
  # Not as root: the same user as in the image
  RUN_USER=1001:1001
  chown -R "$RUN_USER" "$WORK/run/server"
fi
"$DOCKER" image inspect "$JRE_IMAGE" >/dev/null 2>&1 || "$DOCKER" pull -q "$JRE_IMAGE" >/dev/null
START=$(date +%s.%N)
CONTAINER_ID=$("$DOCKER" run -d --user "$RUN_USER" -v "$WORK/run/server":/srv/wildfly -w /srv/wildfly \
  -p 127.0.0.1::8080 -p 127.0.0.1::9990 \
  -e LAUNCH_JBOSS_IN_BACKGROUND=true -e JGROUPS_DNS_QUERY=localhost -e NODE_NAME=archive-check \
  -e POSTGRESQL_HOST=localhost -e POSTGRESQL_DATABASE=orders -e POSTGRESQL_USER=orders -e POSTGRESQL_PASSWORD=unused \
  --entrypoint /srv/wildfly/bin/standalone.sh "$JRE_IMAGE" -b=0.0.0.0 -bmanagement=0.0.0.0)
HTTP="127.0.0.1:$("$DOCKER" port "$CONTAINER_ID" 8080/tcp | head -n 1 | sed 's/.*://')"
MANAGEMENT="127.0.0.1:$("$DOCKER" port "$CONTAINER_ID" 9990/tcp | head -n 1 | sed 's/.*://')"
log "started bin/standalone.sh in $JRE_IMAGE as user $RUN_USER (container ${CONTAINER_ID:0:12}), HTTP $HTTP, management $MANAGEMENT"
# Ready as for the readiness probe in k8s/deployment.yaml: HTTP 200 from /health/ready
ready=""
for _ in $(seq 120); do
  if [[ "$(curl -s -o /dev/null -w '%{http_code}' --max-time 2 "http://$MANAGEMENT/health/ready" || true)" == 200 ]]; then
    ready=$(awk -v a="$START" -v b="$(date +%s.%N)" 'BEGIN { printf "%.1f", b - a }')
    break
  fi
  sleep 1
done
curl -s --max-time 5 "http://$MANAGEMENT/health/ready" >"$RUN_DIR/health-ready.json" || true
if [[ -n "$ready" ]]; then
  log "/health/ready returned HTTP 200 ${ready} s after docker run; $("$DOCKER" logs "$CONTAINER_ID" 2>&1 | grep -o 'WFLYSRV0025: .*' | head -n 1)"
  body=$(curl -s -c "$WORK/jar" -X POST "http://$HTTP/session")
  read1=$(curl -s -b "$WORK/jar" "http://$HTTP/session")
  if jq -e --argjson c "$body" '.sessionId == $c.sessionId and .requestCount == 2 and .beanVisits == 2 and .token == $c.token' \
      <<<"$read1" >/dev/null 2>&1; then
    log "servlet session created and read: $(jq -c '{sessionId, requestCount, beanVisits}' <<<"$read1")"
  else
    fail "servlet session: $body / $read1"
  fi
  page=$(curl -s -w '\n%{http_code}' "http://$HTTP/order.xhtml")
  if [[ "${page##*$'\n'}" == 200 ]] && grep -q 'id="flow-state" data-step="1"' <<<"$page"; then
    log "order form: HTTP 200, step 1"
  else
    fail "order form: HTTP ${page##*$'\n'}"
  fi
else
  fail "/health/ready did not return HTTP 200 within 120 s: $(cat "$RUN_DIR/health-ready.json")"
fi

# 4. SIGTERM, as a service manager sends it
"$DOCKER" stop -t 30 "$CONTAINER_ID" >/dev/null
"$DOCKER" logs "$CONTAINER_ID" >"$RUN_DIR/server.log" 2>&1
"$DOCKER" rm "$CONTAINER_ID" >/dev/null
CONTAINER_ID=""
if grep -q 'WFLYSRV0050' "$RUN_DIR/server.log"; then
  log "stopped with SIGTERM: $(grep -o 'WFLYSRV0050: .*' "$RUN_DIR/server.log" | head -n 1)"
else
  fail "no WFLYSRV0050 after SIGTERM"
fi

if (( FAILURES > 0 )); then
  log "RESULT: FAILED ($FAILURES failures), details in $SHOWN_RUN_DIR"
  exit 1
fi
log "RESULT: PASSED, details in $SHOWN_RUN_DIR"
