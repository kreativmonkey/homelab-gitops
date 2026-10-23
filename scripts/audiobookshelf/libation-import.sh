#!/usr/bin/env bash
# Import finished Libation downloads into Audiobookshelf.
#
#   just abs-import                 # move + scan + author images
#   DRY=1 just abs-import           # show what would be moved / matched
#   ABS_IMPORT_NO_WIFI=1 just abs-import   # disconnect Wi-Fi for the copy
#
# 1. MOVE every "<Title> [ASIN]" folder from $SRC to the library root on the
#    NAS (rsync over SSH; each local file is deleted only after a verified
#    transfer). Skipped: ASINs already anywhere in the library (any depth) and
#    folders touched in the last 5 min (Libation still downloading). Loose
#    "<Title> [ASIN].pdf" files go into their book folder.
# 2. Library scan via the ABS API (the watcher misses writes on NFS).
# 3. Missing author images via author-images.py (Audnexus, then Wikidata).
#
# Auth: a 1h access token for the ABS root user is signed inside the pod with
# ABS' own secret (kubectl exec) — no API key to store. Needs kubectl access
# (nix develop + KUBECONFIG) and `ssh root@<NAS>`.
#
# Wi-Fi: with Wi-Fi and Ethernet in the same subnet, Wi-Fi wins the route and
# uploads crawl (~0.3 MB/s vs ~70 MB/s wired). ABS_IMPORT_NO_WIFI=1
# disconnects the Wi-Fi device via nmcli and reconnects it on exit.
set -euo pipefail

SRC=${SRC:-$HOME/Musik/Libation/Books}
NAS=${NAS:-192.168.10.94}
HOST=${HOST:-root@$NAS}
DST=${DST:-/mnt/Storagepool/Media/MediaStack/media/audiobooks}
ABS_URL=${ABS_URL:-https://audible.f4mily.net/audiobookshelf}
ABS_LIBRARY_NAME=${ABS_LIBRARY_NAME:-Audiobooks}
ABS_NAMESPACE=${ABS_NAMESPACE:-audiobookshelf}
DRY=${DRY:-0}
# ASINs this script started copying: resumed instead of skipped as "existing"
# when a previous run was interrupted.
JOURNAL=${JOURNAL:-${XDG_STATE_HOME:-$HOME/.local/state}/abs-libation-import/copied_asins}
HERE=$(cd "$(dirname "$0")" && pwd)

log() { printf '%s %s\n' "$(date +%T)" "$*"; }

# --- network path -----------------------------------------------------------
dev=$(ip route get "$NAS" | grep -oP 'dev \K\S+')
if [[ -d /sys/class/net/$dev/wireless ]]; then
  if [[ ${ABS_IMPORT_NO_WIFI:-0} == 1 && $DRY != 1 ]]; then
    log "disconnecting Wi-Fi $dev for the copy"
    nmcli device disconnect "$dev" >/dev/null
    trap 'nmcli device connect "'"$dev"'" >/dev/null && log "Wi-Fi $dev reconnected"' EXIT
    sleep 3
    log "route to $NAS now via $(ip route get "$NAS" | grep -oP 'dev \K\S+')"
  else
    log "WARN route to $NAS goes over Wi-Fi ($dev) — slow; set ABS_IMPORT_NO_WIFI=1 to use the cable"
  fi
fi

# --- 1. move ----------------------------------------------------------------
mkdir -p "$(dirname "$JOURNAL")"; touch "$JOURNAL"
# shellcheck disable=SC2029  # $DST is meant to expand locally
existing=$(ssh "$HOST" "cd '$DST' && find . -mindepth 1 -type d" \
  | grep -oE '\[[0-9A-Z]{10}\]' | sort -u | grep -vxFf "$JOURNAL" || true)

moved=0; skipped_exist=0; skipped_busy=0
cd "$SRC"
for d in */; do
  d=${d%/}
  asin=$(grep -oE '\[[0-9A-Z]{10}\]$' <<<"$d" || true)
  [[ -z $asin ]] && { log "WARN no [ASIN] in folder name, skipped: $d"; continue; }
  if grep -qxF "$asin" <<<"$existing"; then skipped_exist=$((skipped_exist+1)); continue; fi
  # find instead of globs: the [ASIN] brackets are glob characters
  if [[ -n $(find "$d" -type f -mmin -5) || -z $(find "$d" -type f \( -name '*.m4b' -o -name '*.mp3' \)) ]]; then
    log "busy/empty, next run: $d"; skipped_busy=$((skipped_busy+1)); continue
  fi
  log "move: $d"
  moved=$((moved+1))
  [[ $DRY == 1 ]] && continue
  echo "$asin" >> "$JOURNAL"
  rsync -rt --partial --remove-source-files --chown=1000:1000 --chmod=D2775,F664 "$d" "$HOST:$DST/"
  while IFS= read -r -d '' pdf; do
    rsync -t --remove-source-files --chown=1000:1000 --chmod=F664 "$pdf" "$HOST:$DST/$d/"
  done < <(find . -maxdepth 1 -type f -name "*${asin}.pdf" -print0)
  rmdir "$d" 2>/dev/null || log "WARN not empty after move: $d"
done
log "moved=$moved already_in_library=$skipped_exist busy=$skipped_busy"

# --- 2. scan ----------------------------------------------------------------
TOKEN=$(kubectl exec -n "$ABS_NAMESPACE" deploy/audiobookshelf -- node -e '
const s=require("/app/node_modules/sqlite3"),jwt=require("/app/node_modules/jsonwebtoken");
const db=new s.Database("/config/absdatabase.sqlite",s.OPEN_READONLY);
db.get("select value from settings where key=\"server-settings\"",(e,r)=>{if(e)throw e;
 const sec=process.env.JWT_SECRET_KEY||JSON.parse(r.value).tokenSecret;
 db.get("select id,username from users where type=\"root\"",(e,u)=>{if(e)throw e;
  process.stdout.write(jwt.sign({userId:u.id,username:u.username,type:"access"},sec,{expiresIn:"1h"}))})});')
api() { curl -fsS -H "Authorization: Bearer $TOKEN" "$@"; }
LIB=$(api "$ABS_URL/api/libraries" | jq -r --arg n "$ABS_LIBRARY_NAME" '.libraries[]|select(.name==$n).id')
[[ -n $LIB ]] || { log "ERROR library '$ABS_LIBRARY_NAME' not found"; exit 1; }

if [[ $moved -gt 0 && $DRY != 1 ]]; then
  before=$(api "$ABS_URL/api/libraries/$LIB/items?limit=1" | jq .total)
  api -X POST "$ABS_URL/api/libraries/$LIB/scan" >/dev/null
  log "scan started"
  sleep 5
  for _ in $(seq 1 120); do
    running=$(api "$ABS_URL/api/tasks" | jq '[.tasks[]?|select(.action=="library-scan" and (.isFinished|not))]|length')
    [[ $running == 0 ]] && break
    sleep 5
  done
  after=$(api "$ABS_URL/api/libraries/$LIB/items?limit=1" | jq .total)
  log "scan done: items $before -> $after"
fi

# --- 3. author images -------------------------------------------------------
ABS_URL=$ABS_URL ABS_TOKEN=$TOKEN ABS_LIBRARY=$LIB DRY=$DRY python3 -I "$HERE/author-images.py"
