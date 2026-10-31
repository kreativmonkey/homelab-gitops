#!/usr/bin/env bash
# Regression: the Immich init-container retries API/exec failures under sh -ec
# and never leaves a failed partial dump as the final backup.
set -euo pipefail
cd "$(dirname "$0")/../.."

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
mkdir -p "$tmp/bin" "$tmp/staging"
kustomize build infrastructure/base/offsite-backup \
  | yq -r 'select(.kind == "CronJob" and .metadata.name == "immich-offsite-backup") | .spec.jobTemplate.spec.template.spec.initContainers[] | select(.name == "database-dump") | .command[2]' \
  > "$tmp/dump.sh"
[ -s "$tmp/dump.sh" ] || { echo 'Immich dump script missing'; exit 1; }

cat > "$tmp/bin/kubectl" <<'STUB'
#!/bin/sh
case "$*" in
  '--request-timeout=30s get pods -n cnpg-system '* )
    n=$(($(cat "$T/gets" 2>/dev/null || echo 0) + 1)); echo "$n" > "$T/gets"
    [ "$n" -gt "${GET_FAILURES:-0}" ] || { echo 'API unavailable' >&2; exit 1; }
    echo "primary-$n" ;;
  'exec -n cnpg-system '* )
    n=$(($(cat "$T/execs" 2>/dev/null || echo 0) + 1)); echo "$n" > "$T/execs"
    [ "$n" -gt "${EXEC_FAILURES:-0}" ] || { printf partial; exit 1; }
    printf complete ;;
  *) echo "unexpected kubectl call: $*" >&2; exit 2 ;;
esac
STUB
cat > "$tmp/bin/timeout" <<'STUB'
#!/bin/sh
duration=$1; shift
if [ "$duration" = "10m" ] && [ "${TIMEOUT_FAILURES:-0}" -gt 0 ]; then
  n=$(($(cat "$T/timeouts" 2>/dev/null || echo 0) + 1)); echo "$n" > "$T/timeouts"
  [ "$n" -gt "$TIMEOUT_FAILURES" ] || { echo 'timed out' >&2; exit 124; }
fi
exec "$@"
STUB
cat > "$tmp/bin/sleep" <<'STUB'
#!/bin/sh
exit 0
STUB
cat > "$tmp/bin/date" <<'STUB'
#!/bin/sh
n=$(($(cat "$T/date-calls" 2>/dev/null || echo 0) + 1)); echo "$n" > "$T/date-calls"
if [ "$n" -le 2 ]; then echo "${DATE_START:-1000}"; else echo "${DATE_AFTER_FIRST:-1000}"; fi
STUB
chmod +x "$tmp/bin/kubectl" "$tmp/bin/timeout" "$tmp/bin/sleep" "$tmp/bin/date"

run() { # label get failures exec failures timeout failures clock after first expected status expected gets expected execs
  label=$1 get_failures=$2 exec_failures=$3 timeout_failures=$4 date_after_first=$5 expected_status=$6 expected_gets=$7 expected_execs=$8
  rm -rf "$tmp/staging" "$tmp/gets" "$tmp/execs" "$tmp/timeouts" "$tmp/date-calls"; mkdir -p "$tmp/staging"
  status=0
  T="$tmp" PATH="$tmp/bin:$PATH" GET_FAILURES="$get_failures" EXEC_FAILURES="$exec_failures" TIMEOUT_FAILURES="$timeout_failures" DATE_AFTER_FIRST="$date_after_first" \
    sh -ec "$(cat "$tmp/dump.sh" | sed "s#/staging#$tmp/staging#g; s/attempts=32/attempts=3/")" \
    >"$tmp/log" 2>&1 || status=$?
  [ "$status" = "$expected_status" ] || { echo "FAIL $label: status=$status"; cat "$tmp/log"; exit 1; }
  [ "$(cat "$tmp/gets" 2>/dev/null || echo 0)" = "$expected_gets" ] || { echo "FAIL $label: get count"; cat "$tmp/log"; exit 1; }
  [ "$(cat "$tmp/execs" 2>/dev/null || echo 0)" = "$expected_execs" ] || { echo "FAIL $label: exec count"; cat "$tmp/log"; exit 1; }
  if [ "$expected_status" = 0 ]; then
    [ "$(cat "$tmp/staging/database/immich.dump")" = complete ] \
      && [ ! -e "$tmp/staging/database/immich.dump.partial" ] \
      || { echo "FAIL $label: final dump invalid"; exit 1; }
  else
    [ ! -e "$tmp/staging/database/immich.dump" ] \
      && [ ! -e "$tmp/staging/database/immich.dump.partial" ] \
      || { echo "FAIL $label: dump left after exhausted retries"; exit 1; }
  fi
  echo "ok   $label"
}

run 'API get error then recovery' 1 0 0 1000 0 2 1
run 'exec transport error then recovery' 0 1 0 1000 0 2 2
run 'exec timeout then recovery' 0 0 1 1000 0 2 1
run 'exhausted retries leave no dump' 3 3 0 1000 1 3 0
run 'total budget expires after timed-out attempt' 0 0 1 2800 1 1 0
