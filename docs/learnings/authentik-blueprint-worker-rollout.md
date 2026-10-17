# Authentik blueprint discovery during a worker rollout

**Date:** 2026-10-18
**Affected:** new OIDC applications deployed with an Authentik worker rollout

## What went wrong

Ainsel's ConfigMap and Authentik Helm upgrade were applied together. Hub and MCP
started before the provider existed; OIDC discovery returned HTTP 404 and both
services entered restart backoff. Authentik itself remained available.

## Why it failed

Adding a blueprint ConfigMap changes worker mounts and rolls workers. The new
worker enqueues `authentik.blueprints.v1.tasks.blueprints_discovery` into the
shared task queue. During overlap, an old worker can consume that task while
still seeing its old mounts. A successful discovery task or a Ready HelmRelease
therefore does not prove the new provider exists.

In this rollout, discovery tasks completed while old workers were present, but
the Ainsel issuer still returned 404 after new workers became Ready. Importing
the unchanged mounted blueprint in a new worker immediately created the provider.

## Correct approach

1. Let Flux mount the ConfigMap and finish the Authentik worker rollout.
2. Verify the issuer's `.well-known/openid-configuration` returns HTTP 200.
3. If it remains absent, identify a new worker with the expected blueprint mount.
   Compare that file with the Git-managed ConfigMap before importing it.
4. Apply that exact mounted file through Authentik's `Importer.from_string()` in
   the new worker, as described in root `AGENTS.md` under Apply / Sync. Do not
   create a different provider manually in the UI.
5. Verify the provider, callback and discovery response, then wait for clients
   to recover from restart backoff.

## Prevention

- New OIDC HelmReleases should depend on the Authentik HelmRelease to avoid
  starting during its rollout. This orders deployment; it does not prove
  blueprint application.
- Include an actual issuer discovery check and a full PKCE login in onboarding.
- Keep issuer, client ID and callback identical between chart values and blueprint.
