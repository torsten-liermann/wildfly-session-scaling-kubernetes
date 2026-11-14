- **UI and session state living in the backend hinder elastic cloud operation, high availability and scaling**: no
- **Scaling is vertical only**: no
- **Capacity must be sized permanently for the peak**: no
- **Replicas can be added within a load peak and removed afterwards**: yes, scale-up ready after 58 s, scale-down one replica per minute starting nine minutes after the load ended
- **A JSF frontend with @SessionScoped and @ViewScoped beans ties a user to one instance**: no
- **A local second-level cache requires sticky sessions**: no
- **Sessions are lost when an instance fails**: no; only the change of a request answered just before a hard kill can be lost (see Limits)
- **Starting takes minutes**: no, 15 to 26 s from container start to ready
- **Cloud operation requires a major rebuild of the application**: no

# WildFly with JSF and PrimeFaces on Kubernetes: elastic and highly available

A Jakarta EE 10 application with a Jakarta Faces frontend (PrimeFaces, `@ViewScoped` and
`@SessionScoped` beans, server-side state saving), servlet sessions and JPA with a Hibernate
second-level cache runs on WildFly 42 and Java 21 in two to four replicas on Kubernetes. A script
builds a throw-away [k3d](https://k3d.io) cluster, scales the application up and down, drains a
node, stops a node, updates the image, deletes a pod and kills a JVM, and checks after every step
that every replica serves every session and every open Faces view. A second script measures the
image; a third starts the same server, packed as an archive by the same build, without Kubernetes.

The repository answers six assumptions that are often made about this kind of application; the
list above gives the short answers. Each answer is a step of the scripts and a value measured in
the recorded run.

## Assumptions and measured results

Final run (run 4) of 10 November 2026, k3d with one server and three agent nodes on one host.
Details and raw data: [docs/results/2026-11-10/run-4](docs/results/2026-11-10/run-4/summary.md); method and further numbers under
[The check](#the-check) and [Results](#results).

| Assumption | What this repository shows | Step | Measured result |
| --- | --- | --- | --- |
| **1. Scaling is vertical only.** Capacity has to be sized for the peak; adding instances within a load peak and removing them afterwards is not possible. | A HorizontalPodAutoscaler adds replicas under CPU load and removes them one per minute afterwards. Sessions and open Faces views stay valid on every replica. | [verify-session-scaling.sh](scripts/verify-session-scaling.sh), steps 2 and 5 | The HPA set three replicas about 15 s and four replicas 30.3 s after the load started (CPU at 237 % of the request); the four replicas were ready and cluster members 58 s after the load started. Without load it removed one replica at 14:39:13 and the next at 14:40:13. In all eleven checks 672 of 672 session reads and 168 of 168 Faces postbacks passed. |
| **2. A JSF frontend is stateful.** `@SessionScoped` beans and the server-side view state tie a user to one instance; scaling out needs a frontend that keeps no UI state on the server. | An order form in four steps with PrimeFaces: a `@ViewScoped` bean, a `@SessionScoped` bean, server-side state saving. Any replica processes the next postback of a view that another replica created. | Faces postbacks after every step; step 8 kills the JVM that served the last postback; step 9 submits the forms | Every replica continued every open view after every step, also views whose creating replica no longer existed. After the SIGKILL, order form 0 (27 lines, view created by a replica that had left in the drain of step 3) was continued on the other replica 2.5 s after the kill, at the second attempt, with every line. 6 of 6 forms were submitted; the database held each order with all of its lines (28 to 30) and the expected total. |
| **3. A local second-level cache serves stale data on other instances.** Several instances therefore need sticky sessions or a cache that is replicated between them. | Each replica keeps its own second-level cache (Galleon layer `jpa-distributed`); a change on one replica removes the entry on all others (invalidation), so they read the new state from the database. The ingress distributes requests round robin, without session affinity. | Cache check after every step: every replica holds product 1 in its cache, one replica changes the price, the others are read | 17 of 17 reads after a price change on another replica reported that the entry was no longer in the cache and returned the new price. Every order line added afterwards on any replica carried the new price. 1267 of 1267 answers through the ingress (round robin) returned the correct session. |
| **4. With sticky sessions, sessions are lost when an instance fails.** | Each session is held by two replicas on different nodes. A whole node with two of four replicas is stopped; the JVM of a replica is killed with SIGKILL. | Steps 4 and 8 | Node stop: the remaining two replicas had a settled cluster view 3.2 s after the stop; 48 of 48 session reads and 12 of 12 Faces postbacks on them passed. Requests that the ingress still sent to the stopped replicas got no answer until Kubernetes removed them from the Service after 47.6 s (8 of 16 probe requests in that time). SIGKILL: settled view after 2.7 s, 24 of 24 reads and 6 of 6 postbacks passed on the remaining replica; the restarted container was ready and a cluster member after 24.8 s. No answer contained a lost or outdated session. Limit: the changes of a request whose JVM dies after the response and before the write to the second owner are lost; one earlier run hit that window (see [Limits](#limits)). |
| **5. Starting takes minutes; each image must contain the full runtime**, which increases image size and start time. | The server is provisioned with Galleon from the subsystems the application uses. The image has separate layers for JRE, server and application; a new application version changes only the application layers. | [measure-image.sh](scripts/measure-image.sh); container starts in the k3d run | 12 container starts: WildFly started in 14.6 to 24.2 s (WFLYSRV0025), Ready 15 to 26 s after the container start. The image is 224.9 MB compressed: JRE base 100.0 MB, server 119.6 MB, application 5.2 MB. A node that has the image pulls 5.3 MB for the next application version. The provisioned server has 319 modules and 141 MB, the full WildFly distribution 601 modules and 317 MB. |
| **6. Running on a cloud platform needs very high operating costs or a substantial rework of the application.** | The programming model is that of a single server: Faces, CDI and JPA, no cloud or vendor API. For several replicas the application needs `<distributable/>`, serializable session contents and, for the cache, `@Cacheable` with the layer `jpa-distributed`; the server configuration is part of the build. The same build produces the image and a server archive for an installation without containers. | Source files named in the result; [verify-server-archive.sh](scripts/verify-server-archive.sh) | Specific to several replicas in the application: `<distributable/>` ([web.xml L9](app/src/main/webapp/WEB-INF/web.xml#L9)); `implements Serializable` on the four classes stored in the session ([VisitCounter](app/src/main/java/io/github/torstenliermann/sessionscaling/VisitCounter.java#L11), [OrderHistory](app/src/main/java/io/github/torstenliermann/sessionscaling/OrderHistory.java#L12), [OrderWizard](app/src/main/java/io/github/torstenliermann/sessionscaling/OrderWizard.java#L26), [OrderLineDraft](app/src/main/java/io/github/torstenliermann/sessionscaling/OrderLineDraft.java#L7)); `@Cacheable` on [Product](app/src/main/java/io/github/torstenliermann/sessionscaling/Product.java#L20) and `shared-cache-mode` in [persistence.xml](app/src/main/resources/META-INF/persistence.xml#L10). Only the diagnostics servlet `ClusterServlet` imports anything besides `jakarta.*` and `java.*`. The server: seven Galleon layers ([image/pom.xml](image/pom.xml#L108-L119)) and twelve CLI operations at build time. Each replica requests 0.5 CPU and 768 MiB; four replicas without load used 17 to 163 millicores and 624 to 652 MiB each (14:34:30 to 14:39:00, `top.tsv`). The server archive holds the same 765 files with the same content as `/opt/server` in the image; started with `bin/standalone.sh` on Linux outside Kubernetes, it was ready after 16.0 s. A start on Windows was not run. |

The ingress distributes requests without session affinity on purpose; [Architecture](#architecture)
explains why and what is recommended for operation. The run covers the mechanisms on one host
with synthetic load; what it does not show is listed under [Limits](#limits).

## Architecture

![Architecture: a browser and curl outside the Kubernetes cluster reach the Traefik ingress at 127.0.0.1:18080. Inside the cluster, the ingress distributes requests round robin without sticky sessions to the Service session-scaling and on to the WildFly pods of the Deployment session-scaling: three pods on three nodes and one dashed pod on node 1 that the autoscaler adds and removes. Each pod holds the PrimeFaces UI, the sessions and a second-level cache. A band behind the pods marks the JGroups cluster over TCP 7600 and 7601; the node name is the JGroups rack. The pods find each other through the headless Service session-scaling-discovery with DNS_PING. A dot marks the two owners of one session on different nodes; a change invalidates the second-level cache entry on the other pods. A HorizontalPodAutoscaler (2 to 4 replicas) and a PodDisruptionBudget (maxUnavailable: 1) act on the Deployment. All pods use one PostgreSQL database (Deployment, one replica) through the Service session-scaling-db.](docs/architecture.png)

The ingress deliberately distributes requests round robin, without session affinity, to show the
hardest case: every replica serves every session and every open Faces view from the replicated
state alone. For operation, session affinity at the load balancer (a persistence cookie) together
with the replication is the better setup: the requests of a session go to one replica, which saves
remote reads and locks, and the replication covers the failure of that replica. Affinity and
replication do not exclude each other; assumption 4 holds only for affinity without replication.

| Concern | How it is solved here | Where |
| --- | --- | --- |
| Session state outside a single JVM | `<distributable/>` in `web.xml`; the Galleon layer `web-clustering` keeps sessions in an Infinispan distributed cache with two owners per session. Everything stored in the session is `Serializable`: session attributes, `@SessionScoped` and `@ViewScoped` beans and what they hold | [web.xml](app/src/main/webapp/WEB-INF/web.xml), [image/pom.xml](image/pom.xml) |
| Faces view state on any replica | Server-side state saving (Mojarra's default, set explicitly): Mojarra keeps the component state of each view and the `@ViewScoped` beans in the HTTP session, which is replicated | [web.xml](app/src/main/webapp/WEB-INF/web.xml), [OrderWizard](app/src/main/java/io/github/torstenliermann/sessionscaling/OrderWizard.java) |
| Second-level cache with several replicas | Galleon layer `jpa-distributed`: Infinispan cache container `hibernate` with an invalidation cache for entities; `@Cacheable` and `shared-cache-mode ENABLE_SELECTIVE` | [Product](app/src/main/java/io/github/torstenliermann/sessionscaling/Product.java), [persistence.xml](app/src/main/resources/META-INF/persistence.xml) |
| Replicas find each other without multicast | JGroups `DNS_PING` asks a headless Service for the pod addresses | [configure-server.cli](image/src/main/wildfly/configure-server.cli), [service-discovery.yaml](k8s/service-discovery.yaml) |
| The two copies of a session on different nodes | The node name from the Downward API becomes the JGroups `rack`; Infinispan places the owners of a segment on members with different racks | [deployment.yaml](k8s/deployment.yaml), [configure-server.cli](image/src/main/wildfly/configure-server.cli) |
| Elastic replica count | HorizontalPodAutoscaler on CPU, 2 to 4 replicas; scale-down after a five-minute stabilization window, at most one pod per minute | [hpa.yaml](k8s/hpa.yaml) |
| Node maintenance | PodDisruptionBudget `maxUnavailable: 1`, preferred pod anti-affinity per node | [pdb.yaml](k8s/pdb.yaml), [deployment.yaml](k8s/deployment.yaml) |
| Traffic only to working replicas | Startup, readiness and liveness probes on the WildFly health endpoints | [deployment.yaml](k8s/deployment.yaml) |
| Orderly end of a pod | `preStop` sleep; SIGTERM reaches the JVM; WildFly suspends (finishes running requests) and leaves the cluster | [image/pom.xml](image/pom.xml), [deployment.yaml](k8s/deployment.yaml) |
| Start without the database | Hibernate gets the database product and version from `persistence.xml` instead of a connection at deployment time; replicas start in any order | [persistence.xml](app/src/main/resources/META-INF/persistence.xml) |
| Immutable image | Server provisioned and configured at build time, WAR included, deployment scanner removed, logging to stdout only, no TLS key store (HTTP only in this demo), read-only root file system, non-root user | [image/pom.xml](image/pom.xml), [configure-server.cli](image/src/main/wildfly/configure-server.cli), [deployment.yaml](k8s/deployment.yaml) |
| One application per server | Each pod runs one WAR as root context. The session cookie `JSESSIONID` is scoped to host name and path; applications that share a host name and a cookie path need different cookie names (`<cookie-config><name>` in `web.xml`), on Kubernetes as on a single server | [web.xml](app/src/main/webapp/WEB-INF/web.xml) |
| The same server without containers | The build also packs the provisioned server with the application as `tar.gz` and `zip`, with the start scripts for Linux and Windows | [server.xml](image/src/main/assembly/server.xml), [verify-server-archive.sh](scripts/verify-server-archive.sh) |

## Repository layout

| Path | Content |
| --- | --- |
| [app](app) | The WAR. Servlet sessions: [`SessionServlet`](app/src/main/java/io/github/torstenliermann/sessionscaling/SessionServlet.java), [`VisitCounter`](app/src/main/java/io/github/torstenliermann/sessionscaling/VisitCounter.java) (`@SessionScoped`). Faces: [`order.xhtml`](app/src/main/webapp/order.xhtml), [`OrderWizard`](app/src/main/java/io/github/torstenliermann/sessionscaling/OrderWizard.java) (`@ViewScoped`), [`OrderHistory`](app/src/main/java/io/github/torstenliermann/sessionscaling/OrderHistory.java) (`@SessionScoped`). JPA: [`Product`](app/src/main/java/io/github/torstenliermann/sessionscaling/Product.java) (cached), [`CustomerOrder`](app/src/main/java/io/github/torstenliermann/sessionscaling/CustomerOrder.java), [`OrderService`](app/src/main/java/io/github/torstenliermann/sessionscaling/OrderService.java), [`ProductServlet`](app/src/main/java/io/github/torstenliermann/sessionscaling/ProductServlet.java) (cache diagnostics). [`LoadServlet`](app/src/main/java/io/github/torstenliermann/sessionscaling/LoadServlet.java) (CPU load), [`ClusterServlet`](app/src/main/java/io/github/torstenliermann/sessionscaling/ClusterServlet.java) (owner diagnostics) |
| [image](image) | Galleon provisioning with the WildFly Maven Plugin, build-time CLI script, image build with Jib, server archive |
| [k8s](k8s) | Namespace, Deployment, Services, Ingress, HorizontalPodAutoscaler, PodDisruptionBudget, PostgreSQL (Kustomize) |
| [scripts/verify-session-scaling.sh](scripts/verify-session-scaling.sh) | The end-to-end check on a throw-away k3d cluster; [scripts/k3d](scripts/k3d) keeps the database on the k3d server node |
| [scripts/measure-image.sh](scripts/measure-image.sh) | Image size and layers, compared with the next application version |
| [scripts/verify-server-archive.sh](scripts/verify-server-archive.sh) | The server archive compared with the image and started without Kubernetes |
| [docs/results](docs/results) | Recorded runs with versions and logs |

## How it works

### Application

The only Jakarta EE API the application is compiled against is
`jakarta.platform:jakarta.jakartaee-api:10.0.0`; besides it, the compile class path holds
PrimeFaces and, for the diagnostics in `ClusterServlet`, `infinispan-core` and
`infinispan-commons`. The application uses no API of Jakarta EE 11. WildFly 42 implements
Jakarta EE 11 and runs it unchanged.

**Servlet sessions.** `POST /session` creates a session and stores a random token twice: as a
session attribute and in the `@SessionScoped` bean `VisitCounter`. `GET /session` increments a
request counter in both places and returns them with the pod and node that served the request.
Because every request writes, a later request on another replica shows whether the previous
write was replicated: both counters must equal the number of requests sent with that cookie.

**Faces order form.** [`order.xhtml`](app/src/main/webapp/order.xhtml) is a form in four steps,
built with PrimeFaces 16.0.2, which is built against Jakarta EE 10 (Faces 4.0):

1. customer name, sent with a full-page postback (`p:commandButton ajax="false"`),
2. order lines: product and quantity, each line added with a PrimeFaces Ajax postback that
   renders only the form panel again,
3. review, 4. submit: the order is stored in PostgreSQL and read back for the confirmation.

The state of the form is in the `@ViewScoped` bean `OrderWizard`: step, customer, lines. It
records the replica that created it and an instance ID fixed at creation. The submitted orders
of the session are in the `@SessionScoped` bean `OrderHistory`. State saving is `server`:
Mojarra keeps the component state of the most recent views and the `@ViewScoped` beans in the
HTTP session; the browser sends only the view state ID (`jakarta.faces.ViewState`). With
`<distributable/>`, WildFly replicates that session like any other. The page contains an
element `flow-state` with the step, the bean's instance ID, the number of lines, the price of
the last line and the replica that answered; the check script reads it.

**Second-level cache.** [`Product`](app/src/main/java/io/github/torstenliermann/sessionscaling/Product.java)
is `@Cacheable`; `persistence.xml` sets `shared-cache-mode` to `ENABLE_SELECTIVE`. With the
Galleon layer `jpa-distributed`, WildFly uses the Infinispan cache container `hibernate`, in
which the entity cache is an invalidation cache: each replica caches the products it has read
in its own memory; when a transaction changes a product, the other replicas remove their entry
and read the new state from the database the next time. `GET /product?id=1` reports whether
this replica held the product in its cache before the read (`jakarta.persistence.Cache.contains`);
`POST /product?id=1&price=…` changes the price.

`persistence.xml` names the database product and major version and switches off JDBC metadata
access at boot. Without these settings Hibernate opens a connection while the application is
deployed, to determine the SQL dialect; if the database is not reachable at that moment, the
deployment fails and the replica never becomes ready (seen in a trial run of the check before
this change, when the WildFly pods started before PostgreSQL accepted connections).

`GET /load?ms=250` burns CPU without touching a session; the check uses it to drive the
autoscaler. `GET /cluster` reports the Infinispan view of the replica that answers: members
with their rack, and for the session cache the number of segments whose two owners have
different racks. It is a diagnostic for this demo and uses a private server module (see
[Limits](#limits)).

### Server

The [WildFly Maven Plugin](https://docs.wildfly.org/wildfly-maven-plugin/) provisions a trimmed
server from the WildFly 42 feature pack and the
[WildFly datasources feature pack](https://github.com/wildfly-extras/wildfly-datasources-galleon-pack)
11.5.0.Final. The Galleon layers are `web-clustering`, `cdi`, `jsf`, `jpa-distributed`,
`postgresql-datasource`, `logging` and `health`; the layer `deployment-scanner` is excluded. The
datasource `PostgreSQLDS` reads host, database, user and password from environment variables
at boot. A CLI script, [configure-server.cli](image/src/main/wildfly/configure-server.cli), runs
once at build time in an embedded server:

```
/subsystem=jgroups/stack=tcp/protocol=MPING:remove()
/subsystem=jgroups/stack=tcp/protocol=dns.DNS_PING:add(add-index=0, properties={dns_query="${env.JGROUPS_DNS_QUERY}", dns_record_type="A"})
/subsystem=jgroups/channel=ee:write-attribute(name=stack, value=tcp)
/subsystem=jgroups/stack=tcp/transport=TCP:write-attribute(name=rack, value="${env.NODE_NAME:unknown}")
/subsystem=jgroups/stack=tcp/protocol=UNICAST3:write-attribute(name=properties, value={conn_close_timeout=5000})
/subsystem=logging/console-handler=CONSOLE:write-attribute(name=named-formatter, value=PATTERN)
/subsystem=logging/root-logger=ROOT:remove-handler(name=FILE)
/subsystem=logging/periodic-rotating-file-handler=FILE:remove()
/subsystem=elytron/server-ssl-context=applicationSSC:remove()
/subsystem=elytron/key-manager=applicationKM:remove()
/subsystem=elytron/key-store=applicationKS:remove()
/deployment=ROOT.war:add(content=[{path=application/ROOT.war, relative-to=jboss.home.dir, archive=true}], enabled=true)
```

The `${env.…}` expressions stay in `standalone.xml` and are resolved at boot. Nothing configures
the server through the management API when a pod starts. The logging layer defines a rotating
`server.log` next to the console handler; the script removes it, so the server writes its log
to stdout only. The layers also define a TLS key store `application.keystore` with a key manager
that creates a self-signed certificate on first use; no HTTPS listener uses it, the demo configures
HTTP only, and the configuration directory is read-only in the image, so the script removes it.

The node name goes into `rack`, not `machine`. WildFly 42 does not pass the JGroups `machine`
attribute on to Infinispan: `JGroupsTransportResourceDefinitionRegistrar` hands over the site
twice and the machine not at all
([lines 96–98 in 42.0.0.Final](https://github.com/wildfly/wildfly/blob/42.0.0.Final/clustering/infinispan/extension/src/main/java/org/jboss/as/clustering/infinispan/subsystem/JGroupsTransportResourceDefinitionRegistrar.java#L96-L98)).
`rack` reaches Infinispan, whose topology-aware placement puts the two owners of a segment on
members with different racks. `/cluster` shows the rack of every member; the check compares it
with the node the pod runs on.

`conn_close_timeout=5000` limits how long JGroups keeps resending to a replica that has left.
With the JGroups default of 240 s, a remaining replica that still holds an unacknowledged
message for the removed pod resends it every 100 ms (`xmit_interval` in WildFly; JGroups defaults
to 500 ms), and each attempt waits 300 ms
(`sock_conn_timeout` in WildFly) for a TCP connection to an address that no longer answers.
With its default `per-destination` bundler and `use_single_sender_thread=true`, JGroups 5.5 sends
the bundled messages of a member from one thread, so session requests that need a message of
that replica wait as well. 5 s is the value of Infinispan's own Kubernetes stack. The
analysis is in
[docs/results/2026-11-10/latency-after-leave](docs/results/2026-11-10/latency-after-leave/README.md).
In the k3d runs, a remaining replica was sometimes slow for much longer after a leave (see
[Limits](#limits)).

The other defaults of the layers are kept: cache container `web` with a distributed cache, two
owners, synchronous replication, session granularity `SESSION`, affinity `primary-owner`; cache
container `hibernate` with an invalidation cache `entity` and a replicated cache `timestamps`.
WildFly writes the changes of a request to the other owner when it closes the session, after
the response has been committed
([DistributableSession.java#L47–L69](https://github.com/wildfly/wildfly/blob/42.0.0.Final/clustering/web/undertow/src/main/java/org/wildfly/clustering/web/undertow/session/DistributableSession.java#L47-L69));
the next request of the same session waits for that write to finish. If the JVM dies between
the response and the end of that write, the changes of this request are lost, although the
client has seen the response (see [Limits](#limits)).

### Image

[Jib](https://github.com/GoogleContainerTools/jib) builds the image without a Dockerfile: the
base image `eclipse-temurin:21.0.13_9-jre-noble` (pinned by digest) plus four layers:
JVM argument files, the provisioned server under `/opt/server`, the application WAR,
and the software bill of materials that Galleon writes at every provisioning. The server layer
contains nothing that changes from one build to the next (files the build-time CLI run writes
under `standalone/data` are left out; at runtime these directories are under `/tmp/wildfly`), so
two builds of different application versions share it. The WAR is deployed as unmanaged content, so the server never
copies it into a writable repository. The image is built for `amd64` (Maven property
`image.architecture`).

The entrypoint is `bin/standalone.sh` with these settings:

- `LAUNCH_JBOSS_IN_BACKGROUND=true`: `standalone.sh` runs as PID 1, starts the JVM as a child,
  traps SIGTERM and forwards it. Without this variable the shell ignores SIGTERM, the JVM never
  sees it, and Kubernetes kills the pod with SIGKILL after the grace period.
- `JBOSS_PIDFILE=/tmp/wildfly.pid`: `standalone.sh` writes the process ID of the JVM there; the
  check reads it to kill exactly that process.
- `-Dorg.wildfly.sigterm.suspend.timeout=20`: on SIGTERM, WildFly first suspends (readiness goes
  down, running requests may finish for up to 20 seconds), then stops.
- `--read-only-server-config=standalone.xml` and `jboss.server.data.dir`, `…temp.dir`, `…log.dir`
  under `/tmp/wildfly`: the root file system can be read-only, `/tmp` is an `emptyDir`.
- User `1001:1001`.

### Server archive

The same build packs the provisioned server with the application into
`image/target/wildfly-session-scaling-server-<version>.tar.gz` and `.zip`
([server.xml](image/src/main/assembly/server.xml), maven-assembly-plugin). The archive holds the
same files as `/opt/server` in the image, among them `bin/standalone.sh` and
`bin/standalone.bat`. Unpacked, it starts like any WildFly installation, with the configuration
of the image: the same environment variables as in the pod (`POSTGRESQL_HOST`,
`POSTGRESQL_DATABASE`, `POSTGRESQL_USER`, `POSTGRESQL_PASSWORD`, `JGROUPS_DNS_QUERY`, optionally
`NODE_NAME`), log output to stdout, and `DNS_PING` for the discovery: the members find each other
through a DNS name with one A record per server; an installation without such a name replaces
`DNS_PING` in configure-server.cli. [verify-server-archive.sh](scripts/verify-server-archive.sh)
compares the archive with `/opt/server` in the image, file by file and by SHA-256, starts the
unpacked server with `bin/standalone.sh` until `/health/ready` returns HTTP 200, creates and reads
a servlet session, opens the order form and stops the server with SIGTERM. The JVM runs in a
container of the JRE base image only so that the host needs no Java; the container gets the
unpacked directory, nothing of the image.

### Kubernetes

[deployment.yaml](k8s/deployment.yaml) passes pod name, namespace, pod IP and node name through
the Downward API, and the database user name and password from the Secret `session-scaling-db`.
The host `session-scaling-db` and database name `orders` are fixed in the manifest. The container
arguments bind HTTP and management to all interfaces and JGroups to the pod IP
(`-bprivate=$(POD_IP)`); JGroups uses port 7600 and, for failure detection (`FD_SOCK2`), 7601.
The probes use the management port 9990: `/health/started`, `/health/ready`, `/health/live`.
`preStop` sleeps ten seconds so that endpoints, kube-proxy and the ingress controller stop
routing to the pod before WildFly suspends; `terminationGracePeriodSeconds` is 60. The pods run
without a service account token.

The Deployment has no `replicas` field; the HorizontalPodAutoscaler owns it. The relevant HPA
`spec` fields are:

```yaml
  minReplicas: 2
  maxReplicas: 4
  metrics:
    - type: Resource
      resource:
        name: cpu
        target:
          type: Utilization
          averageUtilization: 60
  behavior:
    scaleDown:
      stabilizationWindowSeconds: 300
      policies:
        - type: Pods
          value: 1
          periodSeconds: 60
```

Two replicas are the minimum because each session has two owners. Removing one pod per minute
gives Infinispan time to restore the second copy of the removed pod's sessions before the next
pod goes.

[database.yaml](k8s/database.yaml) runs PostgreSQL 18.6 (image pinned by digest) with one
replica and an `emptyDir`; [database/schema.sql](k8s/database/schema.sql) creates the schema and
the catalog when the data directory is empty. The Secret with user name and password is not part
of the repository; the check script creates it with a random password.

## The check

[verify-session-scaling.sh](scripts/verify-session-scaling.sh) creates a k3d cluster with one
server (tainted, no workloads of the application) and three agents. CoreDNS, Traefik,
metrics-server, local-path-provisioner and the database are moved to the server node, so that
stopping an agent stops replicas of the application only ([scripts/k3d](scripts/k3d)); in a
production cluster these components run highly available. Then:

1. Two replicas. 24 servlet sessions and 6 Faces order forms are started through the ingress;
   each form has passed its first step (customer).
2. Six parallel loops call `/load` through the ingress. When the autoscaler has scaled to four
   replicas and they are ready and members of the cluster, the load stops.
3. The node with the most replicas is drained (`kubectl drain --pod-selector=…`); the
   PodDisruptionBudget lets one eviction through at a time. The node is uncordoned afterwards.
4. The node with the most replicas is stopped with `docker kill` on its k3d container: every
   process on it, including the WildFly JVMs, is killed at once. The remaining replicas are
   checked as soon as the cluster view of one of them no longer contains the stopped replicas;
   then the node is started again and its pods restart.
5. The autoscaler scales down to three and then to two replicas on its own.
6. Rolling update of the Deployment to a second image built from the next application version
   (`UPDATE_IMAGE`); one new pod at a time.
7. One pod is deleted (SIGTERM, graceful shutdown) and replaced.
8. Order form 0 receives a postback through the ingress; the replica that served it is the
   victim. Its JVM is killed with SIGKILL (process ID from `/tmp/wildfly.pid`), and the form is
   continued through the ingress at once. The continuation must show the original view with
   every earlier line and the new one. The line added by the victim's last postback may be
   missing, because WildFly writes the session changes of a request to the other owner after the
   response (see [Server](#server)); the check records that case as `last-change-lost`. The
   remaining replica is checked; then the restarted container is checked as well.
9. Every order form is reviewed and submitted through the ingress.

After each of the steps 1 to 8, every ready replica is checked through `kubectl port-forward`
(steps 4, 5 and 8 are checked twice, eleven checks in all):

- **Servlet sessions:** all 24 sessions are read with their original cookies. A read passes if it
  returns HTTP 200 from the replica addressed, the original session ID, `new: false`, the original
  token in the session attribute and in the CDI bean, and both counters equal to the number of
  requests sent with that cookie so far.
- **Faces order forms:** each of the 6 forms receives one PrimeFaces Ajax postback "Add line"
  with its current view state. It passes if the response has HTTP 200, comes from the replica
  addressed and contains the `flow-state` element and no `<error>` element, the form is in step 2
  for its customer, the `@ViewScoped` bean has the instance ID it was created with, holds every
  line entered so far plus the new one, and the new line is product 1 at its current price.
- **Second-level cache:** every replica reads product 1 twice; the second read must report that
  the entry was in its cache. The first replica changes the price. Every other replica must then
  report that the entry was no longer in its cache, and return the new price.
- **Placement:** each replica reports its own JGroups rack, which must be its node. From the view
  of the first checked replica, the number of session cache segments whose two owners are on
  different nodes must equal the total number of segments while the replicas run on two or
  more nodes.

From step 1 to the end, a further servlet session is read through the ingress with a 0.5 s pause
after each request (about 1.5 requests per second in the recorded run). From the deployment of
the application on, CPU and memory of every pod (metrics API) and the status of the
HorizontalPodAutoscaler are sampled about every five seconds. A probe request without answer (no
response within 5 s, or 502,
503 or 504 from the ingress) is counted separately, and so is an answer that misses exactly the
increment of the previous answer when that answer came from a replica the script killed right
after it (`last-change-lost`, as in step 8). Any other answer with a missing or outdated session
and any failed check fails the run; so does a step that does not reach its expected state within
the script's waiting limit (120 to 900 s, depending on the step).

At the end, every submitted order is read back from the database with SQL: the number of rows in
`order_line`, the sum of `unit_price * quantity` over these rows and `customer_order.total` must
match the lines the script added and the sum of the prices it had set. The total of the form and
the confirmation (the order read back through JPA) must match as well, and the `@SessionScoped`
history must hold one order.

## Quick start

You need about 8 GB of free memory, Docker (or Podman, see below), [k3d](https://k3d.io) 5.9 or
newer, `kubectl`, `curl`, `jq`, `tar`, `sha256sum` and `gzip`, and for the build JDK 21 or Docker.
The script pulls `postgres:18.6-alpine` with the host's container engine and imports it into the
cluster; the nodes pull missing images. The k3s system images come from Docker Hub and GitHub.
The manifests in [k8s](k8s) need Kubernetes 1.30 or newer: the `sleep` action of the `preStop` hook
is enabled by default from 1.30 (stable from 1.34), `unhealthyPodEvictionPolicy` of the
PodDisruptionBudget from 1.27. The script runs k3s v1.37.1.

### Linux

```sh
./mvnw package jib:dockerBuild                                  # wildfly-session-scaling:1.0.0-SNAPSHOT and the server archive
./mvnw package jib:dockerBuild -Drevision=1.0.1-SNAPSHOT        # the next version, for the rolling update
UPDATE_IMAGE=wildfly-session-scaling:1.0.1-SNAPSHOT \
  scripts/verify-session-scaling.sh                             # about 20 minutes, deletes the cluster at the end
scripts/measure-image.sh wildfly-session-scaling:1.0.0-SNAPSHOT wildfly-session-scaling:1.0.1-SNAPSHOT
scripts/verify-server-archive.sh wildfly-session-scaling:1.0.0-SNAPSHOT
```

Without `UPDATE_IMAGE`, step 6 restarts the pods with the same image. With
`FULL_DISTRIBUTION=true`, `measure-image.sh` also downloads the full WildFly distribution and
compares its size with the provisioned server.

Without a local JDK, build in a container (this is how the recorded run was built):

```sh
docker run --rm -v "$PWD":/workspace -v wildfly-session-scaling-m2:/root/.m2 \
  -v /var/run/docker.sock:/var/run/docker.sock -v "$(command -v docker)":/usr/local/bin/docker:ro \
  -w /workspace eclipse-temurin:21.0.13_9-jdk-noble ./mvnw clean package jib:dockerBuild
```

The Maven repository goes into the named volume `wildfly-session-scaling-m2`, not into `~/.m2`;
`docker volume rm wildfly-session-scaling-m2` removes it. The container runs as root; the files it
writes under `target/` belong to root.

The script creates its own cluster `session-scaling` with the API on `127.0.0.1:16443` and the
ingress on `127.0.0.1:18080`, writes its own kubeconfig into the output directory and leaves
`~/.kube/config` alone. Ports, cluster name, numbers of sessions and forms, and the output
directory can be changed through environment variables listed at the top of the script.
`KEEP_CLUSTER=true` keeps the cluster for exploration:

```sh
KEEP_CLUSTER=true scripts/verify-session-scaling.sh
export KUBECONFIG=$(ls -d target/verify-* | tail -n 1)/kubeconfig
curl -s -c jar -X POST localhost:18080/session | jq
curl -s -b jar localhost:18080/session | jq '{requestCount, beanVisits, servedBy, servedByNode}'
curl -s 'localhost:18080/product?id=1' | jq                     # cached on the replica that answers?
xdg-open http://localhost:18080/order.xhtml                    # the order form in a browser
kubectl -n session-scaling delete pod <one of the pods>         # then continue the form or read the session again
k3d cluster delete session-scaling
```

With Podman instead of Docker: let Jib use the Podman CLI
(`./mvnw package jib:dockerBuild -Djib.dockerClient.executable=podman`), point k3d at the Podman
socket as described in the [k3d documentation](https://k3d.io/stable/usage/advanced/podman/), and
run the scripts with `DOCKER=podman`.

If cluster creation fails with agents that never register and the agent logs show
`too many open files`, the host's inotify limit is exhausted (typical when other k3d or kind
clusters run on the same host): `sudo sysctl fs.inotify.max_user_instances=512`.

### Windows

Build in PowerShell with Docker Desktop (or Podman Desktop, see above):

```powershell
.\mvnw.cmd package jib:dockerBuild
.\mvnw.cmd package jib:dockerBuild "-Drevision=1.0.1-SNAPSHOT"
```

Run the scripts in a WSL 2 distribution that uses the same container engine (Docker Desktop's
WSL integration) and has k3d, kubectl, curl, jq, tar, sha256sum and gzip installed:

```powershell
wsl env UPDATE_IMAGE=wildfly-session-scaling:1.0.1-SNAPSHOT ./scripts/verify-session-scaling.sh
```

The server archive `image\target\wildfly-session-scaling-server-1.0.0-SNAPSHOT.zip` contains
`bin\standalone.bat` for a start on Windows with a JDK or JRE 21.

## Results

Recorded on 10 November 2026 in the final run (run 4) on one host (Debian 13,
Docker 29.9.2): WildFly 42.0.0.Final
(WildFly Core 34.0.0.Final, Infinispan 16.2.3, Mojarra 4.1.13, Hibernate ORM 7.4.13.Final),
PrimeFaces 16.0.2, PostgreSQL 18.6, Temurin 21.0.13, k3d 5.9.0, k3s v1.37.1+k3s1. The run passed
without failures. All files are in
[docs/results/2026-11-10/run-4](docs/results/2026-11-10/run-4/summary.md): every
request with its result (`requests.tsv`, `flows.tsv`, `cache.tsv`, `ingress-probe.tsv`), the stored
orders as SQL returned them (`orders.tsv`), the pods sampled every second (`pods.tsv`), CPU and
memory of the pods and the status of the autoscaler about every five seconds (`top.tsv`,
`hpa-status.tsv`), the Infinispan view after each step (`cluster-views.jsonl`), the leaves of
cluster members (`leaves.tsv`), the log of every container, the build
([build.md](docs/results/2026-11-10/run-4/build.md)), the image measurement
([image.md](docs/results/2026-11-10/run-4/image.md)) and the check of the server archive
([server-archive](docs/results/2026-11-10/run-4/server-archive/run.log)).
Runs 1 to 3 are earlier stages of the same check. Commit IDs inside the recorded files refer to the
development history before publication, which this repository does not contain.

| Step | Replicas checked | Nodes | Session reads | Faces postbacks | Cache invalidations | Slowest session read | Slowest Faces postback |
| --- | --- | --- | --- | --- | --- | --- | --- |
| 1 two replicas | 2 | 2 | 48/48 | 12/12 | 1/1 | 0.09 s | 0.64 s |
| 2 HPA scale-up | 4 | 3 | 96/96 | 24/24 | 3/3 | 0.38 s | 1.41 s |
| 3 node drain | 4 | 2 | 96/96 | 24/24 | 3/3 | 1.20 s | 1.24 s |
| 4 node stopped | 2 | 1 | 48/48 | 12/12 | 1/1 | 0.07 s | 0.53 s |
| 4b node started again | 4 | 2 | 96/96 | 24/24 | 3/3 | 0.18 s | 1.40 s |
| 5a HPA scale-down to 3 | 3 | 2 | 72/72 | 18/18 | 2/2 | 0.10 s | 0.13 s |
| 5b HPA scale-down to 2 | 2 | 2 | 48/48 | 12/12 | 1/1 | 0.81 s | 0.45 s |
| 6 rolling update | 2 | 2 | 48/48 | 12/12 | 1/1 | 0.08 s | 1.85 s |
| 7 pod deleted | 2 | 2 | 48/48 | 12/12 | 1/1 | 0.09 s | 1.51 s |
| 8 JVM killed | 1 | 1 | 24/24 | 6/6 | – | 0.03 s | 0.08 s |
| 8b JVM restarted | 2 | 2 | 48/48 | 12/12 | 1/1 | 0.08 s | 1.39 s |

In every step with replicas on two or more nodes, the two owners of all 128 segments of the
session cache were on different nodes in the view of the first checked replica, and the JGroups
rack of every replica was its node.

- **Scale-up:** six load loops started at 14:29:12. The HorizontalPodAutoscaler set three
  replicas at 14:29:27 and four at 14:29:42, 30.3 s after the load had started; the four replicas
  were ready and members of the cluster 27.7 s after that.
- **Scale-down:** the load stopped at 14:30:10; the first replica was removed at 14:39:13, the
  second one minute later. The status of the HPA (`hpa-status.tsv`) shows why it took nine
  minutes: after the node had been started again in step 4, the two restarted replicas used 2.9
  and 3.1 CPU cores right after they had become ready (`top.tsv`, 14:33:34), the average
  utilization reached 215 % at 14:33:45. The samples from 14:34:16 to 14:34:26 still show 57 %;
  with four replicas and a target of 60 %, this still calls for four replicas. The removal at
  14:39:13 is consistent with the last recommendation for four replicas around 14:34:13 aging
  out of the five-minute window; individual controller recommendations were not recorded.
- **Drain:** the PodDisruptionBudget refused five evictions until a replacement was ready.
- **Node stop:** `docker kill` of the node with replicas `pntvx` and `ztlq7` at 14:32:14.4. The
  other replicas had a settled view 3.2 s after the stop. Both remaining replicas ran on the same
  node, so the step-4 check found 0 of 128 segments with owners on different nodes; this lasted
  until the restarted replicas had joined, 79.2 s after the stop (see [Limits](#limits)).
  Kubernetes reported the node NotReady after 47.5 s and removed the two pods from the Service
  endpoints after 47.6 s. In between, 8 of 16 requests of the ingress probe got no answer within
  5 s; all other answers were correct. The node was Ready 6.5 s after `docker start`, and all four
  replicas were ready and members of the cluster 31.1 s after the start.
- **Rolling update:** to the image of version 1.0.1-SNAPSHOT, which differs from 1.0.0-SNAPSHOT
  in the application layers only, in 50.7 s; one new pod at a time.
- **SIGKILL:** the last answer of `vj5m7` to order form 0 arrived at 14:42:11.289; the `kubectl
  exec` with the SIGKILL ran from 14:42:11.623 to 14:42:11.864. The next postback of the form
  through the ingress got no answer; the second one, 2.5 s after the kill, was served by `7bhr9`
  with the original view and all 27 lines, including the one added by the last answer of
  `vj5m7`. The remaining replica had a settled view after 2.7 s; the restarted container was ready
  and a cluster member 24.8 s after the kill.
- **Graceful shutdown:** every pod stopped with SIGTERM (seven) logged WFLYSRV0211 (suspend),
  WFLYSRV0220 (shutdown requested by OS signal) and WFLYSRV0050 (stopped after 155 to 492 ms).
- **Order forms:** 6 of 6 forms were submitted. For each, the number of rows in `order_line`
  (28 to 30), the sum of `unit_price * quantity` over them and `customer_order.total` matched the
  lines the script had added and the prices it had set (`orders.tsv`), and the `@SessionScoped`
  history of each session held one order.
- **Ingress probe:** 1275 requests from 14:29:04 to 14:42:53: 1267 correct answers, 8 without
  answer (all during the node stop), 0 without the change of a killed replica, 0 wrong.
- **Slow requests.** Of the 168 check postbacks, 22 took longer than 0.2 s: the first check postback
  on a newly started JVM (11 of the 12 JVMs, 0.64 to 1.85 s), two further early postbacks on two of
  these JVMs (0.42 and 0.58 s), six on replica `ztlq7` during the slow phase described under
  [Limits](#limits) (1.06 to 1.13 s), one on a remaining replica right after the node stop (0.53 s),
  one shortly after the restarted replicas had joined (0.56 s) and one 10 s after a replica had left
  (0.45 s). Of the 27 Faces requests through the ingress, five took longer than 0.2 s: the first GET
  and the first postback of the run (0.68 and 2.30 s), the continuation after the SIGKILL (1.00 s)
  and two submissions (0.89 and 0.32 s). Of the probe answers whose request ran within 6 s after one
  of the 10 leaves of a member, 20 of 63 took longer than 0.2 s (at most 1.85 s); of the other 1204
  answers, 46 (at most 1.11 s), 32 of them in the slow phase. The summary lists every slow request,
  the leaves and the definition of the window. An earlier run without `conn_close_timeout=5000`
  ([docs/results/2026-11-10/run-1](docs/results/2026-11-10/run-1/summary.md)) had slow session reads for
  240 s after a replica had left; the analysis is in
  [latency-after-leave](docs/results/2026-11-10/latency-after-leave/README.md).
- **Server archive:** the archive `wildfly-session-scaling-server-1.0.0-SNAPSHOT.tar.gz` held
  `bin/standalone.sh` and `bin/standalone.bat` and the same 765 files with the same content as
  `/opt/server` in the image. Unpacked and started with `bin/standalone.sh` in a container of the
  JRE base image, as user 1001, WildFly started in 14.8 s, `/health/ready` returned HTTP 200 16.0 s
  after `docker run`, a servlet session was created and read, the order form answered, and
  SIGTERM stopped the server (WFLYSRV0050).

Container starts (API server times, one-second resolution; the readiness probe runs every 5 s):

| Containers | WildFly boot (WFLYSRV0025) | Container start to Ready |
| --- | --- | --- |
| 2 at cluster start, started at the same time | 24.2 s, 18.7 s | 26 s, 22 s |
| 2 from the HPA scale-up, started 15 s apart | 19.4 s, 21.8 s | 21 s, 25 s |
| 8 later starts (drain, node restart, rolling update, pod deletion, SIGKILL) | 14.6 to 19.5 s | 15 to 22 s |

Image ([image.md](docs/results/2026-11-10/run-4/image.md), measured with
[measure-image.sh](scripts/measure-image.sh)):

| Layers | Content | Compressed | Shared with the next application version |
| --- | ---: | ---: | --- |
| JRE base image `eclipse-temurin:21.0.13_9-jre-noble` (5 layers) | 292.2 MB | 100.0 MB | yes |
| Server (WildFly provisioned with Galleon, configuration) | 138.8 MB | 119.6 MB | yes |
| Application (`ROOT.war`, PrimeFaces included) | 5.2 MB | 5.2 MB | no |
| JVM arguments; software bill of materials | < 0.1 MB | < 0.1 MB | yes; no |
| Total | 436.3 MB | 224.9 MB | 5.3 MB to pull |

The full WildFly 42.0.0.Final distribution has 601 modules and 317.1 MB unpacked; the
provisioned server in the image has 319 modules and 141.4 MB including the application.

## Limits

- **One host.** The k3d nodes are containers on one machine. The run shows the Kubernetes,
  WildFly and Infinispan mechanics, not behaviour under real network failures. A network
  partition and the loss of two nodes at once were not tested.
- **Two owners, two nodes.** With two owners per session, losing both replicas that hold a session
  at the same time loses that session. The rack setting keeps the two owners on different nodes as
  long as the replicas run on at least two nodes. The pod anti-affinity is only preferred: after the
  drain in step 3 the four replicas ran on two nodes, and the node stop in step 4 left both
  remaining replicas on one node for 79 s, until the restarted replicas had joined (step 4: 0 of 128
  segments with owners on different nodes). A further node failure in that time would have lost
  every session. In production, spread the replicas with `topologySpreadConstraints` over nodes (and
  zones) and keep enough nodes; Kubernetes applies them when it places a pod, so after a drain or a
  node failure the replicas can stay on fewer nodes until they are replaced.
- **Session writes after the response.** WildFly writes the session changes of a request to the
  second owner after the response has been committed (see [Server](#server)). If the JVM dies in
  between, the client has seen the answer, but the changes of that request are lost; the next
  request of the session gets the state before it. Whether a kill hits this window depends on
  timing, and how long the window lasts was not measured. In the recorded run the SIGKILL came 0.33
  to 0.58 s after the last answer of the killed JVM, and the form kept that answer's line. In an
  earlier run of the same day ([run 3](docs/results/2026-11-10/run-3/summary.md),
  whose check counted this case as a failure), the SIGKILL came 0.21 to 0.44 s after
  the last answer, and the continued form had 26 lines instead of 27: the line added by that answer
  was missing (`flows.tsv`, `run.log`). The killed replica was in a slow phase at that time (see the
  latency point below). The check now records such a case as `last-change-lost` instead of failing.
  Only abrupt failures reach this window (SIGKILL, out-of-memory kill, node crash); planned events
  such as scale-down, rollout and drain end a replica with SIGTERM, which lets running requests
  finish and their session changes reach the second owner before the server stops, and none of
  them lost a change in the run. Changes that must survive an abrupt failure belong in the database
  transaction of the request, which commits before the response is sent, as the order submit does
  here; the session then holds only the unsaved state of the current step.
- **Requests to a stopped node.** After the node stop, the ingress kept sending requests to the
  replicas of the stopped node until Kubernetes marked the node NotReady and removed their
  endpoints (47.6 s with the k3s defaults). These requests got no answer within 5 s; the probe
  counted 8 of them. A shorter window needs a shorter node monitor grace period, or retries
  and passive health checks in the ingress controller; neither was configured or tested.
- **Pods on fixed nodes.** The run scales pods on three nodes that exist for the whole run. Adding
  and removing nodes (Cluster Autoscaler or the node autoscaling of a cloud provider) was not part
  of it; when no node has room for a new pod, a scale-up also waits for a new node.
- **Synthetic load, one run.** The load is a CPU loop, the sessions are small, and the results
  come from one run. They contain no statement about latency under load, throughput or the
  memory cost of large sessions; the size of the replicated Faces state was not measured.
- **System components.** k3s runs CoreDNS, Traefik, metrics-server and local-path-provisioner as
  single replicas; the check moves them and the database to the server node and stops only agent
  nodes. The drain evicts the demo pods only (`--pod-selector`). The database is a single
  PostgreSQL replica with an `emptyDir`; its failure was not part of the check.
- **Affinity and locks.** WildFly appends the route of a session's primary owner to the session
  ID (affinity `primary-owner`, the default of `distributable-web`); a load balancer can route by
  it or by a cookie of its own; the ingress here does not, on purpose (see
  [Architecture](#architecture)). A replica that is not an owner locks and reads the
  session remotely; on the primary owner both are local. Requests of one session are serialized
  by an Infinispan lock across the cluster. The check sends the requests of a session one after
  another; concurrent requests of one session (several browser tabs, parallel Ajax requests) were
  not measured.
- **Rolling update.** Both images were built from the same sources with different versions; the
  classes stored in the session did not change. A release that changes them must keep the stored
  state readable for the replicas of the previous version during the update.
- **Request paths.** The check reads sessions and posts the Faces forms on every replica through
  `kubectl port-forward`, so that every replica is checked. Through the ingress go the creation
  of sessions and forms, the load requests, the probe session, the postback before the SIGKILL,
  the continuation after it, the review and submission of all forms, and the final check that a
  request without a cookie gets no session. The client is `curl`, not a browser: it sends the
  same form fields and Ajax parameters as PrimeFaces, but no JavaScript ran.
- **Latency after a replica leaves.** With `conn_close_timeout=5000`, a remaining replica that still
  holds an unacknowledged message for a removed pod can be slow for about five seconds after the pod
  has left. In the recorded run, 20 of the 63 probe answers whose request ran within 6 s after a
  leave took longer than 0.2 s, the slowest 1.85 s. Longer slow phases occurred as well: after the
  drain, from the leave of `zvd79` at 14:30:44 until replica `ztlq7` was stopped with its node at
  14:32:14, 18 of the 30 probe answers of `ztlq7` took 0.34 to 1.20 s and 19 of the 76 answers of
  the other replicas 0.20 to 0.68 s. In run 3, after the pod deletion of step 7,
  replica `lp9r8` had slow answers in the 37 s until it was killed in step 8 (13 of its 31 answers
  0.31 to 0.96 s, 13 of 13 answers of the other replica 0.35 to 1.78 s). It still answered quickly
  at 14:19:28; all its later probe answers until the kill at 14:19:53 were slow. There the durations
  lie close to 0.35, 0.65 and 0.95 s, the steps of about 0.3 s explained in the analysis. Whether
  these phases would have ended on their own, and why `conn_close_timeout` did not end them, was
  not examined. A sender thread per destination in JGroups would keep that wait away from the messages to the other
  replicas, but WildFly 42 does not accept the property (`WFLYCLJG0031`), so it was not tested.
- **Log messages.** Besides the startup warnings named here (`WFLYCLJG0039`, `WFLYCLJG0040`,
  `WFLYSRV0018`, `WFLYTX0013`, once per container start), the logs contain `ISPN000312` ("lost
  data because of graceful leaver", five times) for the second-level cache region of `Product`,
  whose invalidation cache holds only local copies of database rows, and from JGroups
  `failed handling message: java.io.IOException: Stream closed` (twice) and `failed sending
  graceful close … Socket closed` (once) for connections of members that were leaving. None of
  them was followed by a failed check; the summary of the run counts every WARN and ERROR message.
  Partition handling is not enabled (WildFly default), so after a real network partition both
  halves would keep serving and could change the same session differently; that case was not
  tested.
- **Owner diagnostics.** `ClusterServlet` uses Infinispan classes from the private server module
  `org.infinispan.core` (WildFly logs `WFLYSRV0018`). It exists to make the owner placement
  visible; an application does not need it.
- **Cluster traffic.** JGroups traffic is neither encrypted nor authenticated (WildFly logs
  `WFLYCLJG0039` and `WFLYCLJG0040`). Restrict it with a NetworkPolicy that allows ports 7600
  and 7601 between the replicas only, or configure encryption and authentication in the JGroups
  stack.
- **Transactions.** The layers include the transactions subsystem; WildFly logs `WFLYTX0013`
  about the default node identifier. The demo uses local JTA transactions against one database.
  An application with XA transactions needs a unique node identifier per replica and a recovery
  concept, which is out of scope here.
- **Management interface.** The probes need the management port on all interfaces. No
  management user is configured, so management operations over HTTP are not possible.
- **Platform.** The image is built for `amd64` only (property `image.architecture`).
- **Not run.** The Windows and Podman instructions, a build with a local JDK and the start of the
  server archive on Windows (`bin\standalone.bat`) were not executed for the recorded results.
  The Maven Wrapper does not verify a checksum of the Maven distribution; the reason is in
  `.mvn/wrapper/maven-wrapper.properties`.

## License

Apache License 2.0, see [LICENSE](LICENSE).
