package io.github.torstenliermann.sessionscaling;

import jakarta.inject.Inject;
import jakarta.servlet.annotation.WebServlet;
import jakarta.servlet.http.HttpServlet;
import jakarta.servlet.http.HttpServletRequest;
import jakarta.servlet.http.HttpServletResponse;
import jakarta.servlet.http.HttpSession;
import java.io.IOException;
import java.time.Instant;
import java.util.LinkedHashMap;
import java.util.Map;
import java.util.UUID;

/**
 * POST creates a session, GET reads it and counts the request.
 *
 * <p>The session carries the same information twice: as plain session attributes and in the
 * {@link VisitCounter} CDI bean. Both counters are written on every request, so a reader on any
 * replica sees whether the latest write was replicated.
 */
@WebServlet("/session")
public class SessionServlet extends HttpServlet {

    private static final long serialVersionUID = 1L;

    static final String TOKEN = "token";
    static final String CREATED_BY = "createdBy";
    static final String CREATED_ON_NODE = "createdOnNode";
    static final String CREATED_AT = "createdAt";
    static final String REQUEST_COUNT = "requestCount";

    @Inject
    private VisitCounter visits;

    @Inject
    private PodIdentity pod;

    @Override
    protected void doPost(HttpServletRequest request, HttpServletResponse response) throws IOException {
        HttpSession existing = request.getSession(false);
        if (existing != null) {
            Json.write(response, HttpServletResponse.SC_CONFLICT,
                    Map.of("error", "request already belongs to a session", "servedBy", pod.podName()));
            return;
        }
        HttpSession session = request.getSession(true);
        String token = UUID.randomUUID().toString();
        session.setAttribute(TOKEN, token);
        session.setAttribute(CREATED_BY, pod.podName());
        session.setAttribute(CREATED_ON_NODE, pod.nodeName());
        session.setAttribute(CREATED_AT, Instant.now().toString());
        session.setAttribute(REQUEST_COUNT, 1);
        visits.start(token);
        Json.write(response, HttpServletResponse.SC_CREATED, describe(session));
    }

    @Override
    protected void doGet(HttpServletRequest request, HttpServletResponse response) throws IOException {
        HttpSession session = request.getSession(false);
        if (session == null) {
            Json.write(response, HttpServletResponse.SC_NOT_FOUND,
                    Map.of("error", "no session for this request", "servedBy", pod.podName()));
            return;
        }
        Integer count = (Integer) session.getAttribute(REQUEST_COUNT);
        session.setAttribute(REQUEST_COUNT, count == null ? 1 : count + 1);
        visits.increment();
        Json.write(response, HttpServletResponse.SC_OK, describe(session));
    }

    private Map<String, Object> describe(HttpSession session) {
        Map<String, Object> body = new LinkedHashMap<>();
        body.put("sessionId", session.getId());
        body.put("new", session.isNew());
        body.put("token", session.getAttribute(TOKEN));
        body.put("requestCount", session.getAttribute(REQUEST_COUNT));
        body.put("beanToken", visits.token());
        body.put("beanVisits", visits.visits());
        body.put("createdBy", session.getAttribute(CREATED_BY));
        body.put("createdOnNode", session.getAttribute(CREATED_ON_NODE));
        body.put("createdAt", session.getAttribute(CREATED_AT));
        body.put("servedBy", pod.podName());
        body.put("servedByNode", pod.nodeName());
        return body;
    }
}
