# GitOps Homelab – task runner (run inside: nix develop)

default:
    @just --list

help:
    @just --list
    @echo ""
    @echo "Secrets: set SOPS_AGE_KEY_FILE to your age private key file."
    @echo "  just sops-edit path/to/secret.secret.yaml"
    @echo "  cd <dir> && just sops-create my-secret flux-system api-token=xxx"

# --- Validation & builds ---

validate:
    SKIP_KIND=1 ./scripts/ci/validate.sh

validate-full:
    ./scripts/ci/validate.sh

lint:
    yamllint -c .yamllint.yml clusters infrastructure apps .forgejo/workflows

build-infra:
    kustomize build infrastructure/overlays/main

build-apps:
    kustomize build apps/overlays/main

build-all: build-infra build-apps

# --- Flux ---

flux-reconcile:
    flux reconcile kustomization --all --with-source

flux-status:
    flux get kustomizations,helmreleases -A

shell:
    @echo "Run: nix develop"

# --- SOPS / age ---

# Edit an encrypted *.secret.yaml (decrypt → editor → re-encrypt)
sops-edit file:
    #!/usr/bin/env bash
    set -euo pipefail
    file="{{file}}"
    [[ "$file" == *.secret.yaml ]] || { echo "error: file must end with .secret.yaml"; exit 1; }
    [[ -f "$file" ]] || { echo "error: not found: $file"; exit 1; }
    sops "$file"

# Create and encrypt a generic Secret in the current directory (kubectl dry-run → sops)
# Example: cd infrastructure/base/sources && just sops-create hetzner-api flux-system api-token=TOKEN
sops-create name namespace +literals:
    #!/usr/bin/env bash
    set -euo pipefail
    out="{{name}}.secret.yaml"
    args=()
    for lit in {{literals}}; do
      [[ "$lit" == *"="* ]] || { echo "error: literal must be KEY=VALUE: $lit"; exit 1; }
      args+=(--from-literal="$lit")
    done
    kubectl create secret generic "{{name}}" \
      --namespace "{{namespace}}" \
      "${args[@]}" \
      --dry-run=client -o yaml >"$out"
    sops --encrypt --in-place "$out"
    echo "Created and encrypted: $out"

# Encrypt a plaintext *.secret.yaml in place
sops-encrypt file:
    #!/usr/bin/env bash
    set -euo pipefail
    file="{{file}}"
    [[ "$file" == *.secret.yaml ]] || { echo "error: file must end with .secret.yaml"; exit 1; }
    [[ -f "$file" ]] || { echo "error: not found: $file"; exit 1; }
    sops --encrypt --in-place "$file"
    echo "Encrypted: $file"
