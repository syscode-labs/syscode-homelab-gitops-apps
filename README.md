# syscode-homelab-gitops-apps

[![CI](https://github.com/syscode-labs/syscode-homelab-gitops-apps/actions/workflows/ci.yml/badge.svg)](https://github.com/syscode-labs/syscode-homelab-gitops-apps/actions/workflows/ci.yml)
[![Reconcile derived versions](https://github.com/syscode-labs/syscode-homelab-gitops-apps/actions/workflows/reconcile.yml/badge.svg)](https://github.com/syscode-labs/syscode-homelab-gitops-apps/actions/workflows/reconcile.yml)

> Active migration. `unraid-lab` validated (all Applications Synced/Healthy);
> `oci-lab` not yet re-validated — see
> [docs/architecture/gitops-layering.md](docs/architecture/gitops-layering.md#current-state--todo).

The apps running on the Syscode homelab Kubernetes clusters, and their config.
Argo CD (self-managed, hosted in `unraid-lab`) watches this repo and applies
changes automatically — no manual `kubectl apply`. It also reconciles
`oci-lab` remotely through a registered external cluster; `oci-lab` runs no
Argo CD of its own.

## Apps

**Shared — every cluster:**

| App | Chart | Role |
| --- | --- | --- |
| [cert-manager](apps/cert-manager/app.yaml) | jetstack/cert-manager | TLS certificate issuance |
| [cilium](apps/cilium/app.yaml) | cilium/cilium | pod networking (CNI) |
| [radar](apps/radar/app.yaml) | skyhook-io/radar | Radar app, tailnet-private on every cluster |

Each cluster also runs its own `app.yaml`s under `clusters/<name>/apps/`
(not shared — set up independently per cluster, so the same app can appear
on more than one):

**`unraid-lab`:**

| App | Chart / source | Role |
| --- | --- | --- |
| [harbor](clusters/unraid-lab/apps/harbor/) | goharbor/harbor | container registry backing the Image Factory |
| [arc-controller](clusters/unraid-lab/apps/arc-controller/) | actions/gha-runner-scale-set-controller | GitHub Actions Runner Controller |
| [arc-runners](clusters/unraid-lab/apps/arc-runners/) | ARC runner scale set (ApplicationSet) | self-hosted GH Actions runners, Harbor↔GHCR mirror + homelab jobs |
| [external-secrets](clusters/unraid-lab/apps/external-secrets/) | vendored external-secrets | ESO plus Bitwarden SDK server |
| [radar-pg](clusters/unraid-lab/apps/radar-pg/) | syscode-labs/radar-postgre | radar's Postgres backend |
| [argocd-ingress](clusters/unraid-lab/apps/argocd-ingress/) | raw manifest | tailscale ingress for the Argo CD UI |
| [hubble-proxyclass](clusters/unraid-lab/apps/hubble-proxyclass/) | raw manifest | kernel-network ProxyClass for the hubble-ui tailscale ingress proxy |

**`oci-lab`:**

| App | Chart / source | Role |
| --- | --- | --- |
| [external-secrets](clusters/oci-lab/apps/external-secrets/) | vendored external-secrets | ESO plus Bitwarden SDK server |
| [oci-pivot-controller](clusters/oci-lab/apps/oci-pivot-controller/) | ghcr.io/syscode-labs/charts | OCI free-tier node lifecycle controller |
| [oci-pivot-secrets](clusters/oci-lab/apps/oci-pivot-secrets/) | raw manifest | `ExternalSecret` feeding oci-pivot-controller's OCI credentials |

## Adding or changing an app

1. Every cluster: `apps/<app-name>/app.yaml` (chart + repo + version) +
   `values/base/<app-name>.yaml` (chart values).
2. One cluster only: same two files under `clusters/<name>/apps/<app-name>/`
   and `values/clusters/<name>/<app-name>.yaml`.
3. Commit — Argo CD picks it up on its next sync, no manual step.

Node bootstrap, the ApplicationSet mechanics, and the values-layering rules
live in [docs/architecture/gitops-layering.md](docs/architecture/gitops-layering.md);
cluster bring-up steps are in [docs/deploy/runbook.md](docs/deploy/runbook.md).
