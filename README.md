# syscode-homelab-gitops-apps

Argo CD GitOps applications for Syscode homelab Kubernetes clusters.

The current OCI cluster nodes are provisioned by [oci-free-tier-manager](https://github.com/syscode-labs/oci-free-tier-manager), join Tailscale on first boot with `NODES_TAILSCALE_AUTHKEY`, and enroll into Omni through the normal Omni/Talos flow.
`NODES_TAILSCALE_AUTHKEY` is a provisioner secret; commit only the variable name, never the value.

## Bootstrap

Argo CD and Cilium are bootstrapped via Talos `cluster.inlineManifests` — no manual install step.
On first boot, the inline root Argo CD Application syncs `bootstrap/`; `bootstrap/argocd-app-of-apps.yaml` then syncs `infrastructure/*/application.yaml`.
The `omni/` directory is consumed by Omni tooling, not Argo CD.

## Structure

```text
bootstrap/              Root-synced Argo CD apps, including App-of-Apps and Tailscale operator
infrastructure/         Helm charts + values, one directory per app
clusters/oci/           Cluster-specific kustomize patches
omni/                   Omni machine classes, patches, and cluster templates
```

## Adding an app

1. Add an `Application` CRD to `infrastructure/<app-name>/application.yaml`
2. Add config/values to `infrastructure/<app-name>/`
3. Commit — Argo CD auto-syncs
