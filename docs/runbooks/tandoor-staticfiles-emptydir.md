# Tandoor staticfiles: emptyDir rollout, acceptance and rollback

Use this runbook for Issue #788 after the GitOps change is merged to `main`.
It verifies that generated static files are pod-local while user media remains on
NFS, and the Tandoor application runs as the image's `nginx` uid 100 / gid 101.
It does not increase probe timeouts to conceal a failed startup.

## Scope and safety

- GitOps source: `apps/base/tandoor/deployment.yaml` and
  `apps/base/tandoor/pvc.yaml`, included by `apps/overlays/main/` and reconciled
  by `Kustomization/flux-system/apps` (`clusters/main/apps.yaml`).
- Expected rendered workload: `Deployment/tandoor/tandoor`,
  `Service/tandoor/tandoor`, and `Ingress/tandoor/tandoor`.
- `/opt/recipes/staticfiles` must use the `static` `emptyDir`; it must not have
  a `subPath` or a `tandoor-static` claim mount. Pod `fsGroup: 101` makes this
  emptyDir writable to the non-root Tandoor process.
- The Tandoor container must have `runAsUser: 100`, `runAsGroup: 101`,
  `runAsNonRoot: true`, `allowPrivilegeEscalation: false`, and all Linux
  capabilities dropped. The pod must use `RuntimeDefault` seccomp.
- `/opt/recipes/mediafiles` must remain the `media` mount from the RWO
  `PersistentVolumeClaim/tandoor-media-iscsi`; it mounts the claim root without
  a `subPath`.
- `PersistentVolumeClaim/tandoor-static` and its backing PV are retained. Do
  not delete, resize, or manually alter them. Their deletion is a separate
  work item after successful acceptance.
- The prior image-pull DiskPressure incident is not the current blocker. Treat
  an actual new `DiskPressure` or image-pull failure as a separate incident;
  do not attribute it to `collectstatic`.
- Schedule a maintenance window before each deliberate restart. One replica and
  `strategy: Recreate` make Tandoor unavailable during a pod replacement.
- Do not run `kubectl apply` against the Deployment as a rollout mechanism.
  The only permitted direct apply here is the server-side dry-run below.

## Preconditions and values to record

Use a kubeconfig with read access, Flux reconcile permission, and an operator
account authorized to edit a deliberately chosen test recipe. Record the merge
commit and the following values in the change record; none is known in advance:

| Value | Record during acceptance |
|---|---|
| Git commit and Flux observed revision | SHA |
| Pod 1 / pod 2 name and container start time | UTC timestamps |
| `collectstatic` completion | log timestamp and elapsed seconds |
| `/tmp/tandoor.sock` first observation | UTC timestamp and elapsed seconds |
| Pod `Ready=True` | UTC timestamp and elapsed seconds |
| Startup-probe budget remaining | seconds |
| Existing-media recipe and test-upload recipe/file | user-approved identifiers only |

The startup probe has `initialDelaySeconds: 60`, `failureThreshold: 30`, and
`periodSeconds: 10`. Its configured maximum window is 360 seconds (6 minutes)
from container start. This runbook does not claim a historical `collectstatic`
duration; measure it for both starts.

## 1. Render and server-side admission check

Run from the repository root after the emptyDir change is present locally:

```bash
set -euo pipefail
kustomize build apps/overlays/main > /tmp/tandoor-apps-rendered.yaml
kubectl apply --dry-run=server -f /tmp/tandoor-apps-rendered.yaml
```

Confirm the rendered contract before proceeding. `emptyDir: {}` and the media
PVC must be visible; `tandoor-static` must still be rendered but must not be
referenced by the Deployment.

```bash
# yq-go is provided by the repository's nix develop shell.
yq 'select(.kind == "Deployment" and .metadata.namespace == "tandoor" and .metadata.name == "tandoor")
  | .spec.template.spec.volumes[] | select(.name == "static")' /tmp/tandoor-apps-rendered.yaml
yq 'select(.kind == "Deployment" and .metadata.namespace == "tandoor" and .metadata.name == "tandoor")
  | .spec.template.spec.containers[] | select(.name == "tandoor") | .volumeMounts[]
  | select(.mountPath == "/opt/recipes/staticfiles" or .mountPath == "/opt/recipes/mediafiles")' /tmp/tandoor-apps-rendered.yaml
yq 'select(.kind == "PersistentVolumeClaim" and .metadata.namespace == "tandoor" and .metadata.name == "tandoor-static")
  | {name: .metadata.name, annotations: .metadata.annotations, volumeName: .spec.volumeName}' /tmp/tandoor-apps-rendered.yaml
yq 'select(.kind == "Deployment" and .metadata.namespace == "tandoor" and .metadata.name == "tandoor")
  | {podSecurityContext: .spec.template.spec.securityContext,
     containerSecurityContext: (.spec.template.spec.containers[] | select(.name == "tandoor") | .securityContext),
     startupProbe: (.spec.template.spec.containers[] | select(.name == "tandoor") | .startupProbe)}' /tmp/tandoor-apps-rendered.yaml
```

