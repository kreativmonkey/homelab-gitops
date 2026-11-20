# ESO: gemeinsame Quellen, getrennte Leser und sichere Übernahme

Stand: 2026-11-20. Runtime-Spike mit ESO 2.15.0, CNPG 1.30.1 (Chart 0.29.1)
und Kubernetes 1.36.4 in einem lokalen Kind-Cluster. Ausschließlich synthetische
Credentials; Produktions-Manifeste und Produktionscluster unverändert.
Abschlusslauf: 41 Prüfungen erfolgreich, Passwortwechsel nach 2,5 Sekunden
beobachtet; Wegwerf-Cluster anschließend entfernt. Zeitwert ist Messung dieses
Laufs, keine garantierte Reconciliation-Frist.

## What went wrong

Der erste Entwurf setzte auf einen gemeinsamen `ClusterSecretStore` mit
Namespace-Filter als Zugriffsgrenze. Außerdem wurden `Orphan` und `CreateOrMerge`
als gleichwertige Absicherung für einmalig generierte Werte behandelt.
`CreatedOnce` und `immutable` wirkten zusammen wie eine vollständige
Lebenszyklus-Absicherung, einschließlich der Übernahme von Template-Metadaten.

## Why it failed

- Ein gemeinsamer Store verwendet dieselbe Identität für alle zugelassenen
  Namespaces. Wer dort ein ExternalSecret schreiben darf, kann alle Quellen
  abrufen, die diese Identität lesen darf. Namespace-Filter sind keine
  Secret-Allowlist.
- Generatoren speichern keine Werte. Zwei Quellen mit demselben Generator
  liefern unterschiedliche Passwörter. Nach Verlust von Quell-Secret und
  ExternalSecret-Status entsteht ebenfalls ein neuer Wert.
- `CreatedOnce` + `Orphan`: Nach Löschen nur des Quell-Secrets blieb es im
  beobachteten Zehn-Sekunden-Fenster trotz Refresh-Anforderung verschwunden.
  Das ExternalSecret meldete weiterhin Ready. `CreateOrMerge` erzeugte nach
  derselben Löschung einen neuen Wert. Diese Policies sind nicht austauschbar.
- Bei vorhandenem Secret mit `target.immutable: true` behielt ESO den bisherigen
  Wert und setzte `immutable`, übernahm aber die Template-Prune-Annotation
  nicht. Prune-Schutz nur im ExternalSecret-Template reicht bei Import nicht.
- ESO meldet Provider-Fehler in Ready-Condition und Events generisch. Ein
  beliebiges `SecretSyncedError` beweist keinen RBAC-Denial; auch ein
  Verbindungs- oder Authentifizierungsfehler könnte ihn auslösen.

## The correct approach

- Genau eine Quelle je Credential in `secret-source`, beliebig viele
  ausdrücklich berechtigte Leser. App und CNPG lesen dieselbe DB-Quelle;
  App und Authentik dieselbe OIDC-Quelle.
- Pro Verbraucher-Namespace ein lokaler `SecretStore homelab`, eigene
  Store-ServiceAccount und eine Role in `secret-source`: nur `get` auf
  explizite `resourceNames`. Kein pauschales `list/watch`, kein `find`.
  App-ServiceAccounts bekommen keine Quellrechte.
- `rbac.serviceAccountTokenCreate: false` im ESO-Chart. ESO bekommt TokenRequest
  nur für die expliziten Store-ServiceAccounts über namespaced Roles.
  Store-Validierung funktionierte im Spike mit `get` + `resourceNames`;
  `SelfSubjectRulesReview` war über `system:basic-user` bereits erlaubt.
- Bei A2 zuerst unveränderten Wert unabhängig und verschlüsselt sichern.
  Quell-Secret mit direkter Prune-Annotation anlegen und Wert prüfen; erst
  danach Generator-ExternalSecret aktivieren. Übernahme und ExternalSecret-
  Neuanlage behielten im Spike den existierenden Wert.
- SOPS→ESO-Übergabe: zuerst Live-Ziele vor Prune schützen, anschließend alte
  Writer ausbinden und deren Reconciliation bestätigen, dann ESO aktivieren.
  Gleiche Quellwerte und tatsächliche App-/DB-Nutzung prüfen.
- CNPG mit `kubernetes.io/basic-auth`, passendem `username`, `password` und
  `cnpg.io/reload: "true"`: inline `managed.roles` übernahm das neue Passwort.
  Frischer TCP-Login mit neuem Passwort funktionierte; altes Passwort wurde
  explizit abgewiesen. Reconciliation ist asynchron, kein atomarer Wechsel
  zusammen mit App-Restarts.

## Prevention

- Wiederholen: `nix develop -c just eso-spike`. Rootless Podman:
  `KIND_EXPERIMENTAL_PROVIDER=podman systemd-run --user --scope -p Delegate=yes nix develop -c just eso-spike`.
  Skript erstellt und entfernt eigenen Cluster mit eigenem Kubeconfig.
- Negative ESO-Reads müssen konkrete API-Fehler für richtige Store-SA,
  Quellnamespace und `get`/`list` belegen; danach erlaubten Read erneut prüfen.
- Restore-Reihenfolge: Generatoren deaktiviert lassen, Quellwerte aus Backup
  wiederherstellen und prüfen, danach Generatoren und Verbraucher aktivieren.
  Zusätzlich zu Ready-Metriken fehlende Quell-Secrets überwachen.
- Neue A2-Schlüssel vor erster Datennutzung unabhängig verschlüsselt sichern
  und Restore prüfen. Der tägliche Velero-Zeitplan schützt das Zeitfenster vor
  dem ersten Backup nicht; Quellen und Verbraucher deshalb getrennt freigeben.
- Schlüssel nach tatsächlicher Nutzung und gepinnter App-Validierung
  klassifizieren: Outline `SECRET_KEY` ist A2 und verlangt 64 Hexzeichen;
  `UTILS_SECRET` ist ein nichtleeres Cron-Token. Der Spike prüft den eigenen
  `outline-key-64-hex`-Generator; Bestandswerte bleiben unverändert.
- Ergänzende Phase-0-Läufe bestätigten Flux-Prune an zwei Revisionen im
  Wegwerf-Cluster, Velero-Restore eines einzelnen synthetischen Secrets und
  Cilium-API-Egress im Homelab. Nachweise im Proposal. Für echte A2-Daten gilt
  der separate Offsite-Restore vor Erstnutzung.
- Reloader-Rollouts und der vollständige Authentik-Login bleiben Schritte der
  späteren App-Migration.

Referenzen: [Proposal](../proposals/eso-generated-secrets.md),
[ESO Lifecycle](https://external-secrets.io/latest/guides/ownership-deletion-policy/),
[ESO Multi Tenancy](https://external-secrets.io/latest/guides/multi-tenancy/),
[ESO Security](https://external-secrets.io/latest/guides/security-best-practices/),
[CNPG Rollen](https://cloudnative-pg.io/docs/1.30/declarative_role_management/).
