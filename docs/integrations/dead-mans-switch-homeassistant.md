# Dead-Man's-Switch → Home Assistant

Die letzte Rückfallebene der Alerting-Pipeline. Jeder andere Alert setzt
voraus, dass vmalert, Alertmanager, die ntfy-bridge **und** ntfy selbst
laufen. Fällt diese Kette komplett aus, kommt schlicht nichts mehr an — und
Stille sieht von außen aus wie "alles grün". Der Dead-Man's-Switch löst genau
dieses Problem, indem er die Kette über einen permanent feuernden Alert und
einen zweiten, clusterunabhängigen Signalweg absichert.

## Kette

```mermaid
flowchart LR
  VM[VMRule Watchdog<br/>expr: vector(1)]
  AM[Alertmanager<br/>Route alertname=Watchdog]
  HA[Home Assistant<br/>Webhook]
  Timer[timer.k8s_watchdog_herzschlag<br/>60 Min, restore: true]
  Push[Mobile Push +<br/>persistent_notification]

  VM -->|alle 60s| AM
  AM -->|alle 5 Min, POST| HA
  HA -->|timer.start| Timer
  Timer -->|timer.finished| Push
```

- **VMRule** `apps/base/monitoring/rules/dead-mans-switch-vmrule.yaml`: Alert
  `Watchdog`, `expr: vector(1)` — feuert **immer**, unabhängig von jeder echten
  Metrik. `severity: none` hält ihn bewusst aus allen ntfy-Routen heraus, er
  darf nur den Herzschlag auslösen, nicht dauerhaft pushen.
- **Alertmanager-Route**: erste Kind-Route unter der Root-Route,
  `matchers: [alertname="Watchdog"]` → Receiver `homeassistant-watchdog`,
  `group_wait: 0s`, `group_interval: 5m`, `repeat_interval: 5m`,
  `send_resolved: false`. Der Receiver ruft
  `url_file: /etc/vm/secrets/alertmanager-homeassistant-webhook/url` auf — das
  SOPS-Secret `alertmanager-homeassistant-webhook` (Key `url`) liegt in
  `apps/base/monitoring/notifications/` und zeigt auf
  `http://192.168.10.25:8123/api/webhook/<webhook_id>`. Die `webhook_id` **ist**
  das Geheimnis in dieser Kette — sie steht nicht in diesem Dokument und nicht
  in Klartext in Git.
- **Home Assistant** (separates System, nicht in diesem Repo, nicht per GitOps
  verwaltet):
  - `timer.k8s_watchdog_herzschlag` — Dauer 60 Minuten, `restore: true`. Bei
    einem Herzschlag alle 5 Minuten toleriert das 11 verpasste Zustellungen,
    bevor alarmiert wird — kurze Reconciles, AM-Neustarts und Netz-Blips lösen
    also keinen Fehlalarm aus.
  - `automation.k8s_watchdog_herzschlag_empfangen` — Trigger: Webhook (POST,
    `local_only: true`) → Aktion: `timer.start`.
  - `automation.k8s_watchdog_herzschlag_fehlt` — Trigger: **ausschließlich**
    `timer.finished`, ohne Condition. Aktion: Push an
    `notify.mobile_app_pixel_10_pro_xl_sebastian` +
    `persistent_notification.create` mit fester `notification_id:
    k8s_heartbeat_missing`. Es gibt bewusst **eine** Meldung pro Ausfall und
    keine Wiederholung.

    > **Nicht wieder einbauen:** Ein zusätzlicher `time_pattern`-Trigger mit
    > Condition „Timer ist `idle`" als Erinnerung sieht naheliegend aus, ist
    > aber falsch. Ein Timer, der **nie gestartet** wurde, steht ebenfalls auf
    > `idle` — die Condition kann „abgelaufen" und „noch nie gelaufen" nicht
    > unterscheiden. Genau das ist am 14.08.2026 passiert: die HA-Seite stand,
    > die Cluster-Seite hing noch im Flux-Reconcile, also kam nie ein
    > Herzschlag, der Timer blieb seit Erstellung `idle` und die Automation
    > pushte 2,5 Stunden lang alle 15 Minuten. `timer.finished` setzt dagegen
    > voraus, dass der Timer tatsächlich lief.
  - `automation.k8s_watchdog_herzschlag_zuruck` — Trigger: `timer.started`
    (feuert nur beim Übergang idle→active, nicht bei jedem Neustart des
    Timers). Condition: `persistent_notification.k8s_heartbeat_missing` ist
    im Zustand `notifying`. Aktion: Entwarnung + Dismiss der Notification.

## Warum `restore: true`

