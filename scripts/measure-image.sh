#!/usr/bin/env bash
#
# Size and layers of the demo image, compared with a second build of a new application version.
#
#   scripts/measure-image.sh [image] [image of the next version]
#
# For each layer: its share of the image (JRE base image or this build), the size of its content
# (uncompressed) and the size a registry stores and a node pulls (gzip, as in the image manifest),
# and whether the second image has the same layer. With FULL_DISTRIBUTION=true, the script also
# downloads the full WildFly distribution (release archive) and compares its size with the
# provisioned server in the image.
#
# Requires docker (or a compatible CLI, see DOCKER), jq, tar, gzip and, for FULL_DISTRIBUTION, curl.
# Build both images first:
#   ./mvnw package jib:dockerBuild
#   ./mvnw package jib:dockerBuild -Drevision=1.0.1-SNAPSHOT

set -Eeuo pipefail

IMAGE="${1:-wildfly-session-scaling:1.0.0-SNAPSHOT}"
NEXT_IMAGE="${2:-}"
DOCKER="${DOCKER:-docker}"
FULL_DISTRIBUTION="${FULL_DISTRIBUTION:-false}"
WILDFLY_VERSION="${WILDFLY_VERSION:-42.0.0.Final}"

WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT

mb() { awk -v b="$1" 'BEGIN { printf "%.1f", b / 1000000 }'; }

# layers <image> <dir>: one line per layer: diff ID, uncompressed bytes, gzip bytes, created by
layers() {
  local image=$1 dir=$2 config manifest
  mkdir -p "$dir"
  "$DOCKER" save "$image" | tar -x -C "$dir"
  manifest=$(jq -r '.[0].Config' "$dir/manifest.json")
  config="$dir/$manifest"
  local i=0 diff_id blob created
  # Layers in order; history entries without a layer (ENV, CMD ...) are skipped
  mapfile -t created < <(jq -r '[.history[] | select(.empty_layer != true) | .created_by // .comment // "-"] | .[]' "$config")
  while IFS= read -r blob; do
    diff_id=$(jq -r --argjson i "$i" '.rootfs.diff_ids[$i]' "$config")
    local file="$dir/$blob" raw gz
    if gzip -t "$file" 2>/dev/null; then
      raw=$(gzip -dc "$file" | wc -c)
      gz=$(wc -c <"$file")
    else
      raw=$(wc -c <"$file")
      gz=$(gzip -6 -c "$file" | wc -c)
    fi
    printf '%s\t%s\t%s\t%s\n' "$diff_id" "$raw" "$gz" "$(cut -c1-60 <<<"${created[i]:-?}" | tr '\t' ' ')"
    i=$((i + 1))
  done < <(jq -r '.[0].Layers[]' "$dir/manifest.json")
}

layers "$IMAGE" "$WORK/a" >"$WORK/a.tsv"
if [[ -n "$NEXT_IMAGE" ]]; then layers "$NEXT_IMAGE" "$WORK/b" >"$WORK/b.tsv"; fi

echo "Image $IMAGE ($("$DOCKER" image inspect --format '{{.Id}}' "$IMAGE" | cut -c1-19))"
[[ -n "$NEXT_IMAGE" ]] && echo "compared with $NEXT_IMAGE ($("$DOCKER" image inspect --format '{{.Id}}' "$NEXT_IMAGE" | cut -c1-19))"
echo
printf '| %s | %s | %s | %s | %s |\n' "Layer" "Created by" "Content (MB)" "Compressed (MB)" "${NEXT_IMAGE:+Same in $NEXT_IMAGE}"
echo "| --- | --- | ---: | ---: | --- |"
total_raw=0 total_gz=0 ours_raw=0 ours_gz=0 changed_gz=0 n=0
while IFS=$'\t' read -r diff_id raw gz created; do
  n=$((n + 1))
  same=""
  if [[ -n "$NEXT_IMAGE" ]]; then
    if cut -f1 "$WORK/b.tsv" | grep -qx "$diff_id"; then same=yes; else same=no; changed_gz=$((changed_gz + gz)); fi
  fi
  printf '| %s %s | %s | %s | %s | %s |\n' "$n" "${diff_id:7:12}" "$created" "$(mb "$raw")" "$(mb "$gz")" "$same"
  total_raw=$((total_raw + raw)); total_gz=$((total_gz + gz))
  if [[ "$created" == jib-maven-plugin* ]]; then ours_raw=$((ours_raw + raw)); ours_gz=$((ours_gz + gz)); fi
done <"$WORK/a.tsv"
echo
echo "Total: $(mb "$total_raw") MB content, $(mb "$total_gz") MB compressed;" \
  "added by this build (jib-maven-plugin layers): $(mb "$ours_raw") MB content, $(mb "$ours_gz") MB compressed."
if [[ -n "$NEXT_IMAGE" ]]; then
  echo "Layers of $IMAGE that $NEXT_IMAGE does not share: $(mb "$changed_gz") MB compressed;" \
    "a node that runs $IMAGE pulls only these for $NEXT_IMAGE."
fi

if [[ "$FULL_DISTRIBUTION" == "true" ]]; then
  echo
  # The release archive as linked from wildfly.org (Maven Central has only a .zip of it)
  url="https://github.com/wildfly/wildfly/releases/download/$WILDFLY_VERSION/wildfly-$WILDFLY_VERSION.tar.gz"
  curl -sfL "$url" -o "$WORK/dist.tar.gz" || { echo "download of $url failed" >&2; exit 1; }
  mkdir -p "$WORK/dist"
  tar -xzf "$WORK/dist.tar.gz" -C "$WORK/dist"
  container=$("$DOCKER" create "$IMAGE")
  "$DOCKER" cp "$container:/opt/server" "$WORK/server" >/dev/null
  "$DOCKER" rm "$container" >/dev/null
  echo "Full WildFly $WILDFLY_VERSION distribution: $(mb "$(wc -c <"$WORK/dist.tar.gz")") MB download, $(mb "$(du -sb "$WORK/dist" | cut -f1)") MB unpacked, $(find "$WORK/dist" -name module.xml | wc -l) modules"
  echo "Provisioned server in the image (/opt/server, with the application): $(mb "$(du -sb "$WORK/server" | cut -f1)") MB, $(find "$WORK/server" -name module.xml | wc -l) modules"
fi
