# Flux-Reconcile-Alerts

## 1. Warum es diese Alerts gibt

Am 14.08.2026 hat PR #661 die PVC `backup-offsite/nextcloud-offsite-staging`
(250Gi, StorageClass `truenas-iscsi`) eingeführt. TrueNAS lehnte die
Provisionierung ab (`It is not recommended to use more than 80% of your
available space for VOLUME`), die PVC blieb `Pending`. Der Health-Check der
Kustomization `infra-base` wartet auf genau diese PVC und lief dadurch alle
fünf Minuten erneut in den Timeout:

```
health check failed: timeout waiting for: [PersistentVolumeClaim/backup-offsite/nextcloud-offsite-staging status: 'InProgress']
```

`infra-base` blieb dauerhaft auf `Ready=Unknown` stehen. Weil `infra-main`,
`apps` und `apps-monitoring-rules` per `dependsOn` an `infra-base` hängen,
standen die drei auf `Ready=False` mit `dependency ... is not ready`.
Ergebnis: Flux hat fünf Stunden lang nichts mehr aus Git ausgerollt — ohne
jede Meldung. Aufgefallen ist es nur, weil zufällig jemand auf ein
ausbleibendes Deployment wartete.

Der Fall ist derselbe wie beim Job-Watchdog (siehe
[job-watchdog.md](job-watchdog.md)): Ausbleiben von Erfolg ist ein Signal,
nicht nur ein expliziter Fehler. Bis zu diesem Vorfall gab es für die
GitOps-Pipeline selbst kein Alerting — ein Kustomization- oder
HelmRelease-Objekt konnte beliebig lange `False` oder `Unknown` stehen, ohne
dass irgendwer benachrichtigt wurde.

Alle vier Alerts liegen in `apps/base/monitoring/rules/flux-vmrule.yaml`,
Gruppe `homelab.platform.flux`, im Namespace `monitoring`.

## 2. `gotk_*` ist tot — nicht wieder einbauen

Die erste Fassung dieser Alerts (14.08.2026) basierte auf
`gotk_reconcile_condition` und `gotk_suspend_status`, angeblich geliefert vom
`VMPodScrape flux-vmpodscrape.yaml`. Das war falsch: **diese Metriken
existieren in Flux 2.9 (hier: v2.9.4) nicht mehr.** Die Flux-Controller
exportieren auf ihrem Metrics-Port (`http-prom`, 8080) ausschließlich
`controller_runtime_*`, `certwatcher_*` und `go_*`. Der Scrape war korrekt
konfiguriert, die Targets standen auf `up`, andere Metriken kamen an — die
Serie gab es einfach nicht (mehr). Ergebnis: alle vier Regeln liefen seit
Einführung ins Leere, ohne dass der VM-Operator das ablehnte (eine Regel auf
einer nicht existierenden Metrik ist kein Config-Fehler, nur dauerhaft
`absent()`).

**Fix (15.08.2026):** Die Serien kommen jetzt aus **kube-state-metrics Custom
Resource State (CRS)** — kube-state-metrics liest die Flux-Custom-Resources
direkt über die Kubernetes-API (list/watch), nicht über den Metrics-Port der
Controller. Konfiguriert in
`apps/base/monitoring/vm-k8s-stack/helmrelease.yaml`, Block
`kube-state-metrics.customResourceState` (+ `kube-state-metrics.rbac.extraRules`
für die nötigen Leserechte auf die Flux-API-Gruppen). Abgedeckte Kinds:
`Kustomization`, `HelmRelease`, `GitRepository`, `OCIRepository`,
`HelmRepository`, `HelmChart`.

Neue Metriken:

