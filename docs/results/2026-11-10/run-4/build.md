Build of 985bbef on the test host (Debian 13, Docker 29.9.2) in eclipse-temurin:21.0.13_9-jdk-noble, with the
Maven repository in the volume wildfly-session-scaling-m2 (see the README, Quick start):

    ./mvnw -B -q clean package jib:dockerBuild
    ./mvnw -B -q package jib:dockerBuild -Drevision=1.0.1-SNAPSHOT

    Apache Maven 3.9.16 (2bdd9fddda4b155ebf8000e807eb73fd829a51d5)
    Maven home: /root/.m2/wrapper/dists/apache-maven-3.9.16/56ba1f9f
    Java version: 21.0.13, vendor: Eclipse Adoptium, runtime: /opt/java/openjdk
    Default locale: en_US, platform encoding: UTF-8
    OS name: "linux", version: "6.12.115+deb13.1-amd64", arch: "amd64", family: "unix"

Images and server archives:

    wildfly-session-scaling:1.0.0-SNAPSHOT sha256:cb9a92fc5d4d62b1206b4e264563e8a4305a795ad77c5fea8d6ff872f7b235d1
    wildfly-session-scaling:1.0.1-SNAPSHOT sha256:78eea48b4277ed12137c9f684381b401d0181e69e2c1ce194408014c9c6ea924
    image/target/wildfly-session-scaling-server-1.0.0-SNAPSHOT.tar.gz  124857927 bytes
    image/target/wildfly-session-scaling-server-1.0.0-SNAPSHOT.zip  125359590 bytes
    image/target/wildfly-session-scaling-server-1.0.1-SNAPSHOT.tar.gz  124858079 bytes
    image/target/wildfly-session-scaling-server-1.0.1-SNAPSHOT.zip  125359588 bytes
    1ac93bd2d345721afe4c83fe7f52b92310788db67e0f92ecc3016bfaea19c128  image/target/wildfly-session-scaling-server-1.0.0-SNAPSHOT.tar.gz
    05b73cfae8e85ffce6b5fb6f592726ef0e83a5b3ed461aafe92e85516245b09f  image/target/wildfly-session-scaling-server-1.0.1-SNAPSHOT.tar.gz
    a8b6674994b84909688ae295cd2185ae8b3a2044cb4721096b3f47260e90b5b0  image/target/wildfly-session-scaling-server-1.0.0-SNAPSHOT.zip
    737608c07459dc41050ccddf0a98cef41f22eb5609b5022744aa87dad212b7e8  image/target/wildfly-session-scaling-server-1.0.1-SNAPSHOT.zip
