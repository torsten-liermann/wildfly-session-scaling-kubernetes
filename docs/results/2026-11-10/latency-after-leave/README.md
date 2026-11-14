# Slow session requests after a replica leaves

Analysis of 10 November 2026. It explains the latency seen in the
[k3d run of the same day](../run-1/summary.md), shows the cause in a reproduction with plain
Docker containers and measures the change made in
[configure-server.cli](../../../../image/src/main/wildfly/configure-server.cli).

## Observation in the k3d run

Up to the drain, every session read took less than 0.2 s. The first replica to leave, pod
`nrf9n` at 08:21:15.4, was followed by a few slow reads only (7 of the 23 probe reads until
08:21:31 took longer than 0.2 s). After pod `l5hns` had left at 08:21:31.4, most session reads
were slow, but not all: in the checks after the drain and the later steps, 72 of 96, 45 of 72,
24 of 48 and 24 of 48 reads took 0.25 to 1.64 s, the others less than 0.2 s. Requests to
`/load`, which use no session, stayed fast. The durations of the slow reads are not spread
evenly but lie close to multiples of 0.3 s:

| Source | Most frequent durations of slow reads |
| --- | --- |
| [requests.tsv](../run-1/requests.tsv), reads through `kubectl port-forward` | 0.26, 0.56, 0.86, 1.16, 1.46 s |
| [ingress-probe.tsv](../run-1/ingress-probe.tsv), reads through the ingress | 0.36, 0.66, 0.96, 1.26 s |

Pod `l5hns` left the cluster at 08:21:31.4 (ISPN100001 in the logs of the other pods).
Between 08:21:33 and 08:25:31, 165 of 170 probe reads took longer than 0.2 s. The last slow
probe read ended at 08:25:31.2, the next one, at 08:25:31.8, took 0.016 s: the slow phase
ended 240 s after the pod had left. From 08:25:31.7 to 08:26:24.2, all 93 probe reads took at
most 0.103 s. Each later removal (08:26:22, 08:27:23, 08:27:53) was followed by slow reads
again; the run ended at 08:28:22, less than 240 s after the last one.

## Cause

Three settings of JGroups 5.5.8 as configured by WildFly 42.0.0.Final work together:

