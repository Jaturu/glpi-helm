# Exposing GLPI

The chart's Service speaks plain HTTP to the nginx sidecar. TLS terminates at
whatever sits in front: a Gateway API `Gateway` (via `httpRoute`) or an
Ingress controller (via `ingress`). Either or both can be enabled.

Whichever you use, three settings should agree:

| Setting | Must match |
|---------|------------|
| `glpi.url` | The exact public URL users type, with scheme, no trailing slash |
| `httpRoute.hostnames` / `ingress.hosts` | The host part of `glpi.url` |
| `glpi.trustedProxies` | The network your gateway or controller pods run in |

GLPI answers on whatever host a request arrives with, so a wrong `glpi.url`
does not break the web UI. It shows up as notification emails that link to
the wrong address.

## Gateway API (HTTPRoute)

Requires the Gateway API CRDs (`gateway.networking.k8s.io/v1`) and a Gateway
with a listener that accepts routes from the release namespace.

```yaml
glpi:
  url: https://glpi.example.com
  trustedProxies:
    - 10.244.0.0/16                   # pod network of the gateway's data plane

httpRoute:
  enabled: true
  parentRefs:
    - name: my-gateway
      namespace: gateway-system
      sectionName: https              # the HTTPS listener
  hostnames:
    - glpi.example.com
```

- TLS is configured on the Gateway listener, not in this chart. A wildcard
  certificate on the listener (e.g. `*.example.com`) covers GLPI with no
  per-app certificate.
- Set `sectionName` to attach only to the HTTPS listener. If the Gateway also
  has an HTTP listener with a redirect route, plain-HTTP requests are
  redirected before they reach GLPI.
- Check the route was accepted:

```console
  kubectl -n glpi get httproute desk-glpi \
    -o jsonpath='{range .status.parents[*]}{.parentRef.name}: {range .conditions[*]}{.type}={.status} {end}{"\n"}{end}'
```

  Both `Accepted=True` and `ResolvedRefs=True` are expected.

## Ingress

```yaml
glpi:
  url: https://glpi.example.com
  trustedProxies:
    - 10.244.0.0/16                   # pod network of the ingress controller

ingress:
  enabled: true
  className: nginx
  annotations:
    cert-manager.io/cluster-issuer: letsencrypt
  hosts:
    - glpi.example.com
  tls:
    - secretName: glpi-tls
      hosts:
        - glpi.example.com
```

The chart renders one rule per host, all with the same `path` / `pathType`
(`/`, `Prefix`) pointing at the Service's `http` port. Annotations are passed
through unchanged, so controller-specific features (TLS issuers, auth, body
size) go there.

## Trusted proxies

Between the user and PHP there are two hops: the gateway or Ingress
controller, then the nginx sidecar. The sidecar passes requests to php-fpm
over FastCGI and does not add a proxy hop of its own. PHP sees the gateway
pod's address as the client, with the original scheme and client IP in
`X-Forwarded-Proto` / `X-Forwarded-For`.

GLPI only honours those headers from addresses in `glpi.trustedProxies`
(its `GLPI_TRUSTED_REVERSE_PROXIES` constant). Set it to the IPs or CIDRs your
gateway or controller pods use, typically the cluster pod network:

```yaml
glpi:
  trustedProxies:
    - 10.244.0.0/16
```

`glpi.reverseProxyHeaders` lists which headers are trusted from them
(`GLPI_REVERSE_PROXY_HEADERS`). The default is `X-Forwarded-For` and
`X-Forwarded-Proto`. Add `X-Forwarded-Host` or `X-Forwarded-Port` only if the
gateway rewrites the host or port and sets those headers itself.

When this is wrong:

- Not set: GLPI sees `http://` from the gateway and the gateway's address as
  every user's IP. Logs and the session list record the gateway instead of the
  user, and links GLPI derives from the request use `http://`.
- Client IPs still wrong after setting it: the gateway itself may be receiving
  SNATed traffic. Its LoadBalancer Service needs
  `externalTrafficPolicy: Local` for the real client address to reach it.

## Upload size

The chart derives the limits inside the pod from `glpi.uploadLimitMB`: PHP's
`upload_max_filesize`, `post_max_size` (N + 5 MB) and nginx's
`client_max_body_size` (N + 5 MB). The gateway or controller in front must
also accept request bodies of at least `uploadLimitMB` + 5 MB. Otherwise large
uploads fail before reaching GLPI, usually as an HTTP 413 from the proxy.

| Front end | Default body limit | Where to raise it |
|-----------|--------------------|-------------------|
| ingress-nginx | 1 MB | annotation `nginx.ingress.kubernetes.io/proxy-body-size: 55m` |
| NGINX Ingress Controller (F5) | 1 MB | annotation `nginx.org/client-max-body-size: 55m` |
| Envoy Gateway | no limit on streamed request bodies by default | only relevant if a policy enables request buffering |
| Traefik | no limit by default | only relevant if a Buffering middleware is attached |

Check your controller's documentation for its current default. The values
above are the commonly shipped ones.

GLPI has its own limit on top, "Document files maximum size (Mio)" under
Setup > General > Management. The smallest of the three limits wins.

Inventory agents post their data to the same hostname. A full inventory of a
large machine can run to several megabytes, well inside the default limit.

## Restricting access

The chart doesn't add access control in front of GLPI. To limit who can reach
it at the network level:

- attach the route only to an internal Gateway or IngressClass, so GLPI is
  never published externally,
- use your gateway's own authorisation or IP-allowlist policy,
- add a NetworkPolicy in the release namespace that admits traffic to the
  GLPI pod's port 8080 only from the gateway's namespace.

If inventory agents on other networks need to reach GLPI while the UI stays
internal, publish only the agent path on the external gateway and keep the
rest on the internal one.

Inside GLPI, access is governed by its profiles and entities, and by the
authentication sources under Setup > Authentication.
