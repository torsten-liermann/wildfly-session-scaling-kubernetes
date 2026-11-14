| Step | Checked (UTC) | Replicas checked | Nodes | Session reads OK | Faces postbacks OK | Cache invalidations seen | Slowest session read (s) | Slowest Faces postback (s) | Segments with owners on different nodes | JGroups rack = node |
| --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- |
| 1 two replicas | 14:08:21 | 2 | 2 | 48/48 | 12/12 | 1/1 | 0.074076 | 0.663847 | 128/128 | 2/2 |
| 2 HPA scale-up | 14:09:25 | 4 | 3 | 96/96 | 24/24 | 3/3 | 0.121149 | 1.282146 | 128/128 | 4/4 |
| 3 node drain | 14:10:36 | 4 | 2 | 96/96 | 24/24 | 3/3 | 0.321116 | 1.434220 | 128/128 | 4/4 |
| 4 node stopped | 14:10:50 | 2 | 1 | 48/48 | 12/12 | 1/1 | 0.383623 | 0.112351 | 0/128 | 2/2 |
| 4b node started again | 14:12:10 | 4 | 2 | 96/96 | 24/24 | 3/3 | 0.163713 | 1.491873 | 128/128 | 4/4 |
| 5a HPA scale-down to 3 | 14:17:00 | 3 | 2 | 72/72 | 18/18 | 2/2 | 0.103915 | 0.183308 | 128/128 | 3/3 |
| 5b HPA scale-down to 2 | 14:17:56 | 2 | 2 | 48/48 | 12/12 | 1/1 | 0.070378 | 0.072102 | 128/128 | 2/2 |
| 6 rolling update | 14:19:05 | 2 | 2 | 48/48 | 12/12 | 1/1 | 0.111678 | 1.538058 | 128/128 | 2/2 |
| 7 pod deleted | 14:19:52 | 2 | 2 | 48/48 | 12/12 | 1/1 | 0.871693 | 1.169853 | 128/128 | 2/2 |
| 8 JVM killed | 14:19:58 | 1 | 1 | 24/24 | 6/6 | n/a | 0.028747 | 0.102257 | 0/128 | 1/1 |
| 8b JVM restarted | 14:20:27 | 2 | 2 | 48/48 | 12/12 | 1/1 | 0.467992 | 1.351727 | 128/128 | 2/2 |

Ingress probe: 1183 requests from 2026-11-10T14:08:13.840Z to 2026-11-10T14:20:35.614Z: 1175 correct, 8 without answer (no response within 5 s, or 502/503/504 from the ingress), 0 wrong; slowest answer 2.463 s

Events:

- 2 HPA set the deployment to 4 replicas 15.1 s after the load started: session-scaling Deployment/session-scaling cpu: 165%/60% 2 4 2 92s
- 2 the two new replicas were ready and members of the cluster 30.1 s after the HPA decision was seen
- 3 drain of k3d-session-scaling-agent-0 finished: 5 evictions refused by the PodDisruptionBudget until a replacement was ready
- 4 node k3d-session-scaling-agent-2 stopped at 14:10:37.805 with replicas session-scaling-85dc458f7f-2fmqj session-scaling-85dc458f7f-65xwn; the remaining replicas run on 1 node(s): jtct6@session-scaling-agent-1 sxljp@session-scaling-agent-1
- 4 the remaining replicas had a settled view without the stopped replicas 5.2 s after the stop
- 4 Kubernetes reported k3d-session-scaling-agent-2 NotReady 44.7 s after the stop
- 4 the service had no ready endpoints on the stopped node any more 44.8 s after the stop
- 4 node k3d-session-scaling-agent-2 Ready again 4.4 s after the start
- 4 all 4 replicas ready and members of the cluster 28.5 s after the node start, 73.7 s after the stop
- 5 HPA set the deployment to 3 replicas at 14:16:37.355
- 5 HPA set the deployment to 2 replicas at 14:17:38.354
- 6 rolling update finished after 55.6 s
- 7 pod session-scaling-66c7888bb4-6xknt gone after 13 s (terminationGracePeriodSeconds: 60)
- 8 JVM of session-scaling-66c7888bb4-lp9r8 killed with SIGKILL: kubectl exec started at 14:19:53.451 and returned at 14:19:53.683; the last answer of session-scaling-66c7888bb4-lp9r8 (order form 0) had arrived at 14:19:53.243
- 8 order form 0 continued through the ingress on session-scaling-66c7888bb4-m2kcf 1.9 s after the kill (2 attempt(s); view fcee3737-7d6d-4e85-8f28-281d590c3cdd created by session-scaling-85dc458f7f-jtct6, 26 lines)
- 8 the remaining replicas had a settled view without session-scaling-66c7888bb4-lp9r8 2.2 s after the kill
- 8 container of session-scaling-66c7888bb4-lp9r8 restarted, ready and member of the cluster 24.4 s after the kill
- 9 order forms submitted through the ingress: 6/6 orders in the database with every line and the expected total (lines per form: 29 28 28 28 28 28)

