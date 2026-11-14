package io.github.torstenliermann.sessionscaling;

import jakarta.inject.Inject;
import jakarta.servlet.annotation.WebServlet;
import jakarta.servlet.http.HttpServlet;
import jakarta.servlet.http.HttpServletRequest;
import jakarta.servlet.http.HttpServletResponse;
import java.io.IOException;
import java.nio.charset.StandardCharsets;
import java.security.MessageDigest;
import java.security.NoSuchAlgorithmException;
import java.util.Map;

/**
 * Burns CPU for the requested number of milliseconds (at most one second) without touching
 * any session. The demo uses it to drive the HorizontalPodAutoscaler.
 */
@WebServlet("/load")
public class LoadServlet extends HttpServlet {

    private static final long serialVersionUID = 1L;
    private static final long MAX_MILLIS = 1000;

    @Inject
    private PodIdentity pod;

    @Override
    protected void doGet(HttpServletRequest request, HttpServletResponse response) throws IOException {
        long millis = parse(request.getParameter("ms"));
        long deadline = System.nanoTime() + millis * 1_000_000L;
        byte[] data = pod.podName().getBytes(StandardCharsets.UTF_8);
        long rounds = 0;
        try {
            MessageDigest digest = MessageDigest.getInstance("SHA-256");
            while (System.nanoTime() < deadline) {
                data = digest.digest(data);
                rounds++;
            }
        } catch (NoSuchAlgorithmException e) {
            throw new IllegalStateException(e);
        }
        Json.write(response, HttpServletResponse.SC_OK,
                Map.of("servedBy", pod.podName(), "millis", millis, "rounds", rounds));
    }

    private static long parse(String value) {
        try {
            return Math.max(0, Math.min(MAX_MILLIS, Long.parseLong(value)));
        } catch (NumberFormatException | NullPointerException e) {
            return 50;
        }
    }
}
