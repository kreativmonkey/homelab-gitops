# Cluster-generierte Secrets via External Secrets Operator

## Status: Proposal

Clusterinterne Credentials (DB-Passwörter, Session-/JWT-Keys, OIDC-Client-Secrets
zwischen App und Authentik) werden nicht mehr als SOPS-Dateien gepflegt, sondern
einmalig im Cluster von ESO erzeugt und an die Verbraucher verteilt. SOPS bleibt
nur für echte Fremd-Credentials. Der Secret-Store ist hinter einem
namespace-lokalen `SecretStore`-Namen abstrahiert, damit später Vault/OpenBao
ohne Umbau der Verbraucher dahinter treten kann.

Langfristziel: Repo forken, Domain + eine überschaubare Liste externer
Credentials setzen, deployen.

---

## Ist-Zustand (Inventar 2026-11-20)

- **82 SOPS-Dateien**, 65 distinkte Secrets, plus 34 `*.secret.yaml.template`.
- Jedes CNPG-Rollenpasswort liegt **doppelt** im Repo:
  `infrastructure/overlays/main/database-clusters/credentials/<app>-db-credentials`
  (`cnpg-system`, für `managed.roles[].passwordSecret`) und
  `apps/overlays/main/db-secrets/<app>-db-credentials` (per Kustomize-Patch
  umbenannt/umgezogen nach `homelab-postgres-<app>` im App-Namespace).
  16 Rollen → 32 Dateien, plus `ainsel-hub-db`.
- OIDC-Client-Secrets ebenfalls doppelt: App-Seite hier (SOPS), Authentik-Seite
  (`!Env OIDC_<APP>_CLIENT_SECRET`) im privaten Repo `homelab-gitops-private`.
- `apps/base/outline/valkey.yaml` enthält ein Passwort im Klartext.
- Vor Phase 1 war ESO nicht installiert. Reflector verteilt TLS-Secrets.
- Velero sichert täglich/wöchentlich alle Namespaces inkl. Secrets.

## Klassifizierung

| Klasse | Inhalt | Ziel |
|---|---|---|
| **A1 – generierbar, Wechsel harmlos** | DB-Rollenpasswörter (App liest aus Env), JWT-/Session-Secrets, HMAC zwischen zwei Cluster-Komponenten, Valkey/Redis/Mongo-Passwörter, interne Tokens wie Outline `UTILS_SECRET` | ESO-Generator |
| **A2 – generierbar, an Daten gebunden** | Schlüssel, mit denen persistente Daten verschlüsselt sind: `n8n-encryption-key`, `teslamate ENCRYPTION_KEY`, `goloom ENCRYPTION_KEY`, `SPARKY_FITNESS_API_ENCRYPTION_KEY`, `authentik secret-key`, Outline `SECRET_KEY`; Nextcloud-DB-Passwort (steht in `config.php` auf dem PVC) | ESO-Generator **nur bei Neuinstallation**; Bestand übernimmt den heutigen Wert; nie automatisch neu erzeugen |
| **B – OIDC-Paar App ↔ Authentik** | `client-secret` von nextcloud, grafana, gatus, linkding, dawarich, vikunja, hister, outline, goloom, teslamate-grafana, linkwarden, sparkyfitness, tandoor/paperless (`SOCIALACCOUNT_PROVIDERS`) | ESO-Generator, beide Seiten lesen denselben Quellwert; `client-id` wird statischer Nicht-Secret-Wert |
| **C – extern** | GitHub-/Renovate-Tokens, OpenAI-Keys, Hetzner-API, Storagebox + `restic-password`, Barman-/Velero-S3, TrueNAS-API/democratic-csi, NetBird, Omni, ntfy, Webhook-URLs, AdGuard, SMB, App-erzeugte API-Tokens (Immich, Paperless) | bleibt SOPS → später Vault |
| **D – Bootstrap** | `sops-age`, Flux-Git-Credentials | bleibt außerhalb (Henne-Ei) |

Schätzung: A+B ≈ 55–60 der 82 Dateien entfallen. Übrig bleibt Klasse C (~20)
als dokumentierte „Bring your own credentials"-Liste.

`restic-password` bewusst Klasse C: ohne ihn ist das Offsite-Backup wertlos,
er darf nie nur im Cluster existieren.

