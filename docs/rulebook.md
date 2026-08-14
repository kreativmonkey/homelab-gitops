# Kubernetes Homelab Rulebook

> **A portable set of rules for building a self-hosted Kubernetes homelab
> without walking into the pitfalls this one already walked into.**

This rulebook is deliberately **technology-agnostic**. It talks about *roles*
("your shared storage backend", "your OS-upgrade automation", "your GitOps
controller") rather than the specific products this cluster happens to run, so
the rules travel to any homelab regardless of stack. Each rule is one imperative
+ the underlying mechanism/why.

Where this cluster's concrete choices are useful as an example, they appear as a
short *e.g.* — never as the rule itself. The incidents that produced each rule
are mapped in the [Appendix](#appendix-provenance); the full stories live in
[`docs/learnings/`](./learnings/).

**How to read it:** start with the [three meta-principles](#the-three-meta-principles)
— they explain *why* most of the specific rules exist. Then use the themed
sections as a checklist when you design storage, set up a database operator,
enable auto-upgrades, or onboard an app.

---

## The three meta-principles

1. **Match storage to each workload's own replication model — never put
   everything on one shared backend.** The most common homelab failure mode is a
   single shared storage target (network block or file storage) sitting under
   *every* stateful workload. One storage blip then becomes a whole-cluster
   outage. A workload that already replicates itself does not want shared
   storage; a workload with no replication does not want node-pinned storage.
   Decide per workload. → §1.
2. **A backend that reports itself "healthy" is not exonerated.** Storage,
   network, and external services routinely pass their own health checks *while*
   failing in a way that only shows up on the consumer side (latency, transport
   timeouts, contention). Monitor for the *actual* failure mode from the client's
   perspective, not just the one the backend's own dashboard shows you. → §1, §6.
3. **Automation needs guardrails, not just triggers.** Auto-update and
   auto-upgrade systems will happily drive an unreviewed, unpinned, or
   non-existent version straight into a node reboot. Every autonomous path must
   fail *closed* and loud: pinned versions, published artifacts, and workloads
   that have actually been drain-tested. → §3, §4.

---

## 1. Storage

Storage is the number-one source of homelab outages. These rules are organized
by **storage type**, because the right choice depends on the workload's own
resilience — not on which product you happen to run.

### Choosing a storage class per workload

| Workload | Right storage type | Why |
| :-- | :-- | :-- |
| **Self-replicating databases** (a DB operator that keeps N replicas + backups) | **Node-local** (e.g. local-path / hostPath-class) | The DB already replicates and can re-clone a lost node. Node-local is faster and keeps the shared-backend SPOF out of the data path. |
| **Single-writer app data, no app-level replication** | **Replicated network block** (e.g. Ceph/Longhorn) | Survives a node loss; not tied to one node. |
| **Bulk / media / archives** | **Network file or object** (e.g. NFS / S3) | Large, sequential, shareable; replication handled elsewhere. |
| **Reproducible data** (logs, caches) | Cheapest available; skip backups | Rebuildable, so resilience isn't worth the cost. |

- **Do not put a self-replicating database on shared network storage.** The
  operator already replicates at the DB layer; layering it on a shared backend
  just adds a single point of failure and attach/detach churn on every reboot,
  which drops replicas and blocks node drains. Give it node-local disks.
- **Do not put single-writer, non-replicated app data on node-local storage.**
  Node-local volumes are node-pinned — a node loss takes the data with it and
  nothing re-clones it. Such data belongs on replicated storage.
- **Match the filesystem to the failure mode of the underlying transport.** On
  network block storage, prefer a filesystem that recovers its journal gracefully
  after a transport stall (e.g. XFS) over one that flips read-only on the first
  blip (e.g. ext4 → `emergency_ro`), which drags the app into CrashLoop.

### Rules for any shared storage backend

- **Treat every shared backend as a blast-radius multiplier and design to shrink
  it.** Count how many workloads depend on one backend before you add the next
  one to it. The fewer stateful workloads share a failure domain, the smaller
  each incident.
- **Do not let contending workloads share the same physical spindle.** Latency-
  sensitive storage (databases) sharing a disk with other heavy I/O tenants
  (other VMs, bulk transfers) causes I/O contention that surfaces on the client
  as command timeouts and I/O errors — even while the backend reports zero errors.
- **Monitor the backend for the failure mode your workloads actually hit.**
  Backend-health metrics (pool status, error counters) are necessary but not
  sufficient — they stayed green through real cascades here. Add **client-side**
  latency/error alerting (per-device I/O latency, database restart spikes) so a
  transport-latency event is actually caught.
- **Alert on silent filesystem state changes.** A volume remounting read-only, or
  a mount option flipping, precedes the visible CrashLoop — catch it directly.
- **Pre-size volumes generously; treat online resize as risky.** Online filesystem
  growth on network storage is fragile and platform-dependent (can fail even
  privileged); the reliable path is often offline (unmount → fsck → resize).
  Provision headroom up front.
- **Give storage-backed pods a clean-shutdown budget and avoid full-volume
  permission rewrites on start.** A short termination grace period lets the client
  release storage locks/reservations cleanly; a recursive ownership change on a
  large volume at every start can time out and trigger remounts (prefer an
  "only on mismatch" fsGroup policy).

### Backups

- **Keep at least one backup copy off the storage box it protects.** If your
  primary storage, your secondary storage, *and* your database backups all live
  on the same physical box, a single box loss takes the data and its backups
  together. An off-box (ideally off-site) copy is the only real DR.
- **Take a fresh backup before any storage migration or risky change**, and after
  recovering/re-cloning a replica (so the recovery baseline sits on the clean
  state).
- **Alert on the absence of success, not just on failure.** A backup job that
  gets deleted, suspended, or never scheduled again produces no error — only
  silence, and silence looks exactly like "all good" on a dashboard that only
  tracks failures. Age the time since the *last success*, with a fallback to
  the job's creation time so a job that has never once succeeded doesn't read
  as fine — that single signal covers all three failure shapes (fails, stops
  running, never ran) without a separate alert for each.

## 2. Databases (via an operator)

These assume a Kubernetes-native database operator that manages replicas,
failover, and backups (this cluster uses CloudNativePG for PostgreSQL; the rules
generalize to any such operator).

- **Require hard anti-affinity between database replicas.** A "preferred"
  (soft) anti-affinity silently co-locates primary and replica on one node, so a
  single node drain becomes a failover storm. Make it required.
- **Add a small failover delay instead of failing over on the first blink.** A
  short grace period rides out transient node-drain / storage blips that would
  otherwise trigger an unnecessary (and cascading) failover.
- **Give any cluster that must survive drains ≥2 instances.** A single-instance
  "cluster" has no failover target, so its pod-disruption-budget blocks every
  drain of its node — and stalls node upgrades.
- **Re-clone a diverged replica; never hand-repair it.** Delete the replica's
  pod + volume and let the operator re-clone from the primary. Reconciling a
  replica that has diverged onto its own timeline is more fragile than a clean
  re-clone.
- **Un-cordon a node before repairing the database on it.** Many operators freeze
  reconciliation while a primary sits on an unschedulable node — repairs silently
  do nothing until the node is schedulable again.
- **A new database's owner must be the application's role, not the operator's
  default user.** Modern PostgreSQL refuses schema creation for a non-owner;
  set the owner at creation, not at the first failed migration.
- **Superuser-only operations (extension upgrades, etc.) must run as the
  superuser.** Operator-managed app roles typically get LOGIN, not SUPERUSER. An
  app that auto-runs an extension update at startup will CrashLoop — pin or
  gate the update.
- **Expect an operator *minor* upgrade to roll every database instance.** Plan
  for brief connection-refused windows; DB-backed apps will blip and recover.
- **Pin database engine versions and raise the pin deliberately before a major
  upgrade.** A loose version range will offer beta/pre-release engines; an
  intentional major upgrade is a decision, not an automatic PR.

## 3. Node / OS auto-upgrades

Assumes an automated node/OS upgrade mechanism (this cluster: an immutable-OS
upgrade controller driven by GitOps). The rules generalize to any auto-upgrade
loop.

- **Never let the upgrade orchestrator's own scheduling constraints deadlock the
  last node.** If per-node upgrade jobs inherit labels/anti-affinity that match
  the orchestrator's own pod, the job can never schedule onto the node hosting
  the orchestrator. Scope the orchestrator's anti-affinity narrowly and don't use
  "exclusive" scheduling modes that add cluster-wide required anti-affinity.
- **Pin upgrade component images to a *published, stable* tag, and keep the
  manifest reference and the image tag identical.** An unpublished tag can survive
  on cached image layers and then fail to pull the moment a job lands on an
  uncached (freshly rebooted) node — stalling the whole rollout.
- **Keep the target version in sync across every place it's declared** (upgrade
  plan, CLI/tooling image, installer image, infrastructure-as-code). A drift
  between them produces confusing partial-upgrade states.
- **Authenticate upgrade automation properly; don't lean on insecure/maintenance
  modes.** Provision the credentials it needs out-of-band (they're often
  regenerated per deploy and can't be committed), and validate the exact
  auth+endpoint with a dry run before trusting the loop.
- **Pause the auto-upgrade loop before any manual recovery**, especially while a
  node is cordoned — and un-cordon before running infra-as-code that health-checks
  the cluster.
- **Treat every OS/node bump as a live drain test for all stateful workloads.**
  Before merging, grep the repo for un-pinned images (`:latest`,
  `imagePullPolicy: Always`) — on reboot those become unreviewed, unrevertible
  upgrades.
- **Expect update waves to fill node disks with image pulls.** Nodes have limited
  ephemeral storage; batch upgrades can cause transient disk-pressure/evictions
  (usually self-healing via kubelet GC) — don't panic, but leave headroom.

## 4. Dependency automation (Renovate-style)

- **One owner per version line.** When multiple update managers can each match the
  same version string (e.g. a Helm manager that already reads chart values *and* a
  generic manager that scans every `image:` line), you get double-updates or
  missed updates. Constrain each manager's file scope to the files it should own,
  and verify with a dry-run extract which manager owns each line.
- **Non-semver tags (CalVer, commit hashes, date tags) need an explicit
  datasource/versioning hint**, or the updater misreads them as pre-releases and
  silently never proposes an update. Audit every new image's tag scheme when you
  add it.
- **Pin every image and update only via reviewed PRs — never `:latest`.** An
  unpinned image turns any pod restart or node reboot into an unreviewed upgrade
  (this bit a protocol-breaking change here).
- **Know which of your update bot's status checks are *pending-by-design*** and
  don't block your automation/merge waits on them.

## 5. GitOps / reconciliation

- **Monitor the deploy pipeline itself, not just what it deploys.** A GitOps
  controller (or any pull-based deploy automation) that stops reconciling does
  not raise an error — it simply stops doing anything, while the cluster's
  last-applied state keeps looking healthy on every other dashboard. Alert
  directly on the controller's own reconcile-condition metrics, and treat a
  hard failure and a reconcile that never finishes as two different failure
  modes needing separate alerts: a stuck health-check wedged in a permanent
  timeout (e.g. one blocked on a `Pending` PVC) reports as "still in
  progress", not as an error, and a dependency chain built on top of it fails
  loudly downstream while the true cause sits quietly upstream reporting
  neither success nor failure.
- **All changes land via Git — never `kubectl edit` a managed resource.** A
  pruning reconciler reverts live edits on its interval; a live patch is an
  emergency unblock only, and must be converged back into Git or it silently
  disappears.
- **A suspended/paused reconciled resource drifts silently — check it first when
  an update "won't land".** A resource paused out-of-band (and not recorded in
  Git) can sit stale for months while you look everywhere else.
- **When a workload's image and its chart/source change in the same commit, verify
  the rendered revision actually matches** — a reconcile timing race can render a
  new image against an old template.
- **Recover a stuck dependency chain by poking reconciliation top-down.** After an
  infrastructure stall, dependent kustomizations can stick on stale
  "dependency not ready"; force a re-reconcile from the root down.

## 6. Networking / ingress

- **Exonerate the cluster first before blaming an external hop.** An in-cluster
  request straight to the ingress/service (bypassing DNS and any external proxy)
  that returns healthy proves the fault is *upstream* (external proxy / tunnel /
  DNS), not the cluster. Do this before touching the ingress controller.
- **A post-reboot ingress 5xx is almost always a not-ready backend, not the
  ingress.** During the startup fan-out (storage attach, image pull, DB, OIDC) a
  5xx usually means no ready backend yet — investigate backend readiness, not the
  proxy.
- **External-facing exposure may require a manual step outside GitOps — document
  it.** If public hostnames route through an external proxy/tunnel that isn't in
  your repo, deploying the app is not enough to make it reachable. Symptom is
  typically a TLS/connection error from outside while the cluster side is fine.
  Write the manual step down so it's not rediscovered each time.
- **Long-lived streams (gRPC, websockets) must not be cut by a proxy's default
  idle/response timeout.** Set the relevant timeout to unlimited on the hop
  serving those streams; a periodic cut breaks control-plane sync in subtle ways
  (peers "connected" but nothing works). Restart the affected components after
  fixing it — many don't self-heal from a long broken-reconnect state.
- **Standardize the HTTPS-redirect annotations for apps behind a TLS-terminating
  proxy** so the app honors `X-Forwarded-Proto` and doesn't form a redirect loop.

## 7. Secrets

- **Encrypting a secret needs only the public recipient; decrypting needs the
  private key.** You can re-encrypt/rotate a secret without holding the cluster's
  private key by reconstructing the plaintext from the live in-cluster secret and
  re-encrypting to the public recipient.
- **A secret consumed via env/`secretKeyRef` does not trigger a rollout when it
  changes — restart the workload after rotating.** (A secret mounted as a file
  usually does propagate; env injection does not.)
- **Expect a backend's major upgrade to invalidate its API credentials.** After
  upgrading an external service (storage appliance, etc.), be ready to rotate the
  key its cluster clients use; a purged key often surfaces as a 5xx from the
  backend, not a clean 401, and CrashLoops every consumer.

## 8. Application onboarding

- **Single-replica Deployment + ReadWriteOnce volume → use the `Recreate`
  strategy.** The default rolling update starts the new pod before the old one
  releases the volume → multi-attach deadlock. Applies to any single-writer app.
- **Prefer apps/charts that expose the image tag so your update bot can see
  them.** A dead chart pinned to `:latest` hides the app from dependency
  automation entirely — it can silently miss major releases for months.
- **Swapping the chart under an existing release is a cutover, not an in-place
  upgrade.** Two different charts collide on immutable-field/ownership conflicts.
  The safe pattern: pause reconciliation → uninstall the old release → release the
  underlying volumes (set them back to `Available`/reclaimable) → switch → resume.
  Retained data volumes stay untouched.
- **Verify persistence sub-path semantics when a chart library changes major
  versions.** A shared-root network mount without the right sub-path handling can
  silently point at the share root instead of the app's directory.
- **Understand where an app keeps its source of truth before a storage migration.**
  E.g. an app whose object storage holds only opaque blobs keyed by a database
  index must never have that index rebuilt/rescanned, or every object is orphaned.
- **OIDC integration: watch for issuer-string normalization mismatches.** Some
  providers always emit a trailing slash on the issuer; some clients strip it,
  then fail discovery on an exact-string compare ("Issuer mismatch"). Grep the app
  logs for that error before suspecting client-id/secret/redirect-URI.
- **When you customize an upstream template, re-diff it against upstream on every
  upgrade** — an un-handled new input type can crash the view (add defensive
  nil-checks).

## 9. Working process

- **One task = one branch = one worktree.** Keep the default branch clean for
  review/merges; do feature/fix/experiment work in isolation. Know your VCS
  layout (a bare repo + worktrees has a non-obvious working path).
- **Verify the cluster context before you touch anything** — the default kube
  context may point at an unrelated cluster.
- **Read your own past incident notes before a complex migration.** This rulebook
  is the summary; the detailed learnings hold the exact commands and context.
- **Tune alert grouping so one blast radius isn't one giant unreadable alert.**
  Group per-instance alerts by instance, or a cascade collapses every failing
  endpoint into a single message and hides the root cause.
- **When an incident teaches a generalizable rule, add it here** — and keep the
  full story in your learnings directory.

---

## Appendix: Provenance

Every rule above was paid for by a real incident on this cluster. This table maps
the generic rules back to the concrete stories, for anyone who wants the full
context (products, commands, PRs). Files are under [`docs/learnings/`](./learnings/).

| Rulebook section | Originating incident(s) |
| :-- | :-- |
| §1 Storage — SPOF, contention, client-side monitoring | `truenas-iscsi-spof-storage-incident`, `truenas-iscsi-outage-2026-06-13`, `truenas-exporter-facts` |
| §1 Storage — DB off shared storage → node-local | `cnpg-local-path-storage` |
| §1 Storage — filesystem choice, emergency-ro, resize, shutdown | `nextcloud-iscsi-emergency-readonly`, `democratic-csi-pvc-resize-permission-denied` |
| §2 Databases — anti-affinity, failover delay, re-clone | `cnpg-failover-storm-soft-antiaffinity` |
| §2 Databases — ≥2 instances, freeze-on-cordon | `talos-suc-upgrade-blockers` |
| §2 Databases — owner, superuser extensions, operator upgrade | `upgrade-session-2026-07-04`, `immich-vchord-extension-update` |
| §2 Databases — version pinning | `renovate-single-owner-refactor` |
| §3 Node/OS upgrades — scheduling deadlock, image pin, auth | `talos-automatic-upgrade-suc-auth`, `talos-autonomous-upgrade-handbook`, `talos-suc-upgrade-blockers` |
| §4 Dependency automation | `renovate-single-owner-refactor`, `renovate-calver-docker-image-not-detected` |
| §5 GitOps | `goloom-rwo-upgrade-race`, `democratic-csi-truenas-apikey-purge`, `truenas-iscsi-spof-storage-incident` |
| §6 Networking | `netbird-reverse-proxy-traefik-grpc-timeout`, `public-app-needs-netbird-proxy-entry`, `talos-autonomous-upgrade-handbook` |
| §7 Secrets | `democratic-csi-truenas-apikey-purge`, `truenas-exporter-facts` |
| §8 App onboarding | `goloom-rwo-upgrade-race`, `paperless-zekker6-chart-migration`, `nextcloud-s3-primary-storage`, `authentik-issuer-trailing-slash`, `forgejo-500-nil-pullrequest`, `upgrade-session-2026-07-04` |
| §9 Process | `codebase-memory-index-worktree-path`, `truenas-iscsi-spof-storage-incident` |
