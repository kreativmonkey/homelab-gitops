# Flux dry-run on an existing Deployment

## What went wrong

The Outline Valkey manifest passed admission in the empty Kind CI cluster.
Production Flux rejected the same manifest and kept the old pod serving.
The error was `spec.strategy.rollingUpdate: Forbidden: may not be specified when strategy type is 'Recreate'`.

## Why it failed

The production Deployment already had defaulted RollingUpdate settings.
Server-side apply retained those fields when applying the new strategy,
even with `rollingUpdate: null` in the manifest. Creating the resource in
an empty cluster did not exercise the update path.

## The correct approach

For the single Valkey replica, keeping RollingUpdate with `maxSurge: 0`
and `maxUnavailable: 1` let the controller remove the old replica from
service before routing to its replacement. A terminating pod may still
have existing connections. Pause writers and verify the queue is empty
before replacing a volatile backend.

## Prevention

Test a strategy change against the existing Deployment with the same field
manager as Flux. This checks the update without persisting changes.

```sh
yq 'select(.kind == "Deployment")' apps/base/outline/valkey.yaml |
  kubectl --context homelab apply --server-side --dry-run=server \
    --field-manager=kustomize-controller --force-conflicts -f - -o name
```
