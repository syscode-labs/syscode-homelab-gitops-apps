#!/usr/bin/env bash
# Fill the generated blocks of a cluster's Talos inline-manifests:
#   unraid-lab   argocd       raw Argo CD install manifest (upstream install.yaml)
#                argocd-apps  appset.yaml — the layering ApplicationSet, embedded
#                             verbatim (it covers BOTH clusters; oci-lab apps are
#                             reconciled remotely through the registered cluster)
#   oci-lab      cilium       rendered Cilium — oci-lab bootstraps Cilium ONLY,
#                             no local Argo CD (unraid-lab's Argo reconciles it
#                             through the registered external cluster)
#
# The static blocks (oci-lab's argocd-manager RBAC, unraid's argocd-bootstrap /
# argocd-unraid-raw) and every comment are left untouched — yq edits only the
# named blocks in place.
#
# Usage:  omni/scripts/generate-manifests.sh <oci-lab|unraid-lab>
#   or:   mise run oci-lab:generate-manifests   /   mise run unraid:generate-manifests
#
# Requirements: yq (mikefarah v4), curl, helm, kubectl. Run after Cilium/Argo CD
# version bumps or appset.yaml changes, then review + commit the result.
set -euo pipefail

CLUSTER="${1:?usage: generate-manifests.sh <oci-lab|unraid-lab>}"
CILIUM_VERSION="${CILIUM_VERSION:-1.17.2}"
ARGOCD_VERSION="${ARGOCD_VERSION:-}"

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"

case "$CLUSTER" in
  oci-lab)
    FILE="omni/cluster-templates/patches/oci-lab-inline-manifests.yaml"
    WITH_ARGOCD=0
    WITH_CILIUM=1
    ;;
  unraid-lab)
    FILE="clusters/unraid-lab/omni/inline-manifests.yaml"
    WITH_ARGOCD=1
    WITH_CILIUM=0
    ARGOCD_VERSION="${ARGOCD_VERSION:-v3.5.0}"
    ;;
  *)
    echo "unknown cluster '$CLUSTER' (expected oci-lab or unraid-lab)" >&2
    exit 1
    ;;
esac
FILE="$REPO_ROOT/$FILE"

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

# Replace one named inlineManifest's contents in place, as a literal block, keeping
# every other block and all comments intact. yq reads the payload from the file
# directly (loadstr) — it is far too big to pass through an env var.
inject() {
  local name="$1" payload="$2"
  NAME="$name" PAYLOAD="$payload" yq -i '
    (.cluster.inlineManifests[] | select(.name == strenv(NAME)) | .contents) = loadstr(strenv(PAYLOAD)) |
    (.cluster.inlineManifests[] | select(.name == strenv(NAME)) | .contents) style="literal"
  ' "$FILE"
}

if [[ "$WITH_ARGOCD" == 1 ]]; then
  echo "==> Argo CD ${ARGOCD_VERSION} install manifest (namespaced to argocd)..."
  # Upstream install.yaml carries NO namespace on its resources — it relies on
  # `kubectl apply -n argocd`. Talos applies inline manifests verbatim with no
  # namespace default, so the namespaced resources would miss the argocd namespace
  # and never install. Stamp it with kustomize (also fixes the RBAC binding
  # subjects), and prepend the Namespace since kustomize won't create it.
  mkdir -p "$TMP/argocd"
  curl -sfL "https://raw.githubusercontent.com/argoproj/argo-cd/${ARGOCD_VERSION}/manifests/install.yaml" \
    -o "$TMP/argocd/install.yaml"
  cat > "$TMP/argocd/kustomization.yaml" <<'KUST'
namespace: argocd
resources:
  - install.yaml