---

## Zielarchitektur

```
                 ┌─────────────────────────── Namespace secret-source ───┐
 ClusterGenerator│ ExternalSecret <name>  ──Password-Generator──▶ Secret  │
   (password-32) │  refreshPolicy: CreatedOnce                    <name>  │
                 └──────────────────────────────────────────────┬────────┘
                                                                │ liest
                                    Je Verbraucher-Namespace: SecretStore "homelab"
                                    eigene Store-SA + erlaubte Quellnamen
                                    provider: kubernetes → später provider: vault
                                                                │
          ┌───────────────────────────┬─────────────────────────┼──────────────────┐
          ▼                           ▼                         ▼                  ▼
 cnpg-system:                 <app-ns>:                 authentik:            <app-ns>:
 ExternalSecret →             ExternalSecret →          ExternalSecret →      ExternalSecret →
 <app>-db-credentials         homelab-postgres-<app>    oidc-client-secrets-  <app>-authentik-oauth
 (basic-auth, cnpg.io/reload) (+ templated DATABASE_URL) <app>
```

Kernentscheidungen:

1. **Eine Quelle, viele Leser.** ESO-Generatoren sind zustandslos – zwei
   ExternalSecrets mit demselben Generator erzeugen zwei *verschiedene* Werte
   (auch `ClusterExternalSecret`). Deshalb erzeugt genau ein ExternalSecret den
   Wert im Namespace `secret-source`; alle Verbraucher (inkl. `cnpg-system`)
   lesen ihn über ihren lokalen `SecretStore homelab` (kubernetes-Provider).
2. **Store-Name als Abstraktion.** Verbraucher kennen nur
   `secretStoreRef: {kind: SecretStore, name: homelab}` und einen Key.
   Vault-Migration = Werte per `PushSecret` nach Vault schieben und
   jeden Store-Provider umstellen. Vault-Pfade und Properties müssen dieselben
   Keys abbilden; Verbraucher-Manifeste bleiben unverändert.
3. **Generate-once-Absicherung** für Quell-Secrets:
   `refreshPolicy: CreatedOnce`, `target.creationPolicy: Orphan`
   (kein ownerReference → Löschen des ExternalSecrets löscht
   das Secret nicht), `target.immutable: true`, Flux-Annotation
   `kustomize.toolkit.fluxcd.io/prune: disabled` am ExternalSecret und
   Quell-Secret. `immutable` verhindert Änderungen, keine Löschung.
   Verhalten nach Secret-Löschung und ExternalSecret-Neuanlage wird in Phase 0
   getrennt geprüft; `Orphan` und `CreateOrMerge` sind nicht austauschbar.
   DR-Pfad bis Vault ist Velero: Quellen wiederherstellen und Werte prüfen,
   **bevor** Generator-ExternalSecrets und Verbraucher aktiviert werden.
   Für jeden neuen A2-Schlüssel gilt zusätzlich: unabhängig vom Cluster
   verschlüsselt sichern und Wiederherstellbarkeit samt identischem Wert
   verifizieren, **bevor die App erstmals Daten damit schreibt**. Ein täglicher
   Velero-Zeitplan deckt die Lücke zwischen Erzeugung und erstem Backup nicht.
   GitOps-Gate: Quellen zunächst ohne Verbraucher/App aktivieren; erst nach
   bestätigter externer Sicherung Verbraucher und App separat freigeben.
4. **Getrennte Leser, gemeinsame Quellen.** Pro Verbraucher-Namespace ein
   `SecretStore homelab` mit eigener Store-ServiceAccount. Eine Role in
   `secret-source` erlaubt nur `get` mit expliziten `resourceNames`;
   kein pauschales `list/watch`, kein `dataFrom.find`. RoleBinding verbindet
   diese Role mit der Store-SA des Verbrauchers. App-Pods nutzen eine andere
   ServiceAccount ohne Quellrechte und erhalten lokale Secret-Kopien.
5. **Verbraucher-Secrets dürfen sich ändern** (`refreshPolicy: Periodic`,
   z. B. `1h`, `creationPolicy: Owner`) – sie sind reine Kopien. So greift eine
   bewusste Rotation in der Quelle automatisch überall.
