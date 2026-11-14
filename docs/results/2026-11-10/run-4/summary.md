| Step | Checked (UTC) | Replicas checked | Nodes | Session reads OK | Faces postbacks OK | Cache invalidations seen | Slowest session read (s) | Slowest Faces postback (s) | Segments with owners on different nodes | JGroups rack = node |
| --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- |
| 1 two replicas | 14:29:12 | 2 | 2 | 48/48 | 12/12 | 1/1 | 0.086313 | 0.639029 | 128/128 | 2/2 |
| 2 HPA scale-up | 14:30:32 | 4 | 3 | 96/96 | 24/24 | 3/3 | 0.381485 | 1.411287 | 128/128 | 4/4 |
| 3 node drain | 14:32:12 | 4 | 2 | 96/96 | 24/24 | 3/3 | 1.198960 | 1.242164 | 128/128 | 4/4 |
| 4 node stopped | 14:32:25 | 2 | 1 | 48/48 | 12/12 | 1/1 | 0.069181 | 0.531971 | 0/128 | 2/2 |
| 4b node started again | 14:33:55 | 4 | 2 | 96/96 | 24/24 | 3/3 | 0.183940 | 1.400892 | 128/128 | 4/4 |
| 5a HPA scale-down to 3 | 14:39:37 | 3 | 2 | 72/72 | 18/18 | 2/2 | 0.097111 | 0.131445 | 128/128 | 3/3 |
| 5b HPA scale-down to 2 | 14:40:34 | 2 | 2 | 48/48 | 12/12 | 1/1 | 0.813754 | 0.449515 | 128/128 | 2/2 |
| 6 rolling update | 14:41:37 | 2 | 2 | 48/48 | 12/12 | 1/1 | 0.077216 | 1.846228 | 128/128 | 2/2 |
| 7 pod deleted | 14:42:11 | 2 | 2 | 48/48 | 12/12 | 1/1 | 0.091626 | 1.511225 | 128/128 | 2/2 |
| 8 JVM killed | 14:42:17 | 1 | 1 | 24/24 | 6/6 | n/a | 0.033982 | 0.082911 | 0/128 | 1/1 |
| 8b JVM restarted | 14:42:45 | 2 | 2 | 48/48 | 12/12 | 1/1 | 0.077535 | 1.388384 | 128/128 | 2/2 |

Ingress probe: 1275 requests from 2026-11-10T14:29:04.360Z to 2026-11-10T14:42:52.960Z: 1267 correct, 8 without answer (no response within 5 s, or 502/503/504 from the ingress), 0 without the change of the previous answer of a killed replica, 0 wrong; slowest answer 1.846 s

Events:

- 2 HPA set the deployment to 4 replicas 30.3 s after the load started: session-scaling Deployment/session-scaling cpu: 237%/60% 2 4 3 106s
- 2 the two new replicas were ready and members of the cluster 27.7 s after the HPA decision was seen
- 3 drain of k3d-session-scaling-agent-2 finished: 5 evictions refused by the PodDisruptionBudget until a replacement was ready
- 4 node k3d-session-scaling-agent-1 stopped at 14:32:14.427 with replicas session-scaling-85dc458f7f-pntvx session-scaling-85dc458f7f-ztlq7; the remaining replicas run on 1 node(s): 4c96r@session-scaling-agent-0 jfnc5@session-scaling-agent-0
- 4 the remaining replicas had a settled view without the stopped replicas 3.2 s after the stop
- 4 Kubernetes reported k3d-session-scaling-agent-1 NotReady 47.5 s after the stop
- 4 the service had no ready endpoints on the stopped node any more 47.6 s after the stop
- 4 node k3d-session-scaling-agent-1 Ready again 6.5 s after the start
- 4 all 4 replicas ready and members of the cluster 31.1 s after the node start, 79.2 s after the stop
- 5 HPA set the deployment to 3 replicas at 14:39:14.526
- 5 HPA set the deployment to 2 replicas at 14:40:15.762
- 6 rolling update finished after 50.7 s
- 7 pod session-scaling-66c7888bb4-ht8jp gone after 13 s (terminationGracePeriodSeconds: 60)
- 8 JVM of session-scaling-66c7888bb4-vj5m7 killed with SIGKILL: kubectl exec started at 14:42:11.623 and returned at 14:42:11.864; the last answer of session-scaling-66c7888bb4-vj5m7 (order form 0) had arrived at 14:42:11.289
- 8 order form 0 continued through the ingress on session-scaling-66c7888bb4-7bhr9 2.5 s after the kill (2 attempt(s); view 502ffce1-e6d4-4c55-a669-1acf6b1ada70 created by session-scaling-85dc458f7f-vllfp, 27 lines, with every line, including the one added by the last answer of session-scaling-66c7888bb4-vj5m7)
- 8 the remaining replicas had a settled view without session-scaling-66c7888bb4-vj5m7 2.7 s after the kill
- 8 container of session-scaling-66c7888bb4-vj5m7 restarted, ready and member of the cluster 24.8 s after the kill
- 9 order forms submitted through the ingress: 6/6 orders in the database with every line and the expected total (lines per form: 30 28 28 28 28 28)

