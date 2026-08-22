#!/usr/bin/env bash
# Open or update a tracking issue when the scheduled security scan fails.
# Requires gh + GITHUB_TOKEN; no-ops (exit 0) if gh/API unavailable.
set -euo pipefail

LABEL="security-scan"
TITLE="Scheduled Security Scan: Findings detected"
RUN_URL="${GITHUB_SERVER_URL:-https://github.com}/${GITHUB_REPOSITORY:-kreativmonkey/homelab-gitops}/actions/runs/${GITHUB_RUN_ID:-unknown}"
BODY="Automated weekly scan (gitleaks + trivy) reported new findings.

Run: ${RUN_URL}

Please review the artifacts and triage. Reproduce locally with: \`just security-scan\`."

command -v gh >/dev/null 2>&1 || { echo "gh not available, skipping issue creation"; exit 0; }
gh auth status >/dev/null 2>&1 || { echo "gh not authenticated, skipping issue creation"; exit 0; }

# Ensure the tracking label exists so issue creation never fails on a missing label.
gh label create "$LABEL" --color "d73a4a" \
  --description "Automated scheduled security scan findings" 2>/dev/null || true

EXISTING=$(gh issue list --label "$LABEL" --state open --json number --jq '.[0].number' 2>/dev/null || true)
if [[ -n "$EXISTING" ]]; then
  echo "Updating existing issue #$EXISTING"
  gh issue comment "$EXISTING" --body "$BODY" >/dev/null
  gh issue reopen "$EXISTING" >/dev/null 2>&1 || true
else
  echo "Creating issue: $TITLE"
  gh issue create --title "$TITLE" --label "$LABEL" --body "$BODY" >/dev/null
fi
