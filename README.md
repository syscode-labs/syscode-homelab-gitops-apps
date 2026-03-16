# oci-talos-gitops-apps

Argo CD GitOps applications for the OCI free-tier Talos cluster (4× Ampere A1.Flex).

Nodes are provisioned by [oci-free-tier-manager](https://github.com/syscode-labs/oci-free-tier-manager) and enrolled into Omni via SideroLink.

## Bootstrap

Argo CD and Cilium are bootstrapped via Talos `cluster.inlineManifests` — no manual install step.
On first boot, the App-of-Apps in `bootstrap/argocd-app-of-apps.yaml` is applied automatically.

## Structure

```text
bootstrap/              App-of-Apps + manually bootstrapped apps (Argo CD, Tailscale operator)
infrastructure/         Helm charts + values, one directory per app
clusters/oci/           Cluster-specific kustomize patches
omni/                   Omni machine classes, patches, and cluster templates
```

## Adding an app

1. Add an `Application` CRD to `bootstrap/<app-name>.yaml`
2. Add config/values to `infrastructure/<app-name>/`
3. Commit — Argo CD auto-syncs
