# HTTPRoute Timeouts

`HTTPRouteRule.timeouts` bounds how long the gateway waits on a backend.

```yaml
apiVersion: gateway.networking.k8s.io/v1
kind: HTTPRoute
metadata:
  name: api-route
spec:
  parentRefs:
    - name: my-gateway
  rules:
    - matches:
        - path:
            type: PathPrefix
            value: /slow-api
      backendRefs:
        - name: api-service
          port: 8080
      timeouts:
        backendRequest: 5s
```

A route whose backend exceeds the timeout returns **504 Gateway Timeout**.

## How it maps to Varnish

Varnish backends are pooled by `address:port`, so they cannot carry per-route
timeouts. Ghost bridges the value on the matched route to the fetch instead:

```
routing.json → ghost.json → ghost sets X-Ghost-Timeout on the request
  → vcl_backend_fetch sets bereq.first_byte_timeout + bereq.between_bytes_timeout
  → vcl_backend_error reports 504 instead of 503
```

`backendRequest` is scoped by Gateway API to the *complete* response, but Varnish
has no total-fetch cap. `between_bytes_timeout` is the closest equivalent: it
bounds the gap between response body bytes, not the total elapsed time.

## Caveats

**Any fetch failure on a timeout route reports 504.** Varnish exposes no failure
reason in `vcl_backend_error`, so a refused connection on a route with
`backendRequest` set also returns 504 rather than 503. Routes without a timeout
are unaffected and keep 503.

**Connect time is not bounded.** The timeout governs waiting for response bytes.
Establishing the TCP connection is governed by varnishd's `connect_timeout`
(3.5s by default), so an unreachable pod can take longer than `backendRequest`
to fail. Lower it globally via
[varnishd arguments](varnishd-args.md) if that matters.

**Streaming responses are cut.** `between_bytes_timeout` applies to every gap in
the response body, so a long-lived SSE or streaming response on a route with a
short `backendRequest` will be terminated. Do not set `backendRequest` on
streaming routes.

**Once headers are delivered, the status cannot change.** A timeout that fires
mid-body truncates the response — the 504 flip only applies before response
headers are sent.

**`0s` falls back to varnishd defaults.** Gateway API defines `0s` as "disable
the timeout". Varnish always applies `first_byte_timeout` /
`between_bytes_timeout`, so a disabled route inherits the global varnishd values
(60s each by default) rather than running unbounded.

**No retries.** A timed-out fetch fails immediately; Varnish only retries when
VCL calls `return (retry)`.

## Interaction with user VCL

The 504 flip lives in the gateway postamble, which is concatenated *after* user
VCL. A user-supplied `vcl_backend_error` that ends with `return (deliver)`
terminates VCL execution before the postamble runs, and the response keeps
Varnish's 503. Branch on `bereq.http.X-Ghost-Timeout` if you need custom
handling for timed-out routes:

```vcl
sub vcl_backend_error {
    if (bereq.http.X-Ghost-Timeout) {
        set beresp.status = 504;
        set beresp.http.Content-Type = "application/json";
        set beresp.body = {"{"error": "upstream timeout"}"};
        return (deliver);
    }
}
```

`X-Ghost-Timeout` is stripped from client requests in `vcl_recv` before routing,
so it cannot be spoofed. Like the cache policy headers, it stays on `bereq`
through the fetch and is therefore visible to the backend.
