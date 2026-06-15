# Purpose

Durable operational knowledge: runbooks, learnings, integration guides, disaster-recovery docs, proposals.

# Ownership

- Owns: `runbooks/` (incident response), `learnings/` (hard-won pitfalls), `integrations/` (cross-service setup, incl. Authentik OIDC guides), `disaster-recovery/`, `proposals/`, top-level reference docs.

# Local Contracts

- `learnings/<slug>.md` — create only when an op needed multiple attempts, had unexpected side effects, contradicted intuition, or required a specific workaround. Skip for standard procedures, generic best practices, obvious typo fixes.
- Learning structure: What went wrong → Why it failed → Correct approach → Prevention.
- `runbooks/<service>.md` — actionable incident response, referenced by Alertmanager rules.
- Check `learnings/` BEFORE complex migrations or reconfig.

# Work Guidance

- Document stable, reusable knowledge — not diary entries. Delete stale docs.

# Verification

- `yamllint -c .yamllint.yml .` covers embedded YAML docs.

# Child DOX Index

No child AGENTS.md.