- **`flux_resource_ready{namespace, name, kind, type, status}`** — Info-Metrik
  (Wert immer `1`), eine Serie je Eintrag in `.status.conditions[]` des
  Flux-Objekts. `status` ist bewusst ein **Label** und nicht der Metrikwert:
  ein klassisches Gauge mit `valueFrom: [status]` würde laut
  KSM-Typkonvertierung sowohl `"False"` als auch `"Unknown"` auf `0.0`
  abbilden (alles außer `"true"`/`"yes"` wird `0.0`) — genau die
  Unterscheidung, die am 14.08. den Unterschied zwischen Ursache
  (`Ready=Unknown`) und Folgefehlern (`Ready=False`) ausmachte, ginge damit
  verloren.
- **`flux_resource_suspended{namespace, name, kind}`** — Gauge (`0`/`1`) aus
  `.spec.suspend`.

"Ready ist False" heißt in MetricsQL jetzt
`flux_resource_ready{type="Ready", status="False"}` — das reine Vorhandensein
dieser Label-Kombination ist bereits das Signal, ein zusätzliches `== 1` ist
bei dieser Info-Metrik nicht nötig (anders als früher bei einem klassischen
Gauge). Bei `flux_resource_suspended` bleibt `== 1` weiterhin die richtige
Prüfung.

**Diese Metriken kommen automatisch über die Default-`VMServiceScrape` von
kube-state-metrics selbst rein** (chart-eigener `vmScrape`-Wert, bereits mit
`honorLabels: true`) — es gibt dafür keinen eigenen Scrape. Der
`VMPodScrape flux-vmpodscrape.yaml` bleibt trotzdem bestehen, liefert aber nur
noch `controller_runtime_*`/`certwatcher_*`/`go_*` (Controller-Performance,
kein Ersatz für CRS) — siehe Kommentar in der Datei.

**Beleg, dass die Values-Pfade stimmen:** `nix develop -c just validate` im
`helm-render`-Schritt prüfen — dort muss sowohl der
`customResourceState.config`-Block (als ConfigMap-Inhalt) als auch die
`rbac.extraRules`-Regeln im gerenderten kube-state-metrics-`ClusterRole`
auftauchen. Ohne die RBAC-Regeln liefert CRS still keine Daten — kein Fehler,
einfach leere Metriken.

**Routing:** unverändert gegenüber allen anderen Platform-Alerts. `severity`
+ `homelab_owner: platform` greifen in die bestehenden Alertmanager-Routen →
ntfy-Topic `monitoring` sowie n8n/Telegram-Triage. Es gibt keinen eigenen
Receiver für Flux — siehe [monitoring-stack.md](monitoring-stack.md).

## 3. Nützliche Basisbefehle für jede Diagnose

```bash
flux get all -A --status-selector ready=false
kubectl -n flux-system get kustomization
kubectl -n flux-system get kustomization <name> -o jsonpath='{.status.conditions}'
kubectl -n flux-system logs deploy/kustomize-controller | grep -i "health check"
kubectl -n flux-system logs deploy/helm-controller --tail=100
flux reconcile source git flux-system
flux reconcile kustomization <name> --timeout=5m
flux resume kustomization <name>

# Direkt an den neuen Metriken prüfen (kube-state-metrics CRS statt gotk_*):
kubectl -n monitoring exec deploy/vm-k8s-stack-kube-state-metrics -- \
  wget -qO- http://127.0.0.1:8080/metrics | grep ^flux_resource_
```

**Wichtig:** Der Kustomization-Status selbst zeigt bei einem hängenden
Health-Check meist nur `"Reconciliation in progress"` — die eigentliche
Ursache (welche Ressource, welcher Timeout) steht fast nie im Status, sondern
nur im Log des `kustomize-controller`. Der `grep -i "health check"` oben ist
deshalb der entscheidende Schritt, nicht ein Nice-to-have.

## 4. Die Alerts

### FluxControllerDown — critical, `for: 15m`

