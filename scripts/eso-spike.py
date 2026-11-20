#!/usr/bin/env python3
"""Run ESO Phase 0 in a NEW local kind cluster, then delete only that cluster.

Usage: nix develop -c just eso-spike
Requires working Docker or Podman. Rootless Podman needs a delegated systemd scope:
  KIND_EXPERIMENTAL_PROVIDER=podman systemd-run --user --scope -p Delegate=yes nix develop -c just eso-spike
Never uses the caller's kubeconfig; never imports production data or manifests.
"""

import base64
import json
import os
from pathlib import Path
import re
import secrets
import shutil
import signal
import subprocess
import sys
import tempfile
import time


# Official kind v0.33.0 release image.
NODE_IMAGE = "docker.io/kindest/node:v1.36.4@sha256:099e049362a1526b2db71494e1947aae99bd16290d7c895f2b7ea312e3cbfaed"
ESO_VERSION = "2.15.0"  # renovate: datasource=helm depName=external-secrets registryUrl=https://charts.external-secrets.io
SOURCE = "secret-source"
READERS = {
    "spike-app-a": ["db-a", "oidc-a", "rotation"],
    "spike-app-b": ["db-b", "oidc-b"],
    "spike-cnpg": ["db-a", "db-b"],
    "spike-authentik": ["oidc-a", "oidc-b"],
}
PASSED = 0


def run(args, data=None, check=True, timeout=300):
    result = subprocess.run(args, input=data, text=True, capture_output=True, timeout=timeout)
    if check and result.returncode:
        # Never print stdin or secret-bearing command arguments.
        detail = result.stderr[-1200:] if args[0] in ["kind", "helm"] else "request details suppressed"
        raise RuntimeError(f"{args[0]} failed (exit {result.returncode}): {detail}")
    return result


def select_local_runtime():
    provider = os.environ.get("KIND_EXPERIMENTAL_PROVIDER") or (
        "docker" if shutil.which("docker") else "podman"
    )
    if provider == "docker":
        override = os.environ.get("DOCKER_HOST")
        if override and not override.startswith("unix:///"):
            raise RuntimeError("Kind requires a local Docker Unix socket")
        endpoint = run(["docker", "context", "inspect", "--format", "{{.Endpoints.docker.Host}}"],
                       timeout=10).stdout.strip()
        if not endpoint.startswith("unix:///"):
            raise RuntimeError("Kind requires a local Docker Unix socket")
    elif provider == "podman":
        if os.environ.get("CONTAINER_HOST") or os.environ.get("CONTAINER_CONNECTION"):
            raise RuntimeError("Kind requires local Podman without a remote connection override")
        remote = run(["podman", "info", "--format", "{{.Host.ServiceIsRemote}}"],
                     timeout=10).stdout.strip()
        if remote != "false":
            raise RuntimeError("Kind requires local Podman")
    else:
        raise RuntimeError("Select local docker or podman with KIND_EXPERIMENTAL_PROVIDER")
    os.environ["KIND_EXPERIMENTAL_PROVIDER"] = provider


def passed(message, condition=True):
    global PASSED
    if not condition:
        raise RuntimeError(message)
    PASSED += 1
    print(f"PASS {PASSED}: {message}", flush=True)


def eventually(message, predicate, timeout=120):
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        if predicate():
            return
        time.sleep(2)
    raise RuntimeError(f"Timeout: {message}")


def resource(kind, name, namespace=None, **fields):
    api = {
        "ExternalSecret": "external-secrets.io/v1",
        "SecretStore": "external-secrets.io/v1",
        "ClusterGenerator": "generators.external-secrets.io/v1alpha1",
        "Role": "rbac.authorization.k8s.io/v1",
        "RoleBinding": "rbac.authorization.k8s.io/v1",
        "SubjectAccessReview": "authorization.k8s.io/v1",
        "Cluster": "postgresql.cnpg.io/v1",
    }.get(kind, "v1")
    metadata = {"name": name}
    if namespace:
        metadata["namespace"] = namespace
    return {"apiVersion": api, "kind": kind, "metadata": metadata, **fields}


