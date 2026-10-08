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
