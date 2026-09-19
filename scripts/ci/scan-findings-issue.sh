#!/usr/bin/env bash
# Open or update the security-scan tracking issue without exposing report content.
set -euo pipefail

LABEL="security-scan"
TITLE="Scheduled Security Scan: Findings or scanner blocker"
RUN_URL="${GITHUB_SERVER_URL:-https://github.com}/${GITHUB_REPOSITORY:-kreativmonkey/homelab-gitops}/actions/runs/${GITHUB_RUN_ID:-unknown}"
SCANNED_SHA="$(git rev-parse HEAD)"
BODY="Automated security scan did not pass its HIGH/CRITICAL gate.\n\nRun: ${RUN_URL}\nScanned commit: \`${SCANNED_SHA}\`\n\nSanitized artifacts contain per-scanner evidence and execution status."

command -v gh >/dev/null 2>&1 || { echo "gh unavailable; issue update skipped"; exit 0; }
gh auth status >/dev/null 2>&1 || { echo "gh unauthenticated; issue update skipped"; exit 0; }

existing="$(gh issue list --label "$LABEL" --state open --json number --jq '.[0].number' 2>/dev/null || true)"
if [[ -n "$existing" ]]; then
  gh issue comment "$existing" --body "$BODY" >/dev/null
  printf 'Updated security scan issue #%s\n' "$existing"
else
  gh issue create --title "$TITLE" --label "$LABEL" --body "$BODY" >/dev/null
  echo "Created security scan tracking issue"
fi