1. **UNICAST3 keeps resending to a member that has left.** When a member leaves the view,
   UNICAST3 marks its connection entry as closing and removes it only after
   `conn_close_timeout`, by default 240 s
   ([UNICAST3.java#L53](https://github.com/belaban/JGroups/blob/jgroups-5.5.8.Final/src/org/jgroups/protocols/UNICAST3.java#L53)).
   As long as the highest message sent to that member is not acknowledged, the retransmission
   task resends it on every run
   ([L1406–L1430](https://github.com/belaban/JGroups/blob/jgroups-5.5.8.Final/src/org/jgroups/protocols/UNICAST3.java#L1406-L1430)),
   every 100 ms in WildFly
   ([jgroups-defaults.xml#L67–L68](https://github.com/wildfly/wildfly/blob/42.0.0.Final/clustering/jgroups/extension/src/main/resources/jgroups-defaults.xml#L67-L68)).
   Whether a replica still holds such a message when the member leaves depends on timing; in
   the experiments below it was the case after ten of twelve leaves.
2. **Every resend opens a TCP connection to an address that does not answer.** The
   connection to the removed member is closed, so the transport connects again
   ([BaseServer.java#L309–L368](https://github.com/belaban/JGroups/blob/jgroups-5.5.8.Final/src/org/jgroups/blocks/cs/BaseServer.java#L309-L368)).
   The pod and its IP address are gone, nothing answers, and the attempt ends after
   `sock_conn_timeout`, which WildFly sets to 300 ms
   ([jgroups-defaults.xml#L21](https://github.com/wildfly/wildfly/blob/42.0.0.Final/clustering/jgroups/extension/src/main/resources/jgroups-defaults.xml#L21)).
3. **One thread sends all messages of a member.** The default bundler of JGroups 5.5 is
   `per-destination`
   ([TPConfig.java#L121](https://github.com/belaban/JGroups/blob/jgroups-5.5.8.Final/src/org/jgroups/protocols/TPConfig.java#L121))
   with a single sender thread for all destinations
   ([BaseBundler.java#L77](https://github.com/belaban/JGroups/blob/jgroups-5.5.8.Final/src/org/jgroups/protocols/BaseBundler.java#L77),
   [PerDestinationBundler.java#L142–L152](https://github.com/belaban/JGroups/blob/jgroups-5.5.8.Final/src/org/jgroups/protocols/PerDestinationBundler.java#L142-L152)).
   While this thread waits for the connection to the removed member, no other cluster
   message of the replica is sent.

A session request is therefore delayed when, before its response is sent, it needs a message
of the affected replica: a lock, a read of the session or an answer to a replication. It is
also delayed when it waits for the lock that the previous request of the same session still
holds: WildFly 42 closes a session, and writes its changes to the other owner, only after the
response has been committed
([DistributableSession.java#L47–L68](https://github.com/wildfly/wildfly/blob/42.0.0.Final/clustering/web/undertow/src/main/java/org/wildfly/clustering/web/undertow/session/DistributableSession.java#L47-L68)),
and that write can itself wait for the affected replica. Each wait lasts until the connection
attempt running at the time ends, and once more for every further message; that gives the
steps of about 0.3 s. Which requests are affected therefore depends on the replica that serves
them and on the owners of the session (see the split by primary owner below). Requests without
a session send no cluster message and are not affected. After 240 s UNICAST3 removes the entry,
the resending stops, and the requests are fast again.

## Reproduction without Kubernetes

[leave-cycles.sh](leave-cycles.sh) runs the demo image as plain Docker containers on one
Docker network; `DNS_PING` finds the members through a network alias. Members `a` and `b`
stay for the whole experiment and hold 25 sessions. In each cycle a new member `c1`, `c2`, …
joins with a new IP address, as a new pod would, and is stopped with SIGTERM. A background
loop reads every session on `a` and on `b`, about five reads per second, and checks the
request counters. The script also samples UNICAST3 counters through the management CLI,
TCP sockets in state `SYN-SENT`, and takes three thread dumps of `a` in the first cycle.
[analyze-cycles.sh](analyze-cycles.sh) groups the reads by the time since the last leave.

Host: Debian 13, kernel 6.12, Docker 29.9.2. WildFly 42.0.0.Final, JGroups 5.5.8,
Infinispan 16.2.3, Temurin 21.0.13. Images, built on the host with the Maven Wrapper in
`eclipse-temurin:21.0.13_9-jdk-noble`:

| Image | Source | Image ID |
| --- | --- | --- |
| baseline | code of run 1, unchanged | `sha256:8b455021a4e7…` |
| diagnostic | code of run 1 plus [diagnostics.cli](diagnostics.cli): JGroups statistics on, `sock_conn_timeout` and `conn_close_timeout` settable through environment variables, defaults unchanged | `sha256:01a65580878d…` |
| fixed | code of run 1 plus the `conn_close_timeout=5000` line of this change | `sha256:ee69488a9b3f…` |

Each experiment ran the cycle two to four times. Durations are those of single reads;
"last slow read" is the end of the last read slower than 0.25 s after a leave (before a
gap of 10 s without slow reads).

| Experiment | Image | `conn_close_timeout` | `sock_conn_timeout` | Leaves | Leaves followed by resending | Durations of the slow reads | Last slow read after the leave | Reads 30–60 s after a leave slower than 0.2 s |
| --- | --- | --- | --- | --- | --- | --- | --- | --- |
| [baseline](baseline/analysis.txt) | baseline | 240 s | 300 ms | 2 | 2 | 0.30–0.50 s, 0.90–1.00 s, 1.15–1.25 s | 240.6 s, 240.1 s | 75 of 102 |
| [conn-close-timeout-30s](conn-close-timeout-30s/analysis.txt) | diagnostic | 30 s | 300 ms | 3 | 3 | 0.30–0.40 s, 1.15–1.20 s | 30.6 s, 29.9 s, 29.9 s | 1 of 608 |
| [sock-conn-timeout-1000ms](sock-conn-timeout-1000ms/analysis.txt) | diagnostic | 30 s | 1000 ms | 3 | 2 | 1.70–2.05 s, 2.70–3.05 s, 3.70–4.00 s | 31.4 s, 30.4 s | 3 of 621 |
| [fixed](fixed/analysis.txt) | fixed | 5 s | 300 ms | 4 | 3 | 0.30–0.45 s, 1.15–1.20 s | 5.5 s, 5.2 s, 5.2 s | 1 of 735 |

- The slow phase ends when `conn_close_timeout` has passed: after 240 s with the defaults,
  after 30 s with 30 s, after about 5 s with the change.
- The durations follow `sock_conn_timeout`: steps of about 0.3 s with 300 ms, about 1 s
  with 1000 ms.
- After two of the twelve leaves, neither `a` nor `b` resent anything, and no read was slow.
- With the change, all reads from 6 s after a leave were faster than 0.2 s, except three
  single reads of 0.20 to 0.34 s (22.6, 25.4 and 37.3 s after a leave); before the first
  leave, single reads also took up to 0.23 s.

All reads returned the expected session and counters (column `wrong` in the analyses: 0).

### What the samples show

- **Split by primary owner** ([baseline/reads.tsv](baseline/reads.tsv), first cycle,
  11:11:43–11:15:30): sessions 0, 2, 4, … were created on `a`, the others on `b`. WildFly
  generates the ID of a new session so that the creating replica is its primary owner (the
  session cookie carries its route). Reads on `a` of the sessions created on `a`, which need
  no message from another member before the response, were fast: 0 of 99 slower than 0.2 s,
  mean 0.006 s. All other combinations were slow: on `a` the sessions created on `b` (99 of
  99, mean 0.40 s), on `b` the sessions created on `a` (99 of 100, mean 0.35 s) and those
  created on `b` (91 of 99, mean 1.01 s). The read loop reads each session first on `a` and
  right after that on `b`, so a read on `b` can also wait for the lock of the read on `a`.
  Which messages each request waited for was not traced.
- **Thread dumps** ([baseline/a.log](baseline/a.log), first cycle, about 9 s after the leave):
  in all three dumps the thread `pd-bundler` of `a`, the one sender thread of the
  `per-destination` bundler, waits in `Socket.connect`, called by
  `BaseServer.getConnection` from `TCP.send`. In the experiment with the change
  ([fixed/a.log](fixed/a.log)), taken at the same point, the thread waits for messages
  (`WAITING (parking)`).
- **Connection attempts** ([baseline/syn-sent.txt](baseline/syn-sent.txt)): every sample of
  `a` shows a socket in state `SYN-SENT` to the old address of the removed member
  (`172.31.250.21:7600` after the first leave); the local port changes from sample to sample,
  so these are new attempts. The samples of `b` show none, although `b` also resent messages;
  why the attempts of `b` did not wait was not examined. Reads on `b` were slow anyway,
  because they need answers from `a`: in the first baseline window, 197 of 206 reads on `b`
  and 102 of 205 reads on `a` took longer than 0.2 s.
- **UNICAST3 counters** ([baseline/unicast3.tsv](baseline/unicast3.tsv)): the retransmissions
  of `a` rose by 3634 in the first cycle and stopped when the entry was
  removed (3634 in both the last sample of cycle 1 and the first sample of cycle 2); the
  number of send connections fell from 2 to 1. The management CLI takes three to four
  seconds per call, so the samples labelled `+1s` were taken 3 to 4 s (`a`) and 6 to 8 s (`b`)
  after the stop; the times in the file are exact.

## Change

[configure-server.cli](../../../../image/src/main/wildfly/configure-server.cli) now sets

```
/subsystem=jgroups/stack=tcp/protocol=UNICAST3:write-attribute(name=properties, value={conn_close_timeout=5000})
```

5 s is the value of Infinispan's own default stacks for Kubernetes and TCP
([default-jgroups-kubernetes.xml#L52](https://github.com/infinispan/infinispan/blob/16.2.3/core/src/main/resources/org/infinispan/configuration/default-jgroups-kubernetes.xml#L52)).
WildFly 42 does not override the JGroups default of 240 s. With the change, a replica that
holds an unacknowledged message for a removed member stops resending it after five seconds.

Not chosen:

- **A sender thread per destination** (`bundler.use_single_sender_thread=false`) would keep the
  waiting connection away from the messages to the other members. WildFly 42 ignores the
  property and logs `WFLYCLJG0031: Ignoring unrecognized TCP property:
  bundler.use_single_sender_thread` (diagnostic image, for example in
  [conn-close-timeout-30s/a.log](conn-close-timeout-30s/a.log)); WildFly applies properties to the components a protocol
  has when it is created
  ([ProtocolConfigurationResourceDefinitionRegistrar.java#L92–L101](https://github.com/wildfly/wildfly/blob/42.0.0.Final/clustering/jgroups/extension/src/main/java/org/jboss/as/clustering/jgroups/subsystem/ProtocolConfigurationResourceDefinitionRegistrar.java#L92-L101)),
  and the bundler is created later, in `TP.init()`. Not tested.
- **`bundler_type=no-bundler`**: JGroups describes `NoBundler` as "not really meant for
  production". Not tested.
- **A lower `sock_conn_timeout`** shortens each wait but keeps it, and also limits the time for
  connections to members that are alive.

## Limits

- The reproduction runs Docker containers on one host, not Kubernetes. It covers the JGroups
  and Infinispan behaviour. The k3d check with the change, run 2
  ([run 2](../run-2/summary.md)), showed slow answers of the ingress probe mainly
  shortly after a replica had left: of the 65 probe answers whose request ran within 6 s after
  one of the 10 leaves, 22 took longer than 0.2 s (at most 1.79 s); of the other 1207 answers, 25
  (at most 0.55 s). A leave is the first `ISPN100001` ("Node … left the cluster") for a member in
  the container logs; a request ran within 6 s after a leave if it started less than 6 s after the
  leave and ended after it (start: time in `ingress-probe.tsv`, which this script version recorded
  at the end of the request, minus the duration). Later versions of
  [verify-session-scaling.sh](../../../../scripts/verify-session-scaling.sh) compute these numbers
  in the same way (`leave_report`) and write them into the summary of the run.
- With the change, an affected replica is still slow for about five seconds after a member
  has left. In two later k3d runs a remaining replica stayed slow much longer, until it was
  stopped itself: 86 s after the drain in [run 4](../run-4/summary.md) and 37 s
  after a pod deletion in [run 3](../run-3/summary.md), in the latter with
  durations close to 0.35, 0.65 and 0.95 s. Why `conn_close_timeout` did not end these phases was
  not examined; the main README lists the numbers under Limits.
- The wait occurs only while a connection attempt to the old address gets no answer within
  `sock_conn_timeout`. In the Docker reproduction this was the case for `a` (sockets in
  `SYN-SENT`), not visibly for `b`. In the k3d run the sockets were not sampled; the steps of
  0.3 s and the end after 240 s point to the same mechanism.
- Whether a replica is affected at a given leave depends on timing (see Cause, point 1);
  the counts are from a few cycles each.

## Files

| Path | Content |
| --- | --- |
| [leave-cycles.sh](leave-cycles.sh), [analyze-cycles.sh](analyze-cycles.sh) | Experiment and analysis |
| [diagnostics.cli](diagnostics.cli) | Additional CLI lines of the diagnostic image |
| `<experiment>/exp.log` | Course of the experiment |
| `<experiment>/reads.tsv` | Every read: time (UTC), member, session, HTTP status, seconds, counters correct |
| `<experiment>/unicast3.tsv` | UNICAST3 samples: time, sample, member, retransmissions, unacknowledged messages, send connections |
| `<experiment>/syn-sent.txt` | TCP sockets of `a` and `b` in state `SYN-SENT` |
| `<experiment>/a.log`, `b.log`, `c*.log` | Server logs; `a.log` contains the thread dumps of the first cycle |
| `<experiment>/thread-dump-requests.txt` | Durations of the requests sent to `a` during the thread dumps |
| `<experiment>/tcp-a.txt` | Runtime attributes of the TCP transport of `a` (bundler, `sock_conn_timeout`) |
| `<experiment>/leaves.txt`, `analysis.txt` | Leave times from `a.log` and the output of analyze-cycles.sh |