Container starts (pod, restarts, node, created, container started, ready, started to ready in s, created to ready in s, WildFly boot in ms):

    session-scaling-85dc458f7f-jtct6	0	session-scaling-agent-1	2026-11-10T14:07:06Z	2026-11-10T14:07:06Z	2026-11-10T14:07:27Z	21	21	19217
    session-scaling-85dc458f7f-vp2vc	0	session-scaling-agent-0	2026-11-10T14:07:05Z	2026-11-10T14:07:06Z	2026-11-10T14:07:29Z	23	24	20204
    session-scaling-85dc458f7f-2fmqj	0	session-scaling-agent-2	2026-11-10T14:08:36Z	2026-11-10T14:08:37Z	2026-11-10T14:09:04Z	27	28	22947
    session-scaling-85dc458f7f-nk6br	0	session-scaling-agent-0	2026-11-10T14:08:36Z	2026-11-10T14:08:37Z	2026-11-10T14:09:04Z	27	28	25253
    session-scaling-85dc458f7f-sxljp	0	session-scaling-agent-1	2026-11-10T14:09:27Z	2026-11-10T14:09:28Z	2026-11-10T14:09:48Z	20	21	16591
    session-scaling-85dc458f7f-65xwn	0	session-scaling-agent-2	2026-11-10T14:09:52Z	2026-11-10T14:09:53Z	2026-11-10T14:10:14Z	21	22	16416
    session-scaling-85dc458f7f-2fmqj	1	session-scaling-agent-2	2026-11-10T14:08:36Z	2026-11-10T14:11:28Z	2026-11-10T14:11:49Z	21	-	17082
    session-scaling-85dc458f7f-65xwn	1	session-scaling-agent-2	2026-11-10T14:09:52Z	2026-11-10T14:11:28Z	2026-11-10T14:11:48Z	20	-	16917
    session-scaling-66c7888bb4-6xknt	0	session-scaling-agent-0	2026-11-10T14:17:56Z	2026-11-10T14:17:57Z	2026-11-10T14:18:18Z	21	22	17915
    session-scaling-66c7888bb4-lp9r8	0	session-scaling-agent-1	2026-11-10T14:18:18Z	2026-11-10T14:18:19Z	2026-11-10T14:18:39Z	20	21	17620
    session-scaling-66c7888bb4-m2kcf	0	session-scaling-agent-2	2026-11-10T14:19:06Z	2026-11-10T14:19:06Z	2026-11-10T14:19:27Z	21	21	17565
    session-scaling-66c7888bb4-lp9r8	1	session-scaling-agent-1	2026-11-10T14:18:18Z	2026-11-10T14:19:54Z	2026-11-10T14:20:15Z	21	-	16224

