#!/usr/bin/env bash
# Fill the generated blocks of a cluster's Talos inline-manifests:
#   argocd       raw Argo CD install manifest (upstream install.yaml)
#   argocd-apps  the repo-root appset.yaml with THIS cluster's identity substituted
#   cilium       rendered Cilium (only clusters that bootstrap their own CNI, e.g. OCI)
#
# The static blocks (argocd-bootstrap, argocd-unraid-raw) and every comment are
# left untouched — yq edits only the named blocks in place.
#
# Usage:  omni/scripts/generate-manifests.sh <oci-talos|unraid-lab>
#   or:   mise run oci:generate-manifests   /   mise run unraid:generate-manifests
#
# Requirements: yq (mikefarah v4), curl, helm, kubectl. Run after Cilium/Argo CD version
# bumps or appset.yaml changes, then review + commit the result.
set -euo pipefail

CLUSTER="${1:?usage: generate-manifests.sh <oci-talos|unraid-lab>}"
CILIUM_VERSION="${CILIUM_VERSION:-1.17.2}"
ARGOCD_VERSION="${ARGOCD_VERSION:-v2.14.4}"

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"

case "$CLUSTER" in
  oci-talos)
    CLUSTER_TYPE="cloud"
    FILE="omni/patches/inline-manifests.yaml"
    WITH_CILIUM=1
    ;;
  unraid-lab)
    CLUSTER_TYPE="homelab-kvm"
    FILE="clusters/unraid-lab/omni/inline-manifests.yaml"
    WITH_CILIUM=0
    ;;
  *)
    echo "unknown cluster '$CLUSTER' (expected oci-talos or unraid-lab)" >&2
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
KUST
{ printf 'apiVersion: v1\nkind: Namespace\nmetadata:\n  name: argocd\n---\n'; \
  kubectl kustomize "$TMP/argocd"; } > "$TMP/argocd-manifest.yaml"
inject argocd "$TMP/argocd-manifest.yaml"

echo "==> appset.yaml for ${CLUSTER} / ${CLUSTER_TYPE}..."
sed -e "s/CLUSTER_NAME/${CLUSTER}/g" -e "s/CLUSTER_TYPE/${CLUSTER_TYPE}/g" \
  "$REPO_ROOT/appset.yaml" > "$TMP/appset.yaml"
inject argocd-apps "$TMP/appset.yaml"

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
    --set hubble.relay.enabled=true \
    --set hubble.ui.enabled=true \
    > "$TMP/cilium.yaml"
  inject cilium "$TMP/cilium.yaml"
fi

echo "==> Wrote ${FILE#"$REPO_ROOT"/} (${CLUSTER} / ${CLUSTER_TYPE}). Review + commit."
