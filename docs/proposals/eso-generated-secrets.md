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
- ESO ist **nicht** installiert (nur `external-secret.barman-s3.example.yaml`
  mit veralteter `v1beta1`-API). Reflector ist installiert, wird aber nur für
  TLS-Secrets genutzt.
- Velero sichert täglich/wöchentlich alle Namespaces inkl. Secrets.

## Klassifizierung

| Klasse | Inhalt | Ziel |
|---|---|---|
| **A1 – generierbar, Wechsel harmlos** | DB-Rollenpasswörter (App liest aus Env), JWT-/Session-Secrets, HMAC zwischen zwei Cluster-Komponenten, Valkey/Redis/Mongo-Passwörter, interne Tokens | ESO-Generator |
| **A2 – generierbar, an Daten gebunden** | Schlüssel, mit denen persistente Daten verschlüsselt sind: `n8n-encryption-key`, `teslamate ENCRYPTION_KEY`, `goloom ENCRYPTION_KEY`, `SPARKY_FITNESS_API_ENCRYPTION_KEY`, `authentik secret-key`; Nextcloud-DB-Passwort (steht in `config.php` auf dem PVC) | ESO-Generator **nur bei Neuinstallation**; Bestand übernimmt den heutigen Wert; nie automatisch neu erzeugen |
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

**Bestands-RBAC vor dem Pilot prüfen.** RBAC ist additiv; neue Allowlist-Roles
entziehen keine vorhandenen Rechte. Repo-Befunde, noch nicht live verifiziert:

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

Diese Rechte nicht im ESO-Spike verändern. Vor Phase 2 effektive Berechtigungen
und explizite Ausnahmen dokumentieren; neue Stores allein lösen sie nicht.

