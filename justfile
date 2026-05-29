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

renovate-audit:
    ./scripts/ci/renovate-audit.sh

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

# Nextcloud ↔ Authentik OAuth (nextcloud namespace)
nextcloud-authentik-oauth:
    #!/usr/bin/env bash
    set -euo pipefail
    : "${SOPS_AGE_KEY_FILE:?Set SOPS_AGE_KEY_FILE to your age private key}"
    client_id="homelab-nextcloud"
    client_secret="$(openssl rand -base64 32 | tr -d '\n')"
    dir="apps/base/nextcloud"
    cd "$dir"
    kubectl create secret generic nextcloud-authentik-oauth \
      --namespace nextcloud \
      --from-literal=client-id="$client_id" \
      --from-literal=client-secret="$client_secret" \
      --dry-run=client -o yaml >nextcloud-authentik-oauth.secret.yaml
    sops --encrypt --in-place nextcloud-authentik-oauth.secret.yaml
    echo "Created: $dir/nextcloud-authentik-oauth.secret.yaml"
    echo ""
    echo "Next:"
    echo "  1. Add nextcloud-authentik-oauth.secret.yaml to apps/base/nextcloud/kustomization.yaml"
    echo "  2. Commit, push, flux reconcile"
    echo "  3. In Authentik create application slug nextcloud (see docs/integrations/nextcloud-authentik.md)"
    echo "     Client secret: $client_secret"
    echo ""
    echo "See docs/integrations/nextcloud-authentik.md"

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

# Import remediation + error-notify workflows; link error handler (API or UI)
n8n-bootstrap url="https://n8n.cluster.f4mily.net":
    #!/usr/bin/env bash
    set -euo pipefail
    : "${KUBECONFIG:?Set KUBECONFIG (e.g. homelab-infrastructure/talos/kubeconfig)}"
    wf_main="apps/base/n8n/workflows/homelab-gitops-remediation.workflow.json"
    wf_err="apps/base/n8n/workflows/homelab-gitops-remediation-error.workflow.json"
    [[ -f "$wf_main" && -f "$wf_err" ]] || { echo "error: missing workflow JSON under apps/base/n8n/workflows/"; exit 1; }

    _api_import() {
      local base="${1%/}" file="$2" activate="${3:-false}"
      local payload name id
      payload="$(jq '{name, nodes, connections, settings: (.settings // {})}' "$file")"
      name="$(jq -r '.name' "$file")"
      id="$(curl -fsS -H "X-N8N-API-KEY: ${N8N_API_KEY}" \
        "${base}/api/v1/workflows?limit=250" | jq -r --arg n "$name" '.data[]? | select(.name == $n) | .id' | head -1)"
      if [[ -n "$id" && "$id" != "null" ]]; then
        curl -fsS -X PATCH -H "X-N8N-API-KEY: ${N8N_API_KEY}" -H "Content-Type: application/json" \
          -d "$payload" "${base}/api/v1/workflows/${id}" >/dev/null
        echo "  updated: ${name} (id=${id})"
      else
        id="$(curl -fsS -X POST -H "X-N8N-API-KEY: ${N8N_API_KEY}" -H "Content-Type: application/json" \
          -d "$payload" "${base}/api/v1/workflows" | jq -r '.id')"
        echo "  created: ${name} (id=${id})"
      fi
      if [[ "$activate" == "true" ]]; then
        curl -fsS -X POST -H "X-N8N-API-KEY: ${N8N_API_KEY}" \
          "${base}/api/v1/workflows/${id}/activate" >/dev/null
      fi
      echo "$id"
    }

    _bootstrap_via_api() {
      : "${N8N_API_KEY:?Set N8N_API_KEY (n8n UI → Settings → API → Create API key)}"
      local base="${1%/}" err_id main_id payload
      echo "Importing via n8n API…"
      err_id="$(_api_import "$base" "$wf_err" false)"
      payload="$(jq --arg eid "$err_id" '{name, nodes, connections, settings: ((.settings // {}) + {errorWorkflow: $eid})}' "$wf_main")"
      main_id="$(curl -fsS -H "X-N8N-API-KEY: ${N8N_API_KEY}" \
        "${base}/api/v1/workflows?limit=250" | jq -r --arg n "$(jq -r .name "$wf_main")" '.data[]? | select(.name == $n) | .id' | head -1)"
      if [[ -n "$main_id" && "$main_id" != "null" ]]; then
        curl -fsS -X PATCH -H "X-N8N-API-KEY: ${N8N_API_KEY}" -H "Content-Type: application/json" \
          -d "$payload" "${base}/api/v1/workflows/${main_id}" >/dev/null
        echo "  updated: $(jq -r .name "$wf_main") (id=${main_id}, errorWorkflow=${err_id})"
      else
        main_id="$(curl -fsS -X POST -H "X-N8N-API-KEY: ${N8N_API_KEY}" -H "Content-Type: application/json" \
          -d "$payload" "${base}/api/v1/workflows" | jq -r '.id')"
        echo "  created: $(jq -r .name "$wf_main") (id=${main_id})"
      fi
      curl -fsS -X POST -H "X-N8N-API-KEY: ${N8N_API_KEY}" \
        "${base}/api/v1/workflows/${main_id}/activate" >/dev/null
      echo "Done. Remediation active; error workflow linked. Webhook: ${base}/webhook/vmalert"
    }

    _bootstrap_via_kubectl() {
      local pod="$1"
      local user_id err_id main_id tmpdir
      tmpdir="$(mktemp -d)"
      trap 'rm -rf "$tmpdir"' RETURN
      user_id="$(kubectl run sqlite-n8n-bootstrap --rm -i --restart=Never -n ai-ops --image=alpine:3.21 \
        --overrides='{"spec":{"containers":[{"name":"s","image":"alpine:3.21","command":["sh","-c","apk add -q sqlite && sqlite3 /data/database.sqlite \"SELECT id FROM user LIMIT 1;\""],"volumeMounts":[{"name":"d","mountPath":"/data"}]}],"volumes":[{"name":"d","persistentVolumeClaim":{"claimName":"n8n-app"}}]}}' 2>/dev/null | tail -1)"
      [[ -n "$user_id" && "$user_id" != *Error* ]] || { echo "error: could not read n8n user id (complete owner setup in UI first)"; return 1; }
      jq --arg id "$(uuidgen)" '. + {id: $id}' "$wf_err" > "${tmpdir}/err.json"
      jq --arg id "$(uuidgen)" '. + {id: $id}' "$wf_main" > "${tmpdir}/main.json"
      kubectl cp "${tmpdir}/err.json" "ai-ops/${pod}:/tmp/homelab-gitops-remediation-error.workflow.json"
      kubectl cp "${tmpdir}/main.json" "ai-ops/${pod}:/tmp/homelab-gitops-remediation.workflow.json"
      kubectl exec -n ai-ops "$pod" -- n8n import:workflow --input=/tmp/homelab-gitops-remediation-error.workflow.json --userId="$user_id"
      main_id="$(kubectl exec -n ai-ops "$pod" -- n8n import:workflow --input=/tmp/homelab-gitops-remediation.workflow.json --userId="$user_id" 2>&1 | sed -n 's/.*id=\([^ ]*\).*/\1/p' || true)"
      err_id="$(kubectl exec -n ai-ops "$pod" -- n8n list:workflow 2>/dev/null | rg 'Error Notify' | cut -d'|' -f1 || true)"
      main_id="$(kubectl exec -n ai-ops "$pod" -- n8n list:workflow 2>/dev/null | rg 'GitHub PR' | cut -d'|' -f1 || true)"
      [[ -n "$main_id" ]] && kubectl exec -n ai-ops "$pod" -- n8n publish:workflow --id="$main_id"
      kubectl rollout restart deploy/n8n-app -n ai-ops
      kubectl rollout status deploy/n8n-app -n ai-ops --timeout=5m
      echo "Workflows imported via kubectl (userId=${user_id})."
      echo "Link error workflow in UI if needed: {{url}} → Homelab GitOps Remediation → Settings → Error workflow"
      echo "Webhook: {{url}}/webhook/vmalert"
    }

    pod="$(kubectl get pod -n ai-ops -l app.kubernetes.io/instance=n8n-app -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || \
      kubectl get pod -n ai-ops -l app.kubernetes.io/name=n8n -o jsonpath='{.items[0].metadata.name}')"
    [[ -n "$pod" ]] || { echo "error: no n8n pod in ai-ops"; exit 1; }

    if [[ -n "${N8N_API_KEY:-}" ]]; then
      _bootstrap_via_api "{{url}}"
      exit 0
    fi
    if _bootstrap_via_kubectl "$pod" 2>/dev/null; then
      exit 0
    fi
    echo "kubectl exec/cp failed (often: no route to node/kubelet 100.96.x.x:10250)." >&2
    echo "Set N8N_API_KEY and re-run, or fix Netbird routes — docs/netbird-cluster-access.md" >&2
    exit 1

