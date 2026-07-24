# Deploy runbook

Ordered steps to bring up the two clusters from this repo. Steps 1–2 and 6 are
in-repo (commit them); the rest run against real clusters and need secret
material you hold. Do not skip the pre-merge gate (step 5).

Clusters:

- `oci-talos` — type `cloud`, bootstraps its own Cilium (CNI-none Talos).
- `unraid-lab` — type `homelab-kvm`, no inline Cilium.

## 1. Fill placeholders

Edit `values/base/harbor.yaml`: replace both `harbor.<tailnet>.ts.net` with the
cluster's real MagicDNS name. Nothing else in `values/` carries a placeholder.

## 2. Generate inline-manifests, commit

Fills each cluster's `argocd` (install), `argocd-apps` (appset with that
cluster's identity), and — OCI only — `cilium` block:

```bash
mise run oci:generate-manifests
mise run unraid:generate-manifests
git add omni/patches/inline-manifests.yaml clusters/unraid-lab/omni/inline-manifests.yaml
git commit -m "chore: generate inline-manifests for deploy"
```

Version pins live in `omni/scripts/generate-manifests.sh` (`ARGOCD_VERSION`,
`CILIUM_VERSION`) — override via env to bump.

## 3. Bootstrap the clusters (Omni)

Apply the Talos machine config with the generated patch through Omni. On first
control-plane boot Talos applies the inline-manifests: Argo CD installs, then the
seeded root Applications pull the rest of this repo:

- `argocd-apps` — the layering ApplicationSet (chart-apps, values `base → type → cluster`).
- `argocd-bootstrap` — syncs `bootstrap/` (Tailscale operator).
- `argocd-unraid-raw` (unraid only) — syncs `clusters/unraid-lab/apps/*/application.yaml` (arc-runners).

## 4. Create in-cluster secrets

Apps stay `Progressing` until these exist. `harbor-mirror-robot` depends on
Harbor being up (step 7) — create it there, not here.

- `harbor-admin-password` — ns `harbor`, key `HARBOR_ADMIN_PASSWORD`.
- `arc-gha-secret` — ns `arc-runners`, the GitHub App credentials
  (`github_app_id`, `github_app_installation_id`, `github_app_private_key`).

Generate the App private key yourself; never commit any of these.

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
