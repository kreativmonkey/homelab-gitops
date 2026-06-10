# Renovate erkennt keine Docker-Image-Updates bei CalVer/Hash-Tags

**Date**: 2026-06-10
**Severity**: high
**Affected**: apps
**Status**: resolved

## What Went Wrong

SearXNG Docker-Image war 16 Monate alt (`2025.2.7-739822f70`). Renovate hat nie ein Update-PR vorgeschlagen. Google und Startplace waren seit Cluster-Erstellung nicht funktionsfähig (CAPTCHA-Blockierung durch fehlenden `arc_id`-Parameter).

## Why It Failed

Renovate's `kubernetes`-Manager erkennt `image:`-Felder in Deployment-Manifests und nutzt standardmäßig die `docker`-Datasource mit **Semver**-Versioning.

SearXNG's Tag-Format ist `YYYY.M.D-commitshort` (z.B. `2025.2.7-739822f70`). Dieses CalVer + Hash-Format wird von Semver-Logik nicht korrekt versioniert:
- Renovate interpretiert den Hash als Pre-Release-Suffix
- Der Versionsvergleich zwischen `2025.2.7-739822f70` und `2026.6.2-e964708c0` schlägt fehl
- Kein Update-PR wird erstellt

Das gleiche Problem betrifft potenziell alle Images mit CalVer/Hash-Tags (z.B. SearXNG, manche Monitoring-Tools).

## The Correct Approach

`# renovate:`-Marker mit `versioning=loose` in die Deployment-Manuale einfügen:

```yaml
containers:
  - name: searxng
    # renovate: datasource=docker depName=docker.io/searxng/searxng versioning=loose
    image: docker.io/searxng/searxng:2026.6.2-e964708c0
```

`loose`-Versioning sagt Renovate: "Vergleiche nach Datum/Tag-Name, nicht nach Semver-Compliance."

## Prevention

- **Bei jedem neuen App-Deployment mit Docker-Images prüfen**: Folgt das Tag-Format Semver (`v1.2.3`) oder CalVer/Hash? Bei CalVer/Hash → `# renovate: datasource=docker depName=... versioning=loose` einfügen.
- **Nicht auf den `kubernetes`-Manager allein vertrauen** — er erkennt `image:`-Felder, aber das Versioning muss stimmen.
- **Regelmäßig `renovatedashboard` prüfen**: `https://dashboard.renovatebot.com` zeigt an, welche Packages Renovate nicht versionieren kann.
- **Renovate-Config-Review bei neuen Apps**: Prüfen ob ein `packageRules`-Eintrag oder `# renovate:`-Marker benötigt wird.

## Related

- SearXNG Deployment: `apps/base/searxng/deployment.yaml`
- Renovate Config: `renovate.json`
- Renovate Docs: [Versioning - Docker](https://docs.renovatebot.com/modules/versioning/docker/)
- Renovate Docs: [Custom Managers](https://docs.renovatebot.com/configuration-options/#custommanagers)
