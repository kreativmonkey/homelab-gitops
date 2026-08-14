# Job-Watchdog (generisch)

## 1. Was ist der Job-Watchdog

Die Offsite-Backup-CronJobs in `backup-offsite` (`immich-offsite-backup`,
`nextcloud-offsite-backup`, `offsite-restore-verify`) hatten kein Alerting. Ein
Job, der scheitert, suspendiert wird, aus Git verschwindet oder nie anläuft,
blieb unbemerkt — bis jemand zufällig `kubectl get cronjob` lief.

Statt für jeden Job eigene Alerts zu schreiben (so wie früher für Authentik,
siehe unten), melden sich CronJobs per Label am generischen Watchdog an. Der
Watchdog liest ausschließlich `kube_cronjob_labels` und die Standard-KSM-Metriken
zu Jobs/CronJobs — er kennt keine App-spezifische Logik.

Alle sieben Alerts liegen in `apps/base/monitoring/rules/job-watchdog-vmrule.yaml`,
Gruppe `homelab.platform.jobs`, im Namespace `monitoring`.

**Routing:** unverändert gegenüber allen anderen Platform-Alerts. `severity` +
`homelab_owner: platform` greifen in die bestehenden Alertmanager-Routen →
ntfy-Topic `monitoring` (über die ntfy-bridge) sowie n8n/Telegram-Triage. Es
gibt keinen neuen Kanal und keine Alertmanager-Änderung, um einen weiteren Job
anzumelden — siehe [monitoring-stack.md](monitoring-stack.md) und
[alerting-n8n-telegram-triage.md](../integrations/alerting-n8n-telegram-triage.md).

## 2. Neuen Job anmelden

Drei Labels an `CronJob.metadata.labels` — **nicht** an `spec.jobTemplate.metadata.labels`,
kube-state-metrics exponiert nur die CronJob-Labels als `kube_cronjob_labels`:

```yaml
metadata:
  labels:
    homelab.f4mily.net/watchdog: "true"          # Pflicht
    homelab.f4mily.net/max-age-hours: "32"        # Pflicht, max. Alter des letzten Erfolgs
    homelab.f4mily.net/max-runtime-hours: "6"     # optional, ab wann ein Lauf als hängend gilt
```

**Dimensionierungsregel:**

```
max-age-hours >= Schedule-Intervall + activeDeadlineSeconds
```

Grund: `kube_cronjob_status_last_successful_time` wird erst am **Ende** eines
Laufs gesetzt, nicht beim Start. Ein täglicher Job mit `activeDeadlineSeconds:
28800` (8h) braucht also mindestens `24h + 8h = 32h` — genau der Wert, den
`immich-offsite-backup` und `nextcloud-offsite-backup` tragen.

`max-runtime-hours` sollte knapp **unter** `activeDeadlineSeconds` liegen, damit
die Warnung kommt, bevor Kubernetes den Job selbst killt.

**Fallstricke:**

- Werte **immer als String quoten** (`"32"`, nicht `32`). Kubernetes-Label-Werte
  sind ohnehin Strings, aber ein unquotiertes YAML-Skalar wird beim Parsen zur
  Zahl und schlägt beim Apply fehl.
- Labelkeys nur **kleingeschrieben** — `label_value()` in den VMRule-Queries
  matcht auf den durch kube-state-metrics erzeugten, bereits kleingeschriebenen
  Metric-Label-Namen (`label_homelab_f4mily_net_max_age_hours`).
- Labels gehören an `CronJob.metadata.labels`, **nicht** ins `jobTemplate`. Ein
  Label im `jobTemplate` landet auf den erzeugten Jobs, aber `kube_cronjob_labels`
  liest nur die Labels des CronJob-Objekts selbst.
- Voraussetzung, die schon erfüllt ist und bei jedem neuen Label-Key erneut
  geprüft werden muss: `metricLabelsAllowlist` für `cronjobs` in
  `apps/base/monitoring/vm-k8s-stack/helmrelease.yaml`. Ohne einen Eintrag dort
  liefert `kube_cronjob_labels` für dieses Label **keine** Serien — der Job wäre
  angemeldet, aber unsichtbar für den Watchdog (siehe `WatchdogBlind`).

