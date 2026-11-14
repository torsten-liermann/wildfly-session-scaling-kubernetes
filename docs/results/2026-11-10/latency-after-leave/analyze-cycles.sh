#!/usr/bin/env bash
#
# analyze-cycles.sh <output directory of leave-cycles.sh>
#
# 1. Groups the session reads by the time since the most recent leave (taken from the log of a:
#    ISPN100001 "Node ... left the cluster"): number of reads, reads slower than 0.2 s, mean, maximum.
# 2. Per leave: reads slower than 0.25 s after it, and the times of the first and the last of them
#    (the last one before a gap of 10 s without slow reads). Times are those at which a read ended.
# 3. Slow reads in 50 ms bins.
# 4. Per leave: UNICAST3 retransmissions of a and b between the sample before the leave and the last
#    sample of the cycle.
OUT=$1
grep -h 'ISPN100001: Node wssk-diag-c[0-9]* left the cluster' "$OUT/a.log" \
  | awk '{ print substr($2, 1, 12), $(NF - 3) }' | sed 's/,/./' | sort -u -k2,2 | sort >"$OUT/leaves.txt"
echo "Leaves (time in the log of a, member):"; sed 's/^/  /' "$OUT/leaves.txt"
echo
awk -F'\t' -v leaves="$OUT/leaves.txt" '
  function sec(t,  a) { split(t, a, ":"); return a[1] * 3600 + a[2] * 60 + a[3] }
  BEGIN { while ((getline line < leaves) > 0) { split(line, f, " "); L[++nl] = sec(f[1]) } }
  {
    t = sec($1); k = 0
    for (j = 1; j <= nl; j++) if (L[j] <= t) k = j
    if (k == 0) g = "before the first leave"
    else {
      d = t - L[k]
      g = (d < 5) ? "0-5 s after a leave" : (d < 30) ? "5-30 s after a leave" : (d < 60) ? "30-60 s after a leave" : (d < 240) ? "60-240 s after a leave" : "more than 240 s after a leave"
    }
    n[g]++; if ($5 > 0.2) slow[g]++; sum[g] += $5; if ($5 > max[g]) max[g] = $5; if ($6 != "ok") bad[g]++
  }
  END {
    split("before the first leave|0-5 s after a leave|5-30 s after a leave|30-60 s after a leave|60-240 s after a leave|more than 240 s after a leave", order, "|")
    printf "%-31s %6s %8s %8s %8s %6s\n", "Reads", "count", "> 0.2 s", "mean s", "max s", "wrong"
    for (o = 1; o <= 6; o++) { g = order[o]; if (n[g]) printf "%-31s %6d %8d %8.3f %8.3f %6d\n", g, n[g], slow[g], sum[g] / n[g], max[g], bad[g] }
  }' "$OUT/reads.tsv"
echo
echo "Slow reads (> 0.25 s) per leave:"
awk -F'\t' -v leaves="$OUT/leaves.txt" '
  function sec(t,  a) { split(t, a, ":"); return a[1] * 3600 + a[2] * 60 + a[3] }
  BEGIN { while ((getline line < leaves) > 0) { split(line, f, " "); nl++; L[nl] = sec(f[1]); N[nl] = f[2] } }
  $5 > 0.25 {
    t = sec($1); k = 0; for (j = 1; j <= nl; j++) if (L[j] <= t) k = j
    if (k == 0) next
    if (!(k in first)) first[k] = t - L[k]
    if (!(k in last) || t - L[k] - last[k] < 10) { last[k] = t - L[k]; cnt[k]++ }
  }
  END {
    for (k = 1; k <= nl; k++)
      if (cnt[k]) printf "  %s: %d, first %.1f s, last %.1f s after the leave\n", N[k], cnt[k], first[k], last[k]
      else printf "  %s: none\n", N[k]
  }' "$OUT/reads.tsv"
echo
echo "Reads slower than 0.1 s, 50 ms bins (lower bound:count):"
awk -F'\t' '$5 > 0.1 { printf "%.2f\n", int($5 * 20) / 20 }' "$OUT/reads.tsv" | sort -n | uniq -c | awk '{ printf "  %s:%s", $2, $1 } END { print "" }'
echo
echo "UNICAST3 retransmissions per leave (sample before the leave to the last sample of the cycle):"
awk -F'\t' '{ split($2, s, " "); v[s[1], s[2], $3] = $4; cs[s[1]] = 1 }
  END { for (c in cs) printf "  %s: a %d, b %d\n", c, v[c, "end", "a"] - v[c, "before", "a"], v[c, "end", "b"] - v[c, "before", "b"] }' "$OUT/unicast3.tsv" | sort
echo
echo "UNICAST3 samples (time, sample, member, retransmissions, unacknowledged messages, send connections):"
sed 's/^/  /' "$OUT/unicast3.tsv"