def source(name, policy="Orphan", generator="password-32"):
    obj = resource("ExternalSecret", name, SOURCE, spec={
        "refreshPolicy": "CreatedOnce",
        "target": {
            "name": name, "creationPolicy": policy, "immutable": True,
            "template": {"metadata": {"annotations": {
                "kustomize.toolkit.fluxcd.io/prune": "disabled",
            }}},
        },
        "dataFrom": [{"sourceRef": {"generatorRef": {
            "apiVersion": "generators.external-secrets.io/v1alpha1",
            "kind": "ClusterGenerator", "name": generator,
        }}}],
    })
    obj["metadata"]["annotations"] = {"kustomize.toolkit.fluxcd.io/prune": "disabled"}
    return obj


def consumer(namespace, name, key):
    template = {"data": {"password": "{{ .password }}"}}
    if key.startswith("db-"):
        username = "spike_a" if key == "db-a" else "spike_b"
        template["data"]["username"] = username
        if namespace == "spike-cnpg":
            template["type"] = "kubernetes.io/basic-auth"
            template["metadata"] = {"labels": {"cnpg.io/reload": "true"}}
        else:
            template["data"]["DATABASE_URL"] = "postgresql://" + username + ":{{ .password | urlquery }}@spike-db-rw.spike-cnpg/postgres"
    if key == "rotation":
        template["data"]["dsn"] = "prefix:{{ .password }}:suffix"
    return resource("ExternalSecret", name, namespace, spec={
        "refreshPolicy": "Periodic", "refreshInterval": "2s",
        "secretStoreRef": {"kind": "SecretStore", "name": "homelab"},
        "target": {"name": name, "creationPolicy": "Owner", "template": template},
        "data": [{"secretKey": "password", "remoteRef": {"key": key, "property": "password"}}],
    })


