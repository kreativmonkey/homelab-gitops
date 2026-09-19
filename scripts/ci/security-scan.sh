#!/usr/bin/env bash
# Evidence-preserving scheduled security scan. Artifacts are sanitized before upload.
set -euo pipefail

REPORT_DIR="${REPORT_DIR:-$(mktemp -d)}"
TRIVY_CACHE_DIR="${TRIVY_CACHE_DIR:-$REPORT_DIR/trivy-cache}"
SCAN_TIMEOUT="${SCAN_TIMEOUT:-20m}"
GITLEAKS_BIN="${GITLEAKS_BIN:-gitleaks}"
TRIVY_BIN="${TRIVY_BIN:-trivy}"
PYTHON_BIN="${PYTHON_BIN:-python3}"

mkdir -p "$REPORT_DIR" "$TRIVY_CACHE_DIR"
GIT_SHA="$(git rev-parse HEAD)"
STARTED_AT="$(date --utc +%Y-%m-%dT%H:%M:%SZ)"

sanitize_report() {
  local source="$1" destination="$2"
  "$PYTHON_BIN" - "$source" "$destination" <<'PY'
import json
import sys
from pathlib import Path

source, destination = map(Path, sys.argv[1:])
redact_keys = {"match", "matched", "snippet", "content", "code", "codeflows", "lines", "raw", "secret", "text", "markdown"}

def sanitize(value):
    if isinstance(value, dict):
        return {
            key: "[REDACTED]" if key.casefold() in redact_keys else sanitize(item)
            for key, item in value.items()
        }
    if isinstance(value, list):
        return [sanitize(item) for item in value]
    return value

try:
    payload = json.loads(source.read_text())
except (OSError, json.JSONDecodeError) as error:
    destination.write_text(json.dumps({"sanitization_error": str(error)}) + "\n")
    raise SystemExit(1)
destination.write_text(json.dumps(sanitize(payload), indent=2, sort_keys=True) + "\n")
PY
}

sanitize_diagnostics() {
  local source="$1" destination="$2"
  "$PYTHON_BIN" - "$source" "$destination" <<'PY'
import hashlib
import sys
from pathlib import Path

source, destination = map(Path, sys.argv[1:])
lines = source.read_bytes().splitlines()
output = [
    "Scanner diagnostic content withheld to prevent disclosure of matched values.",
    "Each following SHA-256 digest represents one original diagnostic line in order.",
]
output.extend(hashlib.sha256(line).hexdigest() for line in lines)
destination.write_text("\n".join(output) + "\n")
PY
}

write_result() {
  local scanner="$1" status="$2" sarif_status="$3" result="$4" json_sanitized="$5" sarif_sanitized="$6" started="$7" finished="$8"
  "$PYTHON_BIN" - "$REPORT_DIR/${scanner}.result.json" "$scanner" "$status" "$sarif_status" "$result" "$json_sanitized" "$sarif_sanitized" "$started" "$finished" "$GIT_SHA" <<'PY'
import json
import sys
from pathlib import Path

path, scanner, status, sarif_status, result, json_sanitized, sarif_sanitized, started, finished, sha = sys.argv[1:]
Path(path).write_text(json.dumps({
    "scanner": scanner,
    "exit_status": int(status),
    "sarif_exit_status": int(sarif_status),
    "result": result,
    "json_sanitized": json_sanitized == "true",
    "sarif_sanitized": sarif_sanitized == "true",
    "started_at": started,
    "finished_at": finished,
    "commit_sha": sha,
}, indent=2, sort_keys=True) + "\n")
PY
}

run_trivy() {
  local scanner="$1" safe_name="$2"
  local started finished status result raw_json raw_sarif
  started="$(date --utc +%Y-%m-%dT%H:%M:%SZ)"
  raw_json="$REPORT_DIR/.${safe_name}.raw.json"
  raw_sarif="$REPORT_DIR/.${safe_name}.raw.sarif"

  set +e
  timeout --signal=TERM --kill-after=60s "$SCAN_TIMEOUT" \
    "$TRIVY_BIN" fs --cache-dir "$TRIVY_CACHE_DIR" --scanners "$scanner" \
    --severity HIGH,CRITICAL --exit-code 1 --format json --output "$raw_json" . \
    2>"$REPORT_DIR/${safe_name}.stderr.raw.txt"
  status=$?
  set -e

  if sanitize_report "$raw_json" "$REPORT_DIR/${safe_name}.json"; then json_sanitized=true; else json_sanitized=false; fi
  sanitize_diagnostics "$REPORT_DIR/${safe_name}.stderr.raw.txt" "$REPORT_DIR/${safe_name}.stderr.txt"
  rm -f "$raw_json" "$REPORT_DIR/${safe_name}.stderr.raw.txt"

  # SARIF is regenerated in a separate invocation to retain a standard upload format.
  set +e
  timeout --signal=TERM --kill-after=60s "$SCAN_TIMEOUT" \
    "$TRIVY_BIN" fs --cache-dir "$TRIVY_CACHE_DIR" --scanners "$scanner" \
    --severity HIGH,CRITICAL --exit-code 1 --format sarif --output "$raw_sarif" . \
    2>"$REPORT_DIR/${safe_name}.sarif.stderr.raw.txt"
  sarif_status=$?
  set -e
  if sanitize_report "$raw_sarif" "$REPORT_DIR/${safe_name}.sarif"; then sarif_sanitized=true; else sarif_sanitized=false; fi
  sanitize_diagnostics "$REPORT_DIR/${safe_name}.sarif.stderr.raw.txt" "$REPORT_DIR/${safe_name}.sarif.stderr.txt"
  rm -f "$raw_sarif" "$REPORT_DIR/${safe_name}.sarif.stderr.raw.txt"

  finished="$(date --utc +%Y-%m-%dT%H:%M:%SZ)"
  if [[ "$status" == "0" && "$sarif_status" == "0" && "$json_sanitized" == true && "$sarif_sanitized" == true ]]; then
    result="clean"
  elif [[ "$status" == "1" && "$sarif_status" == "1" && "$json_sanitized" == true && "$sarif_sanitized" == true ]]; then
    result="findings_or_policy_failure"
  else
    result="execution_blocker"
  fi
  write_result "$safe_name" "$status" "$sarif_status" "$result" "$json_sanitized" "$sarif_sanitized" "$started" "$finished"
  printf '%s scanner: exit=%s sarif_exit=%s result=%s\n' "$safe_name" "$status" "$sarif_status" "$result"
  return 0
}

