# Renovate — Konzept

**Grundregel: Jede Versionszeile hat genau einen Besitzer.**
Doppelte Erkennung durch mehrere Manager erzeugt doppelte PRs für dieselbe
Änderung (siehe PRs #385/#386/#387: dreimal derselbe Immich-Bump).

## Wer besitzt was

| Besitzer | Zuständig für | Beispiel |
|---|---|---|
| `flux`-Manager (nativ) | HelmRelease-Chart-Versionen, GitRepository/OCIRepository `ref.tag`, `repository:`+`tag:`-Paare in HelmRelease-values | `apps/base/immich/helmrelease.yaml` |
| `kubernetes`-Manager (nativ) | `image:`-Zeilen in Dateien, deren Name auf `…deployment/daemonset/statefulset/job/cronjob.yaml` endet | `apps/base/teslamate/mosquitto-deployment.yaml` |
| `kustomize`-Manager (nativ) | Remote-Bases (`?ref=`), `images:`-Overrides (`newTag:`) | `infrastructure/base/system-upgrade-controller/kustomization.yaml` |
| `github-actions`-Manager (nativ) | `uses:` in `.github/workflows/` **und** `.forgejo/workflows/` | `pr-validation.yaml` |
| `nix`-Manager + lockFileMaintenance | `flake.nix` / `flake.lock` | |
| Regex-Marker (`# renovate: datasource=… depName=…`) | **Nur** Felder, die kein nativer Manager versteht | CNPG `imageName:`, tag-only values, Image-Strings in values/ConfigMaps, Talos-Plan `version:` |

## Dateinamens-Konvention (wichtig!)

Der kubernetes-Manager scannt **naiv jede `image:`-Zeile** in Dateien, die er
matcht — auch in HelmRelease-values, ConfigMap-Daten oder SUC-Plans. Er darf
deshalb nur Dateien sehen, die wirklich Workloads enthalten:

- Workload-Manifeste heißen `<name>-deployment.yaml`, `<name>-statefulset.yaml`,
  `<name>-daemonset.yaml` (oder schlicht `deployment.yaml` usw.).
- HelmReleases heißen `helmrelease*.yaml` — **niemals** eine HelmRelease in eine
  Datei namens `deployment.yaml` legen (war bei kite/sterling-pdf der Fall).
- Eine falsch benannte Workload-Datei wird von Renovate **gar nicht** überwacht
  (so waren dawarich-valkey und spectrumknx-timescaledb unbeobachtet).

## Marker-Policy

Einen `# renovate:`-Marker **nur** setzen, wenn flux/kubernetes/kustomize die
Zeile nachweislich nicht erkennen. Sonst entsteht wieder Doppel-Monitoring.
Aktuell legitime Marker:

- CNPG `Cluster.spec.imageName` (kein Manager kennt CNPG)
- Tag-only-Werte ohne `repository:`-Geschwisterfeld (Immich common `image.tag`, Goloom, Nextcloud `image.tag`)
- Vollständige Image-Strings **innerhalb von HelmRelease-values / ConfigMap-Daten** (Nextcloud occ-Init-Container, Busybox-Helper)
- SUC `Plan.spec.version` + talosctl-Image (Kind `Plan` ist kein Workload)
- Datasource-Overrides (Readeck: Codeberg-Registry ist per Docker-Datasource nicht auflösbar → `gitea-tags`)
- Grafana-Plugins (Custom-Datasource gegen den grafana.com-Katalog)

## Gruppierung: ein PR pro App

Eine einzige Regel gruppiert alles per Verzeichnis: `groupName: {{parentDir}}`.
Ein neues App-Verzeichnis braucht **keine** Renovate-Konfiguration — Chart,
Images und Marker desselben Verzeichnisses landen automatisch im selben PR.
Damit sind Lockstep-Kopplungen (Nextcloud Chart+occ-Images, Teslamate
App+Grafana, Immich server+ML, SparkyFitness Chart-Tag+Images, SUC ref+newTag)
ohne Extra-Regeln erfüllt. Major-Updates trennt Renovate weiterhin ab
(`update <app> (major)`).

Ausnahmen (explizite Regeln, stehen nach der Gruppenregel und gewinnen):

- **Talos** (`siderolabs/talos`): eigene Gruppe, nicht mit dem SUC-Controller mischen.
- **CNPG-Images**: Major = manuelle Migration (`pg_upgrade`/Re-Bootstrap). Die
  `allowedVersions`-Regexe pinnen die aktuelle Major und filtern Betas
  (`19beta1` war mit `versioning=loose` sonst ein "Update"). **Für einen
  geplanten Major-Sprung die Regex in `renovate.json` anheben.**
- **Authentik**: CalVer, gepinnt auf 2026.5.x — für Upgrades Pin anheben.
- **Fast lane** (searxng rolling, Renovate selbst): 2 Tage Soak + Automerge,
  statt global 7 Tage.

## Timing & Automerge

- Global `minimumReleaseAge: 7 days` — alles bekommt eine Woche Soak.
- Automerge nur: nix/flake-Lock, Renovate-Selbstupdate, searxng, Homepage-Patches.

## Verifikation nach Config-Änderungen

```sh
LOG_LEVEL=debug npx -y renovate@43 --platform=local --dry-run=extract
```

zeigt pro Manager die extrahierten Dependencies. Jede Dependency darf genau
einmal auftauchen. Nach dem Merge räumt Renovate die obsoleten Gruppen-PRs
(`flux helm releases`, `helm chart values`, `renovate markers`) selbst ab.
