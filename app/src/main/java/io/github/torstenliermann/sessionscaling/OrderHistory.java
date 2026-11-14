package io.github.torstenliermann.sessionscaling;

import jakarta.enterprise.context.SessionScoped;
import jakarta.inject.Named;
import java.io.Serializable;
import java.util.ArrayList;
import java.util.List;

/** The orders submitted in this HTTP session: session state of the Faces frontend. */
@Named
@SessionScoped
public class OrderHistory implements Serializable {

    private static final long serialVersionUID = 1L;

    private final List<Long> orderIds = new ArrayList<>();

    void add(long orderId) {
        orderIds.add(orderId);
    }

    public int getCount() {
        return orderIds.size();
    }

    public List<Long> getOrderIds() {
        return List.copyOf(orderIds);
    }
}
