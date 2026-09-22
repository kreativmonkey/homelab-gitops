# Flux stale CRD cleanup

## Decision

Flux image automation is intentionally not installed. Renovate manages image updates; `goloom` has no declared `ImageRepository`, `ImagePolicy`, or `ImageUpdateAutomation` in this repository.

Flux notification-controller is intentionally not installed. Flux reconciliation health is alerted through VictoriaMetrics VMRule `homelab-flux` and Alertmanager → ntfy, not Flux `Alert`/`Provider` resources.

`clusters/main/flux-system/gotk-components.yaml` is generated for Flux v2.9.5 with only `source-controller`, `kustomize-controller`, and `helm-controller`. Its generated RBAC may name optional Flux API groups or ServiceAccounts; that is baseline Flux RBAC, not a controller deployment or CRD declaration. Do not hand-edit it. Add an optional controller only by regenerating this file with the matching component and declaring the associated resources in Git.

## Audit evidence

Read-only audit, 2026-09-22T07:44:07Z:

- Installed Flux deployments: `source-controller`, `kustomize-controller`, `helm-controller`; no notification or image automation deployment.
- Stale image resources: `goloom/imagerepository`, `goloom/imagepolicy`, and `goloom/imageupdateautomation`. The ImagePolicy was `Ready=False`.
- No `Alert`, `Provider`, or `Receiver` resources.
- Stale CRDs:
  - `alerts.notification.toolkit.fluxcd.io`
  - `providers.notification.toolkit.fluxcd.io`
  - `receivers.notification.toolkit.fluxcd.io`
  - `imagepolicies.image.toolkit.fluxcd.io`
  - `imagerepositories.image.toolkit.fluxcd.io`
  - `imageupdateautomations.image.toolkit.fluxcd.io`

The three `goloom` image resources carried Flux `apps` inventory labels but no owner references. They are no longer in the rendered Git source, so Flux prune cannot remove them. The CRDs are also not declared by `gotk-components.yaml`; Flux cannot prune them.

## One-time production cleanup

Do not run this before the GitOps documentation change is merged and the `flux-system` Kustomization has reconciled that merge. This is an explicit operational cleanup, not a Flux prune operation.

1. Get the merged revision and verify the selected controllers and current inventory:

```bash
REVISION="main@sha1:<merged-sha>"
kubectl -n flux-system get gitrepository, kustomization flux-system
kubectl -n flux-system get deploy
kubectl get alerts,providers,receivers -A
kubectl get imagerepositories,imagepolicies,imageupdateautomations -A
```

2. Run the guarded cleanup. It requires both the GitRepository and the `flux-system` Kustomization to report `REVISION`, refuses to proceed if an optional controller deployment exists, and stops before CRD deletion if any dependent image or notification resource remains. Notification resources are never deleted by the script; any `Alert`, `Provider`, or `Receiver` aborts the cleanup for review.

```bash
./scripts/flux/cleanup-stale-flux-crds.sh --revision "$REVISION" --execute
```

The script deletes, in order:

1. `goloom` ImageRepository, ImagePolicy, and ImageUpdateAutomation.
2. It verifies all image resources are absent cluster-wide.
3. It verifies all `Alert`, `Provider`, and `Receiver` resources are absent cluster-wide.
4. The three image CRDs and the three unused notification CRDs.
5. It reads back targeted CRDs and optional controller deployments and fails on any residue.

Save the command output in the change/incident record as the exact post-cleanup inventory. Do not delete a CRD manually before the script's dependent-resource check succeeds.

## Post-cleanup checks

```bash
kubectl get crd | grep -E '(notification|image)\.toolkit\.fluxcd\.io' || true
kubectl get imagerepositories,imagepolicies,imageupdateautomations -A
kubectl -n flux-system get deploy
flux get kustomizations -A
```

Expected: none of the six named CRDs and no image automation resources; exactly source-, kustomize-, and helm-controller remain in `flux-system`; Flux Kustomizations stay Ready.

## Future change

If Flux-native image automation or notifications becomes required, make a separate reviewed GitOps change first: regenerate `gotk-components.yaml` for the added controller(s), declare all related CRs and secrets in Git, validate, and only then install/reconcile. Do not recreate an orphan CRD or CR directly in production.