Aktuell angemeldet:

| CronJob | max-age-hours | max-runtime-hours |
|---|---|---|
| `backup-offsite/immich-offsite-backup` | 32 | 6 |
| `backup-offsite/nextcloud-offsite-backup` | 32 | 6 |
| `backup-offsite/offsite-restore-verify` | 174 | 5 |
| `authentik/authentik-blueprint-check` | 3 | 1 |

## 3. Die Alerts

Nützliche Basisbefehle für jede Diagnose:

```bash
kubectl -n <ns> get cronjob,job
kubectl -n <ns> logs job/<name> --all-containers --prefix
# Aktueller Regelzustand direkt aus vmalert (zeigt auch Syntaxfehler in Queries):
kubectl -n monitoring exec deploy/vmalert-vm-k8s-stack-victoria-metrics-k8s-stack -c vmalert -- \
  wget -qO- http://127.0.0.1:8080/api/v1/rules
```

### WatchdogBlind — critical, `for: 30m`

**Bedeutung:** Keine einzige überwachte CronJob-Serie ist sichtbar
(`kube_cronjob_labels{label_homelab_f4mily_net_watchdog="true"}` liefert nichts).
Der wichtigste Alert im Set: solange er steht, überwacht der Watchdog **nichts**
— nicht "ein Job ist stale", sondern "die Überwachung selbst ist blind".

**Sofortdiagnose:**

```bash
kubectl -n monitoring get pods -l app.kubernetes.io/name=kube-state-metrics
kubectl -n monitoring exec deploy/vmalert-vm-k8s-stack-victoria-metrics-k8s-stack -c vmalert -- \
  wget -qO- 'http://127.0.0.1:8080/api/v1/rules' | grep -A3 WatchdogBlind
grep -A2 metricLabelsAllowlist apps/base/monitoring/vm-k8s-stack/helmrelease.yaml
```

**Typische Ursachen:**

- kube-state-metrics ist ausgefallen oder wird nicht mehr gescraped.
- Die `metricLabelsAllowlist` für `cronjobs` wurde aus der HelmRelease entfernt
  oder ein Refactor hat den Eintrag verloren.
- Alle angemeldeten CronJobs haben gleichzeitig ihr Watchdog-Label verloren
  (unwahrscheinlich, aber möglich bei einem fehlerhaften Kustomize-Patch).

**Behebung:** kube-state-metrics reparieren bzw. `metricLabelsAllowlist` in
`apps/base/monitoring/vm-k8s-stack/helmrelease.yaml` wiederherstellen und
`flux reconcile helmrelease vm-k8s-stack -n monitoring`. Danach prüfen, dass
`kube_cronjob_labels{label_homelab_f4mily_net_watchdog="true"}` wieder Serien
liefert.

### WatchdogConfigInvalid — warning, `for: 30m`

**Bedeutung:** Ein Job trägt `homelab.f4mily.net/watchdog: "true"`, aber
`max-age-hours` fehlt oder ist keine Zahl (z. B. `"26h"` statt `"26"`).
MetricsQL `label_value()` verwirft solche Serien **still** — ohne diesen Alert
wäre der Job unbemerkt unüberwacht, trotz Opt-in.

**Sofortdiagnose:**

```bash
kubectl -n <ns> get cronjob <name> -o jsonpath='{.metadata.labels}'
```

**Typische Ursachen:**

- Tippfehler im Wert (`"32h"`, `" 32"`, Leerzeichen).
- Label vorhanden, aber leerer String.
- Copy-Paste-Fehler beim Anmelden eines neuen Jobs.

**Behebung:** Label-Wert in Git korrigieren (reine Zahl als String, siehe
Abschnitt 2), committen, Flux reconcilen lassen.

### WatchdogJobFailed — warning, `for: 10m`

**Bedeutung:** Ein Job dieses CronJobs ist fehlgeschlagen
(`kube_job_failed{condition="true"}`).

**Sofortdiagnose:**

```bash
kubectl -n <ns> get cronjob,job
kubectl -n <ns> logs job/<name> --all-containers --prefix
kubectl -n <ns> describe job/<name>
```