def exercise(kubectl):
    def k(*args, data=None, check=True):
        return run([*kubectl, *args], data=data, check=check)

    def apply(obj):
        payload = json.dumps(obj)
        k("apply", "--server-side", "--dry-run=server", "-f", "-", data=payload)
        k("apply", "--server-side", "-f", "-", data=payload)

    def get(kind, name, namespace):
        result = k("get", kind, name, "-n", namespace, "-o", "json", "--ignore-not-found")
        return json.loads(result.stdout) if result.stdout.strip() else {}

    def value(namespace, name, key="password"):
        encoded = get("secret", name, namespace).get("data", {}).get(key)
        return base64.b64decode(encoded).decode() if encoded else None

    def ready(kind, name, namespace):
        return any(c["type"] == "Ready" and c["status"] == "True"
                   for c in get(kind, name, namespace).get("status", {}).get("conditions", []))

    def sar(namespace, account, target_ns, verb, res, name=None, subresource=None):
        attrs = {"namespace": target_ns, "verb": verb, "resource": res, "group": ""}
        if name:
            attrs["name"] = name
        if subresource:
            attrs["subresource"] = subresource
        obj = resource("SubjectAccessReview", "")
        obj.pop("metadata")
        obj["spec"] = {
            "user": f"system:serviceaccount:{namespace}:{account}",
            "groups": ["system:authenticated", "system:serviceaccounts", f"system:serviceaccounts:{namespace}"],
            "resourceAttributes": attrs,
        }
        return json.loads(k("create", "-f", "-", "-o", "json", data=json.dumps(obj)).stdout)["status"]["allowed"]

    for namespace in [SOURCE, *READERS]:
        obj = resource("Namespace", namespace)
        obj["metadata"]["labels"] = {"pod-security.kubernetes.io/enforce": "restricted"}
        apply(obj)
    apply(resource("ClusterGenerator", "password-32", spec={
        "kind": "Password", "generator": {"passwordSpec": {
            "length": 32, "digits": 8, "symbols": 0, "allowRepeat": True,
        }},
    }))
    apply(resource("ClusterGenerator", "outline-key-64-hex", spec={
        "kind": "Password", "generator": {"passwordSpec": {
            "length": 64, "digits": 0, "symbols": 64,
            "symbolCharacters": "0123456789abcdef", "allowRepeat": True,
            "encoding": "raw",
        }},
    }))
    apply(source("outline-key", generator="outline-key-64-hex"))
    eventually("Outline key generated", lambda: ready("externalsecret", "outline-key", SOURCE))
    passed("Outline key matches pinned application's 64-hex format",
           re.fullmatch(r"[0-9a-f]{64}", value(SOURCE, "outline-key") or "") is not None)
    for namespace, allowed in READERS.items():
        for account in ["store-reader", "application"]:
            apply(resource("ServiceAccount", account, namespace, automountServiceAccountToken=False))
        apply(resource("Role", f"read-{namespace}", SOURCE, rules=[{
            "apiGroups": [""], "resources": ["secrets"], "resourceNames": allowed, "verbs": ["get"],
        }]))
        apply(resource("RoleBinding", f"read-{namespace}", SOURCE,
                       roleRef={"apiGroup": "rbac.authorization.k8s.io", "kind": "Role", "name": f"read-{namespace}"},
                       subjects=[{"kind": "ServiceAccount", "name": "store-reader", "namespace": namespace}]))
        apply(resource("Role", "eso-store-token", namespace, rules=[{
            "apiGroups": [""], "resources": ["serviceaccounts/token"],
            "resourceNames": ["store-reader"], "verbs": ["create"],
        }]))
        apply(resource("RoleBinding", "eso-store-token", namespace,
                       roleRef={"apiGroup": "rbac.authorization.k8s.io", "kind": "Role", "name": "eso-store-token"},
                       subjects=[{"kind": "ServiceAccount", "name": "external-secrets", "namespace": "external-secrets"}]))
        apply(resource("SecretStore", "homelab", namespace, spec={"provider": {"kubernetes": {
            "remoteNamespace": SOURCE,
            "server": {"caProvider": {"type": "ConfigMap", "name": "kube-root-ca.crt", "key": "ca.crt"}},
            "auth": {"serviceAccount": {"name": "store-reader"}},
        }}}))
        eventually(f"{namespace} store Ready", lambda ns=namespace: ready("secretstore", "homelab", ns))
        passed(f"{namespace}: SA auth + get/resourceNames store Ready")

    passed("App SA cannot read source", not sar("spike-app-a", "application", SOURCE, "get", "secrets", "db-a"))
    passed("Store SA cannot list source", not sar("spike-app-a", "store-reader", SOURCE, "list", "secrets"))
    passed("Store SA cannot read foreign DB", not sar("spike-app-a", "store-reader", SOURCE, "get", "secrets", "db-b"))
    passed("ESO can mint store token", sar("external-secrets", "external-secrets", "spike-app-a", "create", "serviceaccounts", "store-reader", "token"))
    passed("ESO cannot mint application token", not sar("external-secrets", "external-secrets", "spike-app-a", "create", "serviceaccounts", "application", "token"))

    for name in ["db-a", "db-b", "oidc-a", "oidc-b", "lifecycle"]:
        apply(source(name))
        eventually(f"generate {name}", lambda n=name: ready("externalsecret", n, SOURCE) and value(SOURCE, n) is not None)
    passed("Same generator produces distinct source values", value(SOURCE, "db-a") != value(SOURCE, "db-b"))
    generated = get("secret", "db-a", SOURCE)
    passed("Generated source immutable, orphaned and prune-protected",
           generated.get("immutable") is True and not generated["metadata"].get("ownerReferences")
           and generated["metadata"].get("annotations", {}).get("kustomize.toolkit.fluxcd.io/prune") == "disabled")
    for namespace, allowed in READERS.items():
        for key in allowed:
            if key == "rotation":
                continue
            expected = value(SOURCE, key)
            if not expected:
                raise RuntimeError(f"Missing source {key}")
            apply(consumer(namespace, key, key))
            eventually(f"copy {namespace}/{key}", lambda ns=namespace, key=key, expected=expected: value(ns, key) == expected)
            passed(f"{namespace}/{key}: exact shared source value")
            if namespace.startswith("spike-app") and key.startswith("db-"):
                username = "spike_a" if key == "db-a" else "spike_b"
                passed(f"{namespace}/{key}: correct username/password in DB URL", value(namespace, key, "DATABASE_URL") == f"postgresql://{username}:{expected}@spike-db-rw.spike-cnpg/postgres")

    # ESO 2.15 sanitizes provider failures in status and Events. Verify the
    # controller's actual API denial in its logs without printing log contents.
    for name, find in [("forbidden-name", False), ("forbidden-find", True)]:
        obj = consumer("spike-app-a", name, "db-b")
        resource_denial = 'secrets "db-b" is forbidden:' if not find else "secrets is forbidden:"
        verb = "list" if find else "get"
        expected_denial = (
            f'{resource_denial} User "system:serviceaccount:spike-app-a:store-reader" '
            f'cannot {verb} resource "secrets" in API group "" in the namespace "{SOURCE}"'
        )
        if find:
            obj["spec"].pop("data")
            obj["spec"]["target"].pop("template")
            obj["spec"]["dataFrom"] = [{"find": {"name": {"regexp": ".*"}}}]
        apply(obj)

        def denied():
            conditions = get("externalsecret", name, "spike-app-a").get("status", {}).get("conditions", [])
            if not any(c["type"] == "Ready" and c["status"] == "False"
                       and c.get("reason") == "SecretSyncedError" for c in conditions):
                return False
            logs = k("logs", "-n", "external-secrets", "deployment/external-secrets").stdout
            for line in logs.splitlines():
                try:
                    entry = json.loads(line)
                except json.JSONDecodeError:
                    continue
                if (entry.get("namespace") == "spike-app-a" and entry.get("name") == name
                        and expected_denial in entry.get("error", "")):
                    return True
            return False

        eventually(f"{name}: API forbids source {verb}", denied)
        passed(f"{name}: ESO rejects read and creates no secret", not get("secret", name, "spike-app-a"))

    expected = value(SOURCE, "db-a")
    apply(consumer("spike-app-a", "allowed-control", "db-a"))
    eventually("same store still copies allowed db-a", lambda: expected is not None
               and value("spike-app-a", "allowed-control") == expected)
    passed("Same store still copies allowed source after both denials")

    # Import an existing synthetic data-encryption key; never regenerate it.
    imported = "synthetic-existing-data-key"
    apply(resource("Secret", "adopted-bare", SOURCE, stringData={"password": imported}))
    apply(source("adopted-bare"))
    eventually("bare import Ready", lambda: ready("externalsecret", "adopted-bare", SOURCE))
    passed("Immutable adoption skips template metadata: protection must precede adoption",
           value(SOURCE, "adopted-bare") == imported
           and not get("secret", "adopted-bare", SOURCE)["metadata"].get("annotations", {}).get("kustomize.toolkit.fluxcd.io/prune"))
    imported_secret = resource("Secret", "adopted", SOURCE, stringData={"password": imported})
    imported_secret["metadata"]["annotations"] = {"kustomize.toolkit.fluxcd.io/prune": "disabled"}
    apply(imported_secret)
    apply(source("adopted"))
    eventually("adopted Ready", lambda: ready("externalsecret", "adopted", SOURCE))
    adopted = get("secret", "adopted", SOURCE)
    passed("Existing value preserved and made immutable", value(SOURCE, "adopted") == imported and adopted.get("immutable") is True)
    passed("Adopted source has no ownerReference", not adopted["metadata"].get("ownerReferences"))
    passed("Imported source retains directly set prune protection", adopted["metadata"].get("annotations", {}).get("kustomize.toolkit.fluxcd.io/prune") == "disabled")
    k("delete", "externalsecret", "adopted", "-n", SOURCE)
    passed("Orphan survives ExternalSecret deletion", value(SOURCE, "adopted") == imported)
    apply(source("adopted"))
    eventually("adopted recreated ES Ready", lambda: ready("externalsecret", "adopted", SOURCE))
    passed("ExternalSecret recreation preserves imported value", value(SOURCE, "adopted") == imported)
    patch = json.dumps({"data": {"password": base64.b64encode(b"must-not-replace").decode()}})
    result = k("patch", "secret", "adopted", "-n", SOURCE, "--type=merge", "-p", patch, check=False)
    passed("API rejects immutable data update", result.returncode != 0 and "immutable" in result.stderr and value(SOURCE, "adopted") == imported)

    old = value(SOURCE, "lifecycle")
    k("delete", "secret", "lifecycle", "-n", SOURCE)
    k("annotate", "externalsecret", "lifecycle", "-n", SOURCE, f"force-sync={time.time_ns()}", "--overwrite")
    time.sleep(10)
    passed("CreatedOnce/Orphan: missing source stays absent over 10s after refresh request", not get("secret", "lifecycle", SOURCE))
    passed("CreatedOnce/Orphan may report Ready while source is absent", ready("externalsecret", "lifecycle", SOURCE))
    k("delete", "externalsecret", "lifecycle", "-n", SOURCE)
    apply(source("lifecycle"))
    eventually("source + ES loss generates new value", lambda: value(SOURCE, "lifecycle") is not None)
    passed("Losing source AND ES status regenerates value", value(SOURCE, "lifecycle") != old)

    apply(source("merge-lifecycle", policy="CreateOrMerge"))
    eventually("CreateOrMerge Ready", lambda: ready("externalsecret", "merge-lifecycle", SOURCE))
    old = value(SOURCE, "merge-lifecycle")
    k("delete", "secret", "merge-lifecycle", "-n", SOURCE)
    k("annotate", "externalsecret", "merge-lifecycle", "-n", SOURCE, f"force-sync={time.time_ns()}", "--overwrite")
    eventually("CreateOrMerge regenerates", lambda: value(SOURCE, "merge-lifecycle") not in [None, old])
    passed("CreateOrMerge regenerates after source deletion; differs from Orphan")

    apply(resource("Secret", "rotation", SOURCE, stringData={"password": "synthetic-before"}))
    apply(consumer("spike-app-a", "rotation", "rotation"))
    eventually("initial template", lambda: value("spike-app-a", "rotation", "dsn") == "prefix:synthetic-before:suffix")
    apply(resource("Secret", "rotation", SOURCE, stringData={"password": "synthetic-after"}))
    eventually("template refresh", lambda: value("spike-app-a", "rotation", "dsn") == "prefix:synthetic-after:suffix")
    passed("Periodic consumer re-renders template after source change")

    # Same inline managed.roles contract as production, in a brand-new test DB.
    apply(resource("Cluster", "spike-db", "spike-cnpg", spec={
        "instances": 1, "storage": {"size": "1Gi"},
        "resources": {"requests": {"cpu": "50m", "memory": "128Mi"}, "limits": {"memory": "512Mi"}},
        "managed": {"roles": [{"name": "spike_a", "login": True, "passwordSecret": {"name": "db-a"}}]},
    }))
    eventually("CNPG Ready", lambda: ready("cluster", "spike-db", "spike-cnpg"), timeout=300)
    primary = get("cluster", "spike-db", "spike-cnpg")["status"]["currentPrimary"]

    def login(password):
        # TCP forces password auth. A NEW psql process per attempt avoids stale sessions.
        result = k("exec", "-i", primary, "-n", "spike-cnpg", "-c", "postgres", "--",
                   "sh", "-c", 'IFS= read -r PGPASSWORD; export PGPASSWORD; export PGCONNECT_TIMEOUT=5; exec psql -XAtw -h spike-db-rw -U spike_a -d postgres -c "SELECT current_user"',
                   data=password + "\n", check=False)
        return result

    old = value(SOURCE, "db-a")
    eventually("initial CNPG password login", lambda: login(old).returncode == 0)
    passed("CNPG inline managed.roles accepts generated DB password", login(old).stdout.strip() == "spike_a")
    changed_at = time.monotonic()
    replacement = secrets.token_hex(16)
    # Controlled rotation of a TEST source. Orphan keeps ES deletion unrelated.
    k("delete", "secret", "db-a", "-n", SOURCE)
    rotated_secret = resource("Secret", "db-a", SOURCE, immutable=True, stringData={"password": replacement})
    rotated_secret["metadata"]["annotations"] = {"kustomize.toolkit.fluxcd.io/prune": "disabled"}
    apply(rotated_secret)
    for namespace in ["spike-app-a", "spike-cnpg"]:
        eventually(f"rotated copy in {namespace}", lambda ns=namespace: value(ns, "db-a") == replacement)
    eventually("CNPG accepts new password", lambda: login(replacement).returncode == 0)
    passed(f"CNPG password rotation observed in {time.monotonic() - changed_at:.1f}s", login(replacement).stdout.strip() == "spike_a")
    rejected = login(old)
    passed("Old DB password rejected on fresh TCP connection", rejected.returncode != 0 and "password authentication failed" in rejected.stderr)
    passed("App DB URL re-rendered with rotated password", replacement in value("spike-app-a", "db-a", "DATABASE_URL"))


