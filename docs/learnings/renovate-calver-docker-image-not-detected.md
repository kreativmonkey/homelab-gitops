# Renovate Misses Docker Image Updates with CalVer/Hash Tags

**Date**: 2026-06-10
**Severity**: high
**Affected**: apps
**Status**: resolved

## What Went Wrong

SearXNG Docker image was 16 months old (`2025.2.7-739822f70`). Renovate never proposed an update PR. Google and Startpage were non-functional since cluster creation (CAPTCHA blocking due to missing `arc_id` parameter).

## Why It Failed

Renovate's `kubernetes` manager detects `image:` fields in Deployment manifests and defaults to the `docker` datasource with **Semver** versioning.

SearXNG's tag format is `YYYY.M.D-commitshort` (e.g. `2025.2.7-739822f70`). This CalVer + hash format is not handled correctly by Semver logic:
- Renovate interprets the hash as a pre-release suffix
- Version comparison between `2025.2.7-739822f70` and `2026.6.2-e964708c0` fails
- No update PR is created

This affects any image using CalVer or commit-hash tags (e.g. SearXNG, some monitoring tools).

## The Correct Approach

Add `# renovate:` markers with `versioning=loose` to Deployment manifests:

```yaml
containers:
  - name: searxng
    # renovate: datasource=docker depName=docker.io/searxng/searxng versioning=loose
    image: docker.io/searxng/searxng:2026.6.2-e964708c0
```

`loose` versioning tells Renovate: "Compare by date/tag name, not Semver compliance."

## Prevention

- **Check every new app deployment with Docker images**: Does the tag follow Semver (`v1.2.3`) or CalVer/hash? For CalVer/hash — add `# renovate: datasource=docker depName=... versioning=loose`.
- **Do not rely solely on the `kubernetes` manager** — it detects `image:` fields but versioning must match.
- **Regularly check the Renovate dashboard**: `https://dashboard.renovatebot.com` shows which packages Renovate cannot version.
- **Review Renovate config for new apps**: Check if a `packageRules` entry or `# renovate:` marker is needed.

## Related

- SearXNG Deployment: `apps/base/searxng/deployment.yaml`
- Renovate Config: `renovate.json`
- Renovate Docs: [Versioning - Docker](https://docs.renovatebot.com/modules/versioning/docker/)
- Renovate Docs: [Custom Managers](https://docs.renovatebot.com/configuration-options/#custommanagers)
