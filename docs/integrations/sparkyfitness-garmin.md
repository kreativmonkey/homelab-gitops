# SparkyFitness — Garmin Connect

Garmin sync uses a **separate microservice** (`sparkyfitness_garmin`), not only the main server. Without it, login fails with connection errors (`ECONNREFUSED`) because `GARMIN_MICROSERVICE_URL` is unset.

## GitOps (this repo)

Helm (`apps/base/sparkyfitness/helmrelease.yaml`):

- `config.garmin.enabled: true`
- Image `docker.io/codewithcj/sparkyfitness_garmin:v0.16.6.3` (same tag as server/frontend)
- Server gets `GARMIN_MICROSERVICE_URL=http://sparkyfitness-garmin:8000`

After Flux reconcile, check:

```bash
kubectl -n sparkyfitness get pods -l app.kubernetes.io/component=garmin
kubectl -n sparkyfitness exec deploy/sparkyfitness-server -- printenv GARMIN_MICROSERVICE_URL
kubectl -n sparkyfitness top pods
```

Helm resources are tuned from `kubectl top` (homelab idle: server ~260Mi, garmin ~95Mi, frontend ~5Mi). Re-check after heavy Garmin sync.

## Connect in the app

1. Log in at https://fitness.f4mily.net
2. **Settings** → **Integrations** / **External providers**
3. **Add provider** → type **Garmin**
4. Enter your **Garmin Connect email and password** (same as connect.garmin.com)
5. Save — SparkyFitness calls the Garmin microservice; credentials are **not stored**, only tokens after login
6. If Garmin requires **MFA**, complete the code prompt in the UI (`resume_login`)

Then use **Sync** for the date range you need (health, activities, sleep — coverage varies; see [upstream docs](https://codewithcj.github.io/SparkyFitness/features/settings/external-providers)).

## Notes

- **Unofficial API** — uses the same approach as other self-hosted Garmin tools; account lockouts are rare but possible if Garmin changes things.
- **China region** — set `config.garmin.isChinaRegion: true` if your account is on Garmin China.
- **Pod security** — the upstream Garmin image runs as UID `1`. If the pod stays `Pending`/`CreateContainerConfigError`, check namespace Pod Security (Talos may require a policy exception for this deployment).

## Troubleshooting

| Symptom | Likely cause |
|---------|----------------|
| `Failed to login to Garmin:` (empty) or `ECONNREFUSED` | Garmin pod not running or wrong image |
| `Failed to login to Garmin: …` with detail | Wrong email/password or Garmin MFA required |
| Sync missing metrics | Known limitation — see upstream Discord/docs |

## References

- [External providers (SparkyFitness)](https://codewithcj.github.io/SparkyFitness/features/settings/external-providers)
- [Environment variables — Garmin](https://codewithcj.github.io/SparkyFitness/install/environment-variables)
