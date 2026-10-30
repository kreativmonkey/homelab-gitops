#!/usr/bin/env bash
# Upstream health: weekly check for dead, moved or EOL upstreams.
#
# 1. Renovate lookup run against the working tree (no PRs, no pushes) writes a
#    report with every dependency, its sourceUrl and lookup warnings.
# 2. upstream-health.py checks those sources on GitHub/Codeberg and the
#    release cycles on endoflife.date -> markdown.
# 3. With --publish: one tracking issue (label upstream-health) gets its body
#    replaced; a comment is added only when NEW findings appear, so the issue
#    notifies on change instead of every week.
#
# Usage: ./scripts/ci/upstream-health.sh [--publish]
# Needs: node >= 24 (npx), python3, gh; GITHUB_TOKEN (or gh auth) for lookups.
set -euo pipefail

RENOVATE_VERSION="44.181.0" # renovate: datasource=npm depName=renovate
LABEL="upstream-health"
TITLE="Upstream Health"
cd "$(git rev-parse --show-toplevel)"

export GITHUB_TOKEN="${GITHUB_TOKEN:-$(gh auth token 2>/dev/null || true)}"
[[ -n "$GITHUB_TOKEN" ]] || { echo "GITHUB_TOKEN missing (or run gh auth login)"; exit 1; }

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
echo '{}' >"$WORK/global.json"

echo "Renovate ${RENOVATE_VERSION} lookup..."
RENOVATE_CONFIG_FILE="$WORK/global.json" \
RENOVATE_GITHUB_COM_TOKEN="$GITHUB_TOKEN" \
LOG_LEVEL="${LOG_LEVEL:-warn}" \
  npx -y "renovate@${RENOVATE_VERSION}" --platform=local --dry-run=lookup \
    --report-type=file --report-path="$WORK/report.json"

python3 -I scripts/ci/upstream-health.py "$WORK/report.json" scripts/ci/upstream-health.json "$WORK/body.md"

if [[ "${1:-}" != "--publish" ]]; then
  cat "$WORK/body.md"
  exit 0
fi

keys_of() { sed -n 's/.*<!-- upstream-health-keys: \(.*\) -->.*/\1/p'; }
RUN_URL="${GITHUB_SERVER_URL:-https://github.com}/${GITHUB_REPOSITORY:-kreativmonkey/homelab-gitops}/actions/runs/${GITHUB_RUN_ID:-local}"
printf '\nLauf: %s · lokal: `just upstream-health`\n' "$RUN_URL" >>"$WORK/body.md"

gh label create "$LABEL" --color "fbca04" \
  --description "Automated upstream health check (dead/moved/EOL dependencies)" 2>/dev/null || true

ISSUE=$(gh issue list --label "$LABEL" --state all --json number --jq '.[0].number // empty')
if [[ -z "$ISSUE" ]]; then
  gh issue create --title "$TITLE" --label "$LABEL" --body-file "$WORK/body.md"
  exit 0
fi

OLD_KEYS=$(gh issue view "$ISSUE" --json body --jq .body | keys_of)
NEW_KEYS=$(keys_of <"$WORK/body.md")
gh issue edit "$ISSUE" --body-file "$WORK/body.md" >/dev/null
ADDED=$(python3 -c 'import json,sys; o=set(json.loads(sys.argv[1] or "[]")); print("\n".join(f"- `{k}`" for k in json.loads(sys.argv[2]) if k not in o))' "$OLD_KEYS" "$NEW_KEYS")
if [[ -n "$ADDED" ]]; then
  gh issue reopen "$ISSUE" >/dev/null 2>&1 || true
  gh issue comment "$ISSUE" --body "Neue Befunde:
${ADDED}"
elif [[ "$NEW_KEYS" == "[]" ]]; then
  gh issue close "$ISSUE" --reason completed >/dev/null 2>&1 || true
fi
echo "Issue #$ISSUE updated"
