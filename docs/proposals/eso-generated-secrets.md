# Cluster-generierte Secrets via External Secrets Operator

## Status: Proposal

Clusterinterne Credentials (DB-Passwörter, Session-/JWT-Keys, OIDC-Client-Secrets
zwischen App und Authentik) werden nicht mehr als SOPS-Dateien gepflegt, sondern
einmalig im Cluster von ESO erzeugt und an die Verbraucher verteilt. SOPS bleibt
nur für echte Fremd-Credentials. Der Secret-Store ist hinter einem
`ClusterSecretStore`-Namen abstrahiert, damit später Vault/OpenBao ohne Umbau der
Verbraucher dahinter treten kann.

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
                                    ClusterSecretStore "homelab" (provider: kubernetes,
                                    remoteNamespace: secret-source)   ← später provider: vault
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
   lesen ihn über den `ClusterSecretStore` `homelab` (kubernetes-Provider).
2. **Store-Name als Abstraktion.** Verbraucher kennen nur
   `secretStoreRef: {kind: ClusterSecretStore, name: homelab}` und einen Key.
   Vault-Migration = Werte per `PushSecret` nach Vault schieben, Store-Provider
   umstellen. Verbraucher-Manifeste bleiben unverändert.
3. **Generate-once-Absicherung** für Quell-Secrets:
   `refreshPolicy: CreatedOnce`, `target.creationPolicy: Orphan` bzw.
   `CreateOrMerge` (kein ownerReference → Löschen des ExternalSecrets löscht
   das Secret nicht), `target.immutable: true`, Flux-Annotation
   `kustomize.toolkit.fluxcd.io/prune: disabled`. Restrisiko: wird das
   *Secret* gelöscht, entsteht ein neuer Wert → DR-Pfad bis Vault ist Velero
   (sichert `secret-source` täglich mit).
4. **Zugriffsbegrenzung.** `ClusterSecretStore.spec.conditions` begrenzt auf
   Namespaces mit Label `homelab.f4mily.net/secrets: "true"`. Der
   ServiceAccount des Stores darf nur in `secret-source` Secrets lesen (Role,
   nicht ClusterRole).
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

---

## Phasen

### Phase 0 – Spike (Test-Namespace, kein Prod-Einfluss)

Klären, was die Doku offen lässt (ESO 2.15):

- [ ] `CreatedOnce` + `creationPolicy` + `immutable`: Verhalten bei
      (a) ExternalSecret löschen/neu anlegen, (b) Flux-Prune, (c) Secret
      existiert bereits mit anderem Wert. Ergebnis entscheidet das
      Übernahmeverfahren für Klasse A2.
- [ ] CNPG: ändert sich das Rollenpasswort bei inline `managed.roles` wirklich
      sofort (mit `cnpg.io/reload`)? Test mit Wegwerf-Rolle auf
      `homelab-postgres`.
- [ ] `ClusterSecretStore` kubernetes-Provider mit `serviceAccount`-Auth und
      `conditions` funktioniert (Doku zeigt nur `SecretStore` + Token).
- [ ] Rendert `target.template` neu, wenn sich die Quelle ändert, bei
      `Periodic`-Verbrauchern?
- [ ] Cilium: ESO-Controller braucht Egress zum API-Server; prüfen, ob die
      NetworkPolicies in `secret-source`/ESO-Namespace etwas blocken.

Ergebnis als Learning in `docs/learnings/`, falls etwas der Intuition
widerspricht.

### Phase 1 – ESO-Plattform

- `infrastructure/base/external-secrets/`: HelmRelease
  (`charts.external-secrets.io`, Chart `external-secrets` 2.15.x, Renovate
  trackt), CRDs über Chart (`installCRDs: true`), interner cert-controller.
- Flux-Reihenfolge: `infra-base` (Operator, `wait: true`) →
  neue Kustomization `infra-secrets` (`secret-source`-Namespace,
  `ClusterGenerator password-32`, `ClusterSecretStore homelab`, RBAC,
  Quell-ExternalSecrets) → `infra-main` (CNPG-Cluster) / `apps`.