patches:
  # Argo CD 3 defaults to annotation tracking. Keep existing resources on
  # label tracking from the first controller start so none are orphaned.
  - target:
      kind: ConfigMap
      name: argocd-cm
    patch: |-
      apiVersion: v1
      kind: ConfigMap
      metadata:
        name: argocd-cm
      data:
        application.resourceTrackingMethod: label
  # argocd-server serves TLS on its own port by default and 307-redirects
  # any plain-HTTP request to https — including requests our own tailscale
  # Ingress forwards as plain HTTP after terminating TLS at the tailnet
  # edge. Without --insecure that's an infinite redirect loop
  # (ERR_TOO_MANY_REDIRECTS). TLS is already handled by tailscale; argocd-
  # server only needs to speak plain HTTP behind it.
  - target:
      kind: Deployment
      name: argocd-server
    patch: |-
      - op: add
        path: /spec/template/spec/containers/0/args/-
        value: --insecure
  # Upstream ships every ArgoCD component with NO resource requests/limits.
  # Without a memory limit kubelet can't cgroup-cap the container, so a
  # runaway controller (application-controller diffing every Application,
  # repo-server cloning/templating) grows until the kernel OOM-killer
  # intervenes reactively — which is what starved a homelab VM host
  # running multiple cluster nodes, with no per-VM CPU fairness enforced
  # at the hypervisor level, rather than kubelet enforcing a sane cap up front.
  - target:
      kind: StatefulSet
      name: argocd-application-controller
    patch: |-
      - op: add
        path: /spec/template/spec/containers/0/resources
        value:
          requests: {cpu: 250m, memory: 256Mi}
          limits: {cpu: "1", memory: 768Mi}
  - target:
      kind: Deployment
      name: argocd-repo-server
    patch: |-
      - op: add
        path: /spec/template/spec/containers/0/resources
        value:
          requests: {cpu: 100m, memory: 128Mi}
          limits: {cpu: 500m, memory: 512Mi}
  - target:
      kind: Deployment
      name: argocd-server
    patch: |-
      - op: add
        path: /spec/template/spec/containers/0/resources
        value:
          requests: {cpu: 50m, memory: 64Mi}
          limits: {cpu: 300m, memory: 256Mi}
  - target:
      kind: Deployment
      name: argocd-redis
    patch: |-
      - op: add
        path: /spec/template/spec/containers/0/resources
        value:
          requests: {cpu: 50m, memory: 32Mi}
          limits: {cpu: 200m, memory: 128Mi}
  - target:
      kind: Deployment
      name: argocd-dex-server
    patch: |-
      - op: add
        path: /spec/template/spec/containers/0/resources
        value:
          requests: {cpu: 20m, memory: 32Mi}
          limits: {cpu: 100m, memory: 128Mi}
  - target:
      kind: Deployment
      name: argocd-notifications-controller
    patch: |-
      - op: add
        path: /spec/template/spec/containers/0/resources
        value:
          requests: {cpu: 20m, memory: 32Mi}
          limits: {cpu: 100m, memory: 128Mi}
  - target:
      kind: Deployment
      name: argocd-applicationset-controller
    patch: |-
      - op: add
        path: /spec/template/spec/containers/0/resources
        value:
          requests: {cpu: 20m, memory: 64Mi}
          limits: {cpu: 200m, memory: 256Mi}
KUST
  { printf 'apiVersion: v1\nkind: Namespace\nmetadata:\n  name: argocd\n---\n'; \
    kubectl kustomize "$TMP/argocd"; } > "$TMP/argocd-manifest.yaml"
  inject argocd "$TMP/argocd-manifest.yaml"

  echo "==> appset.yaml (single ApplicationSet covering unraid-lab + oci-lab)..."
  cp "$REPO_ROOT/appset.yaml" "$TMP/appset.yaml"
  inject argocd-apps "$TMP/appset.yaml"
fi

if [[ "$WITH_CILIUM" == 1 ]]; then
  echo "==> Cilium ${CILIUM_VERSION} (kube-proxy-free, KubePrism)..."
  helm repo add cilium https://helm.cilium.io/ --force-update >/dev/null 2>&1
  helm repo update cilium >/dev/null
  helm template cilium cilium/cilium \
    --version "${CILIUM_VERSION}" \
    --namespace kube-system \
    --set kubeProxyReplacement=true \
    --set k8sServiceHost=localhost \
    --set k8sServicePort=7445 \
    --set ipam.mode=kubernetes \
    --set securityContext.privileged=true \
    --set hubble.relay.enabled=true \
    --set hubble.ui.enabled=true \
    > "$TMP/cilium.yaml"
  inject cilium "$TMP/cilium.yaml"
fi

echo "==> Wrote ${FILE#"$REPO_ROOT"/} (${CLUSTER}). Review + commit."
