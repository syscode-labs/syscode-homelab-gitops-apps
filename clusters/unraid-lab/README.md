# clusters/unraid-lab

Apps scoped to the Omni-managed **`unraid-lab`** Talos cluster. The repo's shared
`bootstrap/argocd-app-of-apps.yaml` only syncs `infrastructure/` (shared across
clusters); it does **not** sync `clusters/`. So apps placed here run on
`unraid-lab` only and never land on OCI.

First apps:

- **Harbor** — backing registry for the Image Factory
  (`syscode-ai-internal-plans/projects/image-factory-registry`).
- **ARC runner scale sets** — self-hosted GitHub Actions runners for the
  Harbor↔GHCR mirror and later homelab jobs.

## Wiring (how these apps get synced)

The `unraid-lab` cluster's inline root Argo CD Application (defined in its Omni
cluster template — see `omni-on-unraid` / the Omni machine config) must sync
**both**:

- `bootstrap/` — shared infra (Argo CD app-of-apps → `infrastructure/*`).
- `clusters/unraid-lab/app-of-apps.yaml` — this cluster's app-of-apps
  (→ `clusters/unraid-lab/apps/*`).

## Prerequisites / action items

- [ ] **Argo CD + Tailscale operator on `unraid-lab`.** Bootstrap Argo CD via
  Talos `cluster.inlineManifests` (as OCI does); install the Tailscale operator
  (`bootstrap/tailscale-operator.yaml`) for the `tailscale` IngressClass + auto
  TLS.
- [ ] Point the inline root Application at `clusters/unraid-lab/app-of-apps.yaml`
  (plus `bootstrap/`).
- [ ] Set the real MagicDNS name in `apps/harbor/values.yaml`
  (`externalURL` + `expose.ingress.hosts.core` → `harbor.<tailnet>.ts.net`).
- [ ] Create the `harbor-admin-password` Secret (`HARBOR_ADMIN_PASSWORD`) in the
  `harbor` namespace before first sync.
- [ ] Create the `arc-gha-secret` GitHub App Secret in the `arc-runners`
  namespace before syncing `arc-runners`.
- [ ] Create the `harbor-mirror-robot` Secret in the `arc-runners` namespace
  with `username` and `password` keys before runner pods start.

## Harbor bootstrap (post-deploy, plan decision (b): idempotent API script)

After Harbor is up, an idempotent script (a `local-exec` or k8s Job against the
Harbor API) provisions:

- Project **`image-factory`** (private).
- **Push robot** — for the Image Factory service (`omni-on-unraid`) to push
  schematics / installer / cache.
- **Read-only robot** — for the GHCR mirror job; its credential is delivered to
  the ARC runner pod as the `harbor-mirror-robot` k8s Secret (see the
  `talos-arc-kvm-unraid` handoff), NOT to GitHub secrets.
- **PocketID OIDC** for human/UI + `docker login` (`auth_mode = oidc_auth`).
- A retention policy on `installer` / `cache`.

> v1.1 (cross-project): mint the robot credentials on demand from
> [tessera](https://github.com/syscode-labs/tessera) (a Harbor create-then-delete
> Source) instead of static robots.