Pods stopped with SIGTERM (pod, WFLYSRV0211 suspend, WFLYSRV0220 OS signal, WFLYSRV0050 stopped):

    session-scaling-66c7888bb4-6xknt	1	1	WFLYSRV0050: WildFly 42.0.0.Final (WildFly Core 34.0.0.Final) stopped in 239ms
    session-scaling-85dc458f7f-2fmqj.restart-1	1	1	WFLYSRV0050: WildFly 42.0.0.Final (WildFly Core 34.0.0.Final) stopped in 682ms
    session-scaling-85dc458f7f-65xwn.restart-1	1	1	WFLYSRV0050: WildFly 42.0.0.Final (WildFly Core 34.0.0.Final) stopped in 363ms
    session-scaling-85dc458f7f-jtct6	1	1	WFLYSRV0050: WildFly 42.0.0.Final (WildFly Core 34.0.0.Final) stopped in 226ms
    session-scaling-85dc458f7f-nk6br	1	1	WFLYSRV0050: WildFly 42.0.0.Final (WildFly Core 34.0.0.Final) stopped in 439ms
    session-scaling-85dc458f7f-sxljp	1	1	WFLYSRV0050: WildFly 42.0.0.Final (WildFly Core 34.0.0.Final) stopped in 242ms
    session-scaling-85dc458f7f-vp2vc	1	1	WFLYSRV0050: WildFly 42.0.0.Final (WildFly Core 34.0.0.Final) stopped in 326ms

HPA events:

    2026-11-10T14:07:05Z	SuccessfulRescale	New size: 2; reason: Current number of replicas below Spec.MinReplicas
    2026-11-10T14:19:07Z	FailedGetResourceMetric	failed to get cpu utilization: did not receive metrics for targeted pods (pods might be unready)
    2026-11-10T14:19:07Z	FailedComputeMetricsReplicas	invalid metrics (1 invalid out of 1), first error is: failed to get cpu resource metric value: failed to get cpu utilization: did not receive metrics for targeted pods (pods might be unready)
    2026-11-10T14:08:36Z	SuccessfulRescale	New size: 4; reason: cpu resource utilization (percentage of request) above target
    2026-11-10T14:16:36Z	SuccessfulRescale	New size: 3; reason: All metrics below target
    2026-11-10T14:17:37Z	SuccessfulRescale	New size: 2; reason: All metrics below target

Pod samples of the metrics API (top.tsv): 477; CPU at most 3673m; memory 358Mi to 665Mi

Submitted orders (form, order, lines added, expected total; form total; confirmation lines and total; database rows in order_line, sum of unit_price * quantity, customer_order.total):

    0	1	29	215.50	215.50	29	215.50	29	215.50	215.50
    1	2	28	207.70	207.70	28	207.70	28	207.70	207.70
    2	3	28	207.70	207.70	28	207.70	28	207.70	207.70
    3	4	28	207.70	207.70	28	207.70	28	207.70	207.70
    4	5	28	207.70	207.70	28	207.70	28	207.70	207.70
    5	6	28	207.70	207.70	28	207.70	28	207.70	207.70

Leaves (first ISPN100001 per member in the container logs): 10

    2026-11-10T14:09:37.584Z	session-scaling-85dc458f7f-vp2vc
    2026-11-10T14:10:03.256Z	session-scaling-85dc458f7f-nk6br
    2026-11-10T14:10:38.581Z	session-scaling-85dc458f7f-2fmqj
    2026-11-10T14:10:38.581Z	session-scaling-85dc458f7f-65xwn
    2026-11-10T14:16:47.252Z	session-scaling-85dc458f7f-sxljp
    2026-11-10T14:17:47.752Z	session-scaling-85dc458f7f-2fmqj
    2026-11-10T14:18:28.774Z	session-scaling-85dc458f7f-65xwn
    2026-11-10T14:18:50.152Z	session-scaling-85dc458f7f-jtct6
    2026-11-10T14:19:16.246Z	session-scaling-66c7888bb4-6xknt
    2026-11-10T14:19:55.130Z	session-scaling-66c7888bb4-lp9r8

Probe answers whose request ran within 6 s after a leave: 81 answers, 8 of them slower than 0.2 s, slowest 2.462773 s

Other probe answers: 1094 answers, 40 of them slower than 0.2 s, slowest 0.956778 s

