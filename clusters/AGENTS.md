# Purpose

Flux Kustomization entry points. `main/` wires the cluster: `infrastructure.yaml`, `apps.yaml`, `apps-monitoring-rules.yaml`, and `flux-system/`.

# Ownership

- Owns: top-level Flux `Kustomization` objects, dependency ordering between infra and apps, flux-system bootstrap.
- Manifest content owned by [[apps]] and [[infrastructure]].

# Local Contracts

- Entry-point Kustomizations point at `infrastructure/` and `apps/` overlays.
- Respect dependency chain: infrastructure reconciles before dependent apps (`dependsOn`).
- New top-level overlay → add a Kustomization here.
- `private-gitops.yaml` is a temporary migration seed: it wires the private repo
  as an additional source with `prune: false`; remove it after private root
  bootstrap owns the live cluster.
- During the private-root migration, `flux-system/gotk-sync.yaml` pivots the
  bootstrap `GitRepository/flux-system` to `homelab-gitops-private`; the
  private repo then owns live entrypoints and includes this public repo as
  source material.

# Work Guidance

- Keep entry points thin; logic stays in the targeted overlays.

# Verification

- `just lint && just test` validates rendered Kustomizations.

# Child DOX Index

No child AGENTS.md.
