commit: 985bbef
date: 2026-11-10, after the build and before the k3d run; command: FULL_DISTRIBUTION=true scripts/measure-image.sh wildfly-session-scaling:1.0.0-SNAPSHOT wildfly-session-scaling:1.0.1-SNAPSHOT
Image wildfly-session-scaling:1.0.0-SNAPSHOT (sha256:cb9a92fc5d4d)
compared with wildfly-session-scaling:1.0.1-SNAPSHOT (sha256:78eea48b4277)

| Layer | Created by | Content (MB) | Compressed (MB) | Same in wildfly-session-scaling:1.0.1-SNAPSHOT |
| --- | --- | ---: | ---: | --- |
| 1 bec87777bc2f | /bin/sh -c #(nop) ADD file:eed88e94d6aa7c9da62836e137f889e03 | 80.7 | 29.8 | yes |
| 2 67822e3abc85 | RUN /bin/sh -c set -eux;     apt-get update;     DEBIAN_FRON | 45.7 | 17.0 | yes |
| 3 d390ebe61192 | RUN /bin/sh -c set -eux;     ARCH="$(dpkg --print-architectu | 165.8 | 53.2 | yes |
| 4 39598f2f1942 | RUN /bin/sh -c set -eux;     echo "Verifying install ...";   | 0.0 | 0.0 | yes |
| 5 797cce5c7d95 | COPY --chmod=755 entrypoint.sh /__cacert_entrypoint.sh # bui | 0.0 | 0.0 | yes |
| 6 85ae5087c4da | jib-maven-plugin:3.5.2 | 0.0 | 0.0 | yes |
| 7 00705f6e8e5e | jib-maven-plugin:3.5.2 | 138.8 | 119.6 | yes |
| 8 e295e1a462cd | jib-maven-plugin:3.5.2 | 5.2 | 5.2 | no |
| 9 4a3a0f5fb0ae | jib-maven-plugin:3.5.2 | 0.0 | 0.0 | no |

Total: 436.3 MB content, 224.9 MB compressed; added by this build (jib-maven-plugin layers): 144.1 MB content, 124.9 MB compressed.
Layers of wildfly-session-scaling:1.0.0-SNAPSHOT that wildfly-session-scaling:1.0.1-SNAPSHOT does not share: 5.3 MB compressed; a node that runs wildfly-session-scaling:1.0.0-SNAPSHOT pulls only these for wildfly-session-scaling:1.0.1-SNAPSHOT.

Full WildFly 42.0.0.Final distribution: 261.5 MB download, 317.1 MB unpacked, 601 modules
Provisioned server in the image (/opt/server, with the application): 141.4 MB, 319 modules