6. **CNPG-Seite:** `target.template.type: kubernetes.io/basic-auth`,
   Keys `username`/`password`, Label `cnpg.io/reload: "true"`. CNPG setzt
   das Rollenpasswort dann aus dem Secret (nach Restore aus Barman ebenfalls).
7. **Gemischte Secrets** (z. B. `goloom-app`: DB-URL + OIDC + OpenAI-Key)
   werden aufgeteilt: generierte Keys per ESO, externe Keys bleiben im
   SOPS-Secret; die App bekommt beide via `envFrom`. Alternativ ein
   ExternalSecret mit `target.template`, das beide Quellen zusammenführt –
   erst wenn C-Secrets ebenfalls über den Store kommen (Vault-Phase).

### Zugriffsvertrag

Ein Quell-Secret darf mehreren Lesern gehören. Zugriff wird pro vollständigem
Secret-Objekt vergeben, nicht pro Datenfeld; deshalb getrennte Quellen für
DB-Passwort, OIDC-Paar und weitere App-Schlüssel.

| Store im Namespace | Erlaubte Quellen (Beispiel) |
|---|---|
| `hister` | `db-hister`, `oidc-hister`, eigene App-Schlüssel |
| `outline` | `db-outline`, `oidc-outline`, eigene App-Schlüssel |
| `cnpg-system` | DB-Credentials der dort verwalteten Cluster |
| `authentik` | benötigte OIDC-Paare sowie eigene DB-/App-Credentials |

`db-hister` wird einmal erzeugt und von Hister sowie CNPG gelesen;
`oidc-hister` einmal erzeugt und von Hister sowie Authentik gelesen.
Outline darf beide nicht lesen. Separate CNPG-Namespaces erhalten eigene Stores
mit den Credentials ihrer Cluster.

Ein gemeinsamer breit berechtigter `ClusterSecretStore` entfällt: dessen
`conditions` beschränkt nur Namespaces, keine Quellnamen pro Namespace.
Getrennte Store-Namen ohne getrennte Identitäten wären ebenfalls unzureichend.

ESO: `rbac.serviceAccountTokenCreate: false`; pro Store-SA eine Role im
Verbraucher-Namespace mit `create` auf `serviceaccounts/token` und genau deren
Namen in `resourceNames`, gebunden an die ESO-Controller-SA. Store-SA setzt
`automountServiceAccountToken: false`. Store-SA benötigt außerdem die
clusterweite Berechtigung für `SelfSubjectRulesReview`; vorhandene
`system:basic-user`-Berechtigung prüfen, nicht pauschal zusätzliche Rechte vergeben.

Stores, Quell-RBAC und Token-Delegation verwaltet ausschließlich die Plattform
via Flux. App-ServiceAccounts dürfen keine ESO-Ressourcen, RBAC oder fremden
Workloads verändern. Ein Namespace bildet die Vertrauensgrenze: wer dort Pods
erstellen darf, kann dortige Secrets und ServiceAccounts verwenden. Getrennte
Apps mit getrenntem Vertrauensniveau benötigen getrennte Namespaces. ESO und
Cluster-Admins bleiben privilegierte Vertrauensinstanzen.

Später bekommt jeder Store eine eigene Vault-Rolle mit denselben freigegebenen
Pfaden. Ein gemeinsamer Vault-Token mit Vollzugriff würde die Trennung aufheben.

**Bestands-RBAC vor dem Pilot bewerten.** RBAC ist additiv. 292 Live-SARs
bestätigten die folgenden Rechte. Hister läuft mit `hister/default` ohne
automatisch gemounteten Token und hatte keine der 49 abgefragten Berechtigungen.

- [`nextcloud/appapi-harp`](../../apps/base/nextcloud/appapi-harp-rbac.yaml)
  ist an `cluster-admin` gebunden. Damit besteht direkte Umgehung der
  Quell-Isolation. Vor Pilot einschränken oder ausdrücklich als privilegierte
  Plattformkomponente freigeben; kein Versprechen vollständiger App-Isolation
  bei unverändertem Binding.
- [`netbird/clusterproxy-homelab`](../../apps/base/netbird-operator/clusterproxy-rbac.yaml)
  darf Benutzer/Gruppen impersonieren, einschließlich administrativer
  Identitäten. Dieser Proxy gehört zum privilegierten Vertrauensbereich.