**Bedeutung:** `absent(flux_resource_ready)` — es existiert keine einzige
CRS-Serie mehr. Entweder liefert kube-state-metrics keine
Custom-Resource-State-Daten mehr (Pod down, RBAC entzogen), oder der Block
`kube-state-metrics.customResourceState` wurde aus der HelmRelease
`vm-k8s-stack` entfernt. Solange dieser Alert steht, ist unbekannt, ob Git
überhaupt noch ausgerollt wird — er ist der wichtigste Alert im Set, analog
zu `WatchdogBlind` beim Job-Watchdog.

**Sofortdiagnose:**

```bash
kubectl -n monitoring get pods -l app.kubernetes.io/name=kube-state-metrics
kubectl -n monitoring exec deploy/vm-k8s-stack-kube-state-metrics -- \
  wget -qO- http://127.0.0.1:8080/metrics | grep ^flux_resource_
kubectl -n monitoring logs deploy/vm-k8s-stack-kube-state-metrics | grep -i "customresourcestate\|forbidden"
```

**Typische Ursachen:**

- kube-state-metrics-Pod ist gecrasht oder das Deployment ist auf 0 skaliert.
- Der Block `kube-state-metrics.customResourceState` wurde aus
  `apps/base/monitoring/vm-k8s-stack/helmrelease.yaml` entfernt oder die
  `rbac.extraRules` fehlen — dann läuft kube-state-metrics zwar, aber CRS
  liefert still keine Daten (kein Fehler im Log, einfach leere Serien).
- Die Flux-CRDs wurden umbenannt/migriert (API-Group/Version-Wechsel) und die
  `groupVersionKind`-Einträge in `customResourceState.config` stimmen nicht
  mehr.

**Behebung:** kube-state-metrics-Pod reparieren (Logs prüfen, ggf. Deployment
neu starten) bzw. `customResourceState`/`rbac.extraRules` in Git
wiederherstellen und Flux reconcilen lassen. Danach prüfen, dass
`flux_resource_ready` wieder Serien liefert.

### FluxReconcileFailing — critical, `for: 15m`

**Bedeutung:** `flux_resource_ready{type="Ready", status="False"}`,
suspendierte Objekte ausgenommen. Der häufigere Fall: ein fehlgeschlagener
Apply, ein kaputtes Manifest, oder — wie am 14.08. bei `infra-main`, `apps`
und `apps-monitoring-rules` — `dependency ... is not ready`, weil ein
vorgelagertes Objekt hängt.

**Sofortdiagnose:**

```bash
flux get all -A --status-selector ready=false
kubectl -n flux-system get kustomization <name> -o jsonpath='{.status.conditions}'
```

**Typische Ursachen:**

- Ein Manifest ist syntaktisch oder semantisch ungültig (Apply schlägt fehl).
- Eine HelmRelease-Installation/-Upgrade ist fehlgeschlagen (siehe
  `helm-controller`-Logs).
- Die Ursache ist gar nicht in diesem Objekt, sondern in einer
  vorgelagerten Abhängigkeit, die auf `Ready=Unknown` oder `Ready=False`
  steht — siehe Abschnitt "Ursache vs. Folge" unten.

**Behebung:** Fehlermeldung aus den Kustomization-Conditions bzw. den
Controller-Logs lesen, Manifest in Git korrigieren, `flux reconcile
kustomization <name> --timeout=5m`. Steht die Ursache bei einer
Abhängigkeit, dort zuerst reparieren — dieses Objekt löst sich dann meist
von selbst.

### FluxReconcileStalled — critical, `for: 30m`

**Bedeutung:** `flux_resource_ready{type="Ready", status="Unknown"}`,
suspendierte Objekte ausgenommen — ein Reconcile, das nie endet. Genau
so sah `infra-base` am 14.08. aus: der Health-Check auf die
`nextcloud-offsite-staging`-PVC lief alle fünf Minuten erneut in den
Timeout und blieb dauerhaft `Unknown`. 30 Minuten `for`, damit langsame
Helm-Installationen (die während der Installation ebenfalls kurz `Unknown`
stehen) nicht anschlagen.

**Sofortdiagnose:**

