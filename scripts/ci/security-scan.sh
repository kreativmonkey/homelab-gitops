#!/usr/bin/env bash
# Scheduled security scan: Gitleaks full history + Trivy manifest checks.
# This manifests-only checkout has no package manifests or image layers. Keep
# Trivy's secret/misconfiguration scanners as gate; scan deployed images from
# rendered image references, cluster, or SBOMs separately.
# Exits non-zero when NEW findings appear so the workflow flags the run and
# opens/updates a tracking issue.
set -euo pipefail

REPORT_DIR="${REPORT_DIR:-$(mktemp -d)}"
GITLEAKS_JSON="$REPORT_DIR/gitleaks.json"
TRIVY_TXT="$REPORT_DIR/trivy.txt"
EXIT=0

echo "== Gitleaks: full history scan (baseline-suppressed) =="
if ! gitleaks detect \
    --source . \
    --config .gitleaks.toml \
    --baseline-path .gitleaks.baseline.json \
    --no-banner --redact \
    --report-format json --report-path "$GITLEAKS_JSON"; then
  echo "Gitleaks: NEW findings detected -> $GITLEAKS_JSON"
  EXIT=1
else
  echo "Gitleaks: no new findings"
fi

echo "== Trivy: filesystem scan (HIGH,CRITICAL) =="
if ! trivy fs \
    --scanners secret,misconfig \
    --severity HIGH,CRITICAL \
    --ignorefile .trivyignore.yaml \
    --exit-code 1 \
    --format table --output "$TRIVY_TXT" \
    . ; then
  echo "Trivy: findings detected -> $TRIVY_TXT"
  EXIT=1
else
  echo "Trivy: no HIGH/CRITICAL findings"
fi

exit $EXIT
