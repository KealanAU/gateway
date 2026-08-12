# --- Gateway postamble (runs after user VCL) ---
sub vcl_recv {
    # Deferred pass: ghost sets X-Ghost-Pass instead of calling ctx.set_pass()
    # so that user VCL subroutines get a chance to run first.
    if (req.http.X-Ghost-Pass) {
        unset req.http.X-Ghost-Pass;
        return (pass);
    }
}

sub vcl_backend_error {
    # A fetch failure on a route with timeouts.backendRequest set reports 504
    # instead of Varnish's default 503. Routes without a timeout keep 503.
    #
    # Only status and reason are touched — deliberately no return(deliver) — so
    # builtin.vcl still renders the error body, and a user vcl_backend_error that
    # returns first keeps full control (its return means this never runs).
    #
    # Note: this cannot distinguish a timeout from any other fetch failure on a
    # timeout-configured route. A refused connection on such a route also reports
    # 504. Varnish exposes no failure reason in vcl_backend_error.
    if (bereq.http.X-Ghost-Timeout) {
        set beresp.status = 504;
        set beresp.reason = "Gateway Timeout";
        set beresp.ttl = 0s;
    }
}
