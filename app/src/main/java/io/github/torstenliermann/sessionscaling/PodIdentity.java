package io.github.torstenliermann.sessionscaling;

import jakarta.enterprise.context.ApplicationScoped;
import jakarta.inject.Named;

/**
 * Identifies the replica that answers a request. Kubernetes passes pod name and node name
 * through the Downward API (see k8s/deployment.yaml). The Faces page shows it as
 * {@code #{podIdentity.podName()}}.
 */
@Named
@ApplicationScoped
public class PodIdentity {

    private final String podName = env("POD_NAME", System.getProperty("jboss.node.name", "unknown"));
    private final String nodeName = env("NODE_NAME", "unknown");

    public String podName() {
        return podName;
    }

    public String nodeName() {
        return nodeName;
    }

    private static String env(String name, String fallback) {
        String value = System.getenv(name);
        return value == null || value.isBlank() ? fallback : value;
    }
}