Der Timer muss einen HA-Neustart überleben, ohne einen Fehlalarm auszulösen.
Ein `for:`-Trigger (klassische Automation mit Zeitverzögerung) würde beim Boot
von HA auf 0 zurückspringen und dabei einen echten, während der Downtime
aufgetretenen Ausfall verschlucken — HA merkt beim Neustart nicht mehr, dass
der Timer eigentlich schon vor dem Neustart hätte ablaufen müssen. `restore:
true` erhält den verbleibenden Rest der Laufzeit über den Neustart hinweg, der
Timer läuft also weiter genau dort, wo er stand.

## Warum nicht über ntfy

Ein Dead-Man's-Switch darf nicht denselben Weg benutzen, dessen Funktionieren
er beweisen soll — sonst prüft er nur sich selbst. ntfy hängt an der
ntfy-bridge, die wiederum im Cluster läuft; fiele der Cluster komplett aus,
wäre auch dieser Prüfweg tot, ohne dass irgendjemand etwas merkt. Der
Mobile-Push läuft stattdessen über Google/Apple-Push-Infrastruktur, komplett
unabhängig vom Cluster und von ntfy.

**Restrisiko:** Ist Home Assistant selbst down (oder sein Netzwerkpfad zum
Cluster), greift der Switch ebenfalls nicht — er verlagert die
Single-Point-of-Failure-Frage von "Cluster" auf "Cluster **und** HA", schließt
sie aber nicht vollständig.

## Testprozedur

Zerstörungsfrei, ohne auf den echten 5-Minuten-Zyklus zu warten:

1. In Home Assistant `timer.finish` auf `timer.k8s_watchdog_herzschlag`
   aufrufen (Entwickler-Tools → Aktionen, oder `ha_call_service`). Das
   entspricht dem Ablauf eines echten Timers, ohne eine Stunde zu warten.
2. Erwartung: Push-Benachrichtigung an `notify.mobile_app_pixel_10_pro_xl_sebastian`
   und eine `persistent_notification` mit ID `k8s_heartbeat_missing` erscheinen
   sofort.
3. **Erholung passiert automatisch** durch den nächsten regulären Herzschlag —
   spätestens nach 5 Minuten kommt der nächste Alertmanager-POST, startet den
   Timer neu (idle→active), und `automation.k8s_watchdog_herzschlag_zuruck`
   löst die Entwarnung + Dismiss aus. Kein manueller Reset nötig, der Test
   heilt sich selbst.

## Fehlersuche

**Symptom: Timer bleibt dauerhaft `idle`, kein Herzschlag kommt an.**

```bash
# Von einem beliebigen Cluster-Pod aus die Webhook-Kette direkt testen
# (webhook_id aus dem SOPS-Secret, nicht hier dokumentiert):
kubectl -n monitoring run curl-test --rm -it --image=curlimages/curl -- \
  curl -XPOST "http://192.168.10.25:8123/api/webhook/<webhook_id>"

# Alertmanager-Route und Zustellversuche pruefen
kubectl -n monitoring get vmalertmanager vm-am -o yaml | grep -A5 homeassistant-watchdog
kubectl logs -n monitoring -l app.kubernetes.io/name=vmalertmanager --tail=100 | grep -i watchdog

# Steht der Alert überhaupt permanent auf firing?
kubectl -n monitoring exec deploy/vmalert-vm-k8s-stack-victoria-metrics-k8s-stack -c vmalert -- \
  wget -qO- http://127.0.0.1:8080/api/v1/rules | grep -A5 '"name":"Watchdog"'
```

| Prüfschritt | Ergebnis erwartet | Wenn nicht |
|---|---|---|
| `vmalert`-Rules-API zeigt `Watchdog` als `firing`/`active` | ja, dauerhaft | vmalert selbst tot — höhere Ebene, siehe [monitoring-stack.md](../runbooks/monitoring-stack.md) |
| Alertmanager-Logs zeigen POST an `homeassistant-webhook`-URL alle ~5 Min | ja | Secret `alertmanager-homeassistant-webhook` prüfen (`kubectl get secret -n monitoring alertmanager-homeassistant-webhook`), Route-Reihenfolge in der HelmRelease (muss vor den generischen severity-Routen stehen) |
| Direkter `curl -XPOST` vom Cluster-Pod erreicht HA | HTTP 200 | Netzwerkpfad Cluster → `192.168.10.25:8123` prüfen (Firewall, HA down, falsche `webhook_id`) |
| HA-Automation `k8s_watchdog_herzschlag_empfangen` hat eine Trace | Trigger gefeuert | `local_only: true` blockt Requests von außerhalb des LAN — Cluster-Pod-IP muss als lokal gelten |

## Referenzen

- VMRule: `apps/base/monitoring/rules/dead-mans-switch-vmrule.yaml`
- Alertmanager-Route + Receiver: `apps/base/monitoring/vm-k8s-stack/helmrelease.yaml`
- Secret: `apps/base/monitoring/notifications/` (SOPS, Key `url`)
- Home-Assistant-Seite: nicht in Git, separates System — Timer + drei
  Automationen wie oben beschrieben, manuell in HA angelegt.