```bash
kubectl -n flux-system get kustomization
kubectl -n flux-system logs deploy/kustomize-controller | grep -i "health check"
```

**Typische Ursachen:**

- Ein Health-Check wartet auf eine Ressource, die nie in den erwarteten
  Zustand kommt — am 14.08. eine `Pending` gebliebene PVC, weil TrueNAS die
  Provisionierung ablehnte (`>80% VOLUME`-Grenze).
- Ein Helm-Chart-Install/-Upgrade hängt (siehe `helm-controller`-Logs), z. B.
  weil ein Pod nicht `Ready` wird.
- Eine referenzierte Ressource (Secret, ConfigMap) fehlt und der Health-Check
  wartet auf etwas, das nie erscheint.

**Behebung:** Ursache über die Controller-Logs finden (**nicht** über den
Kustomization-Status — der zeigt nur "Reconciliation in progress"), die
blockierende Ressource reparieren (z. B. PVC-Anforderung anpassen, Storage
freimachen), danach `flux reconcile kustomization <name> --timeout=5m`.

**Bekannte Nachbar-Falle (HelmRelease `RetriesExceeded`):** Eine
HelmRelease, die ihre Retries erschöpft hat, geht in den terminalen Zustand
`RetriesExceeded` und **erholt sich nicht von selbst** — sie braucht einen
manuellen `flux reconcile helmrelease <name> -n <ns>` bzw. `flux resume`,
sonst bleibt sie dauerhaft gestallt, auch nachdem die eigentliche Ursache
behoben wurde. Siehe die Erfahrung dazu in
[monitoring-stack.md](monitoring-stack.md) (`vm-k8s-stack`-Reconcile nach
Konfigänderungen).

### FluxSuspended — warning, `for: 1h`

**Bedeutung:** `flux_resource_suspended == 1` — ein Objekt ist suspendiert. Das
GitOps-Pendant zum suspendierten CronJob im Job-Watchdog: Git und Cluster
laufen still auseinander, ohne dass irgendwo ein Fehler steht. Meist eine
Notmaßnahme aus einem Vorfall, die niemand zurückgenommen hat — genau das
Muster, das `nextcloud-cron` während des iSCSI-Ausfalls vom 13.06.2026
hinterlassen hat (siehe [job-watchdog.md](job-watchdog.md)).

**Sofortdiagnose:**

```bash
kubectl -n flux-system get kustomization,helmrelease,gitrepository,ocirepository -A \
  -o jsonpath='{range .items[?(@.spec.suspend==true)]}{.kind}{"/"}{.metadata.name}{" -n "}{.metadata.namespace}{"\n"}{end}'
git log --oneline -- '<pfad-zum-manifest>'
```

**Typische Ursachen:**

- Manuelle Notmaßnahme während eines Vorfalls (`flux suspend ...`), nie in
  Git zurückgenommen.
- `spec.suspend: true` wurde versehentlich gemerged.

**Behebung:** In Git `suspend: false` setzen (bzw. das Feld entfernen),
committen, Flux reconcilen lassen — ein manuelles `flux resume` wird beim
nächsten Reconcile aus Git ohnehin wieder überschrieben, wenn der
`suspend`-Wert in Git nicht ebenfalls korrigiert wird.

## 5. Ursache vs. Folge: Unknown vs. False

Der 14.08.2026-Vorfall zeigte sich als **eine** hängende Kustomization
(`Ready=Unknown`) und **drei** fehlgeschlagene Folge-Kustomizations
(`Ready=False`). Die `dependsOn`-Kette:

```
infra-sources → infra-storage → infra-base → infra-main → apps → apps-monitoring-rules
```

`infra-base` hing am Health-Check der PVC und blieb `Ready=Unknown`.
`infra-main`, `apps` und `apps-monitoring-rules` hängen (direkt oder über
die Kette) an `infra-base` per `dependsOn` und standen deshalb auf
`Ready=False` mit `dependency ... is not ready` — sie selbst hatten keinen
eigenen Fehler.

