Build of 766f719 on the test host (Debian 13, Docker 29.9.2) in eclipse-temurin:21.0.13_9-jdk-noble:

    ./mvnw -B -q clean package jib:dockerBuild
    ./mvnw -B -q package jib:dockerBuild -Drevision=1.0.1-SNAPSHOT

    Apache Maven 3.9.16 (2bdd9fddda4b155ebf8000e807eb73fd829a51d5)
    Maven home: /root/.m2/wrapper/dists/apache-maven-3.9.16/56ba1f9f
    Java version: 21.0.13, vendor: Eclipse Adoptium, runtime: /opt/java/openjdk
    Default locale: en_US, platform encoding: UTF-8
    OS name: "linux", version: "6.12.115+deb13.1-amd64", arch: "amd64", family: "unix"
    wildfly-session-scaling:1.0.0-SNAPSHOT sha256:550c8445c40517a29ea6dc51f5c2a6883a8f0b4644fb1add227a4589bc88a003
    wildfly-session-scaling:1.0.1-SNAPSHOT sha256:f6dab62888a658a6e31778e70d521f75cb57bf93992153dd47314a8580fde346