- PSA `restricted`, NetworkPolicy für ESO-Namespace.
- Monitoring: ESO-Metriken scrapen; Alert auf
  `externalsecret_status_condition{condition="Ready",status="False"}`.
  Ein nicht synchrones Verbraucher-Secret würde sonst erst beim nächsten
  Pod-Neustart auffallen.
- `external-secret.barman-s3.example.yaml` löschen (veraltet, irreführend).
- Doku: `infrastructure/AGENTS.md`, ADR `0005-external-secrets-operator.md`.

### Phase 2 – Pilot: eine DB (`hister` oder `vikunja`)

1. Quell-ExternalSecret `db-hister` in `secret-source` (Generator).
2. `cnpg-system`: ExternalSecret → `hister-db-credentials` (basic-auth,
   reload-Label). SOPS-Datei in `database-clusters/credentials/` entfernen.
3. `hister`: ExternalSecret → `homelab-postgres-hister`. SOPS-Datei + Patch in
   `apps/overlays/main/db-secrets/` entfernen.
4. CNPG setzt neues Passwort, App-Rollout (Reloader oder `kubectl rollout
   restart`). Prüfen: App verbindet, `psql` mit neuem Passwort.

Runbook-Schritt festhalten → Vorlage für alle weiteren.

### Phase 3 – Restliche DB-Rollen (A1)

authentik, paperless, tandoor, linkwarden, teslamate, goloom, forgejo,
sparkyfitness(+`_app`), outline, vikunja, dawarich, immich, ainsel.
Jeweils einzeln, je ein Commit; Restart der App nach Passwortwechsel.

- Prüfen pro App: liest sie das Passwort bei jedem Start aus Env? Wenn nein →
  Klasse A2 behandeln.
- `ainsel-hub-db` enthält `dsn` → per `target.template` erzeugen.
- `immich`/`dawarich` haben eigene Cluster, gleicher Ablauf.
- Am Ende: `apps/overlays/main/db-secrets/` und
  `database-clusters/credentials/` leer → Verzeichnisse + Patches entfernen.

### Phase 4 – Nextcloud + Klasse A2

- Bestandswerte übernehmen statt neu generieren (Verfahren aus Phase 0).
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

- OpenBao (Vault-Provider von ESO, getestet) im Cluster oder extern.
  Offen: wo läuft er, wie wird er entsiegelt (Auto-Unseal) – sonst neue
  Henne-Ei-Abhängigkeit für jeden Cluster-Start.
- `PushSecret` aller Quellen aus `secret-source` nach Vault, dann
  `ClusterSecretStore homelab` auf `provider: vault` (Kubernetes-Auth,
  `audiences: [vault]`) umstellen. Generatoren erzeugen danach nur noch für
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
| Quell-Secret gelöscht → neuer Wert, A2-Daten unlesbar | immutable + prune disabled + kein ownerReference; Velero-Backup; A2 zuerst nach Vault |
| ESO down | Bestehende Secrets bleiben; nur neue/geänderte hängen. Alert auf Ready=False |
| Klartext-Werte jetzt in Velero-Backups | War bei den entschlüsselten Secrets schon so; Velero-Bucket-Zugriff prüfen |
| Store-SA liest alle Quell-Secrets | Role nur in `secret-source`, `conditions` am Store |
| DR des ganzen Clusters ohne Velero | DB-Passwörter egal (CNPG setzt neu); A2 nur über Vault/Velero wiederherstellbar → Vault-Phase priorisieren |

## Offene Fragen

1. Namespace-Name `secret-source` ok, oder lieber `secrets`?
2. Reloader (stakater) einführen, damit Apps bei Secret-Änderung automatisch
   neu starten, oder Restarts bewusst manuell?
3. Vault/OpenBao im Cluster (Henne-Ei bei Cluster-Neuaufbau) oder auf srv1
   außerhalb?
