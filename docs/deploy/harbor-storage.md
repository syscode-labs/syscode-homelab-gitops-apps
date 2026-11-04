# OCI Harbor local storage

## Scope and persistence

Three static, classless 1Gi ReadWriteOnce PVs reserve the existing Harbor claims
by exact UID. No PVC is recreated or edited. Each PV uses `local`, not `hostPath`,
with hostname affinity to `ampere-vnic-1`, the OCI control plane. Reclaim policy
is Retain; Argo deletion and pruning are also disabled for the volumes.

The control-plane patch in `omni/cluster-templates/oci-lab.yaml` declares three
Talos 1.14 directory-backed UserVolumeConfig documents. Talos creates and exposes
`/var/mnt/harbor-database`, `/var/mnt/harbor-redis`, and
`/var/mnt/harbor-jobservice` to kubelet on existing XFS EPHEMERAL `/var`
(`/dev/sda4`). No partitioning, extra disks, filesystem formatting, image change,
or kubelet extraMounts are required. Directory volumes reconcile live; a reboot
is not part of this rollout.

Data survives pod replacement and ordinary node reboot while the existing
EPHEMERAL filesystem remains intact. This is NOT HA and does not survive node/disk
replacement, EPHEMERAL reset, or reinstallation that destroys that filesystem.
Retain does not make host-local data portable or provide backups. All directories
share EPHEMERAL capacity with the node; advertised 1Gi capacities are scheduling
contracts, not enforced quotas. Registry blobs remain in existing OCI Object
Storage; these volumes cover PostgreSQL, Redis, and jobservice only.

## Owner evidence

The live OCI cluster is annotated `omni.sidero.dev/managed-by-cluster-templates`.
Its `oci-lab-control-planes` MachineSet allocates one `oci-cp` machine. Existing
ConfigPatch `400-oci-lab-control-planes-patches/disable-kube-proxy.yaml` matches
this repository's ControlPlane patch list. The new directory patch belongs in
that same list, not an ad-hoc live ConfigPatch or the worker machine class.
Preserve separately managed secret patches when reviewing template changes.

## Reviewed rollout gates

Publication and merge alone must not bind storage: the storage Application has
`automated.enabled: false`, with prune and self-heal disabled. Do not manually
sync it before the following gates. No live storage or machine changes were
performed in this PR.

1. Review and merge fresh-initialization PR #127 first. Verify its restore init
   container is absent from the effective Harbor core Deployment; do not restore
   anything. Keep the backup CronJob and old suspended backup Job suspended.
2. Review and merge this storage PR. Confirm the running Argo CD supports
   `syncPolicy.automated.enabled: false` and that the storage Application remains
   manual. If unsupported, leave the Application unregistered until rollout.
3. Review the Omni template diff against current state. Apply ONLY the reviewed
   control-plane directory patch through its template owner, preserving unrelated
   patches, allocations, versions, and secrets. A whole-template sync is unsafe
   if its diff includes unrelated drift. No reset, reboot, or repartitioning is
   authorized or needed. This is the remaining machine-configuration action.
4. Read back Talos volume/mount status and all three paths on `ampere-vnic-1`.
   Require ready directory volumes backed by existing EPHEMERAL and kubelet
   exposure. Check actual available filesystem bytes for the combined workload
   plus node headroom; stop if insufficient. Verify Kubernetes hostname and
   scheduling eligibility of this node. Do not create paths via privileged pods.
5. Re-read the three PVCs: they must remain Pending, classless, RWO Filesystem,
   requesting 1Gi, with exactly the UIDs committed in the PV claimRefs. Stop on
   any mismatch; never remove UIDs to force a match or delete the existing claims.
6. Manually sync only `oci-lab-harbor-storage` without prune. Require all three
   PVCs Bound to their intended PVs; verify claim UIDs unchanged, Retain,
   classless storage, exact local paths, and hostname affinity. This is storage
   binding acceptance and does not depend on Harbor image CPU architecture.
7. Separately gate application readiness on stable ARM-compatible Harbor images
   and successful empty initialization. Verify application-level writes survive
   pod replacement when runtime is available. Do not claim this persistence test
   has passed merely because claims bind. Do not enable backups until a verified
   database and separately reviewed backup execution are available.

Rollback before binding: leave the manual storage Application unsynced and
revert source. After binding: stop writers and preserve PVs, PVCs, directories,
and data; do not remove UserVolumeConfig or clear claimRefs. Retain cleanup or
migration requires a separate explicit decision.

## Verification

Run `python3 scripts/test_harbor_storage.py`. It verifies all three PV/claim UID
mappings against the pinned contract and the control-plane directory declaration,
including manual sync, Retain, classlessness, local paths, and node affinity.
The rollout additionally revalidates these contracts against live resources.

References:

- [Talos UserVolumeConfig schema](https://docs.siderolabs.com/talos/v1.14/reference/configuration/block/uservolumeconfig)
- [Talos user volumes lifecycle](https://docs.siderolabs.com/talos/v1.14/configure-your-talos-cluster/storage-and-disk-management/disk-management/user)