Success: the server dry-run exits zero. The first query is exactly `name:
static` plus `emptyDir: {}`; the static mount has no `subPath`. The media mount
shows `name: media` without a `subPath`. The last query
shows `volumeName: pv-nfs-tandoor-static` and
`kustomize.toolkit.fluxcd.io/prune: disabled`. The security query shows uid 100,
gid/fsGroup 101, `RuntimeDefault`, `allowPrivilegeEscalation: false`, dropped
capabilities, and the 60 + 30 × 10-second startup budget. Stop and correct the
Git change if any result differs. This check is admission only; it is not a
rollout.

## 2. Merge and reconcile through Flux

1. Merge the reviewed GitOps commit to `main` and confirm the remote contains
   that SHA. Local, unmerged worktrees are not a deployable source.
2. Reconcile the source and application Kustomization:

```bash
flux reconcile source git flux-system
flux reconcile kustomization apps --with-source --timeout=10m
flux get kustomization apps -n flux-system
kubectl get deployment,pvc -n tandoor
```

3. Record the Kustomization `Ready=True` state and observed revision. Confirm
   the Deployment template now specifies `emptyDir` for `static`; confirm both
   PVCs, including `tandoor-static`, still exist.

```bash
kubectl get deploy tandoor -n tandoor -o yaml
kubectl get pvc tandoor-static tandoor-media-iscsi -n tandoor
```

Success: Flux reports `Ready=True` at the merged revision, the Deployment has
not been directly modified, and `tandoor-static` remains `Bound` (or retains
its pre-existing valid status) rather than deleted.

## 3. First fresh pod start: measurements and readiness

The Flux rollout creates the first fresh pod. Before starting, create a change
record with the pod name. Do not use a production upload yet.

```bash
kubectl get pods -n tandoor -l app=tandoor -w
# Set POD manually to the new pod name shown above.
export POD='<new-tandoor-pod>'
kubectl get pod "$POD" -n tandoor -o jsonpath='{.status.startTime}{"\n"}'
kubectl get pod "$POD" -n tandoor -w
```

In a second terminal, preserve timestamped startup logs. Identify and record
the actual `collectstatic` completion line from this image's log; do not assume
a particular wording or file count.

```bash
kubectl logs -n tandoor "$POD" -c tandoor --timestamps -f | tee "/tmp/${POD}-startup.log"
```

While the container is running but before it becomes ready, probe for the Unix
socket at a known interval and record the first successful UTC timestamp. Stop
the loop after success.

```bash
until kubectl exec -n tandoor "$POD" -c tandoor -- sh -c 'test -S /tmp/tandoor.sock'; do
  date -u +'%Y-%m-%dT%H:%M:%SZ socket-not-yet-present'
  sleep 5
done
date -u +'%Y-%m-%dT%H:%M:%SZ socket-present'
```

Inspect effective mounts from inside the same pod. The static mount must not
show an NFS filesystem. The media mount must remain mounted and writable only
through the approved application workflow.

```bash
kubectl exec -n tandoor "$POD" -c tandoor -- sh -c '
  grep -E "(/opt/recipes/(staticfiles|mediafiles))" /proc/self/mountinfo || true
  df -T /opt/recipes/staticfiles /opt/recipes/mediafiles
  test -S /tmp/tandoor.sock && echo socket-present
'
```

During `collectstatic`, inspect logs and pod events for storage delays. If the
image contains `ps`, collect process state as evidence; failure of this optional
command is not a workload failure.

```bash
kubectl logs -n tandoor "$POD" -c tandoor --timestamps
kubectl describe pod -n tandoor "$POD"
kubectl exec -n tandoor "$POD" -c tandoor -- sh -c 'ps -eo pid,state,wchan,comm,args 2>/dev/null || true'
```

