#!/usr/bin/env bash
# Regression: nextcloud-capture.sh übersteht einen Container-Restart im Tar.
# Extrahiert das Script aus der ConfigMap und läuft gegen einen kubectl-Stub.
set -euo pipefail
cd "$(dirname "$0")/../.."

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

# Block-Scalar "nextcloud-capture.sh: |" bis zum nächsten Key, 4 Spaces Einzug.
awk '/^  nextcloud-capture.sh: \|/ {on=1; next} on && /^  [a-z-]+\.sh: / {exit} on {sub(/^    /, ""); print}' \
  infrastructure/base/offsite-backup/scripts.configmap.yaml > "$tmp/capture.sh"
[ -s "$tmp/capture.sh" ] || { echo "nextcloud-capture.sh nicht gefunden"; exit 1; }

mkdir -p "$tmp/bin"
cat > "$tmp/bin/kubectl" <<'STUB'
#!/bin/sh
# nc-1 läuft, ist aber (Wartungsmodus) nicht ready -> muss gewählt werden;
# nc-0 läuft nicht (kein state.running).
# FAIL_TARS = Anzahl Tar-Versuche, die mit 143 abbrechen (Container-Restart).
case "$*" in
  *"get pods -n cnpg-system"*) echo "pg-1" ;;
  *"exec -n cnpg-system"*) echo "dump" ;;
  *"get pods -n nextcloud"*)
    [ -f "$T/no-pod" ] || printf 'nc-0 \nnc-1 2026-10-08T04:00:00Z\n' ;;
  *"exec -n nextcloud"*)
    n=$(($(cat "$T/tars" 2>/dev/null || echo 0) + 1)); echo "$n" > "$T/tars"
    if [ "$n" -le "${FAIL_TARS:-0}" ]; then printf 'partial'; exit 143; fi
    echo "pod=$4" > "$T/pod"; printf 'x' | gzip ;;
esac
STUB
chmod +x "$tmp/bin/kubectl"

run() { # $1=Name, $2=FAIL_TARS, $3=erwartet (ok|failed), $4=Tar-Versuche
  rm -rf "$tmp/work" "$tmp/staging" "$tmp/tars" "$tmp/pod"
  mkdir -p "$tmp/work" "$tmp/staging"
  # Skript nutzt absolute /work, /staging -> per sed auf Tempdir umlenken.
  sed "s#/work#$tmp/work#g; s#/staging#$tmp/staging#g" "$tmp/capture.sh" > "$tmp/c.sh"
  T="$tmp" PATH="$tmp/bin:$PATH" FAIL_TARS="$2" CAPTURE_ATTEMPTS=3 \
    CAPTURE_RETRY_SLEEP=0 CAPTURE_POD_WAIT=0 sh "$tmp/c.sh" >"$tmp/log" 2>&1
  [ -f "$tmp/work/nextcloud-capture.$3" ] || { echo "FAIL $1: Marker $3 fehlt"; cat "$tmp/log"; exit 1; }
  [ "$(cat "$tmp/tars")" = "$4" ] || { echo "FAIL $1: Tar-Versuche $(cat "$tmp/tars") != $4"; exit 1; }
  if [ "$3" = ok ]; then
    [ -f "$tmp/staging/nextcloud-app.tar.gz" ] && [ ! -e "$tmp/staging/nextcloud-app.tar.gz.partial" ] \
      || { echo "FAIL $1: Archiv fehlt/.partial übrig"; exit 1; }
    grep -q 'pod=nc-1' "$tmp/pod" || { echo "FAIL $1: nicht laufender Pod gewählt"; exit 1; }
  else
    [ ! -e "$tmp/staging/nextcloud-app.tar.gz" ] && [ ! -e "$tmp/staging/nextcloud-app.tar.gz.partial" ] \
      || { echo "FAIL $1: Rest-Archiv nach Fehlschlag"; exit 1; }
    grep -q 'App-State-Tar aus /var/www/html fehlgeschlagen' "$tmp/log" \
      || { echo "FAIL $1: Fehlerbeleg fehlt"; exit 1; }
  fi
  echo "ok   $1"
}

run "kein Restart" 0 ok 1
run "Restart im 1. Tar" 1 ok 2
run "Restart im 1.+2. Tar" 2 ok 3
run "dauerhafter Fehler" 9 failed 3

touch "$tmp/no-pod"
rm -rf "$tmp/work" "$tmp/staging" "$tmp/tars"; mkdir -p "$tmp/work" "$tmp/staging"
T="$tmp" PATH="$tmp/bin:$PATH" CAPTURE_ATTEMPTS=2 CAPTURE_RETRY_SLEEP=0 CAPTURE_POD_WAIT=0 \
  sh "$tmp/c.sh" >"$tmp/log" 2>&1
[ -f "$tmp/work/nextcloud-capture.failed" ] && [ ! -f "$tmp/tars" ] \
  && grep -q 'kein laufender Nextcloud-App-Pod' "$tmp/log" \
  || { echo "FAIL kein Pod"; cat "$tmp/log"; exit 1; }
echo "ok   kein laufender Pod"

# Regression: Tandoor tar kann emergency_ro-PVCs lesen. Deshalb muss der
# Mount vor und nach dem Tar geprueft werden, auch wenn kubectl exec erfolgreich ist.
awk '/^  appdata-capture\.sh: \|/ {on=1; next} on && /^  [a-z-]+\.sh: / {exit} on {sub(/^    /, ""); print}' \
  infrastructure/base/offsite-backup/scripts.configmap.yaml > "$tmp/appdata.sh"