Container starts (pod, restarts, node, created, container started, ready, started to ready in s, created to ready in s, WildFly boot in ms):

    session-scaling-85dc458f7f-vllfp	0	session-scaling-agent-2	2026-11-10T14:27:57Z	2026-11-10T14:27:57Z	2026-11-10T14:28:23Z	26	26	24204
    session-scaling-85dc458f7f-ztlq7	0	session-scaling-agent-1	2026-11-10T14:27:57Z	2026-11-10T14:27:58Z	2026-11-10T14:28:20Z	22	23	18674
    session-scaling-85dc458f7f-4c96r	0	session-scaling-agent-0	2026-11-10T14:29:27Z	2026-11-10T14:29:28Z	2026-11-10T14:29:49Z	21	22	19397
    session-scaling-85dc458f7f-zvd79	0	session-scaling-agent-2	2026-11-10T14:29:42Z	2026-11-10T14:29:43Z	2026-11-10T14:30:08Z	25	26	21776
    session-scaling-85dc458f7f-jfnc5	0	session-scaling-agent-0	2026-11-10T14:30:33Z	2026-11-10T14:30:34Z	2026-11-10T14:30:54Z	20	21	15997
    session-scaling-85dc458f7f-pntvx	0	session-scaling-agent-1	2026-11-10T14:30:59Z	2026-11-10T14:30:59Z	2026-11-10T14:31:15Z	16	16	14787
    session-scaling-85dc458f7f-pntvx	1	session-scaling-agent-1	2026-11-10T14:30:59Z	2026-11-10T14:33:08Z	2026-11-10T14:33:30Z	22	-	19488
    session-scaling-85dc458f7f-ztlq7	1	session-scaling-agent-1	2026-11-10T14:27:57Z	2026-11-10T14:33:08Z	2026-11-10T14:33:29Z	21	-	19337
    session-scaling-66c7888bb4-vj5m7	0	session-scaling-agent-2	2026-11-10T14:40:34Z	2026-11-10T14:40:35Z	2026-11-10T14:40:50Z	15	16	14623
    session-scaling-66c7888bb4-ht8jp	0	session-scaling-agent-0	2026-11-10T14:40:50Z	2026-11-10T14:40:51Z	2026-11-10T14:41:12Z	21	22	16330
    session-scaling-66c7888bb4-7bhr9	0	session-scaling-agent-1	2026-11-10T14:41:37Z	2026-11-10T14:41:38Z	2026-11-10T14:41:59Z	21	22	17066
    session-scaling-66c7888bb4-vj5m7	1	session-scaling-agent-2	2026-11-10T14:40:34Z	2026-11-10T14:42:12Z	2026-11-10T14:42:33Z	21	-	16607

