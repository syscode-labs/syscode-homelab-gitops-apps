# syscode-homelab-gitops-apps

> Active migration. `unraid-lab` validated (all Applications Synced/Healthy);
> `oci-lab` not yet re-validated against this layering — see
> [docs/architecture/gitops-layering.md](docs/architecture/gitops-layering.md#current-state--todo).

Config that tells each homelab Kubernetes cluster which apps to run and how to
configure them, applied automatically whenever this repo changes.

## Stack

| Tool | Role |
| --- | --- |
| [Talos](https://www.talos.dev/) | OS + Kubernetes distro on every node |
| [Omni](https://omni.siderolabs.com/) | provisions/enrolls Talos nodes, seeds their inline manifests |
| [Argo CD](https://argo-cd.readthedocs.io/) | watches this repo, applies changes to each cluster (self-managed, one per cluster) |
| [Cilium](https://cilium.io/) | pod networking (CNI) |
| [Tailscale operator](https://tailscale.com/kb/1236/kubernetes-operator) | tailnet ingress/egress for in-cluster services |
| Helm | how each app in `apps/` is packaged |

## Getting started

Node provisioning (Tailscale join, Omni enrollment) is handled by
[oci-free-tier-manager](https://github.com/syscode-labs/oci-free-tier-manager)
for OCI; this repo starts once a node is Omni-enrolled.

```bash
mise install                      # helm, yq, kubectl, kubeconform
mise run oci-lab:generate-manifests    # or unraid:generate-manifests
```

That regenerates the cluster's Talos `inlineManifests` (Argo CD install +
the `apps` ApplicationSet, identity baked in). Commit the result, then apply
the Talos machine config through Omni — first boot bootstraps Argo CD, which
pulls the rest of this repo. Full sequence: [docs/deploy/runbook.md](docs/deploy/runbook.md).

## Day-to-day usage

Add an app to every cluster:

1. `apps/<app-name>/app.yaml` — chart + repo + version
2. `values/base/<app-name>.yaml` — chart values
3. Commit — Argo CD picks it up on its next sync, no manual step

Scope an app to one cluster type or one cluster instead of every cluster, or
override a value at one layer only: see
[docs/architecture/gitops-layering.md](docs/architecture/gitops-layering.md).

<details>
<summary>Repo layout</summary>

```text
apps/<app>/app.yaml                every cluster
types/<type>/apps/<app>/app.yaml   every cluster of that type
clusters/<name>/apps/<app>/...     one cluster (app.yaml = chart-app; application.yaml = custom ApplicationSet, raw lane)
values/base/<app>.yaml             default chart values
values/types/<type>/<app>.yaml     type-level override
values/clusters/<name>/<app>.yaml  cluster-level override
bootstrap/                         shared raw manifests (Tailscale operator, Argo CD CM patches)
omni/                              Omni machine classes, cluster templates, inline-manifest generator
appset.yaml                        canonical `apps` ApplicationSet (copied into each cluster's inline manifests)
```

</details>

<details>
<summary>Further reading</summary>

- [docs/architecture/gitops-layering.md](docs/architecture/gitops-layering.md) — bootstrap roots, selection vs. values axes, how to override anything
- [docs/deploy/runbook.md](docs/deploy/runbook.md) — ordered steps to bring up a cluster from this repo

</details>