Record elapsed seconds as `event UTC timestamp - .status.startTime`. Calculate
startup-probe reserve as `360 - socket elapsed seconds`; it must be positive.
Record Ready elapsed time separately; it is not a substitute for socket time.

Success:

- collectstatic completes without recurring `rpc_wait_bit_killable`, `D` state,
  or an equivalent NFS-RPC wait attributable to static-file writes;
- `/tmp/tandoor.sock` appears before the 360-second budget;
- staticfiles is local `emptyDir`, while mediafiles resolves to the RWO iSCSI
  PVC; and
- the pod reaches `Ready=True` without a restart or startup-probe failure.

If the static mount remains NFS, the socket misses budget, the pod restarts, or
NFS waits recur, stop acceptance and execute the rollback section.

## 4. Routing, existing media, and authorized upload

Only after pod 1 is ready, verify the Service, EndpointSlice and public route:

```bash
kubectl get service tandoor -n tandoor -o wide
kubectl get endpointslice -n tandoor -l kubernetes.io/service-name=tandoor -o yaml
kubectl get pod "$POD" -n tandoor -o jsonpath='{range .status.conditions[?(@.type=="Ready")]}{.status} {.lastTransitionTime}{"\n"}{end}'
curl --fail --show-error --silent --output /dev/null --write-out '%{http_code} %{url_effective}\n' \
  https://rezepte.f4mily.net/
```

Success: EndpointSlice contains a ready endpoint for the current pod and HTTPS
returns a successful HTTP status. A 502, missing ready endpoint, or a response
from an unrelated host fails acceptance.

In the authenticated UI, perform two non-destructive checks:

1. Open a pre-agreed recipe that already has media and record that it renders.
   Do not delete, rename, replace, or bulk-process existing media.
2. With the authorized editor account, upload one small, non-sensitive test file
   to a pre-agreed test recipe. Record the recipe and filename in the change
   record. Confirm it renders in the UI. Do not use an unapproved account,
   production-sensitive file, or direct filesystem writes.

This proves the retained `/opt/recipes/mediafiles` iSCSI path through the
application, without treating user data as a test fixture.

## 5. Second controlled fresh pod start

Obtain the maintenance-window approval, then make the second start explicit.
This restart is diagnostic only; it does not change the desired GitOps state.

```bash
kubectl rollout restart deployment/tandoor -n tandoor
kubectl rollout status deployment/tandoor -n tandoor --timeout=18m
kubectl get pods -n tandoor -l app=tandoor -w
# Set POD to the replacement pod, then repeat every command in section 3.
```

Repeat all first-start measurements: container start, collectstatic completion,
socket time, Ready time, probe reserve, effective mounts, events, and NFS-wait
evidence. Then revisit the authorized test recipe and confirm the upload still
renders. This confirms it survived the pod-local staticfiles recreation because
it is on the persistent mediafiles iSCSI mount.

Success: pod 2 meets every section-3 criterion, has a positive socket reserve,
and the approved upload plus pre-existing media remain available. Record both
sets of measurements; do not claim a timing improvement without them.

## GitOps-first rollback

Rollback is required for any failed acceptance criterion or unexpected media
behavior. Preserve evidence first: pod description, timestamped logs, effective
mount output, EndpointSlice output and the Flux revision.

1. In a new reviewed Git change, restore the former `static` PVC volume and
   mount in `apps/base/tandoor/deployment.yaml`:

```yaml
volumeMounts:
  - name: static
    mountPath: /opt/recipes/staticfiles
    subPath: docker/tandoor/staticfiles
volumes:
  - name: static
    persistentVolumeClaim:
      claimName: tandoor-static
```

   Keep the `media` mount unchanged. Do not delete `apps/base/tandoor/pvc.yaml`
   or `PersistentVolumeClaim/tandoor-static`.
2. Repeat section 1 against the rollback commit, merge it to `main`, then run
   the section-2 Flux reconcile. Do not patch the live Deployment to bypass
   GitOps.
3. Confirm Flux observes the rollback revision, the replacement pod has the
   legacy static PVC mount, `tandoor-static` exists, and the Service,
   EndpointSlice, HTTPS route and existing media are operational.
4. Open a follow-up incident/work item with the captured timings and logs.
   Probe-budget changes need their own evidence-based review; do not enlarge the
   budget merely to allow an NFS-stalled startup.

A later deletion of `tandoor-static` is explicitly out of scope. Create a
separate cleanup task only after this rollout has been accepted.