**Typische Ursachen:** siehe [offsite-backup-restore.md](offsite-backup-restore.md)
bzw. [nextcloud-cronjob-failed.md](nextcloud-cronjob-failed.md) für die
App-spezifischen Ursachen (NFS/Storage-Box-Timeout, Postgres nicht erreichbar,
Restic-Lock, Maintenance-Mode hängt).

**Behebung:** App-spezifisch nach Log-Analyse. Danach den fehlgeschlagenen Job
löschen oder auf den nächsten erfolgreichen Lauf warten, damit `kube_job_failed`
zurückgeht.

**Wichtig — Alters-Gate:** Der Alert vergleicht das Job-Alter gegen
`max-age-hours` und feuert nur, solange der fehlgeschlagene Job **jünger** als
diese Schwelle ist. Grund: ein fehlgeschlagener Job bleibt bis
`failedJobsHistoryLimit` als Objekt liegen — im Cluster lag `nextcloud-cron-29768115`
so 7,4 Tage lang mit `failed=1` herum. Ohne das Gate hätte `WatchdogJobFailed`
ewig weitergefeuert und nie resolved. Nach Ablauf von `max-age-hours` übernimmt
`WatchdogJobStale` lückenlos, weil beide dieselbe Schwelle verwenden — es gibt
keine Lücke zwischen "Job als fehlgeschlagen markiert" und "Job als stale
markiert".

### WatchdogJobStale — critical, `for: 30m`

**Bedeutung:** Kernalert des Watchdogs. Kein erfolgreicher Lauf innerhalb
`max-age-hours`. Deckt drei Fälle mit einer einzigen Query ab: der Job
scheitert wiederholt, er wird nicht mehr eingeplant (z. B. weil der Scheduler
klemmt oder `startingDeadlineSeconds` reißt), oder er ist **nie** erfolgreich
gelaufen.

**Sofortdiagnose:**

```bash
kubectl -n <ns> get cronjob <name> -o jsonpath='{.status}'
kubectl -n <ns> get job,pod
kubectl -n <ns> logs job/<name> --all-containers --prefix
```

**Typische Ursachen:**

- Wiederholte Fehlschläge (siehe `WatchdogJobFailed` oben).
- CronJob ist suspendiert (siehe `WatchdogCronJobSuspended` — dort wird
  gegenseitiges Doppel-Paging per `unless` bereits ausgeschlossen).
- `startingDeadlineSeconds` wurde verpasst (z. B. API-Server war während des
  geplanten Fensters nicht erreichbar).
- Job wurde neu angelegt und die erste Karenzperiode läuft noch (siehe unten).

**Behebung:** je nach Ursache — App-Logs prüfen, Suspend zurücknehmen,
Scheduler-Historie im `kube-controller-manager` prüfen.

**Fallback auf `kube_cronjob_created`:** `kube_cronjob_status_last_successful_time`
**existiert als Metrik gar nicht**, solange ein CronJob nie erfolgreich war. Ohne
einen Fallback würde "nie gelaufen" fälschlich als "alles gut" gelten — genau
das stille Versagen, das dieser Watchdog verhindern soll. Die Query fällt daher
auf `kube_cronjob_created` zurück. Konsequenz: ein neu erstellter CronJob hat
genau **eine** Karenzperiode von `max-age-hours` ab Erstellung, bevor er als
stale gilt, auch wenn er noch keinen einzigen Lauf hinter sich hat.

**Authentik-Sonderfall:** `authentik/authentik-blueprint-check` ist über diesen
Alert angemeldet und ersetzt die früheren dedizierten Alerts
`AuthentikBlueprintCheckFailed`/`AuthentikBlueprintCheckStale` (siehe Abschnitt
"Abgelöst" unten). Steht `WatchdogJobStale` für diesen CronJob, heißt das: der
Blueprint-Check ist seit über 3 Stunden nicht mehr erfolgreich gelaufen, und der
betroffene Authentik-Provider wird **nicht mehr deklarativ verwaltet**.
Client-Secrets und Redirect-URIs können dann zwischen Blueprint und Live-Zustand
auseinanderlaufen — im Zweifel bricht der OIDC-Login für die betroffene App.
Welcher Provider konkret betroffen ist, steht im Job-Log:

```bash
kubectl -n authentik logs job/<name>
```

