#!/bin/sh
# Test n8n Homelab Alert Triage Workflow
# Usage: ./test-n8n-webhook.sh [webhook-url] [secret]

WEBHOOK_URL="${1:-https://n8n.cluster.f4mily.net/webhook/homelab-alert}"
SECRET="${2:-iuWlhhM2gc37YP3OxeML33BStxyV58oR}"

echo "=== Test 1: KubePodOOMKilled (firing) ==="
curl -s -w "\nHTTP %{http_code}\n" -X POST "$WEBHOOK_URL" \
  -H "Content-Type: application/json" \
  -H "x-webhook-secret: $SECRET" \
  -d @- <<'EOF'
{
  "status": "firing",
  "alerts": [{
    "status": "firing",
    "labels": {
      "alertname": "KubePodOOMKilled",
      "severity": "critical",
      "namespace": "authentik",
      "instance": "authentik-worker-6c559d9776-8fbcf",
      "pod": "authentik-worker-6c559d9776-8fbcf",
      "container": "worker",
      "homelab_auto_remediate": "true"
    },
    "annotations": {
      "summary": "Authentik Worker wurde wegen OOM beendet",
      "description": "Pod authentik-worker in authentik mit OOMKilled beendet. Memory Limit: 2Gi"
    }
  }],
  "commonLabels": {
    "alertname": "KubePodOOMKilled",
    "severity": "critical"
  },
  "commonAnnotations": {
    "summary": "Authentik Worker OOM"
  },
  "groupLabels": {
    "alertname": "KubePodOOMKilled"
  }
}
EOF

echo ""
echo "=== Test 2: KubePodOOMKilled (resolved) ==="
curl -s -w "\nHTTP %{http_code}\n" -X POST "$WEBHOOK_URL" \
  -H "Content-Type: application/json" \
  -H "x-webhook-secret: $SECRET" \
  -d @- <<'EOF'
{
  "status": "resolved",
  "alerts": [{
    "status": "resolved",
    "labels": {
      "alertname": "KubePodOOMKilled",
      "severity": "critical",
      "namespace": "authentik",
      "instance": "authentik-worker-6c559d9776-8fbcf"
    },
    "annotations": {
      "summary": "Authentik Worker OOM behoben (4Gi Limit)"
    }
  }],
  "commonLabels": {
    "alertname": "KubePodOOMKilled"
  }
}
EOF
