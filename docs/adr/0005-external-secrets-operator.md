# ADR 0005: External Secrets Operator

Status: accepted for the platform rollout. Credential migration follows the
[ESO proposal](../proposals/eso-generated-secrets.md).

Flux deploys the ESO HelmRelease through `infra-eso` after networking is ready.
`infra-secrets` waits for the release and establishes `secret-source` and the
shared password generator. Existing app and database dependency chains are
independent until a consumer needs ESO.

ESO runs in a restricted namespace with the shared NetworkPolicy baseline and
API egress. The cluster host-network policy covers admission webhook traffic.
Push and cluster-wide store/consumer reconcilers are disabled. A consumer uses
a local SecretStore and a dedicated service account. Explicit source object
names restrict its reads and ESO can mint a token only for a delegated account.

The Kubernetes provider uses Kubernetes RBAC. Existing privileged operators,
backup tooling, cluster administrators and identities that can edit arbitrary
workloads are in the cluster trust boundary. Review these grants before storing
real credentials. A local store allowlist does not narrow other identities'
existing rights.

Keep the source namespace and data-bound keys through a rollback. The namespace
has a Flux prune opt-out because deleting a namespace would also delete Secrets
with individual prune protection. For a platform-only rollback revert the
install commit through GitOps and verify ESO workloads and webhooks are removed.
The Helm release owns the ESO CRDs. Uninstall can delete the custom resources
and their owned Secret copies. After onboarding consumers, retain the
HelmRelease until the migration back to a working credential source has been
verified.