# Fire a test Alertmanager payload at the GitOps remediation webhook (no kubectl exec needed)
n8n-test-webhook url="https://n8n.cluster.f4mily.net" scenario="firing":
    #!/usr/bin/env bash
    set -euo pipefail
    base="{{url}}"
    case "{{scenario}}" in
      firing)
        body='{"status":"firing","alerts":[{"labels":{"alertname":"KubePodCrashLoopBackOff","namespace":"default","pod":"n8n-test","container":"app","severity":"critical"},"annotations":{"summary":"homelab webhook test","description":"triggered by just n8n-test-webhook"}}],"commonLabels":{"alertname":"KubePodCrashLoopBackOff"}}'
        ;;
      resolved)
        body='{"status":"resolved","alerts":[{"labels":{"alertname":"KubePodCrashLoopBackOff","namespace":"default","pod":"n8n-test"}}]}'
        ;;
      skip)
        body='{"status":"firing","alerts":[{"labels":{"alertname":"KubePodNotReady","namespace":"default","pod":"n8n-test"}}]}'
        ;;
      *)
        echo "error: scenario must be firing|resolved|skip"; exit 1
        ;;
    esac
    resp="$(curl -fsS -X POST "${base%/}/webhook/vmalert" -H 'Content-Type: application/json' -d "$body")"
    echo "$resp"
    echo ""
    echo "Verify: ${base} → Executions (latest run, scenario={{scenario}})"
    echo "  firing   → should reach LLM/GitHub (may end in noop if LLM says needs_human)"
    echo "  resolved → should stop early (skip)"
    echo "  skip     → not allowlisted alertname"
