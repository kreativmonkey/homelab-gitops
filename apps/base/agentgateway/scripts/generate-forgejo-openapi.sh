#!/usr/bin/env bash
# Regenerate config/forgejo-openapi.json — the OpenAPI spec agentgateway turns
# into curated Forgejo MCP tools.
#
# Why this exists: Forgejo only publishes Swagger 2.0 (~491 operations, 800 KB+).
# agentgateway needs OpenAPI 3.x, and a full converted spec (~1.3 MB) blows the
# 1 MiB ConfigMap limit AND floods clients with 491 tools. So we:
#   1. fetch Forgejo's Swagger 2.0
#   2. convert 2.0 -> 3.0 (swagger2openapi)
#   3. trim to the curated ALLOWLIST below, pruning unreferenced components
#      (transitive $ref closure) -> ~46 KB, ~10 tools.
#
# Re-run whenever the allowlist changes or Forgejo's API gains operations you
# want to expose. Requires: curl, python3, and npx (Node) OR podman.
set -euo pipefail

FORGEJO_URL="${FORGEJO_URL:-https://git.f4mily.net}"
OUT="$(cd "$(dirname "$0")/.." && pwd)/config/forgejo-openapi.json"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

# Curated set of Forgejo operationIds exposed as MCP tools. Keep it small and
# task-oriented — more tools = worse agent tool selection.
ALLOWLIST='repoSearch issueListIssues issueGetIssue issueCreateIssue issueCreateComment repoGetContents repoListReleases userGetCurrent repoGet repoListPullRequests'

echo ">> fetching Swagger 2.0 from $FORGEJO_URL"
curl -fsS "$FORGEJO_URL/swagger.v1.json" -o "$TMP/forgejo-2.0.json"

echo ">> converting Swagger 2.0 -> OpenAPI 3.0"
if command -v npx >/dev/null 2>&1; then
  npx -y swagger2openapi "$TMP/forgejo-2.0.json" -o "$TMP/forgejo-3.0.json"
else
  podman run --rm -v "$TMP:/w:Z" -w /w docker.io/library/node:22-alpine \
    npx -y swagger2openapi forgejo-2.0.json -o forgejo-3.0.json
fi

echo ">> trimming to allowlist + pruning unreferenced components"
ALLOWLIST="$ALLOWLIST" python3 - "$TMP/forgejo-3.0.json" "$OUT" <<'PY'
import json, os, re, sys
src, out = sys.argv[1], sys.argv[2]
want = os.environ["ALLOWLIST"].split()
d = json.load(open(src))

opid2path = {op["operationId"]: (p, m)
             for p, ms in d.get("paths", {}).items()
             for m, op in ms.items()
             if isinstance(op, dict) and "operationId" in op}
missing = [o for o in want if o not in opid2path]
if missing:
    sys.exit(f"operationIds not found in spec: {missing}")

keep = {}
for o in want:
    p, m = opid2path[o]
    keep.setdefault(p, {})[m] = d["paths"][p][m]
    if "parameters" in d["paths"][p]:
        keep[p]["parameters"] = d["paths"][p]["parameters"]

new = {k: d[k] for k in ("openapi", "info", "servers", "security", "tags") if k in d}
new["paths"] = keep
comps = d.get("components", {})

def refs(obj, acc):
    if isinstance(obj, dict):
        for k, v in obj.items():
            acc.add(v) if k == "$ref" and isinstance(v, str) else refs(v, acc)
    elif isinstance(obj, list):
        for v in obj:
            refs(v, acc)

needed = set(); refs(keep, needed); changed = True
while changed:
    changed = False
    for r in list(needed):
        m = re.match(r"#/components/([^/]+)/(.+)$", r)
        if not m:
            continue
        node = comps.get(m.group(1), {}).get(m.group(2))
        if node is not None:
            before = len(needed); refs(node, needed); changed |= len(needed) > before

pruned = {}
for r in needed:
    m = re.match(r"#/components/([^/]+)/(.+)$", r)
    if m and m.group(2) in comps.get(m.group(1), {}):
        pruned.setdefault(m.group(1), {})[m.group(2)] = comps[m.group(1)][m.group(2)]
new["components"] = pruned
json.dump(new, open(out, "w"), indent=0)
print(f">> wrote {out}: {len(new['paths'])} paths, "
      f"{ {k: len(v) for k, v in pruned.items()} }, {os.path.getsize(out)} bytes")
PY

echo ">> done"
