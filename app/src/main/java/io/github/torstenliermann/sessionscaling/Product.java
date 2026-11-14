package io.github.torstenliermann.sessionscaling;

import jakarta.persistence.Cacheable;
import jakarta.persistence.Column;
import jakarta.persistence.Entity;
import jakarta.persistence.Id;
import jakarta.persistence.Table;
import jakarta.persistence.Version;
import java.math.BigDecimal;

/**
 * A catalog entry. {@code @Cacheable} with {@code shared-cache-mode ENABLE_SELECTIVE} in
 * persistence.xml puts loaded products into the Hibernate second-level cache. With the Galleon
 * layer {@code jpa-distributed} that cache is an Infinispan invalidation cache: every replica keeps
 * its own copy of the products it has read, and a change on one replica removes the entry on all
 * others.
 */
@Entity
@Table(name = "product")
@Cacheable
public class Product {

    @Id
    private long id;

    @Column(nullable = false, length = 100)
    private String name;

    @Column(nullable = false, precision = 10, scale = 2)
    private BigDecimal price;

    @Version
    private long version;

    protected Product() {
    }

    public long getId() {
        return id;
    }

    public String getName() {
        return name;
    }

    public BigDecimal getPrice() {
        return price;
    }

    public long getVersion() {
        return version;
    }

    void changePrice(BigDecimal newPrice) {
        this.price = newPrice;
    }
}
