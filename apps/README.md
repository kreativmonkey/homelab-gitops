# Apps

## Structure

```
apps/
├── base/                # Self-contained kustomize bases (one folder per app)
│   ├── audiobookshelf/  #   namespace + deployment + ingress + …
│   ├── homer/
│   └── …
└── overlays/
    └── main/            # ◀ THE SWITCHBOARD — controls everything
        ├── kustomization.yaml   # Enable / disable apps; Kustomize replacements
        ├── cluster-config.yaml  # ConfigMap with domains, TLS, per-app hostnames
        ├── databases/           # CNPG Database CRs (per-app schemas)
        └── db-secrets/          # SOPS-encrypted DB user passwords
```

## Day-to-day

See [`../docs/applications.md`](../docs/applications.md) — covers
enable/disable, hostname changes, base-domain migration, adding new apps.

## Conventions

- Each app lives in **its own namespace** (name = directory name).
- Ingresses **always** specify `ingressClassName: nginx` and a reflected
  wildcard TLS secret (`wildcard-f4mily-net-tls` or `wildcard-cluster-f4mily-net-tls`).
  **Do not** set `cert-manager.io/cluster-issuer` on Ingresses — central
  `Certificate` CRs + Reflector issue TLS; ingress-shim would conflict.
- Pod security: `runAsNonRoot`, `allowPrivilegeEscalation: false`,
  explicit `runAsUser`. See `apps/base/audiobookshelf/deployment.yaml` for
  a reference.
- Apps that need a database use the central CNPG cluster via the
  `Database` CR in `apps/overlays/main/databases/` — never start a
  per-app PostgreSQL.
- Apps that need RWX/mass storage use **static NFS PVs** declared in
  `infrastructure/base/storage/pv-nfs.yaml` with a `claimRef`.
