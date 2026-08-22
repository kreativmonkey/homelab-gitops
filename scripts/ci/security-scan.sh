#!/usr/bin/env bash
# Scheduled security scan: gitleaks (full history, baseline-suppressed) + trivy fs.
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
    --scanners vuln,secret,misconfig \
    --severity HIGH,CRITICAL \
    --exit-code 1 \
    --format table --output "$TRIVY_TXT" \
    . ; then
  echo "Trivy: findings detected -> $TRIVY_TXT"
  EXIT=1
else
  echo "Trivy: no HIGH/CRITICAL findings"
fi

exit $EXIT
