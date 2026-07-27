# Design: NFS CSI storage for unraid-lab (Longhorn replacement)

**Date:** 2026-07-25
**Status:** Draft — awaiting review
**Supersedes:** the reverted Longhorn attempt (commit `8cec8fb`, reverted in `e0f3460`)

## Goal

Give the `homelab-kvm` cluster (`unraid-lab`) a **default StorageClass** so stateful
apps — Harbor's registry PVCs first — bind automatically, **without** the host/etcd
risk Longhorn carried. Cloud clusters keep their own provider CSI (per-type storage).

## Decision

Use **`csi-driver-nfs`** with PV data on an **unraid NFS export**, not Longhorn.

**Why (constraint: "don't destroy unraid", replication is unraid's job):**

- PV data lives **on unraid's parity-protected array** — that *is* the data-layer
  replication. No in-VM replicated block storage.
- **No blast radius to the host or the shared node disk:** it's a Helm chart + a
  StorageClass + an NFS mount. No iSCSI, no block devices, nothing writing to the
  nodes' EPHEMERAL/etcd disk (the real Longhorn danger, given each node has a single
  40 GB disk with no dedicated data disk).
- **No Talos image extension needed** — the NFS client is in-kernel (Longhorn needed
  `iscsi-tools`/`util-linux-tools`).
- Survives node/VM rebuild (data isn't in the VM), supports RWX.

Rejected: `local-path-provisioner` (data trapped in the ephemeral VM disk, no RWX);
`csi-driver-smb` (extra credential management; NFS is simpler on a trusted LAN);
Longhorn (replication we don't need + the risk we're avoiding).

## Environment facts (verified 2026-07-24/25)

- Nodes are on libvirt **NAT** `192.168.122.0/24`, gateway `192.168.122.1`.
- unraid `nfsd` listens on `10.10.210.59` (LAN) — **not** on `192.168.122.1`.
  Nodes reach it via the host: probe from cluster → `10.10.210.59:2049` = OPEN.
- Server address for the CSI = **`10.10.210.59`**.
- unraid already runs NFS (`shareNFSEnabled="yes"`).

## Components

1. **unraid (manual, on the host — not GitOps):** an NFS export for k8s PVs.
   - Share/path: **`/mnt/user/unraid-talos-pv-store`** (created).
   - Rule: `192.168.122.0/24(sec=sys,rw,no_root_squash) 10.10.210.0/23(sec=sys,rw,no_root_squash)`
     — `no_root_squash` is required so the provisioner can create/own per-PV subdirs.

2. **Repo — chart-app, scoped to the type** (only unraid-lab gets it):
   - `types/homelab-kvm/apps/csi-driver-nfs/app.yaml` — `chart: csi-driver-nfs`,
     `repoURL: https://raw.githubusercontent.com/kubernetes-csi/csi-driver-nfs/master/charts`,
     pinned `version:` (latest stable, e.g. `v4.11.0`), `namespace: kube-system`.
   - `values/base/csi-driver-nfs.yaml`:

     ```yaml
     storageClass:
       create: true
       name: nfs
       annotations:
         storageclass.kubernetes.io/is-default-class: "true"
       parameters:
         server: 10.10.210.59
         share: /mnt/user/unraid-talos-pv-store
       reclaimPolicy: Retain          # registry data — don't delete backing dir on PVC delete
       mountOptions:
         - nfsvers=4.1
     ```

3. **Default StorageClass** = `nfs` so Harbor's PVCs bind with no per-app change
   (same end-goal the Longhorn commit had).

## Rollout & verification

1. Fix the unraid export (see Open Issues) and confirm it appears in `exportfs -v`.
2. Merge the chart-app; Argo syncs it to unraid-lab only.
3. Verify: `csi-nfs-controller` + `csi-nfs-node` pods Ready; `kubectl get sc` shows
   `nfs (default)`; a test PVC binds and a pod can write; then Harbor's PVCs bind.

## Open issues / prerequisites (BLOCKING)

- **The export is not active.** `/mnt/user/unraid-talos-pv-store` is in `/etc/exports`
  but missing from `exportfs -v` — the two rules were entered with **no space between
  them**, so the line is malformed. Fix in the unraid share's NFS **Rule** box (add the
  space), re-apply, confirm with `exportfs -v` / `showmount -e`.
- **Argo is currently broken on unraid-lab** — the bootstrap inline Argo install landed
  in the `default` namespace (the `omni-on-unraid` generator lacks the `namespace: argocd`
  kustomize stamp that this repo's commit `3340c74` added), so ArgoCD isn't watching the
  `argocd` namespace where the seed apps live. **Nothing will sync — including this
  chart-app — until that's fixed.** Tracked separately.

## Risks

| Risk | Impact | Likelihood | Mitigation |
| ------ | -------- | ----------- | ------------ |
| Export rule/source-IP wrong → mounts fail | Med | Med | `no_root_squash` + both subnets in rule; verify with a test PVC before Harbor |
| NFS single-server (unraid) is a SPOF | Med | Low | Accepted — unraid *is* the durability layer by design |
| Argo not fixed → CSI never deploys | High | High (now) | Fix bootstrap namespacing first (prerequisite above) |
