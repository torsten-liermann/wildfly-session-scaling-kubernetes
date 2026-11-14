| Step | Checked (UTC) | Replicas checked | Nodes | Session reads OK | Faces postbacks OK | Cache invalidations seen | Slowest request (s) | Segments with owners on different nodes | JGroups rack = node |
| --- | --- | --- | --- | --- | --- | --- | --- | --- | --- |
| 1 two replicas | 12:37:21 | 2 | 2 | 48/48 | 12/12 | 1/1 | 0.775030 | 128/128 | 2/2 |
| 2 HPA scale-up | 12:38:28 | 4 | 3 | 96/96 | 24/24 | 3/3 | 1.438869 | 128/128 | 4/4 |
| 3 node drain | 12:39:40 | 4 | 2 | 96/96 | 24/24 | 3/3 | 1.415025 | 128/128 | 4/4 |
| 4 node stopped | 12:39:53 | 2 | 1 | 48/48 | 12/12 | 1/1 | 0.109212 | 0/128 | 2/2 |
| 4b node started again | 12:41:23 | 4 | 2 | 96/96 | 24/24 | 3/3 | 1.402565 | 128/128 | 4/4 |
| 5a HPA scale-down to 3 | 12:47:00 | 3 | 2 | 72/72 | 18/18 | 2/2 | 0.105886 | 128/128 | 3/3 |
| 5b HPA scale-down to 2 | 12:47:56 | 2 | 2 | 48/48 | 12/12 | 1/1 | 0.571241 | 128/128 | 2/2 |
| 6 rolling update | 12:49:04 | 2 | 2 | 48/48 | 12/12 | 1/1 | 1.910945 | 128/128 | 2/2 |
| 7 pod deleted | 12:49:36 | 2 | 2 | 48/48 | 12/12 | 1/1 | 1.321715 | 128/128 | 2/2 |
| 8 JVM killed | 12:49:43 | 1 | 1 | 24/24 | 6/6 | n/a | 0.572453 | 0/128 | 1/1 |
| 8b JVM restarted | 12:50:30 | 3 | 3 | 72/72 | 18/18 | 2/2 | 1.890238 | 128/128 | 3/3 |

Ingress probe: 1281 requests from 12:37:12.586 to 12:50:36.902: 1272 correct, 9 without answer (no response within 5 s, or 502/503/504 from the ingress), 0 wrong; slowest answer 1.789 s

Events:

- 2 HPA set the deployment to 4 replicas 15.3 s after the load started: session-scaling Deployment/session-scaling cpu: 179%/60% 2 4 2 91s
- 2 the two new replicas were ready and members of the cluster 32.2 s after the HPA decision was seen
- 3 drain of k3d-session-scaling-agent-0 finished: 5 evictions refused by the PodDisruptionBudget until a replacement was ready
- 4 node k3d-session-scaling-agent-2 stopped at 12:39:42.359 with replicas session-scaling-85dc458f7f-9rrcs session-scaling-85dc458f7f-z9hqv
- 4 the remaining replicas had a settled view without the stopped replicas 4.9 s after the stop
- 4 Kubernetes reported k3d-session-scaling-agent-2 NotReady 50.2 s after the stop
- 4 the service had no ready endpoints on the stopped node any more 50.4 s after the stop
- 4 node k3d-session-scaling-agent-2 Ready again 6.5 s after the start
- 4 all 4 replicas ready and members of the cluster 31.0 s after the node start
- 5 HPA set the deployment to 3 replicas at 12:46:38.005
- 5 HPA set the deployment to 2 replicas at 12:47:38.688
- 6 rolling update finished after 55.7 s
- 7 pod session-scaling-66c7888bb4-h4h2m gone after 13 s (terminationGracePeriodSeconds: 60)
- 8 JVM of session-scaling-66c7888bb4-k9wlg killed with SIGKILL at 12:49:36.877
- 8 order form 0 continued through the ingress on session-scaling-66c7888bb4-rgf6r 2.4 s after the kill (2 attempt(s); view db35b275-02d9-4c75-b87b-adf27af8a358 created by session-scaling-85dc458f7f-9vkmt, 27 lines)
- 8 the remaining replicas had a settled view without session-scaling-66c7888bb4-k9wlg 2.7 s after the kill
- 8 container of session-scaling-66c7888bb4-k9wlg restarted, ready and member of the cluster 37.5 s after the kill
- 9 order forms submitted through the ingress: 6/6 stored with every line and the total of the form (lines per form: 31 29 29 29 29 29)

