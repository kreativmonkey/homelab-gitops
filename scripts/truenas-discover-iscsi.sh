#!/usr/bin/env bash
# Query TrueNAS iSCSI portal/initiator IDs and list datasets (needs API key).
# Usage: TRUENAS_API_KEY=... ./scripts/truenas-discover-iscsi.sh
set -euo pipefail

HOST="${TRUENAS_HOST:-192.168.10.94}"
API_KEY="${TRUENAS_API_KEY:?Set TRUENAS_API_KEY}"

api() {
  curl -sS -H "Authorization: Bearer ${API_KEY}" "http://${HOST}/api/v2.0/$1"
}

echo "=== iSCSI portals (use id for targetGroupPortalGroup) ==="
api iscsi/portal | python3 -m json.tool 2>/dev/null || api iscsi/portal

echo
echo "=== iSCSI initiator groups (use id for targetGroupInitiatorGroup) ==="
api iscsi/initiator | python3 -m json.tool 2>/dev/null || api iscsi/initiator

echo
echo "=== iSCSI targets (CSI creates extents dynamically; manual target optional) ==="
api iscsi/target | python3 -m json.tool 2>/dev/null || api iscsi/target

echo
echo "=== ZFS pools / datasets (pick sibling parents for volumes + snapshots) ==="
api pool/dataset | python3 -c "
import json,sys
data=json.load(sys.stdin)
for d in sorted(data, key=lambda x: x.get('name','')):
    if d.get('type') in ('FILESYSTEM','VOLUME'):
        print(d.get('name'), d.get('type'), d.get('mountpoint',''))
" 2>/dev/null || api pool/dataset | head -c 4000

echo
echo "Paste portal id, initiator id, and dataset paths into:"
echo "  infrastructure/base/storage/democratic-csi/truenas-iscsi-driver.secret.yaml.template"
