# Deploy runbook

Ordered steps to bring up the two clusters from this repo. Steps 1–2 and 6 are
in-repo (commit them); the rest run against real clusters and need secret
material you hold. Do not skip the pre-merge gate (step 5).

Clusters:

- `oci-lab` — type `cloud`, bootstraps its own Cilium (CNI-none Talos).
- `unraid-lab` — type `homelab-kvm`, no inline Cilium.

## 1. Confirm the Harbor endpoint

`values/base/harbor.yaml` uses `harbor.wind-bearded.ts.net`, the cluster's
Tailscale MagicDNS name. Update both the `externalURL` and ingress host together
if the tailnet domain changes.

## 2. Generate inline-manifests, commit

unraid-lab (installs Argo CD + the layering ApplicationSet, which also covers
`oci-lab`); OCI gets a Cilium-only patch plus the `argocd-manager` service
account — no Argo CD on OCI:

```bash
mise run oci-lab:generate-manifests
mise run unraid:generate-manifests
git add omni/cluster-templates/patches/oci-lab-inline-manifests.yaml clusters/unraid-lab/omni/inline-manifests.yaml
git commit -m "chore: generate inline-manifests for deploy"
```

Version pins live in `omni/scripts/generate-manifests.sh` (`ARGOCD_VERSION`,
`CILIUM_VERSION`) — override via env to bump.

## 3. Bootstrap the clusters (Omni)

Apply the Talos machine config with the generated patch through Omni.

**unraid-lab**: on first control-plane boot Talos applies the
inline-manifests: Argo CD installs, then the seeded root Applications pull the
rest of this repo:

- `argocd-apps` — the layering ApplicationSet (chart-apps; unraid-lab AND
  oci-lab destinations).
- `argocd-bootstrap` — syncs `bootstrap/` (Tailscale operator).
- `argocd-unraid-raw` — syncs `clusters/unraid-lab/apps/*/application.yaml`
  (arc-runners, plus the oci-* lanes below).

**oci-lab**: first control-plane boot applies only Cilium + the
`argocd-manager` ServiceAccount/ClusterRole/Binding. There is no Argo CD on
oci-lab; unraid-lab's Argo reconciles it once registered (step 4b).

## 4. Create in-cluster secrets

Apps stay `Progressing` until these exist. `harbor-mirror-robot` depends on
Harbor being up (step 7) — create it there, not here.

- `harbor-admin-password` — ns `harbor`, key `HARBOR_ADMIN_PASSWORD`.
- `arc-gha-secret` — ns `arc-runners`, the GitHub App credentials
  (`github_app_id`, `github_app_installation_id`, `github_app_private_key`).

Generate the App private key yourself; never commit any of these.

## 4b. Register oci-lab with unraid-lab's Argo CD

After the oci-lab cluster is up and reachable over the private path
(`unraid-lab → tailnet → wrt-london → IPSec → vpn-subnet nodeIP:6443`):

1. Grab the kube CA + build the API URL from the oci-talos-cp-1 VPN-subnet IP
   (`kubectl config view --raw` on an admin kubeconfig, or
   `omnictl cluster kubeconfig`).
2. Mint a long-lived token for `argocd-manager` (kube-system): create a Secret
   of type `kubernetes.io/service-account-token` annotated
   `kubernetes.io/service-account.name: argocd-manager`, read `token`.
3. Store `server` (the `https://<ip>:6443` URL), `ca` (base64 CA), and
   `token` in Bitwarden; put the entry's UUID into
   `clusters/unraid-lab/apps/oci-cluster-registration/manifests/external-secret.yaml`
   (replaces the placeholder keys) and commit.
4. ESO materializes Secret `oci-lab-cluster` in unraid's argocd ns; the
   `argocd.argoproj.io/secret-type: cluster` label registers the cluster.
   The `apps` ApplicationSet, `oci-raw`, and `oci-bootstrap` then sync against
   it (they sit degraded until this step).

Never commit the token or CA; they travel only through Bitwarden.

