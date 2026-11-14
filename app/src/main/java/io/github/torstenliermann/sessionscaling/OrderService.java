package io.github.torstenliermann.sessionscaling;

import jakarta.enterprise.context.ApplicationScoped;
import jakarta.persistence.EntityManager;
import jakarta.persistence.PersistenceContext;
import jakarta.transaction.Transactional;
import java.math.BigDecimal;
import java.time.Instant;
import java.util.List;

/** Data access for the catalog and the orders, persistence unit {@code orders}. */
@ApplicationScoped
public class OrderService {

    @PersistenceContext(unitName = "orders")
    private EntityManager entityManager;

    public List<Product> products() {
        return entityManager.createQuery("select p from Product p order by p.id", Product.class).getResultList();
    }

    /** Reads a product; served from the second-level cache of this replica when it holds the entry. */
    public Product product(long id) {
        Product product = entityManager.find(Product.class, id);
        if (product == null) {
            throw new IllegalArgumentException("no product " + id);
        }
        return product;
    }

    /** Changes the price; on commit the cache entry is invalidated on every replica. */
    @Transactional
    public Product changePrice(long id, BigDecimal price) {
        Product product = product(id);
        product.changePrice(price);
        entityManager.flush();
        return product;
    }

    @Transactional
    public long submit(String customer, List<OrderLineDraft> lines, String submittedBy) {
        CustomerOrder order = new CustomerOrder(customer, submittedBy, Instant.now());
        for (OrderLineDraft line : lines) {
            order.addLine(entityManager.getReference(Product.class, line.getProductId()), line.getQuantity(),
                    line.getUnitPrice());
        }
        entityManager.persist(order);
        entityManager.flush();
        return order.getId();
    }

    /** Reads a submitted order with its lines from the database. */
    public CustomerOrder order(long id) {
        return entityManager
                .createQuery("select o from CustomerOrder o left join fetch o.lines where o.id = :id", CustomerOrder.class)
                .setParameter("id", id)
                .getSingleResult();
    }
}
