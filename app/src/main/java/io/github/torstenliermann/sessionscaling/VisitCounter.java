package io.github.torstenliermann.sessionscaling;

import jakarta.enterprise.context.SessionScoped;
import java.io.Serializable;

/**
 * Session state held in a CDI bean. Weld stores the instance in the HTTP session,
 * so it is replicated together with the plain session attributes.
 */
@SessionScoped
public class VisitCounter implements Serializable {

    private static final long serialVersionUID = 1L;

    private String token;
    private int visits;

    public void start(String token) {
        this.token = token;
        this.visits = 1;
    }

    public void increment() {
        visits++;
    }

    public String token() {
        return token;
    }

    public int visits() {
        return visits;
    }
}
