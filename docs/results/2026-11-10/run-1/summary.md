| Step | Checked (UTC) | Ready replicas | Nodes | Session reads OK | Slowest read (s) | Segments with owners on different nodes | JGroups rack = node |
| --- | --- | --- | --- | --- | --- | --- | --- |
| 1 two replicas | 08:20:06 | 2 | 2 | 48/48 | 0.152149 | 128/128 | 2/2 |
| 2 HPA scale-up | 08:21:03 | 4 | 3 | 96/96 | 0.181950 | 128/128 | 4/4 |
| 3 node drain | 08:23:04 | 4 | 2 | 96/96 | 1.639804 | 128/128 | 4/4 |
| 4a HPA scale-down to 3 | 08:26:56 | 3 | 2 | 72/72 | 1.217990 | 128/128 | 3/3 |
| 4b HPA scale-down to 2 | 08:27:41 | 2 | 2 | 48/48 | 0.625729 | 128/128 | 2/2 |
| 5 pod deleted | 08:28:19 | 2 | 2 | 48/48 | 0.874270 | 128/128 | 2/2 |

Ingress probe: 548 requests from 08:19:59.660 to 08:28:22.468, 548 correct, 0 failed, slowest 1.836 s

Removed pods (pod, WFLYSRV0211 suspend, WFLYSRV0220 OS signal, WFLYSRV0050 stopped):

    session-scaling-6964fc4fb-5zn6d	1	1	WFLYSRV0050: WildFly 42.0.0.Final (WildFly Core 34.0.0.Final) stopped in 180ms
    session-scaling-6964fc4fb-l5hns	1	1	WFLYSRV0050: WildFly 42.0.0.Final (WildFly Core 34.0.0.Final) stopped in 673ms
    session-scaling-6964fc4fb-mppn2	1	1	WFLYSRV0050: WildFly 42.0.0.Final (WildFly Core 34.0.0.Final) stopped in 775ms
    session-scaling-6964fc4fb-nrf9n	1	1	WFLYSRV0050: WildFly 42.0.0.Final (WildFly Core 34.0.0.Final) stopped in 352ms
    session-scaling-6964fc4fb-zdt9f	1	1	WFLYSRV0050: WildFly 42.0.0.Final (WildFly Core 34.0.0.Final) stopped in 1043ms

HPA events:

    2026-11-10T08:19:11Z	SuccessfulRescale	New size: 2; reason: Current number of replicas below Spec.MinReplicas
    2026-11-10T08:19:41Z	FailedGetResourceMetric	failed to get cpu utilization: did not receive metrics for targeted pods (pods might be unready)
    2026-11-10T08:19:41Z	FailedComputeMetricsReplicas	invalid metrics (1 invalid out of 1), first error is: failed to get cpu resource metric value: failed to get cpu utilization: did not receive metrics for targeted pods (pods might be unready)
    2026-11-10T08:20:26Z	SuccessfulRescale	New size: 4; reason: cpu resource utilization (percentage of request) above target
    2026-11-10T08:26:12Z	SuccessfulRescale	New size: 3; reason: All metrics below target
    2026-11-10T08:27:12Z	SuccessfulRescale	New size: 2; reason: All metrics below target

Failures: 0
