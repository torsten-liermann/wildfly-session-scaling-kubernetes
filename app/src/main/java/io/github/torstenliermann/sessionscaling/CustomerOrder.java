package io.github.torstenliermann.sessionscaling;

import jakarta.persistence.CascadeType;
import jakarta.persistence.Column;
import jakarta.persistence.Entity;
import jakarta.persistence.GeneratedValue;
import jakarta.persistence.GenerationType;
import jakarta.persistence.Id;
import jakarta.persistence.OneToMany;
import jakarta.persistence.OrderBy;
import jakarta.persistence.Table;
import java.math.BigDecimal;
import java.time.Instant;
import java.util.ArrayList;
import java.util.List;

/** An order submitted at the end of the Faces flow in order.xhtml. */
@Entity
@Table(name = "customer_order")
public class CustomerOrder {

    @Id
    @GeneratedValue(strategy = GenerationType.IDENTITY)
    private Long id;

    @Column(nullable = false, length = 100)
    private String customer;

    @Column(name = "submitted_at", nullable = false)
    private Instant submittedAt;

    @Column(name = "submitted_by", nullable = false, length = 100)
    private String submittedBy;

    @Column(nullable = false, precision = 12, scale = 2)
    private BigDecimal total = BigDecimal.ZERO;

    @OneToMany(mappedBy = "order", cascade = CascadeType.PERSIST)
    @OrderBy("id")
    private List<OrderLine> lines = new ArrayList<>();

    protected CustomerOrder() {
    }

    CustomerOrder(String customer, String submittedBy, Instant submittedAt) {
        this.customer = customer;
        this.submittedBy = submittedBy;
        this.submittedAt = submittedAt;
    }

    void addLine(Product product, int quantity, BigDecimal unitPrice) {
        OrderLine line = new OrderLine(this, product, quantity, unitPrice);
        lines.add(line);
        total = total.add(line.getAmount());
    }

    public Long getId() {
        return id;
    }

    public String getCustomer() {
        return customer;
    }

    public Instant getSubmittedAt() {
        return submittedAt;
    }

    public String getSubmittedBy() {
        return submittedBy;
    }

    public BigDecimal getTotal() {
        return total;
    }

    public List<OrderLine> getLines() {
        return lines;
    }
}