### WatchdogCronJobSuspended — critical, `for: 15m`

**Bedeutung:** `spec.suspend: true` auf einem überwachten CronJob — er wird
nicht mehr eingeplant und läuft still ins Nichts, ohne dass ein Job fehlschlägt
oder stale wird (bevor `max-age-hours` erreicht ist).

**Sofortdiagnose:**

```bash
kubectl -n <ns> get cronjob <name> -o jsonpath='{.spec.suspend}'
git log --oneline -- '<pfad-zum-cronjob-manifest>'
```

**Typische Ursachen:**

- Manuelle Notmaßnahme während eines Vorfalls (z. B. während des iSCSI-Ausfalls
  vom 13.06.2026 wurde `nextcloud-cron` so pausiert und die Änderung nie
  zurückgenommen), die nie in Git zurückgenommen wurde.
- `suspend: true` wurde versehentlich gemerged.

**Behebung:** `suspend: false` in Git zurücknehmen, committen, PR mergen — ein
manuelles `kubectl patch` wird beim nächsten Flux-Reconcile ohnehin überschrieben.

### WatchdogJobStuck — warning, `for: 15m`

**Bedeutung:** Ein Job läuft länger als `max-runtime-hours`. Reines Opt-in über
das dritte Label — fehlt es, wird der Job schlicht nicht auf Laufzeit geprüft
(bewusst kein `ConfigInvalid`-Pendant dafür).

**Sofortdiagnose:**

```bash
kubectl -n <ns> get pod -l job-name=<job-name>
kubectl -n <ns> logs job/<name> --all-containers --prefix -f
kubectl -n <ns> describe pod <pod-name>
```

**Typische Ursachen:**

- Hängender NFS-Mount (`192.168.10.94`).
- Blockierte Storage-Box-Verbindung (rclone/restic serve).
- Ein Restic-Lock, der von einem vorherigen abgebrochenen Lauf übrig blieb.

**Behebung:** Ursache am Pod diagnostizieren; im Zweifel den Job laufen lassen,
bis Kubernetes ihn bei `activeDeadlineSeconds` killt (der Wert liegt bewusst
über `max-runtime-hours`, damit die Warnung zuerst kommt). Danach ggf. einen
verwaisten Restic-Lock manuell entfernen. `concurrencyPolicy: Forbid` blockiert
in der Zwischenzeit alle Folgeläufe — das ist gewollt, verlängert aber die
Zeit bis zum nächsten Backup.

### WatchdogCronJobDisappeared — critical, `for: 10m`

**Bedeutung:** Ein überwachter CronJob war vor einer Stunde noch da und ist
jetzt weg — aus Git entfernt, umbenannt oder von Flux geprunt. Der Alert feuert
nur in einem Fenster von `[Löschung + 10m, Löschung + 1h]` und resolved danach
automatisch von selbst (keine dauerhafte Nachwirkung).

**Sofortdiagnose:**

```bash
kubectl -n <ns> get cronjob
git log --oneline --diff-filter=D -- '<vermuteter-pfad>'
flux get kustomization -A
```

**Typische Ursachen:**

- CronJob-Manifest wurde aus Git entfernt (beabsichtigt oder versehentlich).
- CronJob wurde umbenannt — für den Watchdog ist ein neuer Name ein neuer,
  bislang unbekannter Job.
- Flux hat den Ressourcen-Prune durchgeführt, nachdem eine Kustomization das
  Manifest nicht mehr referenziert.

**Behebung:** Falls unbeabsichtigt: Manifest in Git wiederherstellen und Flux
reconcilen. Falls beabsichtigt (bewusstes Entfernen eines Jobs): kein Handlungsbedarf,
der Alert resolved nach spätestens einer Stunde von selbst.

## 4. Selbsttest

Kopierbarer End-to-End-Test, der einen echten CronJob-Fehlschlag, eine
Stale-Erkennung und ein Verschwinden auslöst, ohne einen Produktions-Job zu
berühren:

