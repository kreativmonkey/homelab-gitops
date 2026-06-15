# Purpose

Flux Kustomization entry points. `main/` wires the cluster: `infrastructure.yaml`, `apps.yaml`, `apps-monitoring-rules.yaml`, and `flux-system/`.

# Ownership

- Owns: top-level Flux `Kustomization` objects, dependency ordering between infra and apps, flux-system bootstrap.
- Manifest content owned by [[apps]] and [[infrastructure]].

# Local Contracts

- Entry-point Kustomizations point at `infrastructure/` and `apps/` overlays.
- Respect dependency chain: infrastructure reconciles before dependent apps (`dependsOn`).
- New top-level overlay → add a Kustomization here.

# Work Guidance

- Keep entry points thin; logic stays in the targeted overlays.

# Verification

- `just lint && just test` validates rendered Kustomizations.

# Child DOX Index

No child AGENTS.md.
