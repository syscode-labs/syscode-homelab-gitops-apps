# GitOps layering: base → type → cluster

How apps and config are layered across clusters. One Argo CD, hosted in
`unraid-lab`; `oci-lab` is reconciled remotely through a registered external
cluster (see Current state / TODO below).

## Bootstrap

Talos `inlineManifests` on unraid-lab install Argo CD and seed **three roots**:

- **`apps`** (ApplicationSet) — syncs `apps/*`, `types/<type>/apps/*`,
  `clusters/<name>/apps/*`. The **chart-apps**, values layered. Covers BOTH
  clusters; oci-lab Applications target the registered `oci-lab` cluster.
- **`bootstrap`** (Application) — syncs `bootstrap/`. Shared raw manifests
  (tailscale operator).
- **`unraid-raw`** (Application) — syncs
  `clusters/unraid-lab/apps/*/application.yaml`. **Custom ApplicationSets**
  and raw apps, including the oci-* lanes below.

On oci-lab, `inlineManifests` bootstrap **Cilium only** (plus the
`argocd-manager` service account unraid's Argo authenticates as) — no local
Argo CD. Three unraid-hosted Applications reconcile it:
`oci-cluster-registration`, `oci-raw` (`clusters/oci-lab/apps/*/application.yaml`),
`oci-bootstrap` (`bootstrap/` tailscale manifests).

Chart-app lane keys on **`app.yaml`**; raw lane keys on **`application.yaml`** —
so the two never double-manage an app in the same directory.

## Two axes

**Selection — which apps run where** (by directory):

- `apps/<app>/app.yaml` — every cluster
- `types/<type>/apps/<app>/app.yaml` — every cluster of that type
- `clusters/<name>/apps/<app>/app.yaml` — one cluster

**Values — override anything the chart exposes** (deep-merge `valueFiles`, later wins):

```text
values/base/<app>.yaml
values/types/<type>/<app>.yaml       # optional
values/clusters/<name>/<app>.yaml    # optional
```

Maps deep-merge; you write only the keys you change. (Lists replace, not merge —
Helm semantics.)

## Overriding "anything"

- **chart value** → add/patch a value file at the right layer. 99% of cases.
- **Argo `Application` field** (targetRevision, syncPolicy, …) → a kustomize
  strategic-merge patch on the generated Application.
- **rendered chart internal not exposed as a value** → the rare escape hatch: a
  kustomize post-render / SMP on the chart output. Brittle (pinned to the chart's
  internal names) — use sparingly.

## `app.yaml` shape

```yaml
chart: harbor
repoURL: https://helm.goharbor.io   # or an OCI registry for OCI charts
version: "1.15.1"
namespace: harbor
```

The `apps` ApplicationSet reads these + the cluster identity and templates one
Argo Application per app, with the layered `valueFiles`.

## Adding / changing

- **new app everywhere** → `apps/<x>/app.yaml` + `values/base/<x>.yaml`.
- **app on one cluster** → `clusters/<name>/apps/<x>/app.yaml`.
- **override a value on one cluster** → `values/clusters/<name>/<x>.yaml`.
- **custom ApplicationSet** (own generators, e.g. runners) → `application.yaml`
  under `clusters/<name>/apps/<x>/` (raw lane).

## Current state / TODO

- `appset.yaml` (repo root) is the canonical ApplicationSet. It is hosted ONCE,
  in unraid-lab's Argo CD (injected via unraid-lab's `inlineManifests`), and
  covers BOTH clusters: static `unraid-lab`/`oci-lab` list elements; the
  `destination` template targets the in-cluster server for unraid-lab and the
  registered external cluster `name: oci-lab` for OCI.
- `oci-lab` runs NO local Argo CD. Its inline manifests bootstrap Cilium plus
  the `argocd-manager` service account only. unraid-lab's Argo reconciles it
  through the registered external cluster:
  `clusters/unraid-lab/apps/oci-cluster-registration` (ExternalSecret →
  argocd cluster Secret; endpoint is the private VPN-subnet API address),
  `oci-raw` (raw lane for `clusters/oci-lab/apps/*/application.yaml`),
  `oci-bootstrap` (tailscale-* manifests from `bootstrap/`).
- `unraid-lab` is validated: all Argo CD Applications are **Synced** and **Healthy**.
- **OCI not yet bootstrapped.** First bootstrap happens after these changes
  land; validate app sync after cluster registration (see
  centralize-oci-gitops-and-node-dns in syscode-ai-internal-plans).
- Migrated: cert-manager, cilium (shared, `apps/`); harbor, arc-controller
  (unraid-only, `clusters/unraid-lab/apps/`). arc-runners stays a custom
  ApplicationSet on the raw lane.
