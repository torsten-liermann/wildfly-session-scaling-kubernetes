package io.github.torstenliermann.sessionscaling;

import java.io.Serializable;
import java.math.BigDecimal;

/** A line of the order that is being entered; part of the view state of {@link OrderWizard}. */
public class OrderLineDraft implements Serializable {

    private static final long serialVersionUID = 1L;

    private final long productId;
    private final String productName;
    private final int quantity;
    private final BigDecimal unitPrice;

    public OrderLineDraft(long productId, String productName, int quantity, BigDecimal unitPrice) {
        this.productId = productId;
        this.productName = productName;
        this.quantity = quantity;
        this.unitPrice = unitPrice;
    }

    public long getProductId() {
        return productId;
    }

    public String getProductName() {
        return productName;
    }

    public int getQuantity() {
        return quantity;
    }

    public BigDecimal getUnitPrice() {
        return unitPrice;
    }

    public BigDecimal getAmount() {
        return unitPrice.multiply(BigDecimal.valueOf(quantity));
    }
}