## 5. Pre-merge gate

Do not merge #17 until both pass:

- **unraid-lab**: every Argo Application `Synced` + `Healthy`
  (`argocd app list`), Harbor and arc-controller included.
- **OCI**: re-sync is a **no-op** — the restructure must not churn a running
  cluster. `argocd app diff` shows no changes.

## 6. Merge #17

The layering ApplicationSet, `validate.py`, and the generate tooling land on
`main` together once the gate is green.

## 7. Harbor post-deploy bootstrap

With Harbor reachable at its MagicDNS name:

- Create project `image-factory`.
- Create the push robot (Image Factory) and the mirror robot; store the mirror
  robot creds as secret `harbor-mirror-robot` (keys `username`, `password`) in
  ns `arc-runners` — this is what step 4 deferred.
- Wire OIDC (PocketID) per the image-factory-registry plan.

Detail: `syscode-ai-internal-plans/projects/image-factory-registry/plans/2026-07-19-harbor-ghcr-mirror.md`.

## 8. Repoint Image Factory, revoke the PAT

Apply the omni-on-unraid reconfig (points Image Factory at Harbor, drops the
`GITHUB_TOKEN`), confirm end-to-end, then revoke the GHCR PAT — last, only after
sign-off.

Detail: `syscode-ai-internal-plans/projects/image-factory-registry/handoffs/2026-07-20-omni-image-factory-reconfig.md`.

## Secrets bootstrap (unraid-lab, ESO + Bitwarden)

The provider token is secret zero. It must exist before External Secrets can
read any other Bitwarden value. The automatic path is
`omni/scripts/apply-inline-manifests.sh unraid-lab --apply`: it decrypts the
SOPS file from the sibling private `homelab-secrets` checkout, validates that it
is the expected `external-secrets/bws-token` Secret, and adds it to the same
Omni inline-manifest ConfigPatch as the Argo bootstrap. The decrypted value is
written only to a temporary file and the ConfigPatch is stored by Omni.

The default private-repository location is `../homelab-secrets` relative to
this repository. Override it with `HOMELAB_SECRETS_ROOT` when the checkouts are
elsewhere. The encrypted source remains:
`homelab-secrets/unraid-lab/bws-token.enc.yaml`.

After the cluster starts, Argo installs ESO and the Bitwarden SDK server. ESO
then uses `bws-token` to create the remaining secrets, including the Argo
cluster-registration Secret and Tailscale OAuth Secret. Re-running the command
is safe because the ConfigPatch and Kubernetes Secret are applied
idempotently.

For recovery or verification only, the equivalent manual command is:

```sh
sops -d /path/to/homelab-secrets/unraid-lab/bws-token.enc.yaml | \
  kubectl --context omni-unraid-lab -n external-secrets apply -f -
```

Never commit the decrypted file or paste the token into a terminal transcript.

## Secrets bootstrap (oci-lab, ESO + Bitwarden)

OCI runs the same vendored ESO chart and Bitwarden SDK-server plugin as
unraid-lab. Restore its existing machine-account token as
`oci-pivot-system/bw-auth-token` (key `token`) before ESO can reconcile the
`bitwarden-oci` ClusterSecretStore. The token is secret zero and stays outside
this repository; the OCI pivot compartment ID then arrives through its
ExternalSecret.

## Manual recovery record (2026-08-31)

These actions repaired resources that were already stuck outside the intended
GitOps reconciliation path. They must not be treated as regular deployment
steps.

- Removed finalizers from `argocd/unraid-lab-arc-controller`,
  `argocd/arc-runner-scale-sets`, and
  `argocd/unraid-lab-arc-runners-container` after deleting ARC from
  unraid-lab left their Argo deletion operations stuck.
- Labeled OCI worker `ampere-vnic-2-960682` with `imp/enabled=true` to enrol
  one node for the Imp agent and runtime DaemonSets. This label must be moved
  into the OCI machine's declared configuration before rebuilding or replacing
  the node.
