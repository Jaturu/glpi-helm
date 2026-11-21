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

## Sign-in proxy

A sign-in proxy in front of GLPI (for example authentik, Authelia or
oauth2-proxy, as a forward-auth step on the gateway or as a proxy of its own)
can sign users in to GLPI. The proxy authenticates the user and sends the
username in a request header. With `remoteUserAuth`, nginx hands that
username to GLPI as `REMOTE_USER`, the server variable GLPI reads for
[automatic authentication](https://help.glpi-project.org/documentation/modules/configuration/authentication/other).

Any client can send any header, so nginx passes the username on only from a
source it can trust, and PHP never sees the header itself. GLPI's
documentation warns against reading the login from `HTTP_*` variables for
this reason. The chart offers two checks, and at least one is required:

| Setting | Check | Use when |
|---------|-------|----------|
| `allowFrom` | nginx [`allow`/`deny`](https://nginx.org/en/docs/http/ngx_http_access_module.html): only these addresses reach the application server, others get 403 | Every request from those addresses has passed the sign-in proxy, and the proxy replaces any username header the client sent |
| `sharedKey` | The proxy adds a secret key header to each request. Without the right key nginx sends an empty `REMOTE_USER` | The proxy's address is shared with other traffic, for example a gateway that also serves routes without sign-in |

With both set, a request must come from an allowed address, and only a
request that also carries the key is signed in.

What nginx does for each request to GLPI's front controller:

- The username header and the key header are replaced by empty
  [`fastcgi_param`](https://nginx.org/en/docs/http/ngx_http_fastcgi_module.html#fastcgi_param)
  values, so PHP cannot read either.
- `REMOTE_USER` is the username when the check passed, empty otherwise. A
  request without a valid key still reaches GLPI, as an anonymous visitor, so
  the login form and local accounts keep working.
- Header names with underscores are dropped by nginx by default
  ([`underscores_in_headers`](https://nginx.org/en/docs/http/ngx_http_core_module.html#underscores_in_headers)),
  so a client cannot slip the username in under a variant spelling.

### Setting it up

1. Create the key and its Secret. The key may hold letters, digits, `-` and
   `_`, and needs at least 32 characters:

   ```console
   kubectl -n glpi create secret generic glpi-proxy-key \
     --from-literal=key="$(openssl rand -hex 32)"
   ```

2. Configure the sign-in proxy to send the username in a header, replacing any
   value the client sent, and to add the key header with the same key to
   every request it forwards to GLPI.

3. Set the values:

   ```yaml
   remoteUserAuth:
     enabled: true
     header: X-Forwarded-User     # the header your proxy sends
     # allowFrom: [10.244.0.0/16] # optional: the proxy's addresses
     sharedKey:
       header: X-GLPI-Proxy-Key
       existingSecret: glpi-proxy-key
       secretKey: key
   ```

4. In GLPI, under Setup > Authentication > Other authentication methods,
   enable automatic authentication with `REMOTE_USER` as the variable that
   holds the login. GLPI then applies its usual rules: the account must
   exist, or be created by one of GLPI's authentication sources.

### How the key reaches nginx

The key is read from the Secret into the nginx container's environment, never
into a GLPI container. With `sharedKey` set, the chart mounts nginx's
configuration as a template, and the
[nginx image](https://hub.docker.com/_/nginx) ("Using environment variables in
nginx configuration") renders it at start with `envsubst` into an `emptyDir`
at `/etc/nginx/conf.d`, since the root filesystem is read-only.
`NGINX_ENVSUBST_FILTER` limits the substitution to the key's variable, so
nginx's own `$variables` are left alone. The key is compared in a
[`map`](https://nginx.org/en/docs/http/ngx_http_map_module.html) with a
case-sensitive regular expression (plain `map` strings match ignoring case),
which is why the key is limited to letters, digits, `-` and `_`.

Before nginx starts, a check in its container stops it if the key is empty,
`REPLACE_ME`, shorter than 32 characters or holds other characters, so the
pod never becomes ready. `kubectl logs <pod> -c nginx` shows the reason.

To change the key, update the Secret, then restart the pod
(`kubectl -n glpi rollout restart deployment/<release>-glpi`). nginx reads the
key only at start.

### Notes

- `helm test` runs from its own pod. With `allowFrom` set, its requests get
  403 unless its address is in the list. Add the pod network, or set
  `tests.enabled: false`.
- When a user signs out of GLPI, the sign-in proxy may sign them straight
  back in. Send them to the proxy's own sign-out page to end both sessions.
- The kubelet probes use the separate health port and are not affected.

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