Faces postbacks of the per-replica checks slower than 0.2 s: 20 of 168

    14:08:18.161	1 two replicas	session-scaling-85dc458f7f-jtct6#0	postback 1 on this container	0.663847 s
    14:09:14.442	2 HPA scale-up	session-scaling-85dc458f7f-2fmqj#0	postback 1 on this container	1.240634 s
    14:09:21.495	2 HPA scale-up	session-scaling-85dc458f7f-nk6br#0	postback 1 on this container	1.282146 s
    14:09:24.678	2 HPA scale-up	session-scaling-85dc458f7f-vp2vc#0	postback 7 on this container	0.451346 s
    14:10:27.294	3 node drain	session-scaling-85dc458f7f-65xwn#0	postback 1 on this container	1.434220 s
    14:10:34.749	3 node drain	session-scaling-85dc458f7f-sxljp#0	postback 1 on this container	1.321047 s
    14:11:57.832	4b node started again	session-scaling-85dc458f7f-2fmqj#1	postback 1 on this container	1.277992 s
    14:12:02.404	4b node started again	session-scaling-85dc458f7f-65xwn#1	postback 1 on this container	1.491873 s
    14:18:59.203	6 rolling update	session-scaling-66c7888bb4-6xknt#0	postback 1 on this container	1.429719 s
    14:19:00.244	6 rolling update	session-scaling-66c7888bb4-6xknt#0	postback 4 on this container	0.487666 s
    14:19:04.442	6 rolling update	session-scaling-66c7888bb4-lp9r8#0	postback 1 on this container	1.538058 s
    14:19:42.110	7 pod deleted	session-scaling-66c7888bb4-lp9r8#0	postback 7 on this container	0.537928 s
    14:19:42.701	7 pod deleted	session-scaling-66c7888bb4-lp9r8#0	postback 8 on this container	0.479397 s
    14:19:43.329	7 pod deleted	session-scaling-66c7888bb4-lp9r8#0	postback 9 on this container	0.501058 s
    14:19:44.187	7 pod deleted	session-scaling-66c7888bb4-lp9r8#0	postback 12 on this container	0.418754 s
    14:19:50.821	7 pod deleted	session-scaling-66c7888bb4-m2kcf#0	postback 1 on this container	1.169853 s
    14:19:51.763	7 pod deleted	session-scaling-66c7888bb4-m2kcf#0	postback 4 on this container	0.406031 s
    14:19:52.367	7 pod deleted	session-scaling-66c7888bb4-m2kcf#0	postback 5 on this container	0.507442 s
    14:20:23.161	8b JVM restarted	session-scaling-66c7888bb4-lp9r8#1	postback 1 on this container	1.351727 s
    14:20:23.934	8b JVM restarted	session-scaling-66c7888bb4-lp9r8#1	postback 3 on this container	0.458427 s

Faces requests through the ingress slower than 0.2 s: 6 of 27

    14:08:10.489	1 two replicas	form 0	open	ok	0.695888 s
    14:08:12.604	1 two replicas	form 0	customer	ok	2.048303 s
    14:19:53.243	8 JVM killed	form 0	add-line	ok	0.399805 s
    14:19:55.283	8 JVM killed	form 0	add-line	WRONG	0.427462 s
    14:20:28.549	9 order forms submitted	form 0	submit	ok	0.377789 s
    14:20:30.165	9 order forms submitted	form 2	submit	ok	0.375117 s

WARN and ERROR messages in the container logs (count, level, message code or logger and text):

    12	WARN	WFLYCLJG0039
    12	WARN	WFLYCLJG0040
    12	WARN	WFLYSRV0018
    12	WARN	WFLYTX0013
    6	WARN	ISPN000314
    2	ERROR	org.jgroups.protocols.TCP: <address>: failed sending graceful close to <address>: Broken pipe
    2	ERROR	org.jgroups.protocols.TCP: <address>: failed sending graceful close to <address>: Socket closed
    2	WARN	ISPN000312
    1	WARN	ISPN000100
    1	WARN	org.jgroups.protocols.TCP: <address>: failed handling message: java.io.IOException: Stream closed

Container logs fetched completely at the end (the others are the followed logs): session-scaling-66c7888bb4-lp9r8.restart-1.log session-scaling-66c7888bb4-lp9r8.log session-scaling-66c7888bb4-m2kcf.log

Failures: 1
