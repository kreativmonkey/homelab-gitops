# Tandoor CSRF / login failures

## Symptom

`Forbidden (403) — CSRF verification failed` on `https://rezepte.f4mily.net` (login, Authentik SSO, or recipe edits).

## Quick checks

```bash
# TLS must be *.f4mily.net, not *.cluster.f4mily.net
openssl s_client -connect 192.168.10.245:443 -servername rezepte.f4mily.net </dev/null 2>/dev/null \
  | openssl x509 -noout -ext subjectAltName

kubectl get ingress tandoor -n tandoor -o jsonpath='{.spec.tls[0].secretName}{"\n"}'
# Expect: wildcard-f4mily-net-tls

kubectl get deploy tandoor -n tandoor -o jsonpath='{range .spec.template.spec.containers[0].env[*]}{.name}={.value}{"\n"}{end}' \
  | rg 'CSRF|ALLOWED|PROXY'
```

Expected env:

- `CSRF_TRUSTED_ORIGINS=https://rezepte.f4mily.net,https://recipes.f4mily.net`
- `ALLOWED_HOSTS=rezepte.f4mily.net,recipes.f4mily.net,...`
- `ALLAUTH_TRUSTED_PROXY_COUNT=2` (container nginx + ingress)

## Common causes

| Cause | Fix |
|-------|-----|
| Wrong TLS secret on Ingress (`wildcard-cluster-*` on public host) | Overlay must use `publicTlsSecret` for `tandoor` — see `apps/overlays/main/kustomization.yaml` |
| `nginx.org/server-snippets` with `if` on Tandoor Ingress | Breaks F5 NGINX routing → 404; do not use |
| `nginx.org/proxy-set-headers` (ConfigMap or inline) on Tandoor Ingress | Broke upstream routing → **502** in homelab (PR #184 reverted); do not re-add without kind dry-run |
| Second Ingress host `recipes.f4mily.net` | Also reverted with #184 — use `https://rezepte.f4mily.net` only |
| Old bookmark `recipes.f4mily.net` | Use `https://rezepte.f4mily.net`; keep both origins in `CSRF_TRUSTED_ORIGINS` |
| HTTP URL (`http://rezepte…`) | CSRF origins are HTTPS-only; always open `https://rezepte.f4mily.net` |
| Stale cookies after `SECRET_KEY` or domain change | Clear site data for `rezepte.f4mily.net` / `recipes.f4mily.net`, retry in private window |
| DNS still on old Docker host (`192.168.10.244`) | `dig rezepte.f4mily.net` → **192.168.10.245** (Talos VIP) |


## Diagnosis: 502 Bad Gateway

### Symptom
502 when accessing `https://rezepte.f4mily.net`.

### Quick checks

```bash
# Check if tandoor pod is running
kubectl get pods -n tandoor

# Check if endpoints exist for the service
kubectl get endpoints tandoor -n tandoor

# Check ingress controller endpoint state (look for tandoor errors)
kubectl logs -n ingress-nginx -l app.kubernetes.io/name=nginx-ingress --tail=50 2>&1 | grep -i tandoor
```

### Common causes

| Cause | Fix |
|-------|-----|
| Pod restarting / not ready (endpoints missing) | `kubectl rollout restart deployment/tandoor -n tandoor`; wait for Ready |
| Ingress controller not updated after pod restart | Flux reconciles automatically within interval, or `flux reconcile kustomization apps --with-source` |
| `nginx.org/proxy-set-headers` on Tandoor Ingress | Known to break upstream routing -> 502 (PR #184). Do not add. |
| Wrong service targetPort | Service `tandoor` port 80 -> targetPort 8080 (matches TANDOOR_PORT) |
| Pod OOM / resource limit | Check `kubectl top pods -n tandoor`; limit is 3Gi memory |

### Resolution
1. `kubectl get pods -n tandoor` -- if pod is CrashLoopBackOff, check logs.
2. If pod is Running but 502 persists: `kubectl rollout restart deployment/tandoor -n tandoor`.
3. Verify ingress controller picked up endpoints: ingress controller logs should show no `no endpointslices for service tandoor` warnings.
4. If needed: `flux reconcile kustomization apps --with-source`.

## After GitOps fix

```bash
flux reconcile kustomization apps --with-source
kubectl rollout restart deployment/tandoor -n tandoor
```

Browser: hard refresh or clear cookies, then open **https://rezepte.f4mily.net** (not HTTP, not cluster domain).
