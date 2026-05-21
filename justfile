# GitOps Homelab – task runner (run inside: nix develop)

default:
    @just --list

help:
    @just --list
    @echo ""
    @echo "Secrets: set SOPS_AGE_KEY_FILE to your cluster age private key."
    @echo "  just overlay-secrets-help"
    @echo "  just sops-edit path/to/secret.secret.yaml"
    @echo "  cd <dir> && just sops-create my-secret flux-system api-token=xxx"

# --- Validation & builds ---

validate:
    SKIP_KIND=1 ./scripts/ci/validate.sh

validate-full:
    ./scripts/ci/validate.sh

lint:
    yamllint -c .yamllint.yml clusters infrastructure apps .forgejo/workflows .github/workflows

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

# Grafana ↔ Authentik OAuth (monitoring namespace + instructions for Authentik provider secret)
grafana-authentik-oauth:
    #!/usr/bin/env bash
    set -euo pipefail
    : "${SOPS_AGE_KEY_FILE:?Set SOPS_AGE_KEY_FILE to your age private key}"
    client_id="homelab-grafana"
    client_secret="$(openssl rand -base64 32 | tr -d '\n')"
    dir="apps/base/monitoring/notifications"
    cd "$dir"
    kubectl create secret generic grafana-authentik-oauth \
      --namespace monitoring \
      --from-literal=client-id="$client_id" \
      --from-literal=client-secret="$client_secret" \
      --dry-run=client -o yaml >grafana-authentik-oauth.secret.yaml
    sops --encrypt --in-place grafana-authentik-oauth.secret.yaml
    echo "Created: $dir/grafana-authentik-oauth.secret.yaml"
    echo ""
    echo "Next:"
    echo "  1. Uncomment or add this file in notifications/kustomization.yaml"
    echo "  2. Commit, push, flux reconcile"
    echo "  3. In Authentik → Provider for Grafana → set Client secret to:"
    echo "     $client_secret"
    echo ""
    echo "See docs/integrations/grafana-authentik.md"

# Encrypt a plaintext *.secret.yaml in place
sops-encrypt file:
    #!/usr/bin/env bash
    set -euo pipefail
    file="{{file}}"
    [[ "$file" == *.secret.yaml ]] || { echo "error: file must end with .secret.yaml"; exit 1; }
    [[ -f "$file" ]] || { echo "error: not found: $file"; exit 1; }
    sops --encrypt --in-place "$file"
    echo "Encrypted: $file"

# List commands to recreate infra-main overlay secrets (after commenting them out in kustomize)
overlay-secrets-help:
    @echo "Set: export SOPS_AGE_KEY_FILE=/path/to/cluster-age-key"
    @echo ""
    @echo "  just barman-s3-credentials GARAGE_KEY GARAGE_SECRET"
    @echo "  just pgadmin-credentials admin@example.com 'pgadmin-password'"
    @echo "  just cnpg-db-credential immich-db-credentials immich 'password'"
    @echo "  (repeat cnpg-db-credential for each app — see credentials/credentials.secret.yaml.template)"
    @echo ""
    @echo "Then uncomment secret resources in:"
    @echo "  infrastructure/overlays/main/database-clusters/kustomization.yaml"
    @echo "  infrastructure/overlays/main/pgadmin/kustomization.yaml"

# CNPG Barman S3 credentials (Garage/MinIO)
barman-s3-credentials access_key secret_key:
    #!/usr/bin/env bash
    set -euo pipefail
    cd infrastructure/overlays/main/database-clusters
    just sops-create cnpg-barman-s3-credentials cnpg-system \
      "ACCESS_KEY_ID={{access_key}}" "ACCESS_SECRET_KEY={{secret_key}}"

# pgAdmin login secret
pgadmin-credentials email password:
    #!/usr/bin/env bash
    set -euo pipefail
    cd infrastructure/overlays/main/pgadmin
    just sops-create pgadmin-credentials cnpg-system \
      "email={{email}}" "password={{password}}"

# CNPG Database bootstrap secret (username + password keys)
cnpg-db-credential secret_name username password:
    #!/usr/bin/env bash
    set -euo pipefail
    cd infrastructure/overlays/main/database-clusters/credentials
    just sops-create "{{secret_name}}" cnpg-system \
      "username={{username}}" "password={{password}}"

# Import GitOps remediation workflow into running n8n (uses K8s env secrets, no UI credentials)
n8n-bootstrap:
    #!/usr/bin/env bash
    set -euo pipefail
    : "${KUBECONFIG:?Set KUBECONFIG (e.g. homelab-infrastructure/talos/kubeconfig)}"
    wf="apps/base/n8n/workflows/homelab-gitops-remediation.workflow.json"
    pod="$(kubectl get pod -n ai-ops -l app.kubernetes.io/instance=n8n-app -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || \
      kubectl get pod -n ai-ops -l app.kubernetes.io/name=n8n -o jsonpath='{.items[0].metadata.name}')"
    [[ -n "$pod" ]] || { echo "error: no n8n pod in ai-ops"; exit 1; }
    kubectl cp "$wf" "ai-ops/${pod}:/tmp/homelab-gitops-remediation.workflow.json"
    kubectl exec -n ai-ops "$pod" -- n8n import:workflow --input=/tmp/homelab-gitops-remediation.workflow.json
    echo "Workflow imported and set active in JSON. Open https://n8n.cluster.f4mily.net → verify Webhook /webhook/vmalert"
