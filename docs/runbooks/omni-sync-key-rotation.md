# Omni-Sync: Service-Account-Key erneuern

> **Alert**: `OmniSyncKeyExpiringSoon` (30 Tage vor Ablauf, VMRule
> `apps/base/monitoring/rules/omni-vmrule.yaml`).
> **Ablauf aktueller Key**: 2027-10-15T18:59:21Z.

`omni-sync` (`infrastructure/base/omni-sync/`) authentifiziert sich bei Omni
mit dem Service Account `omni-sync` (Rolle Operator). Läuft der Key ab, scheitert
jeder Template-Sync: keine automatischen Talos-/Kubernetes-Upgrades mehr, Drift
aus der Omni-UI bleibt stehen. Symptom: `omni-sync` in CrashLoopBackOff mit
Auth-Fehler.

## Ablauf

```bash
NIXPKGS_ALLOW_UNFREE=1 nix shell --impure nixpkgs#omnictl
# als Admin bei Omni angemeldet (omniconfig oder OMNI_SERVICE_ACCOUNT_KEY eines Admin-SA)

omnictl serviceaccount list                 # EXPIRATION von omni-sync
omnictl serviceaccount renew omni-sync      # gibt neuen OMNI_SERVICE_ACCOUNT_KEY aus (nur einmal sichtbar)

# im homelab-gitops-Worktree (nix develop):
sops set infrastructure/base/omni-sync/omni-sync-credentials.secret.yaml \
  '["stringData"]["OMNI_SERVICE_ACCOUNT_KEY"]' '"<neuer-key>"'
```

Dann im selben PR:

1. Kommentar im Secret (Ablaufdatum) anpassen.
2. In `apps/base/monitoring/rules/omni-vmrule.yaml` den Unix-Zeitstempel im
   `expr` (und den Kommentar `OMNI_SYNC_KEY_EXPIRY`) auf das neue Ablaufdatum setzen:
   `date -u -d '<EXPIRATION>' +%s`.
3. Ablaufdatum oben in diesem Runbook aktualisieren.

Nach dem Merge: Flux aktualisiert das Secret; `envFrom` liest es nur beim
Start, daher `kubectl -n omni-sync rollout restart deploy/omni-sync` und im Log
auf `sync ok` warten.

## Prüfen

```bash
kubectl -n omni-sync logs deploy/omni-sync -c sync --tail=3   # "... sync ok"
omnictl serviceaccount list                                    # neue EXPIRATION
```