[ -s "$tmp/appdata.sh" ] || { echo "appdata-capture.sh nicht gefunden"; exit 1; }

cat > "$tmp/bin/kubectl-appdata" <<'STUB'
#!/bin/sh
case "$*" in
  *"get pods -n audiobookshelf"*|*"get pods -n jellyfin"*|*"get pods -n kavita"*) echo app-1 ;;
  *"get pods -n tandoor"*) echo tandoor-1 ;;
  *"exec -n tandoor"*awk*)
    n=$(($(cat "$T/probes" 2>/dev/null || echo 0) + 1)); echo "$n" > "$T/probes"
    [ "${FAIL_PROBE:-0}" != "$n" ] || exit 1
    if [ "${MISSING_PROBE:-0}" = "$n" ]; then
      printf '/dev/sda /opt/recipes ext4 rw,relatime 0 0\n' > "$T/proc-mounts"
    elif [ "${READONLY_PROBE:-0}" = "$n" ]; then
      printf '/dev/sda /opt/recipes/mediafiles ext4 %s,relatime 0 0\n' \
        "${READONLY_OPTION:-ro}" > "$T/proc-mounts"
    else
      printf '/dev/sda /opt/recipes/mediafiles ext4 rw,relatime 0 0\n' > "$T/proc-mounts"
    fi
    printf '%s\n' "${10}" | sed "s#/proc/mounts#$T/proc-mounts#g" > "$T/probe.sh"
    sh "$T/probe.sh"
    ;;
  *"exec -n tandoor"*tar*)
    n=$(($(cat "$T/tars" 2>/dev/null || echo 0) + 1)); echo "$n" > "$T/tars"
    [ "${FAIL_TAR:-0}" != "$n" ] || exit 1
    printf archive
    ;;
  *"exec -n "*tar*) printf archive ;;
esac
STUB
chmod +x "$tmp/bin/kubectl-appdata"

run_appdata() {
  label="$1"
  fail_probe="$2"
  readonly_probe="$3"
  expected_probes="$4"
  expected_tars="$5"
  expected_status="$6"
  archive_expected="$7"
  readonly_option="$8"
  missing_probe="$9"
  fail_tar="${10}"
  rm -rf "$tmp/staging" "$tmp/probes" "$tmp/tars"
  mkdir -p "$tmp/staging"
  sed "s#/staging#$tmp/staging#g" "$tmp/appdata.sh" > "$tmp/appdata-run.sh"
  status=0
  T="$tmp" PATH="$tmp/bin:$PATH" FAIL_PROBE="$fail_probe" \
    READONLY_PROBE="$readonly_probe" READONLY_OPTION="$readonly_option" \
    MISSING_PROBE="$missing_probe" FAIL_TAR="$fail_tar" \
    sh "$tmp/appdata-run.sh" >"$tmp/appdata.log" 2>&1 || status=$?
  if [ "$status" -ne "$expected_status" ]; then
    echo "FAIL $label: exit $status != $expected_status"; cat "$tmp/appdata.log"; exit 1
  fi
  [ "$(cat "$tmp/probes" 2>/dev/null || echo 0)" = "$expected_probes" ] \
    || { echo "FAIL $label: Mount-Pruefungen falsch"; exit 1; }
  [ "$(cat "$tmp/tars" 2>/dev/null || echo 0)" = "$expected_tars" ] \
    || { echo "FAIL $label: Tar-Aufrufe falsch"; exit 1; }
  if [ "$archive_expected" = yes ]; then
    [ -s "$tmp/staging/tandoor-mediafiles.tar.gz" ] || { echo "FAIL $label: Archiv fehlt"; exit 1; }
  elif [ "$archive_expected" = empty ]; then
    [ -e "$tmp/staging/tandoor-mediafiles.tar.gz" ] \
      && [ ! -s "$tmp/staging/tandoor-mediafiles.tar.gz" ] \
      || { echo "FAIL $label: erwartetes leeres Teilarchiv fehlt"; exit 1; }
  else
    [ ! -e "$tmp/staging/tandoor-mediafiles.tar.gz" ] || { echo "FAIL $label: Archiv trotz Fehler"; exit 1; }
  fi
  echo "ok   $label"
}

# Stub als kubectl installieren (Stub selbst unterscheidet Mount-Check und Tar).
mv "$tmp/bin/kubectl-appdata" "$tmp/bin/kubectl"
run_appdata "Tandoor-Mount gesund" 0 0 2 1 0 yes ro 0 0
run_appdata "Tandoor Mount mit ro" 0 1 1 0 1 no ro 0 0
run_appdata "Tandoor Mount mit emergency_ro" 0 1 1 0 1 no emergency_ro 0 0
run_appdata "Tandoor wechselt beim Tar auf read-only" 0 2 2 1 1 yes ro 0 0
run_appdata "Tandoor-Mount fehlt vor Tar" 0 0 1 0 1 no ro 1 0
run_appdata "Tandoor-Mount fehlt nach Tar" 0 0 2 1 1 yes ro 2 0
run_appdata "kubectl exec scheitert vor Tar" 1 0 1 0 1 no ro 0 0
run_appdata "kubectl exec scheitert nach Tar" 2 0 2 1 1 yes ro 0 0
run_appdata "Tandoor-Tar scheitert" 0 0 1 1 1 empty ro 0 1
