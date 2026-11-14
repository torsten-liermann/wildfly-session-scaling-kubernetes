package io.github.torstenliermann.sessionscaling;

import jakarta.annotation.Resource;
import jakarta.inject.Inject;
import jakarta.servlet.annotation.WebServlet;
import jakarta.servlet.http.HttpServlet;
import jakarta.servlet.http.HttpServletRequest;
import jakarta.servlet.http.HttpServletResponse;
import java.io.IOException;
import java.util.ArrayList;
import java.util.HashSet;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;
import java.util.Objects;
import java.util.Set;
import java.util.TreeMap;
import java.util.TreeSet;
import org.infinispan.Cache;
import org.infinispan.distribution.ch.ConsistentHash;
import org.infinispan.manager.EmbeddedCacheManager;
import org.infinispan.remoting.transport.Address;
import org.infinispan.topology.CacheTopology;

/**
 * Diagnostics for the demo only: reports where Infinispan keeps the copies of the session data.
 *
 * <p>For every distributed cache of the {@code web} cache container it counts the segments whose
 * owners carry different {@code rack} values. The rack value is the Kubernetes node name, so
 * "distinct racks" means the two copies of a session are on two different nodes. An application
 * does not need any of this; it relies on Infinispan internals and a private server module.
 */
@WebServlet("/cluster")
public class ClusterServlet extends HttpServlet {

    private static final long serialVersionUID = 1L;

    @Resource(lookup = "java:jboss/infinispan/container/web")
    private EmbeddedCacheManager cacheManager;

    @Inject
    private PodIdentity pod;

    @Override
    protected void doGet(HttpServletRequest request, HttpServletResponse response) throws IOException {
        Map<String, Object> body = new LinkedHashMap<>();
        body.put("servedBy", pod.podName());
        body.put("servedByNode", pod.nodeName());
        Address local = cacheManager.getAddress();
        body.put("localMember", member(local));

        List<Object> members = new ArrayList<>();
        List<Address> clusterMembers = cacheManager.getMembers();
        if (clusterMembers != null) {
            clusterMembers.forEach(member -> members.add(member(member)));
        }
        body.put("members", members);

        List<Object> caches = new ArrayList<>();
        for (String name : new TreeSet<>(cacheManager.getCacheNames())) {
            if (!cacheManager.isRunning(name)) {
                continue;
            }
            Cache<?, ?> cache = cacheManager.getCache(name, false);
            if (cache == null || !cache.getCacheConfiguration().clustering().cacheMode().isDistributed()) {
                continue;
            }
            caches.add(describe(name, cache));
        }
        body.put("distributedCaches", caches);
        Json.write(response, HttpServletResponse.SC_OK, body);
    }

    private static Map<String, Object> describe(String name, Cache<?, ?> cache) {
        CacheTopology topology = cache.getAdvancedCache().getDistributionManager().getCacheTopology();
        ConsistentHash hash = topology.getCurrentCH();
        int segments = hash.getNumSegments();
        int withTwoOrMoreOwners = 0;
        int ownersOnDistinctRacks = 0;
        Map<String, Integer> primarySegmentsByRack = new TreeMap<>();
        for (int segment = 0; segment < segments; segment++) {
            List<Address> owners = hash.locateOwnersForSegment(segment);
            if (owners.size() >= 2) {
                withTwoOrMoreOwners++;
            }
            Set<String> racks = new HashSet<>();
            owners.forEach(owner -> racks.add(Objects.toString(owner.getRackId())));
            if (owners.size() >= 2 && racks.size() == owners.size()) {
                ownersOnDistinctRacks++;
            }
            primarySegmentsByRack.merge(Objects.toString(owners.get(0).getRackId()), 1, Integer::sum);
        }
        Map<String, Object> result = new LinkedHashMap<>();
        result.put("name", name);
        result.put("owners", cache.getCacheConfiguration().clustering().hash().numOwners());
        result.put("topologyId", topology.getTopologyId());
        result.put("phase", topology.getPhase().name());
        result.put("stable", topology.getPendingCH() == null
                && topology.getPhase() == CacheTopology.Phase.NO_REBALANCE);
        result.put("members", hash.getMembers().size());
        result.put("segments", segments);
        result.put("segmentsWithTwoOwners", withTwoOrMoreOwners);
        result.put("segmentsWithOwnersOnDistinctNodes", ownersOnDistinctRacks);
        result.put("primarySegmentsByNode", primarySegmentsByRack);
        return result;
    }

    private static Map<String, Object> member(Address address) {
        Map<String, Object> member = new LinkedHashMap<>();
        if (address == null) {
            member.put("name", "none");
            return member;
        }
        member.put("name", address.toString());
        member.put("site", address.getSiteId());
        member.put("rack", address.getRackId());
        member.put("machine", address.getMachineId());
        return member;
    }
}