def main():
    # Helm env flags can override even an explicit kubeconfig/context.
    for name in list(os.environ):
        if name.startswith("HELM_KUBE"):
            del os.environ[name]
    os.environ["HELM_DRIVER"] = "secret"
    os.environ.pop("HELM_DRIVER_SQL_CONNECTION_STRING", None)
    for command in ["kind", "kubectl", "helm", "yq"]:
        if not shutil.which(command):
            raise RuntimeError(f"Missing {command}; run inside nix develop")
    # Use the same CNPG versions as the repo, with spike-only Helm values.
    cnpg_release = Path(__file__).resolve().parents[1] / "infrastructure/base/database/cnpg/helmrelease.yaml"
    chart_version, image_tag = json.loads(run([
        "yq", "-o=json", "[.spec.chart.spec.version, .spec.values.image.tag]", str(cnpg_release),
    ]).stdout)
    if not all(isinstance(version, str) and version for version in (chart_version, image_tag)):
        raise RuntimeError("CNPG HelmRelease must specify both chart version and image tag")
    # Never reuse a caller-supplied cluster, name or kubeconfig.
    select_local_runtime()
    cluster = "eso-spike-" + secrets.token_hex(16)
    existing = run(["kind", "get", "clusters", "--quiet"], timeout=30)
    if cluster in existing.stdout.splitlines():
        raise RuntimeError("Random Kind cluster name already exists")
    context = "kind-" + cluster
    with tempfile.TemporaryDirectory(prefix="homelab-eso-spike-") as directory:
        config = str(Path(directory) / "kubeconfig")
        os.environ["KUBECONFIG"] = config
        kubectl = ["kubectl", "--kubeconfig", config, "--context", context]
        helm = ["helm", "--kubeconfig", config, "--kube-context", context]
        print(f"Create disposable {cluster}: K8s 1.36.4, ESO {ESO_VERSION}, CNPG {image_tag} (chart {chart_version})", flush=True)
        try:
            run(["kind", "create", "cluster", "--name", cluster, "--image", NODE_IMAGE,
                 "--kubeconfig", config, "--wait", "180s"], timeout=600)
            version = json.loads(run([*kubectl, "version", "-o", "json"]).stdout)["serverVersion"]["gitVersion"]
            print(f"Server {version}; own kubeconfig/context confirmed", flush=True)
            for release, chart, repo, namespace, version, extra in [
                ("external-secrets", "external-secrets", "https://charts.external-secrets.io", "external-secrets", ESO_VERSION,
                 ["--set", "rbac.serviceAccountTokenCreate=false", "--set", "processClusterStore=false"]),
                ("cnpg", "cloudnative-pg", "https://cloudnative-pg.github.io/charts", "cnpg-system", chart_version,
                 ["--set-string", f"image.tag={image_tag}"]),
            ]:
                print(f"Install {chart} {version}", flush=True)
                run([*helm, "install", release, chart, "--repo", repo, "--version", version,
                     "--namespace", namespace, "--create-namespace", "--wait", "--timeout", "5m", *extra], timeout=360)
            exercise(kubectl)
            print(f"{PASSED} checks passed. Still untested: Flux prune, Velero restore, production Cilium.", flush=True)
        except Exception:
            if Path(config).exists():
                diagnostic = run([*kubectl, "get", "pods", "-A"], check=False)
                print(diagnostic.stdout, flush=True)
            raise
        finally:
            try:
                result = run(["kind", "delete", "cluster", "--name", cluster, "--kubeconfig", config], check=False)
            except subprocess.TimeoutExpired as error:
                raise RuntimeError(f"Cleanup timed out; delete ONLY kind cluster {cluster}") from error
            if result.returncode:
                raise RuntimeError(f"Cleanup failed; delete ONLY kind cluster {cluster}")
            print(f"Deleted disposable {cluster}", flush=True)


if __name__ == "__main__":
    signal.signal(signal.SIGTERM, lambda signum, frame: sys.exit(128 + signum))
    main()
