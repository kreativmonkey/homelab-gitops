#!/usr/bin/env bash
# Regression: the backup initializes Restic only after cat config returns 10.
set -euo pipefail
cd "$(dirname "$0")/../.."

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
mkdir -p "$tmp/bin" "$tmp/work"
awk '/^  restic-backup\.sh: \|/ {on=1; next} on && /^  [a-z-]+\.sh: / {exit} on {sub(/^    /, ""); print}' \
  infrastructure/base/offsite-backup/scripts.configmap.yaml > "$tmp/backup.sh"
[ -s "$tmp/backup.sh" ] || { echo 'restic-backup.sh missing'; exit 1; }

cat > "$tmp/bin/restic" <<'STUB'
#!/bin/sh
case "$1" in
  'cat')
    n=$(($(cat "$T/probes" 2>/dev/null || echo 0) + 1)); echo "$n" > "$T/probes"
    if [ -f "$T/initialized" ]; then exit 0; fi
    if [ "${MODE:-}" = missing ] || [ "${MODE:-}" = init-retry ] \
      || [ "${MODE:-}" = init-fail ] \
      || { [ "${MODE:-}" = init-race ] && [ "$n" -eq 1 ]; }; then
      echo 'private repository details' >&2
      exit 10
    fi
    if [ "${MODE:-}" = transient ] && [ "$n" -eq 1 ]; then
      echo 'private repository details' >&2
      exit 11
    fi
    if [ "${MODE:-}" = auth ]; then
      echo 'password=private' >&2
      exit 12
    fi
    if [ "${MODE:-}" = failure ]; then
      echo 'private repository details' >&2
      exit 1
    fi
    exit 0
    ;;
  'init')
    n=$(($(cat "$T/inits" 2>/dev/null || echo 0) + 1)); echo "$n" > "$T/inits"
    if [ "${MODE:-}" = init-race ]; then
      touch "$T/initialized"
      exit 1
    fi
    if [ "${MODE:-}" = init-fail ] \
      || { [ "${MODE:-}" = init-retry ] && [ "$n" -eq 1 ]; }; then
      echo 'private repository details' >&2
      exit 1
    fi
    touch "$T/initialized"
    ;;
  *) echo "$1" >> "$T/commands" ;;
esac
STUB
cat > "$tmp/bin/sleep" <<'STUB'
#!/bin/sh
exit 0
STUB
chmod +x "$tmp/bin/restic" "$tmp/bin/sleep"

run() { # mode expected exit expected init count expected backup count expected probes
  mode="$1" expected_status="$2" expected_inits="$3" expected_backups="$4" expected_probes="$5"
  rm -f "$tmp/work"/* "$tmp/probes" "$tmp/inits" "$tmp/commands" "$tmp/initialized"
  status=0
  sed "s#/work#$tmp/work#g" "$tmp/backup.sh" > "$tmp/run.sh"
  T="$tmp" MODE="$mode" EXIT_ON_FAILURE=true PATH="$tmp/bin:$PATH" \
    sh "$tmp/run.sh" regression-tag \
    > "$tmp/log" 2>&1 || status=$?
  [ "$status" = "$expected_status" ] || { echo "FAIL $mode: status=$status"; cat "$tmp/log"; exit 1; }
  [ "$(cat "$tmp/inits" 2>/dev/null || echo 0)" = "$expected_inits" ] \
    || { echo "FAIL $mode: init count"; cat "$tmp/log"; exit 1; }
  backups="$(grep -c '^backup$' "$tmp/commands" 2>/dev/null || true)"
  [ "${backups:-0}" = "$expected_backups" ] \
    || { echo "FAIL $mode: backup count ${backups:-0} != $expected_backups"; cat "$tmp/log"; exit 1; }
  [ "$(cat "$tmp/probes" 2>/dev/null || echo 0)" = "$expected_probes" ] \
    || { echo "FAIL $mode: probe count"; cat "$tmp/log"; exit 1; }
  if grep -Eq 'private|password=' "$tmp/log"; then
    echo "FAIL $mode: restic details leaked to logs"; cat "$tmp/log"; exit 1
  fi
  echo "ok   $mode"
}

run missing 0 1 1 1
run transient 0 0 1 2
run auth 1 0 0 5
run failure 1 0 0 5
run init-race 0 1 1 2
run init-retry 0 2 1 3
run init-fail 1 5 0 10