- [`ai-agents/mcp-laptop`](../../apps/base/ai-agents/rbac.yaml) darf clusterweit
  Workload-Templates patchen. Das ermöglicht indirekten Zugriff auf eingebundene
  Secrets oder auf die Identität eines Pods; ebenfalls privilegierter Zugang.

Weitere Plattformidentitäten mit direktem Zugriff sind unter anderem Velero,
Flux, CNPG und Reflector. Auch `list/watch` kann vollständige Secret-Objekte
liefern. Vor Phase 2 muss die Vertrauensgrenze für diese Identitäten akzeptiert
oder ihr Zugriff eingeschränkt sein. Phase 1 enthält nur Plattformressourcen
und einen Generator ohne konsumierendes ExternalSecret.

Referenzen: [ESO Multi Tenancy](https://external-secrets.io/latest/guides/multi-tenancy/),
[ESO Security](https://external-secrets.io/latest/guides/security-best-practices/),
[Kubernetes RBAC](https://kubernetes.io/docs/reference/access-authn-authz/rbac/).

---

## Phasen

### Phase 0 – Spike (lokaler Wegwerf-Cluster, kein Prod-Einfluss)

Reproduzierbar mit `nix develop -c just eso-spike`: eigener Kind-Cluster,
isoliertes Kubeconfig, synthetische Werte, automatisches Aufräumen. Keine
Produktions-Credentials, keine Tests auf `homelab-postgres`. ESO-Version mit
Renovate-Pin im Skript; CNPG-Chartversion und Image-Tag werden aus der
Repository-HelmRelease gelesen. Der dokumentierte Erstlauf verwendete ESO
2.15.0 und CNPG 1.30.1 (Chart 0.29.1).

Runtime-Ergebnis 2026-11-20: **41 Prüfungen erfolgreich** auf Kubernetes
1.36.4. Gemeinsame DB-/OIDC-Quellen, konkrete RBAC-Denials, Bestandsübernahme,
Löschverhalten, Template-Refresh und Outline-Format bestätigt. CNPG akzeptierte das neue
Passwort im letzten Lauf nach 2,5 Sekunden; das alte scheiterte an frischer
TCP-Verbindung. Wegwerf-Cluster nach dem Lauf entfernt.

Klären und Ergebnis samt Versionsstand festhalten:

- [x] `CreatedOnce` + `creationPolicy` + `immutable`: ExternalSecret löschen/
      neu anlegen, vorhandenen Wert übernehmen, nur Quelle löschen,
      Quelle + ExternalSecret-Status verlieren. Orphan und CreateOrMerge
      zeigten unterschiedliches Löschverhalten; vorhandener A2-Wert bleibt
      bei Übernahme erhalten, Prune-Annotation muss direkt gesetzt sein.
- [x] CNPG: ändert sich das Rollenpasswort bei inline `managed.roles` wirklich
      (mit `cnpg.io/reload`)? Eigener Wegwerf-CNPG-Cluster, frische TCP-Logins:
      neues Passwort funktioniert, altes wird abgewiesen. Verzögerung messen.
- [x] Lokale `SecretStore homelab` mit SA-Auth, `get` + `resourceNames`
      und eingeschränkter Token-Erstellung werden Ready.
- [x] Positive Tests: App + CNPG lesen dasselbe DB-Passwort;
      App + Authentik lesen dasselbe OIDC-Secret.
- [x] Negative Tests repräsentativ für App A nach erfolgreichem Positivtest: fremdes `remoteRef.key`
      und `dataFrom.find` scheitern, kein Ziel-Secret entsteht. App-SA hat keine
      Quellrechte; ESO kann kein Token einer unberechtigten SA erstellen.
- [x] Rendert `target.template` neu, wenn sich die Quelle ändert, bei
      `Periodic`-Verbrauchern?
- [x] Eigener Outline-Generator liefert genau 64 Hexzeichen entsprechend der
      Validierung der gepinnten App-Version; Test verwendet synthetischen Wert.
- [x] Flux-Prune mit source-controller und kustomize-controller v1.10.1 in
      Kind 1.37.0: Zweite Revision entfernte das Kontrollobjekt. Annotiertes
      immutable Secret behielt UID und Wert.
- [x] Velero 1.18.2 im Homelab: genau ein synthetisches Secret gesichert und
      ohne Generator in isolierten Zielnamespace restauriert. Identische
      Bytes, `immutable` und Prune-Schutz bestätigt. Testobjekte entfernt.
- [x] A2-Freigabereihenfolge mit synthetischem Schlüssel: age-Sicherung
      außerhalb des Testclusters, Restore der Quelle bei deaktiviertem
      Generator, Wertvergleich, dann Generator und Leser freigegeben. Die
      erste ESO-Kopie enthielt exakt den ursprünglichen Wert.
- [x] Cilium im Homelab: Pod unter Baseline und API-Egress löste den Service
      auf und erreichte die Kubernetes-API per verifiziertem TLS (HTTP 401
      ohne Token). Webhook und Scrape nach Phase-1-Sync live prüfen.
- [x] Effektive Bestands-RBAC mit Live-SubjectAccessReviews erfasst.

Ergebnisse und Grenzen: [ESO-Lifecycle-Learning](../learnings/eso-generated-secrets-lifecycle.md).
Insbesondere kann ein Orphan-ExternalSecret trotz fehlender Quelle Ready melden.
Vor dem Pilot sind die Freigabe der privilegierten Identitäten und die
Phase-1-Live-Prüfungen fällig. Vor erster A2-Neuinstallation muss der konkrete
Offsite-Backup- und Restore-Ablauf samt Freigabe des Verbrauchers geprüft sein.
Der Velero-Test belegt den Kubernetes-Objekt-Restore über den vorhandenen
Backup-Speicher.

### Phase 1 – ESO-Plattform

- `infra-eso` installiert HelmRelease 2.15.0, CRDs, Webhook und cert-controller
  mit PSA `restricted`, Netzwerk-Baseline und API-Egress. Die bestehende
  Host-Netzwerk-Policy lässt API-Server zum Webhook durch.
- `infra-secrets` wartet auf `infra-eso` und legt `secret-source` und den
  `ClusterGenerator password-32` an. Eigenständige Kustomizations halten
  eine fehlgeschlagene ESO-Installation vom bestehenden App-Rollout getrennt.
- Das erste Quell-ExternalSecret und seine Reader-Roles, Stores und
  Token-Delegation kommen mit dem Pilot. Die Überwachung fehlender Quell-Secrets
  ergänzt dann den Controller- und Ready-Alert. Ready allein reicht bei
  `CreatedOnce` nicht als Existenznachweis.
- Nach Merge prüfen: Flux-Kustomizations und HelmRelease Ready, Deployment-
  Verfügbarkeit, serverseitiges Dry-Run eines synthetischen ExternalSecret
  durch den Webhook, aktiver Metrics-Scrape.
- [ADR 0005](../adr/0005-external-secrets-operator.md) hält die Plattformgrenze fest.

### Übergabe bestehender SOPS-Secrets an ESO

Gilt für alle folgenden Migrationen, auch über öffentliche und private
Kustomizations hinweg.

1. **Schutz-Commit.** Bestehende Werte unabhängig und verschlüsselt sichern
   und prüfen. Bei A2 den unveränderten Wert in `secret-source` übernehmen
   und prüfen, bevor der Generator aktiviert wird. Die bisherigen GitOps-Writer
   setzen `kustomize.toolkit.fluxcd.io/prune: disabled` auf die Live-Ziel-Secrets.
   Flux-Reconciliation und die Annotationen am Live-Objekt bestätigen.
2. **Übergabe-Commit.** SOPS-Ressourcen und zugehörige Patches aus den bisherigen
   Kustomizations ausbinden. Deren Reconciliation zuerst bestätigen, dann die
   ExternalSecrets für dieselben Ziele aktivieren. Beide Schritte dürfen nur im
   selben Commit liegen, wenn Flux diese Reihenfolge garantiert. Sonst die
   ESO-Aktivierung separat committen. ESO-Sync und Nutzung der Kopien prüfen
   (bei Datenbanken per frischem Login), dann verbliebene unreferenzierte
   SOPS-Dateien entfernen.

### Phase 2 – Pilot mit Hister

Die bestehenden privilegierten Zugriffe sind für diesen Pilot vorläufig
akzeptiert. [Issue #1557](https://github.com/kreativmonkey/homelab-gitops/issues/1557)
verfolgt die Einschränkung von HaRP.

1. `db-hister` generieren und die beiden lokalen Stores mit namensgebundenem
   Lesezugriff anlegen. ESO erstellt `cnpg-system/hister-db-credentials-eso`
   und `hister/homelab-postgres-hister-eso` parallel zu den bisherigen
   SOPS-Secrets. Beide Kopien und die Quelle geschützt auf Gleichheit prüfen.
   `infra-secrets` verwaltet die CNPG-Kopie. Die Kustomization
   `hister-db-secret` wartet auf `infra-secrets` und den von `apps` erzeugten
   Namespace. Shared Flux-Reconciliations bleiben unabhängig von ESO-Status.
2. Nur den `passwordSecret`-Verweis der CNPG-Rolle `hister` auf
   `hister-db-credentials-eso` umstellen. Auf CNPG-Reconciliation und einen
   frischen TCP-Login mit dem neuen Passwort warten. Frische Verbindungen
   des alten Hister-Pods können in diesem Zeitfenster fehlschlagen.
3. Hister per GitOps auf `homelab-postgres-hister-eso` umstellen. Das
   Deployment startet seinen Pod mit neuen Env-Werten. App- und DB-Funktion
   prüfen und danach die alten SOPS-Dateien und den Namenspatch entfernen.
4. Für einen Rückweg zuerst den alten CNPG-Verweis und TCP-Login
   wiederherstellen, dann Hister auf das alte App-Secret zurückstellen. Nach
   Entfernen der Altdateien diese aus der letzten SOPS-Revision zurückholen,
   bevor die Verweise umgestellt werden.

Stakater Reloader ist im Cluster nicht installiert. Die Pilot-Umstellung
ordnet DB-Wechsel, Login-Test und App-Rollout über getrennte Revisionen.

### Phase 3 – Restliche DB-Rollen (A1)

authentik, paperless, tandoor, linkwarden, teslamate, goloom, forgejo,
sparkyfitness(+`_app`), outline, vikunja, dawarich, immich, ainsel.
Jeweils einzeln nach der Übergabesequenz migrieren; App nach Passwortwechsel neu starten.

- Prüfen pro App: liest sie das Passwort bei jedem Start aus Env? Wenn nein →
  Klasse A2 behandeln.
- CNPG 1.30 empfiehlt separate `DatabaseRole`-Ressourcen. Dieser Umbau testet
  bewusst die bestehenden inline `managed.roles`; die Rollenmodell-Migration
  bleibt getrennt, damit ESO- und DB-Verhaltensänderung nicht zusammenfallen.
- `ainsel-hub-db` enthält `dsn` → per `target.template` erzeugen.
- `immich`/`dawarich` haben eigene Cluster, gleicher Ablauf.
- Am Ende: `apps/overlays/main/db-secrets/` und
  `database-clusters/credentials/` leer → Verzeichnisse + Patches entfernen.

### Phase 4 – Nextcloud + Klasse A2

- Länge, Zeichensatz und Verwendungszweck jedes Schlüssels gegen die gepinnte
  App-Version prüfen; `password-32` ist kein Universalformat für A2.
- Bestandswerte übernehmen statt neu generieren (Verfahren aus Phase 0).
  Bei Neuinstallationen gilt das A2-Backup-Gate vor erster Datennutzung:
  Quellwert extern sichern, Restore und Wertgleichheit prüfen, dann erst
  Verbraucher und App freigeben. Tägliches Velero allein reicht nicht.
  Prune-Schutz direkt am vorhandenen Quell-Secret setzen, bevor ESO es als
  immutable übernimmt; Template-Metadaten werden bei dieser Übernahme nicht
  nachgetragen.
  Fallback, falls ESO kein sauberes „adopt" kann: A2-Quellen bleiben bis zur
  Vault-Phase als SOPS-Secret *in `secret-source`* (eine Datei statt mehrerer),
  Verbraucher lesen trotzdem schon über den Store → Vault-Umzug später ohne
  Verbraucheränderung.
- Outline `secret-key` (`SECRET_KEY`) verschlüsselt Daten. Bei Bestand oder Restore den
  bisherigen Wert unverändert übernehmen. Nur bei leerer Neuinstallation
  automatisch einmalig mit dem ESO-`ClusterGenerator outline-key-64-hex`
  erzeugen und als gesichertes, unveränderliches Quell-Secret bereitstellen.
  `passwordSpec` setzt `length: 64`, `digits: 0`, `symbols: 64`,
  `symbolCharacters: "0123456789abcdef"`, `allowRepeat: true` und
  `encoding: raw`. Die 64 gleichverteilten Hexzeichen entsprechen 256 Bit
  Entropie und dem von Outline 1.10.1 (Chart 0.9.5) erwarteten Format
  (`openssl rand -hex 32`).
  [Chart-Pin](https://github.com/community-charts/helm-charts/blob/outline-0.9.5/charts/outline/Chart.yaml) ·
  [Outline-Validierung](https://github.com/outline/outline/blob/v1.10.1/server/env.ts#L66-L81) ·
  [ESO-Generator](https://github.com/external-secrets/external-secrets/blob/v2.15.0/generators/v1/password/password.go#L108-L139) ·
  [Zufallsauswahl der Bibliothek](https://github.com/sethvargo/go-password/blob/v0.4.0/password/generate.go#L199-L217)
- Nextcloud-DB-Passwort: nur mit Wartungsfenster, `config.php`
  (`dbpassword`) synchron anpassen.

### Phase 5 – Weitere A1-Secrets

searxng, dawarich `SECRET_KEY_BASE`, tandoor/paperless `SECRET_KEY`,
Outline `UTILS_SECRET` (nichtleeres Cron-Token) und `outline-valkey` (Klartext!),
vikunja `jwt-secret`, linkwarden `NEXTAUTH_SECRET`/`MEILI_MASTER_KEY`,
nextcloud-collab, remediation-api `hmac-secret`, ainsel
`internal-validate-secret`, spectrumknx, unifi Mongo, sparkyfitness
`BETTER_AUTH_SECRET`, Grafana-/pgadmin-/Nextcloud-Admin (Passwort per
`kubectl get secret` abrufbar). Folge: Nutzer werden einmal ausgeloggt.

### Phase 6 – OIDC-Paare (B)

- Quelle `oidc-<app>` in `secret-source`.
- Authentik: pro App ein ExternalSecret → `authentik-oidc-client-secrets-<app>`
  (gleicher Name wie heute, `envFrom` am Worker bleibt). Entsprechende Dateien
  im privaten Repo nach der gemeinsamen SOPS→ESO-Übergabesequenz entfernen.
  Warten, bis ExternalSecret `Ready` ist und das Ziel den Quellwert enthält.
- Authentik-Worker nach Secret-Übernahme neu starten; `envFrom` aktualisiert
  laufende Container nicht. Rollout vollständig abwarten, alte Worker müssen
  beendet sein. Danach Anwendung des zugehörigen Blueprints und richtigen
  Providerwert geschützt verifizieren. Worker-Ready oder erfolgreiche
  OIDC-Discovery allein beweisen keine Übernahme des Client-Secrets; siehe
  [Worker-Rollout-Learning](../learnings/authentik-blueprint-worker-rollout.md).
- App-Seite: ExternalSecret → `<app>-authentik-oauth`; für
  `SOCIALACCOUNT_PROVIDERS` (JSON) per `target.template`.
  App-Reloader während Cutover deaktivieren. Erst nach bestätigter
  Authentik-Übernahme und `Ready` samt gleichem Wert auf App-Seite die App
  neu starten und vollständigen OIDC-Login prüfen. Danach Reloader wieder
  freigeben. Bei neuem Secret ist bis zum App-Cutover ein Login-Ausfall möglich;
  deshalb pro App ein Wartungsfenster vorsehen.
- Blueprint-Abschnitt in `AGENTS.md` (§ OIDC / Authentik Blueprint Onboarding)
  auf den neuen Ablauf umschreiben: kein manuelles Secret mehr.

### Phase 7 – Vault/OpenBao (eigener Proposal)

- Bevorzugt OpenBao extern auf srv1, unabhängig vom wiederherzustellenden
  Kubernetes-Cluster. Authentik-Anmeldung für Menschen; separater Notfallzugang
  funktioniert auch bei ausgefallenem Authentik. Unseal, Erreichbarkeit und
  unabhängige Backups im eigenen Proposal festlegen; ein einzelner srv1 bleibt
  ein Ausfallpunkt.
- Bestehende Werte per `PushSecret` aus `secret-source` mit
  `selector.secret` bytegenau nach Vault übertragen. `updatePolicy: IfNotExists`
  und `deletionPolicy: None` erhalten bereits vorhandene Zielwerte und lassen
  sie beim Entfernen des PushSecrets bestehen. Vor der Umstellung Werte
  abgleichen, da `IfNotExists` auch abweichende Zielwerte stehen lässt. Dann
  lokale `SecretStore homelab` auf `provider: vault` mit jeweils eingeschränkter
  Vault-Rolle (Kubernetes-Auth, `audiences: [vault]`) umstellen und alte Writer
  deaktivieren.
- `selector.generatorRef` nur für neue Vault-Einträge mit
  `updatePolicy: IfNotExists` und `deletionPolicy: None` verwenden. Der Default
  `Replace` kann bei jedem Refresh einen neu generierten Wert schreiben.
  [PushSecret-API in ESO 2.15](https://github.com/external-secrets/external-secrets/blob/v2.15.0/apis/externalsecrets/v1alpha1/pushsecret_types.go#L57-L111)
- Klasse C von SOPS nach Vault; SOPS bleibt nur für Bootstrap (D).

---

## Forkbarkeit (Folgearbeit, nicht Teil dieses Umbaus)

Dieser Umbau ist der größte Hebel: aus ~80 Secrets werden ~20 extern
benötigte. Danach fehlen für „clone & deploy" noch:

- **Credential-Manifest:** eine Liste aller Klasse-C-Secrets (Name, Keys,
  Woher), z. B. `docs/bring-your-own-credentials.md`, ersetzt die 34
  `*.template`-Dateien.
- **Domain/IPs:** 158 YAML-Dateien enthalten `f4mily.net`; `cluster-config.yaml`
  deckt nur Ingress-Hosts ab. Feste IPs (Mail-VPS-Pin, `192.168.10.x`) ebenso.
  → Flux `postBuild.substituteFrom` mit einer Site-ConfigMap prüfen.
- **Public/Private-Split** existiert schon (`clusters/main/private-gitops.yaml`):
  Ziel wäre, dass das private Repo nur noch Klasse-C-Secrets + Site-Config
  enthält.
- **Optionale Apps:** Fork soll Apps einzeln abwählen können, ohne
  Abhängigkeiten zu brechen.

---

## Risiken

| Risiko | Gegenmaßnahme |
|---|---|
| Quelle und Generator-Status verloren → neuer Wert, A2-Daten unlesbar | immutable + prune disabled + kein ownerReference; geprüfter Restore vor Generator-Aktivierung; A2 zuerst nach Vault |
| Neuer A2-Schlüssel geht vor erstem Backup verloren | Unabhängige verschlüsselte Sicherung und Restore-Prüfung vor erster Datennutzung; Verbraucher bis dahin gesperrt |
| ESO down | Bestehende Secrets bleiben; nur neue/geänderte hängen. Alert auf Ready=False |
| Klartext-Werte jetzt in Velero-Backups | War bei den entschlüsselten Secrets schon so; Velero-Bucket-Zugriff prüfen |
| Store kann fremde Quellwerte lesen | Eigene Identität je Store; `get` + `resourceNames`; positive und negative Integrationstests |
| DR des ganzen Clusters ohne Velero | DB-Passwörter egal (CNPG setzt neu); A2 nur über Vault/Velero wiederherstellbar → Vault-Phase priorisieren |

## Festgelegte Richtung / verbleibende Prüfungen

1. Namespace `secret-source`; Leser über getrennte lokale Stores.
2. Reloader (stakater) mit explizitem Opt-in je App, bevorzugt
   `secret.reloader.stakater.com/auto: "true"`, ohne globales Auto-Reload.
   GitOps-kompatible Annotation-Strategie prüfen. Helm-`valuesFrom` benötigt
   außerdem Flux-Reconciliation; Reloader allein rendert keine Helm-Values neu.
3. OpenBao bevorzugt extern auf srv1; Betrieb und Bootstrap bleiben Phase 7.
4. Phase 0 muss vor Pilot abgeschlossen sein; lokale Kind-Tests ersetzen keine
   Cilium-, Flux-Prune- oder Velero-Restore-Prüfung.