"$GITLEAKS_BIN" version >"$REPORT_DIR/gitleaks.version.txt" 2>&1 || true
"$TRIVY_BIN" version >"$REPORT_DIR/trivy.version.txt" 2>&1 || true
"$PYTHON_BIN" - "$REPORT_DIR/run-metadata.json" "$GIT_SHA" "$STARTED_AT" "$SCAN_TIMEOUT" <<'PY'
import json
import sys
from pathlib import Path

path, sha, started, timeout = sys.argv[1:]
Path(path).write_text(json.dumps({
    "commit_sha": sha,
    "started_at": started,
    "scan_timeout": timeout,
    "commands": {
        "gitleaks": "gitleaks detect --redact --report-format json",
        "trivy_vulnerability": "trivy fs --scanners vuln --severity HIGH,CRITICAL --exit-code 1 --format json|sarif",
        "trivy_secret": "trivy fs --scanners secret --severity HIGH,CRITICAL --exit-code 1 --format json|sarif (sanitized)",
        "trivy_misconfiguration": "trivy fs --scanners misconfig --severity HIGH,CRITICAL --exit-code 1 --format json|sarif",
    },
}, indent=2, sort_keys=True) + "\n")
PY

set +e
"$GITLEAKS_BIN" detect --source . --no-banner --redact --report-format json \
  --report-path "$REPORT_DIR/.gitleaks.raw.json" \
  >"$REPORT_DIR/gitleaks.stdout.raw.txt" 2>"$REPORT_DIR/gitleaks.stderr.raw.txt"
gitleaks_status=$?
set -e
if sanitize_report "$REPORT_DIR/.gitleaks.raw.json" "$REPORT_DIR/gitleaks.json"; then gitleaks_sanitized=true; else gitleaks_sanitized=false; fi
sanitize_diagnostics "$REPORT_DIR/gitleaks.stdout.raw.txt" "$REPORT_DIR/gitleaks.stdout.txt"
sanitize_diagnostics "$REPORT_DIR/gitleaks.stderr.raw.txt" "$REPORT_DIR/gitleaks.stderr.txt"
rm -f "$REPORT_DIR/.gitleaks.raw.json" "$REPORT_DIR/gitleaks.stdout.raw.txt" "$REPORT_DIR/gitleaks.stderr.raw.txt"
if [[ "$gitleaks_status" == 0 && "$gitleaks_sanitized" == true ]]; then gitleaks_result=clean; elif [[ "$gitleaks_status" == 1 && "$gitleaks_sanitized" == true ]]; then gitleaks_result=findings_or_policy_failure; else gitleaks_result=execution_blocker; fi
write_result "gitleaks" "$gitleaks_status" "0" "$gitleaks_result" "$gitleaks_sanitized" "true" "$STARTED_AT" "$(date --utc +%Y-%m-%dT%H:%M:%SZ)"

run_trivy vuln trivy-vulnerability
run_trivy secret trivy-secret
run_trivy misconfig trivy-misconfiguration

# Trivy writes database and checks metadata inside its cache; retain only metadata.
find "$TRIVY_CACHE_DIR" -type f -name metadata.json -exec cp --parents {} "$REPORT_DIR" \; 2>/dev/null || true
rm -rf "$TRIVY_CACHE_DIR"

printf '%s\n' "Security scan evidence written to $REPORT_DIR for commit $GIT_SHA"
if [[ "$gitleaks_status" != 0 \
  || "$("$PYTHON_BIN" - "$REPORT_DIR" <<'PY'
import json
import sys
from pathlib import Path

report_dir = Path(sys.argv[1])
print(any(json.loads(path.read_text())["result"] != "clean" for path in report_dir.glob("*.result.json")))
PY
)" == "True" ]]; then
  exit 1
fi