Pods stopped with SIGTERM (pod, WFLYSRV0211 suspend, WFLYSRV0220 OS signal, WFLYSRV0050 stopped):

    session-scaling-66c7888bb4-ht8jp	1	1	WFLYSRV0050: WildFly 42.0.0.Final (WildFly Core 34.0.0.Final) stopped in 263ms
    session-scaling-85dc458f7f-4c96r	1	1	WFLYSRV0050: WildFly 42.0.0.Final (WildFly Core 34.0.0.Final) stopped in 155ms
    session-scaling-85dc458f7f-jfnc5	1	1	WFLYSRV0050: WildFly 42.0.0.Final (WildFly Core 34.0.0.Final) stopped in 492ms
    session-scaling-85dc458f7f-pntvx.restart-1	1	1	WFLYSRV0050: WildFly 42.0.0.Final (WildFly Core 34.0.0.Final) stopped in 253ms
    session-scaling-85dc458f7f-vllfp	1	1	WFLYSRV0050: WildFly 42.0.0.Final (WildFly Core 34.0.0.Final) stopped in 331ms
    session-scaling-85dc458f7f-ztlq7.restart-1	1	1	WFLYSRV0050: WildFly 42.0.0.Final (WildFly Core 34.0.0.Final) stopped in 177ms
    session-scaling-85dc458f7f-zvd79	1	1	WFLYSRV0050: WildFly 42.0.0.Final (WildFly Core 34.0.0.Final) stopped in 297ms

HPA events:

    2026-11-10T14:27:57Z	SuccessfulRescale	New size: 2; reason: Current number of replicas below Spec.MinReplicas
    2026-11-10T14:28:12Z	FailedGetResourceMetric	failed to get cpu utilization: unable to get metrics for resource cpu: no metrics returned from resource metrics API
    2026-11-10T14:28:12Z	FailedComputeMetricsReplicas	invalid metrics (1 invalid out of 1), first error is: failed to get cpu resource metric value: failed to get cpu utilization: unable to get metrics for resource cpu: no metrics returned from resource metrics API
    2026-11-10T14:42:43Z	FailedGetResourceMetric	failed to get cpu utilization: did not receive metrics for targeted pods (pods might be unready)
    2026-11-10T14:42:43Z	FailedComputeMetricsReplicas	invalid metrics (1 invalid out of 1), first error is: failed to get cpu resource metric value: failed to get cpu utilization: did not receive metrics for targeted pods (pods might be unready)
    2026-11-10T14:29:27Z	SuccessfulRescale	New size: 3; reason: cpu resource utilization (percentage of request) above target
    2026-11-10T14:29:42Z	SuccessfulRescale	New size: 4; reason: cpu resource utilization (percentage of request) above target
    2026-11-10T14:39:13Z	SuccessfulRescale	New size: 3; reason: All metrics below target
    2026-11-10T14:40:13Z	SuccessfulRescale	New size: 2; reason: All metrics below target

Pod samples of the metrics API (top.tsv): 536; CPU at most 3844m; memory 388Mi to 653Mi

Submitted orders (form, order, lines added, expected total; form total; confirmation lines and total; database rows in order_line, sum of unit_price * quantity, customer_order.total):

    0	1	30	223.30	223.30	30	223.30	30	223.30	223.30
    1	2	28	207.70	207.70	28	207.70	28	207.70	207.70
    2	3	28	207.70	207.70	28	207.70	28	207.70	207.70
    3	4	28	207.70	207.70	28	207.70	28	207.70	207.70
    4	5	28	207.70	207.70	28	207.70	28	207.70	207.70
    5	6	28	207.70	207.70	28	207.70	28	207.70	207.70

Leaves (first ISPN100001 per member in the container logs): 10

    2026-11-10T14:30:43.798Z	session-scaling-85dc458f7f-zvd79
    2026-11-10T14:31:09.454Z	session-scaling-85dc458f7f-vllfp
    2026-11-10T14:32:15.211Z	session-scaling-85dc458f7f-pntvx
    2026-11-10T14:32:15.211Z	session-scaling-85dc458f7f-ztlq7
    2026-11-10T14:39:23.792Z	session-scaling-85dc458f7f-ztlq7
    2026-11-10T14:40:23.884Z	session-scaling-85dc458f7f-4c96r
    2026-11-10T14:41:01.157Z	session-scaling-85dc458f7f-pntvx
    2026-11-10T14:41:22.917Z	session-scaling-85dc458f7f-jfnc5
    2026-11-10T14:41:47.979Z	session-scaling-66c7888bb4-ht8jp
    2026-11-10T14:42:13.868Z	session-scaling-66c7888bb4-vj5m7

Probe answers whose request ran within 6 s after a leave: 63 answers, 20 of them slower than 0.2 s, slowest 1.845853 s

Other probe answers: 1204 answers, 46 of them slower than 0.2 s, slowest 1.110396 s