```bash
kubectl -n backup-offsite create cronjob watchdog-selftest \
  --image=busybox:1.36 --schedule='* * * * *' -- /bin/false
kubectl -n backup-offsite patch cronjob watchdog-selftest --type=json \
  -p '[{"op":"add","path":"/spec/jobTemplate/spec/backoffLimit","value":0}]'
kubectl -n backup-offsite label cronjob watchdog-selftest \
  homelab.f4mily.net/watchdog=true \
  homelab.f4mily.net/max-age-hours=0.05 \
  homelab.f4mily.net/max-runtime-hours=0.05
# Aufraeumen (loest absichtlich WatchdogCronJobDisappeared aus):
kubectl -n backup-offsite delete cronjob watchdog-selftest
```

**Wichtig:** Der CronJob muss den Job **selbst** erzeugen (`schedule: '* * * * *'`
laufen lassen), damit die `ownerReferences` stehen. `kubectl create job
--from=cronjob/...` erzeugt einen Job ohne saubere CronJob-Owner-Referenz und
bricht damit den `kube_job_owner`-Join, den `WatchdogJobFailed` und
`WatchdogJobStuck` benötigen — der Selbsttest würde dann nichts auslösen.

Erwarteter Ablauf: `WatchdogConfigInvalid` bleibt aus (Werte sind gültige
Zahlen), nach dem ersten Lauf feuert `WatchdogJobFailed` (der Job schlägt
mit `/bin/false` fehl), nach ca. 3 Minuten `WatchdogJobStale`
(`max-age-hours=0.05` ≈ 3 Minuten). Nach dem `delete` erscheint irgendwann im
Fenster [+10m, +1h] `WatchdogCronJobDisappeared` und resolved danach von
selbst.

## 5. Bekannte Grenzen

1. **Nur Exitcodes, keine Inhalte.** Der Watchdog prüft, ob ein Job erfolgreich
   war — nicht, ob das erzeugte Backup brauchbar ist. Ein Backup, das
   erfolgreich 0 Bytes sichert, gilt als ok. Dafür existiert
   `offsite-restore-verify`, das den Inhalt tatsächlich zurückliest und prüft —
   siehe [offsite-backup-restore.md](offsite-backup-restore.md). Sein
   Watchdog-Eintrag ist deshalb der wichtigste der drei Backup-Jobs.
2. **Tippfehler = stille Nicht-Überwachung.** `watchdog=ture` oder ein
   fehlendes Label führt zu keinem Alert — der Watchdog erkennt "angemeldet,
   aber halbkonfiguriert" (`WatchdogConfigInvalid`), nicht "nie angemeldet".
   Gegenmittel: PR-Review und der Contract in
   `infrastructure/base/offsite-backup/AGENTS.md`.
3. **`max-age-hours` und `schedule` können auseinanderlaufen.** Es gibt keinen
   automatischen Abgleich, weil `kube_cronjob_info.schedule` ein Cron-String
   ist, kein Intervall. Wer `schedule` oder `activeDeadlineSeconds` ändert, muss
   `max-age-hours` von Hand nachziehen.
4. **`kube_cronjob_created` resettet bei Recreate.** Prune + Neuanlage oder ein
   Rename setzen die Erstellungszeit zurück und maskieren damit bis zu
   `max-age-hours` lang eine echte Staleness, die vor dem Recreate bestand.
5. **Group-by ohne `cronjob`.** Die Root-`group_by` in der Alertmanager-Route
   enthält kein `cronjob`-Label. Drei gleichzeitig stale Backups ergeben deshalb
   eine ntfy-Nachricht mit drei Zeilen statt drei Nachrichten — das ist gewollt.
6. **Keine CI-Prüfung der Queries.** Es gibt keinen VMRule-Admission-Webhook und
   keine Expression-Validierung in der CI-Pipeline. Eine kaputte Query landet
   still im Cluster. Nach jeder Änderung an diesem VMRule die vmalert-Rules-API
   prüfen (Befehl siehe oben, Abschnitt 3).

## Abgelöst

`apps/base/monitoring/rules/authentik-vmrule.yaml` wurde gelöscht.
`AuthentikBlueprintCheckFailed` und `AuthentikBlueprintCheckStale` sind im
generischen Watchdog aufgegangen (`WatchdogJobFailed`/`WatchdogJobStale` für
`authentik/authentik-blueprint-check`) — siehe Authentik-Sonderfall im
`WatchdogJobStale`-Abschnitt oben.
