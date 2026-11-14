package io.github.torstenliermann.sessionscaling;

import jakarta.annotation.PostConstruct;
import jakarta.faces.application.FacesMessage;
import jakarta.faces.context.FacesContext;
import jakarta.faces.view.ViewScoped;
import jakarta.inject.Inject;
import jakarta.inject.Named;
import java.io.Serializable;
import java.math.BigDecimal;
import java.util.ArrayList;
import java.util.List;
import java.util.UUID;

/**
 * The state of one order form in order.xhtml, a flow in four steps: customer, lines, review,
 * confirmation. The bean lives as long as the view; Mojarra keeps it, together with the
 * component state of the view (server-side state saving), in the HTTP session. With
 * {@code <distributable/>} WildFly replicates both, so any replica can process the next postback.
 *
 * <p>{@code instanceId} is fixed when the bean is created. If a later postback shows the same
 * value, the request was processed with the state of the original view, not with a new one.
 */
@Named
@ViewScoped
public class OrderWizard implements Serializable {

    private static final long serialVersionUID = 1L;

    @Inject
    private OrderService orders;

    @Inject
    private OrderHistory history;

    @Inject
    private PodIdentity pod;

    private final String instanceId = UUID.randomUUID().toString();
    private final List<OrderLineDraft> lines = new ArrayList<>();
    private String createdBy;
    private int step = 1;
    private int actions;
    private String customer;
    private Long productId;
    private Integer quantity = 1;
    private Long orderId;
    private transient CustomerOrder storedOrder;

    @PostConstruct
    void init() {
        createdBy = pod.podName();
    }

    public void toItems() {
        actions++;
        step = 2;
    }

    public void addLine() {
        actions++;
        Product product = orders.product(productId);
        lines.add(new OrderLineDraft(product.getId(), product.getName(), quantity, product.getPrice()));
    }

    public void toReview() {
        actions++;
        if (lines.isEmpty()) {
            FacesContext.getCurrentInstance().addMessage(null,
                    new FacesMessage(FacesMessage.SEVERITY_WARN, "Add at least one line.", null));
            return;
        }
        step = 3;
    }

    public void submit() {
        actions++;
        orderId = orders.submit(customer, lines, pod.podName());
        history.add(orderId);
        step = 4;
    }

    public List<Product> getProducts() {
        return orders.products();
    }

    public BigDecimal getTotal() {
        return lines.stream().map(OrderLineDraft::getAmount).reduce(BigDecimal.ZERO, BigDecimal::add);
    }

    /** The submitted order as stored in the database (step 4). */
    public CustomerOrder getStoredOrder() {
        if (orderId != null && storedOrder == null) {
            storedOrder = orders.order(orderId);
        }
        return storedOrder;
    }

    public String getInstanceId() {
        return instanceId;
    }

    public String getCreatedBy() {
        return createdBy;
    }

    public int getStep() {
        return step;
    }

    public int getActions() {
        return actions;
    }

    public List<OrderLineDraft> getLines() {
        return lines;
    }

    public OrderLineDraft getLastLine() {
        return lines.isEmpty() ? null : lines.get(lines.size() - 1);
    }

    public Long getOrderId() {
        return orderId;
    }

    public String getCustomer() {
        return customer;
    }

    public void setCustomer(String customer) {
        this.customer = customer;
    }

    public Long getProductId() {
        return productId;
    }

    public void setProductId(Long productId) {
        this.productId = productId;
    }

    public Integer getQuantity() {
        return quantity;
    }

    public void setQuantity(Integer quantity) {
        this.quantity = quantity;
    }
}