Referenzen: [ESO Multi Tenancy](https://external-secrets.io/latest/guides/multi-tenancy/),
[ESO Security](https://external-secrets.io/latest/guides/security-best-practices/),
[Kubernetes RBAC](https://kubernetes.io/docs/reference/access-authn-authz/rbac/).

---

## Phasen

### Phase 0 – Spike (lokaler Wegwerf-Cluster, kein Prod-Einfluss)

Reproduzierbar mit `nix develop -c just eso-spike`: eigener Kind-Cluster,
isoliertes Kubeconfig, synthetische Werte, automatisches Aufräumen. Keine
Produktions-Credentials, keine Tests auf `homelab-postgres`. ESO 2.15.0 und
CNPG 1.30.1 (Chart 0.29.1, wie im Repo) gezielt pinnen.

Runtime-Ergebnis 2026-11-20: **40 Prüfungen erfolgreich** auf Kubernetes
1.36.4. Gemeinsame DB-/OIDC-Quellen, konkrete RBAC-Denials, Bestandsübernahme,
Löschverhalten und Template-Refresh bestätigt. CNPG akzeptierte das neue
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
- [ ] Flux-Prune mit echten Flux-Controllern testen; Annotation allein ist
      noch kein Runtime-Nachweis.
- [ ] Velero-Restore der Quellen bei deaktivierten Generatoren durchführen,
      anschließend unveränderte Werte und Leser prüfen.
- [ ] Cilium (separat im Cluster vor Phase 2): ESO-Controller braucht Egress zum API-Server; prüfen, ob die
      NetworkPolicies in `secret-source`/ESO-Namespace etwas blocken.
- [ ] Effektive Bestands-RBAC prüfen; insbesondere AppAPI-HaRP, NetBird-Proxy
      und MCP-Workload-Patchrechte einschränken oder explizit als privilegierte
      Vertrauensinstanzen freigeben.

Ergebnisse und Grenzen: [ESO-Lifecycle-Learning](../learnings/eso-generated-secrets-lifecycle.md).
Insbesondere kann ein Orphan-ExternalSecret trotz fehlender Quelle Ready melden.
Phase 0 bleibt wegen Flux-Prune, Velero und Cilium offen; keine Pilot-Freigabe.

### Phase 1 – ESO-Plattform

- `infrastructure/base/external-secrets/`: HelmRelease
  (`charts.external-secrets.io`, Chart `external-secrets` 2.15.x, Renovate
  trackt), CRDs über Chart (`installCRDs: true`), interner cert-controller.
  `rbac.serviceAccountTokenCreate: false`; nur explizite Token-Delegation.
- Flux-Reihenfolge: `infra-base` (Operator, `wait: true`) →
  neue Kustomization `infra-secrets` (`secret-source`-Namespace,
  `ClusterGenerator password-32`, Quell-RBAC, Quell-ExternalSecrets) →
  Verbraucher-Namespaces + lokale Stores/Token-Delegation →
  `infra-main` (CNPG-Cluster) / `apps`. Namespace/Store-Erzeugung darf nicht
  vom erfolgreichen Start ihrer DB-abhängigen Apps abhängen.
- PSA `restricted`, NetworkPolicy für ESO-Namespace.
- Monitoring: ESO-Metriken scrapen; Alert auf
  `externalsecret_status_condition{condition="Ready",status="False"}`.
  Ein nicht synchrones Verbraucher-Secret würde sonst erst beim nächsten
  Pod-Neustart auffallen. Zusätzlich Controller-Verfügbarkeit und fehlende
  Quell-Secrets gegen die deklarierte Quellenliste überwachen; Ready allein
  reicht bei `CreatedOnce` nicht als Existenznachweis.
- `external-secret.barman-s3.example.yaml` löschen (veraltet, irreführend).
- Doku: `infrastructure/AGENTS.md`, ADR `0005-external-secrets-operator.md`.

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

### Phase 2 – Pilot: eine DB (`hister` oder `vikunja`)

1. Quell-ExternalSecret `db-hister` in `secret-source` (Generator).
2. `cnpg-system`: ExternalSecret → `hister-db-credentials` (basic-auth,
   reload-Label). SOPS-Datei in `database-clusters/credentials/` entfernen.
3. `hister`: ExternalSecret → `homelab-postgres-hister`. SOPS-Datei + Patch in
   `apps/overlays/main/db-secrets/` entfernen.
4. CNPG setzt neues Passwort, App-Rollout über Reloader-Opt-in. Beide
   Verbraucher synchronisieren unabhängig: Reloader garantiert keine Reihenfolge
   zwischen Passwortänderung in PostgreSQL und App-Neustart. Kurzen
   Verbindungsabbruch einplanen und frische Logins prüfen.

Runbook-Schritt festhalten → Vorlage für alle weiteren.

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

- Bestandswerte übernehmen statt neu generieren (Verfahren aus Phase 0).
  Prune-Schutz direkt am vorhandenen Quell-Secret setzen, bevor ESO es als
  immutable übernimmt; Template-Metadaten werden bei dieser Übernahme nicht
  nachgetragen.
  Fallback, falls ESO kein sauberes „adopt" kann: A2-Quellen bleiben bis zur
  Vault-Phase als SOPS-Secret *in `secret-source`* (eine Datei statt mehrerer),
  Verbraucher lesen trotzdem schon über den Store → Vault-Umzug später ohne
  Verbraucheränderung.
- Nextcloud-DB-Passwort: nur mit Wartungsfenster, `config.php`
  (`dbpassword`) synchron anpassen.

### Phase 5 – Weitere A1-Secrets

searxng, dawarich `SECRET_KEY_BASE`, tandoor/paperless `SECRET_KEY`,
outline `secret-key`/`utils-secret` + `outline-valkey` (Klartext!),
vikunja `jwt-secret`, linkwarden `NEXTAUTH_SECRET`/`MEILI_MASTER_KEY`,
nextcloud-collab, remediation-api `hmac-secret`, ainsel
`internal-validate-secret`, spectrumknx, unifi Mongo, sparkyfitness
`BETTER_AUTH_SECRET`, Grafana-/pgadmin-/Nextcloud-Admin (Passwort per
`kubectl get secret` abrufbar). Folge: Nutzer werden einmal ausgeloggt.

### Phase 6 – OIDC-Paare (B)

- Quelle `oidc-<app>` in `secret-source`.
- Authentik: pro App ein ExternalSecret → `authentik-oidc-client-secrets-<app>`
  (gleicher Name wie heute, `envFrom` am Worker bleibt). Entsprechende Dateien
  im privaten Repo entfernen.
- App-Seite: ExternalSecret → `<app>-authentik-oauth`; für
  `SOCIALACCOUNT_PROVIDERS` (JSON) per `target.template`.
- Blueprint-Abschnitt in `AGENTS.md` (§ OIDC / Authentik Blueprint Onboarding)
  auf den neuen Ablauf umschreiben: kein manuelles Secret mehr.

### Phase 7 – Vault/OpenBao (eigener Proposal)

- Bevorzugt OpenBao extern auf srv1, unabhängig vom wiederherzustellenden
  Kubernetes-Cluster. Authentik-Anmeldung für Menschen; separater Notfallzugang
  funktioniert auch bei ausgefallenem Authentik. Unseal, Erreichbarkeit und
  unabhängige Backups im eigenen Proposal festlegen; ein einzelner srv1 bleibt
  ein Ausfallpunkt.
- `PushSecret` aller Quellen aus `secret-source` nach Vault, dann
  lokale `SecretStore homelab` auf `provider: vault` mit jeweils eingeschränkter
  Vault-Rolle (Kubernetes-Auth, `audiences: [vault]`) umstellen. Erst nach
  verifiziertem Transfer alle Leser umstellen und alte Writer deaktivieren.
  Generatoren erzeugen danach nur noch für
  neue Einträge (`PushSecret` mit `selector.generatorRef`).
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