**Die Regel für den Doppelschlag:** Wenn `FluxReconcileStalled` und
`FluxReconcileFailing` gleichzeitig feuern, ist **das Unknown-Objekt die
Ursache, die False-Objekte sind die Folge**. Zuerst das `Unknown`-Objekt
reparieren (Health-Check-Blocker beheben), dann top-down entlang der
`dependsOn`-Kette reconcilen — die nachgelagerten `False`-Objekte lösen sich
danach in aller Regel selbst, ohne eigenen Eingriff.

Ein Alert, der nur auf `status="False"` feuert, hätte am 14.08. ausschließlich
die drei Folgefehler gemeldet und den Blick auf die Symptome gelenkt — die
eigentliche Ursache (`infra-base` im Health-Check-Timeout) wäre unsichtbar
geblieben, solange niemand auch in den `Unknown`-Zustand geschaut hätte.
Deshalb gibt es `FluxReconcileFailing` und `FluxReconcileStalled` als zwei
getrennte Regeln statt einer gemeinsamen `!= "True"`-Regel.

## 6. Bekannte Grenzen

1. **Kein eigener ntfy-Receiver.** Die vier Alerts nutzen ausschließlich die
   bestehende Routing-Logik über `severity` + `homelab_owner: platform`. Das
   ist bewusst so — es gibt keinen Grund, für Flux eine eigene Route zu
   pflegen, solange die Platform-Route greift.
2. **`for: 30m` bei `FluxReconcileStalled` heißt bis zu 30 Minuten Blindheit
   nach einem echten Hang.** Der Wert ist bewusst höher als bei
   `FluxReconcileFailing`, um langsame Helm-Installationen nicht
   fälschlicherweise als Stall zu melden — ein sehr kurzer echter Hang bleibt
   in diesem Fenster unbemerkt.
3. **Kein CI-Check der Alert-Queries.** Wie beim Job-Watchdog validiert die
   CI-Pipeline kein MetricsQL. Nach jeder Änderung **zuerst** prüfen, ob der
   VM-Operator die Regel akzeptiert hat — schlägt eine einzige Annotation fehl,
   wird die komplette VMRule abgelehnt und keine ihrer vier Regeln ist aktiv
   (am 15.08.2026 genau so passiert, ein `{{ $labels.kind | lower }}` in
   `FluxSuspended` legte alle vier still; die Template-Engine kennt `lower`
   nicht):

   ```bash
   kubectl -n monitoring get vmrule homelab-flux            # STATUS: operational
   kubectl -n monitoring get vmrule homelab-flux -o jsonpath='{.status.reason}'
   ```

   Danach die vmalert-Rules-API:
   ```bash
   kubectl -n monitoring exec deploy/vmalert-vm-k8s-stack-victoria-metrics-k8s-stack -c vmalert -- \
     wget -qO- http://127.0.0.1:8080/api/v1/rules
   ```
4. **Group-by ohne `name`/`namespace` in der Alertmanager-Root-Route.**
   Mehrere gleichzeitig betroffene Flux-Objekte (wie am 14.08.: eine
   `Unknown`- plus drei `False`-Kustomizations) ergeben deshalb eine
   ntfy-Nachricht mit mehreren Zeilen statt mehreren Einzel-Nachrichten —
   das ist gewollt, siehe [monitoring-stack.md](monitoring-stack.md) bzw. das
   generelle Muster im [Rulebook](../rulebook.md).
5. **`flux_resource_suspended` deckt keine Halb-Suspendierung ab.** Wird nur die
   `GitRepository`-Quelle suspendiert, aber die abhängigen Kustomizations
   nicht, feuert `FluxSuspended` nur für die Quelle — die Kustomizations
   selbst laufen mit dem letzten bekannten Commit weiter, ohne dass das aus
   den Alerts allein erkennbar ist.
