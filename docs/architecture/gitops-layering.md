# GitOps layering: base → type → cluster

How apps and config are layered across clusters. Self-managed Argo CD (each
cluster runs its own), no central hub.

## Bootstrap

Talos `inlineManifests` (per cluster) install Argo CD, then seed **three roots**.
The only per-cluster difference is the cluster's identity (`clusterName`,
`clusterType`), baked into the seeded `appset`.

- **`apps`** (ApplicationSet) — syncs `apps/*`, `types/<type>/apps/*`,
  `clusters/<name>/apps/*`. The **chart-apps**, values layered.
- **`bootstrap`** (Application) — syncs `bootstrap/`. Shared raw manifests
  (tailscale operator).
- **`<cluster>-raw`** (Application) — syncs
  `clusters/<name>/apps/*/application.yaml`. **Custom ApplicationSets** that
  aren't chart-apps (arc-runners).

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

## Current state / TODO before merge

- `appset.yaml` (repo root) is the canonical ApplicationSet; the generate step
  injects it into each cluster's `inlineManifests` with that cluster's identity.
  The `argocd` + `argocd-apps` inline blocks are still placeholders (filled by
  `mise run <cluster>:generate-manifests`) — wire the appset injection into that
  script.
- **Not cluster-validated.** Needs a real sync on `unraid-lab` (once Argo CD is
  bootstrapped there) + a no-op re-sync check on OCI before this replaces the
  live setup.
- Migrated: cert-manager, cilium (shared, `apps/`); harbor, arc-controller
  (unraid-only, `clusters/unraid-lab/apps/`). arc-runners stays a custom
  ApplicationSet on the raw lane.