Container starts (pod, restarts, node, created, container started, ready, started to ready in s, created to ready in s, WildFly boot in ms):

    session-scaling-85dc458f7f-9vkmt	0	session-scaling-agent-1	2026-11-10T12:36:05Z	2026-11-10T12:36:06Z	2026-11-10T12:36:32Z	26	27	24954
    session-scaling-85dc458f7f-r6lfh	0	session-scaling-agent-0	2026-11-10T12:36:05Z	2026-11-10T12:36:06Z	2026-11-10T12:36:26Z	20	21	19410
    session-scaling-85dc458f7f-c5dw5	0	session-scaling-agent-0	2026-11-10T12:37:35Z	2026-11-10T12:37:36Z	2026-11-10T12:38:06Z	30	31	26363
    session-scaling-85dc458f7f-z9hqv	0	session-scaling-agent-2	2026-11-10T12:37:35Z	2026-11-10T12:37:36Z	2026-11-10T12:38:04Z	28	29	23846
    session-scaling-85dc458f7f-j9qcg	0	session-scaling-agent-1	2026-11-10T12:38:29Z	2026-11-10T12:38:30Z	2026-11-10T12:38:51Z	21	22	17564
    session-scaling-85dc458f7f-9rrcs	0	session-scaling-agent-2	2026-11-10T12:38:55Z	2026-11-10T12:38:56Z	2026-11-10T12:39:17Z	21	22	17503
    session-scaling-85dc458f7f-9rrcs	1	session-scaling-agent-2	2026-11-10T12:38:55Z	2026-11-10T12:40:38Z	2026-11-10T12:41:00Z	22	-	19491
    session-scaling-85dc458f7f-z9hqv	1	session-scaling-agent-2	2026-11-10T12:37:35Z	2026-11-10T12:40:38Z	2026-11-10T12:41:01Z	23	-	19641
    session-scaling-66c7888bb4-k9wlg	0	session-scaling-agent-0	2026-11-10T12:47:56Z	2026-11-10T12:47:57Z	2026-11-10T12:48:18Z	21	22	16195
    session-scaling-66c7888bb4-h4h2m	0	session-scaling-agent-1	2026-11-10T12:48:18Z	2026-11-10T12:48:18Z	2026-11-10T12:48:39Z	21	21	16355
    session-scaling-66c7888bb4-rgf6r	0	session-scaling-agent-2	2026-11-10T12:49:04Z	2026-11-10T12:49:05Z	2026-11-10T12:49:25Z	20	21	16643
    session-scaling-66c7888bb4-k9wlg	1	session-scaling-agent-0	2026-11-10T12:47:56Z	2026-11-10T12:49:37Z	2026-11-10T12:49:58Z	21	-	16676
    session-scaling-66c7888bb4-nq8pb	0	session-scaling-agent-1	2026-11-10T12:49:51Z	2026-11-10T12:49:52Z	2026-11-10T12:50:13Z	21	22	16769

Pods stopped with SIGTERM (pod, WFLYSRV0211 suspend, WFLYSRV0220 OS signal, WFLYSRV0050 stopped):

    session-scaling-66c7888bb4-h4h2m	1	1	WFLYSRV0050: WildFly 42.0.0.Final (WildFly Core 34.0.0.Final) stopped in 315ms
    session-scaling-85dc458f7f-9rrcs.restart-1	1	1	WFLYSRV0050: WildFly 42.0.0.Final (WildFly Core 34.0.0.Final) stopped in 226ms
    session-scaling-85dc458f7f-9vkmt	1	1	WFLYSRV0050: WildFly 42.0.0.Final (WildFly Core 34.0.0.Final) stopped in 175ms
    session-scaling-85dc458f7f-c5dw5	1	1	WFLYSRV0050: WildFly 42.0.0.Final (WildFly Core 34.0.0.Final) stopped in 400ms
    session-scaling-85dc458f7f-j9qcg	1	1	WFLYSRV0050: WildFly 42.0.0.Final (WildFly Core 34.0.0.Final) stopped in 180ms
    session-scaling-85dc458f7f-r6lfh	1	1	WFLYSRV0050: WildFly 42.0.0.Final (WildFly Core 34.0.0.Final) stopped in 316ms
    session-scaling-85dc458f7f-z9hqv.restart-1	1	1	WFLYSRV0050: WildFly 42.0.0.Final (WildFly Core 34.0.0.Final) stopped in 350ms

HPA events:

    2026-11-10T12:36:05Z	SuccessfulRescale	New size: 2; reason: Current number of replicas below Spec.MinReplicas
    2026-11-10T12:36:20Z	FailedGetResourceMetric	failed to get cpu utilization: unable to get metrics for resource cpu: no metrics returned from resource metrics API
    2026-11-10T12:36:20Z	FailedComputeMetricsReplicas	invalid metrics (1 invalid out of 1), first error is: failed to get cpu resource metric value: failed to get cpu utilization: unable to get metrics for resource cpu: no metrics returned from resource metrics API
    2026-11-10T12:36:50Z	FailedGetResourceMetric	failed to get cpu utilization: did not receive metrics for targeted pods (pods might be unready)
    2026-11-10T12:36:50Z	FailedComputeMetricsReplicas	invalid metrics (1 invalid out of 1), first error is: failed to get cpu resource metric value: failed to get cpu utilization: did not receive metrics for targeted pods (pods might be unready)
    2026-11-10T12:37:35Z	SuccessfulRescale	New size: 4; reason: cpu resource utilization (percentage of request) above target
    2026-11-10T12:46:36Z	SuccessfulRescale	New size: 3; reason: All metrics below target
    2026-11-10T12:47:36Z	SuccessfulRescale	New size: 2; reason: All metrics below target
    2026-11-10T12:49:51Z	SuccessfulRescale	New size: 3; reason: cpu resource utilization (percentage of request) above target

Failures: 0
