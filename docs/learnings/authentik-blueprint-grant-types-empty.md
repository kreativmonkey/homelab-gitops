# Authentik blueprint without grant_types breaks new OIDC providers

**Date**: 2026-10-01
**Severity**: medium
**Affected**: app (Vikunja; any new Authentik OAuth2 provider)
**Status**: resolved

## What Went Wrong
The Vikunja blueprint was copied from the root AGENTS.md template, which had no
`grant_types`. Discovery, scopes and redirect URI were correct, but every login
bounced back to the app with
`error=invalid_request&error_description=The request is otherwise malformed`.

## Why It Failed
`OAuth2Provider.grant_types` is an `ArrayField(default=list)`. A provider created
fresh by a blueprint that omits the field gets `[]`, and `check_grant()` in
`authentik/providers/oauth2/views/authorize.py` rejects any grant not in that
list with `invalid_request`. Older providers (Grafana, Forgejo, …) work without
the field only because a migration populated their grants when the field was
introduced — so "the other blueprints don't set it either" is misleading.

## The Correct Approach
Set `grant_types` explicitly on every `authentik_providers_oauth2.oauth2provider`
entry:

```yaml
grant_types:
  - authorization_code
  - refresh_token
```

Quick check without a browser: an anonymous
`GET https://login.f4mily.net/application/o/authorize/?client_id=…&redirect_uri=…&response_type=code&scope=openid&state=x`
must 302 to the Authentik login flow, not back to the app with `error=`.

## Prevention
- Root AGENTS.md blueprint template includes `grant_types`.
- Blueprints that still omit it would break on a fresh Authentik (DR rebuild):
  add `grant_types` when touching them.
