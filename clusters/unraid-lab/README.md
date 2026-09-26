# clusters/unraid-lab

Apps scoped to the Omni-managed **`unraid-lab`** Talos cluster. The `apps`
ApplicationSet's `clusters/<name>/apps/*/app.yaml` generator only matches
`unraid-lab`, so apps placed here run on `unraid-lab` only and never land on
OCI. Details: [docs/architecture/gitops-layering.md](../../docs/architecture/gitops-layering.md).

First apps:

- **Harbor** — backing registry for the Image Factory
  (`syscode-ai-internal-plans/projects/image-factory-registry`).
- **ARC runner scale sets** — self-hosted GitHub Actions runners for the
  Harbor↔GHCR mirror and later homelab jobs.

## Wiring (how these apps get synced)

`unraid-lab`'s Talos `inlineManifests` (generated via
`mise run unraid:generate-manifests`, see
[docs/deploy/runbook.md](../../docs/deploy/runbook.md)) install Argo CD, then
seed three roots directly — no per-cluster app-of-apps file:

- `apps` (ApplicationSet) — chart-apps, including this directory's `app.yaml`s.
- `bootstrap` (Application) — syncs `bootstrap/` (Tailscale operator, Argo CD CM patches).
- `unraid-lab-raw` (Application) — syncs `clusters/unraid-lab/apps/*/application.yaml`
  (custom ApplicationSets, e.g. `arc-runners`).

## Prerequisites / action items

- [x] **Argo CD + Tailscale operator on `unraid-lab`.** Bootstrapped via Talos
  `cluster.inlineManifests`; Tailscale operator installed
  (`bootstrap/tailscale-operator.yaml`) for the `tailscale` IngressClass + auto
  TLS. Cluster validated: all Argo CD Applications Synced/Healthy (see
  [docs/architecture/gitops-layering.md](../../docs/architecture/gitops-layering.md#current-state--todo)).
- [x] Set `values/base/harbor.yaml` to the real MagicDNS name
  (`externalURL` + `expose.ingress.hosts.core` → `harbor.wind-bearded.ts.net`).
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

## Workload placement

### The rule

The Imp node is reserved for Imp. Only Imp workloads, DaemonSets, and a short
approved list of low-demand workloads may run there. Other workloads must not
tolerate `imp.dev/runner:NoSchedule`.

Normal workloads are spread across the two general-purpose control-plane nodes.
This is deliberate: putting every workload on every node would defeat the Imp
reservation.

### Capacity budget

Use resource **requests** as the scheduler budget. Actual use is monitored
separately.

| Node class | CPU budget | Memory budget | Why |
| --- | ---: | ---: | --- |
| General-purpose control plane | 2.655 CPU (90%) | 85% of allocatable memory | Keep room for Talos and Kubernetes. |
| Imp node | 1.95 CPU | 3.96 GiB | Reserve 1 CPU and 2.2 GiB for an on-demand ImpVM. |

The Imp memory reservation is 110% of a 2 GiB VM: 2.2 GiB.

### How this will be enforced

1. Keep the existing Imp taint. Normal workloads do not tolerate it.
2. Give ImpVMs a higher priority than the reserve workload.
3. Place a preemptible reserve workload on the Imp node that requests 1 CPU and
   2.2 GiB. The scheduler then keeps that space available until an ImpVM needs
   it.
4. Add topology-spread rules to eligible low-demand workloads so replicas prefer
   different general-purpose nodes.
5. Require CPU and memory requests for every workload managed for this cluster.

This is a target policy, not a live guarantee yet. Do not change placement until
all healthy members, live usage, requests, and the rendered workload rules have
been checked.

### Before any placement change

- Confirm Omni's healthy-member count, not only Kubernetes `Ready`.
- Confirm each eligible node has no memory, disk, or process pressure.
- Check actual CPU and memory use plus requested capacity.
- Render every changed workload.
- Verify after reconciliation that no non-Imp workload has the Imp toleration or
  lands on the Imp node.
