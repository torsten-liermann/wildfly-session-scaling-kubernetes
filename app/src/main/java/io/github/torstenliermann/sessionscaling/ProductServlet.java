package io.github.torstenliermann.sessionscaling;

import jakarta.inject.Inject;
import jakarta.persistence.EntityManagerFactory;
import jakarta.persistence.PersistenceUnit;
import jakarta.servlet.annotation.WebServlet;
import jakarta.servlet.http.HttpServlet;
import jakarta.servlet.http.HttpServletRequest;
import jakarta.servlet.http.HttpServletResponse;
import java.io.IOException;
import java.math.BigDecimal;
import java.util.LinkedHashMap;
import java.util.Map;

/**
 * Makes the second-level cache of the replica that answers visible.
 *
 * <p>GET {@code /product?id=1} reads the product and reports whether this replica held it in its
 * second-level cache before and after the read ({@link jakarta.persistence.Cache#contains}).
 * POST {@code /product?id=1&price=7.10} changes the price in a transaction. A GET on another
 * replica afterwards must report {@code cachedBeforeRead: false} (the entry was invalidated) and
 * the new price.
 */
@WebServlet("/product")
public class ProductServlet extends HttpServlet {

    private static final long serialVersionUID = 1L;

    @PersistenceUnit(unitName = "orders")
    private EntityManagerFactory entityManagerFactory;

    @Inject
    private OrderService orders;

    @Inject
    private PodIdentity pod;

    @Override
    protected void doGet(HttpServletRequest request, HttpServletResponse response) throws IOException {
        Long id = id(request, response);
        if (id == null) {
            return;
        }
        boolean cachedBefore = entityManagerFactory.getCache().contains(Product.class, id);
        Product product = orders.product(id);
        boolean cachedAfter = entityManagerFactory.getCache().contains(Product.class, id);
        Map<String, Object> body = describe(product);
        body.put("cachedBeforeRead", cachedBefore);
        body.put("cachedAfterRead", cachedAfter);
        Json.write(response, HttpServletResponse.SC_OK, body);
    }

    @Override
    protected void doPost(HttpServletRequest request, HttpServletResponse response) throws IOException {
        Long id = id(request, response);
        if (id == null) {
            return;
        }
        BigDecimal price;
        try {
            price = new BigDecimal(request.getParameter("price"));
        } catch (NumberFormatException | NullPointerException e) {
            Json.write(response, HttpServletResponse.SC_BAD_REQUEST, Map.of("error", "parameter price missing"));
            return;
        }
        Json.write(response, HttpServletResponse.SC_OK, describe(orders.changePrice(id, price)));
    }

    private Map<String, Object> describe(Product product) {
        Map<String, Object> body = new LinkedHashMap<>();
        body.put("id", product.getId());
        body.put("name", product.getName());
        body.put("price", product.getPrice());
        body.put("version", product.getVersion());
        body.put("servedBy", pod.podName());
        body.put("servedByNode", pod.nodeName());
        return body;
    }

    private static Long id(HttpServletRequest request, HttpServletResponse response) throws IOException {
        try {
            return Long.valueOf(request.getParameter("id"));
        } catch (NumberFormatException e) {
            Json.write(response, HttpServletResponse.SC_BAD_REQUEST, Map.of("error", "parameter id missing"));
            return null;
        }
    }
}