Faces postbacks of the per-replica checks slower than 0.2 s: 22 of 168

    14:29:08.965	1 two replicas	session-scaling-85dc458f7f-vllfp#0	postback 1 on this container	0.639029 s
    14:30:18.773	2 HPA scale-up	session-scaling-85dc458f7f-4c96r#0	postback 1 on this container	1.411287 s
    14:30:30.562	2 HPA scale-up	session-scaling-85dc458f7f-zvd79#0	postback 1 on this container	1.237169 s
    14:31:34.203	3 node drain	session-scaling-85dc458f7f-jfnc5#0	postback 1 on this container	1.141717 s
    14:31:44.458	3 node drain	session-scaling-85dc458f7f-pntvx#0	postback 1 on this container	1.242164 s
    14:32:06.072	3 node drain	session-scaling-85dc458f7f-ztlq7#0	postback 13 on this container	1.098455 s
    14:32:07.301	3 node drain	session-scaling-85dc458f7f-ztlq7#0	postback 14 on this container	1.113657 s
    14:32:08.528	3 node drain	session-scaling-85dc458f7f-ztlq7#0	postback 15 on this container	1.087310 s
    14:32:09.715	3 node drain	session-scaling-85dc458f7f-ztlq7#0	postback 16 on this container	1.062503 s
    14:32:10.909	3 node drain	session-scaling-85dc458f7f-ztlq7#0	postback 17 on this container	1.080769 s
    14:32:12.157	3 node drain	session-scaling-85dc458f7f-ztlq7#0	postback 18 on this container	1.125560 s
    14:32:24.401	4 node stopped	session-scaling-85dc458f7f-jfnc5#0	postback 10 on this container	0.531971 s
    14:33:40.620	4b node started again	session-scaling-85dc458f7f-4c96r#0	postback 19 on this container	0.556421 s
    14:33:48.639	4b node started again	session-scaling-85dc458f7f-pntvx#1	postback 1 on this container	1.400892 s
    14:33:53.597	4b node started again	session-scaling-85dc458f7f-ztlq7#1	postback 1 on this container	1.395327 s
    14:40:34.015	5b HPA scale-down to 2	session-scaling-85dc458f7f-pntvx#1	postback 18 on this container	0.449515 s
    14:41:31.903	6 rolling update	session-scaling-66c7888bb4-ht8jp#0	postback 1 on this container	1.846228 s
    14:41:35.743	6 rolling update	session-scaling-66c7888bb4-vj5m7#0	postback 1 on this container	1.181652 s
    14:41:36.813	6 rolling update	session-scaling-66c7888bb4-vj5m7#0	postback 4 on this container	0.577002 s
    14:42:06.668	7 pod deleted	session-scaling-66c7888bb4-7bhr9#0	postback 1 on this container	1.511225 s
    14:42:07.430	7 pod deleted	session-scaling-66c7888bb4-7bhr9#0	postback 3 on this container	0.417155 s
    14:42:44.176	8b JVM restarted	session-scaling-66c7888bb4-vj5m7#1	postback 1 on this container	1.388384 s

Faces requests through the ingress slower than 0.2 s: 5 of 27

    14:29:00.768	1 two replicas	form 0	open	ok	0.677061 s
    14:29:03.143	1 two replicas	form 0	customer	ok	2.298549 s
    14:42:14.060	8 JVM killed	form 0	add-line	ok	1.003647 s
    14:42:46.527	9 order forms submitted	form 0	submit	ok	0.885791 s
    14:42:48.126	9 order forms submitted	form 2	submit	ok	0.315835 s

WARN and ERROR messages in the container logs (count, level, message code or logger and text):

    12	WARN	WFLYCLJG0039
    12	WARN	WFLYCLJG0040
    12	WARN	WFLYSRV0018
    12	WARN	WFLYTX0013
    5	WARN	ISPN000312
    2	WARN	org.jgroups.protocols.TCP: <address>: failed handling message: java.io.IOException: Stream closed
    1	ERROR	org.jgroups.protocols.TCP: <address>: failed sending graceful close to <address>: Socket closed

Container logs fetched completely at the end (the others are the followed logs): session-scaling-66c7888bb4-7bhr9.log session-scaling-66c7888bb4-vj5m7.restart-1.log session-scaling-66c7888bb4-vj5m7.log

Failures: 0
