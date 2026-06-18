# Operational Learnings

> **Check `docs/learnings/` first** before attempting complex migrations or configuration changes.

This directory contains distilled knowledge from past operations that did not work on the first attempt. These are not generic tutorials but specific pitfalls and solutions discovered the hard way.

## When to Create a New Learning

**Create a learning when:**
- A migration or major reconfiguration required multiple attempts
- An action had unexpected side effects (e.g., deleting `oc_filecache` breaks S3 storage)
- Kubernetes / Helm / Application behavior contradicts intuitive expectations
- A fix required a specific sequence or workaround
- A rolling update or pod restart caused data corruption or unexpected behavior

**Do NOT create learnings for:**
- Standard procedures that worked as documented
- Generic best practices (e.g., "always use resource limits")
- One-line fixes for obvious typos
- Things already well-documented in upstream docs

## Learning Structure

Each learning is a standalone Markdown file named `<topic>.md` with the following structure:

```markdown
# <Topic>

**Date**: YYYY-MM-DD
**Severity**: critical / high / medium / low
**Affected**: app / infrastructure / CI / cluster-wide
**Status**: resolved / workaround / ongoing

## What Went Wrong
Describe the incorrect assumption or action that led to the problem.

## Why It Failed
The technical root cause. Be specific.

## The Correct Approach
What actually works. Include commands, config snippets, or procedures.

## Prevention
How to avoid this in the future. Include specific checks or guardrails.

## Related
- Links to migration docs, runbooks, or PRs
```

## Existing Learnings

| File | Topic | Date |
|------|-------|------|
| [nextcloud-s3-primary-storage.md](nextcloud-s3-primary-storage.md) | Nextcloud: NFS → S3 Primary Storage Migration | 2026-06-06 |
| [immich-vchord-extension-update.md](immich-vchord-extension-update.md) | Immich: vchord Extension Update Crashes Server on Startup | 2026-06-08 |
| [democratic-csi-pvc-resize-permission-denied.md](democratic-csi-pvc-resize-permission-denied.md) | Democratic-CSI iSCSI PVC Resize: Permission Denied on Talos | 2026-06-09 |
| [nextcloud-iscsi-emergency-readonly.md](nextcloud-iscsi-emergency-readonly.md) | Nextcloud iSCSI: Emergency Read-Only Remount | 2026-06-13 |
| [netbird-reverse-proxy-traefik-grpc-timeout.md](netbird-reverse-proxy-traefik-grpc-timeout.md) | NetBird Reverse Proxy: 404/502 from Traefik gRPC Stream Timeout | 2026-06-14 |
| [talos-automatic-upgrade-suc-auth.md](talos-automatic-upgrade-suc-auth.md) | Automatic Talos OS Upgrades via System Upgrade Controller | 2026-06-18 |

---

**Note**: Learnings are append-only. Do not edit past learnings to reflect current state; create a new entry if the situation changes.
