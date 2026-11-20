# Purpose

Flux Kustomization entry points. `main/` wires the cluster: `infrastructure.yaml`, `apps.yaml`, `apps-monitoring-rules.yaml`, and `flux-system/`.

# Ownership

- Owns: top-level Flux `Kustomization` objects, dependency ordering between infra and apps, flux-system bootstrap.
- Manifest content owned by [[apps]] and [[infrastructure]].

# Local Contracts

- Entry-point Kustomizations point at `infrastructure/` and `apps/` overlays.
- Respect dependency chain: infrastructure reconciles before dependent apps (`dependsOn`).
- `infra-eso` waits for Cilium and host-network policy, then `infra-secrets` waits for the ESO HelmRelease and its CRDs. `infra-main` depends on `infra-secrets` for the Hister role's ESO credential. `apps` waits for `infra-main`.
- New top-level overlay → add a Kustomization here.
- `private-gitops.yaml` is a temporary migration seed: it wires the private repo
  as an additional source with `prune: false`; remove it after private root
  bootstrap owns the live cluster.

# Work Guidance

- Keep entry points thin; logic stays in the targeted overlays.

# Verification

- `just lint && just test` validates rendered Kustomizations.

# Child DOX Index

No child AGENTS.md.
