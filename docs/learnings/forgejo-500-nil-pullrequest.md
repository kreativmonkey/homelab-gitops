# Forgejo 500 Error: Nil PullRequest in Template

**Date**: 2026-06-08
**Severity**: high
**Affected**: app (forgejo)
**Status**: resolved

## What Went Wrong

Opening the Renovate Dependency Dashboard issue (#6) on `goloon` repo
returned a 500 Internal Server Error. The error log showed a nil-pointer
dereference in template `comments.tmpl` at line 577:

```
PANIC: runtime error: invalid memory address or nil pointer dereference
.../gitea/services/context/panic.go:47
.../templates/repo/issue/view_content/comments.tmpl:577
```

The issue was not immediately reproducible — only a specific issue was
affected, making it look like data corruption.

## Why It Failed

Forgejo's `comments.tmpl` renders a timeline for every comment on an
issue. Comment type 29 (PULL_PUSH_EVENT) renders force-push details
by accessing `$.Issue.PullRequest.HeadBranch`. The template assumes
type-29 comments only exist on PR issues, where `.PullRequest` is
populated. When Renovate created push-event comments on the Dependency
Dashboard (a regular issue, `is_pull=false`), `.PullRequest` was nil,
causing the panic.

The root cause of the orphaned comments: Renovate pushes to its PR
branches (force-push after rebasing). Forgejo incorrectly attributed
the push event to the Dependency Dashboard issue instead of the
corresponding PR. This is likely a Forgejo bug in push-event routing
when a bot creates both the PR and the issue.

Affected repos: `goloon`, `homelab-gitops`, `homelab-infrastructure` —
all repos where Renovate creates Dependency Dashboard + PRs.

## The Correct Approach

Two fixes, both applied:

### 1. Immediate: Delete orphaned comments via DB (buy time)

```sql
-- List orphaned type-29 comments on non-PR issues
SELECT c.id, c.issue_id, i.repo_id, i.index as issue_number, i.is_pull, i.name
FROM comment c
JOIN issue i ON c.issue_id = i.id
WHERE c.type = 29 AND i.is_pull = false;

-- Delete them
DELETE FROM comment WHERE id IN (<comma-separated-ids>);
```

Executed via `psql` into the CNPG Postgres cluster:
```bash
PGPASSWORD=<pw> psql -h homelab-postgres-rw.cnpg-system.svc.cluster.local \
  -U forgejo -d forgejo -c 'DELETE FROM comment WHERE id IN (...);'
```

### 2. Permanent: Custom template with nil-check (prevents recurrence)

Added a `$.Issue.PullRequest` nil-check to the type-29 condition in
`comments.tmpl`. Now when a type-29 comment exists on a non-PR issue,
the block is silently skipped instead of panicking.

Implemented as a ConfigMap `forgejo-comments-tmpl` mounted at
`/data/gitea/templates/repo/issue/view_content/comments.tmpl` in the
Forgejo Deployment. The fix is one line:

```
Before: {{else if and (eq .Type 29) (or (gt .CommitsNum 0) .IsForcePush)}}
After:  {{else if and (eq .Type 29) $.Issue.PullRequest (or (gt .CommitsNum 0) .IsForcePush)}}
```

## Prevention

- **Template safety net**: the ConfigMap override prevents 500 even if
  more orphaned comments appear
- **Renovate monitoring**: watch Forgejo logs for `nil pointer
  dereference` / `comments.tmpl` patterns
- **Upgrade awareness**: when updating Forgejo, diff
  `apps/base/forgejo/comments-tmpl.configmap.yaml` against the new
  release's `templates/repo/issue/view_content/comments.tmpl` and
  re-apply the one-line nil-check

## Related

- PR: (link to PR that applied the ConfigMap fix)
- Upstream Forgejo source: `templates/repo/issue/view_content/comments.tmpl`
- Custom templates in Forgejo: placed in `{CUSTOM_PATH}/templates/...`
  (`CUSTOM_PATH=/data/gitea` in Docker)
