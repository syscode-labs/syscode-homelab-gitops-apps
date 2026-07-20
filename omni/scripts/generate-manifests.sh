#!/usr/bin/env bash
# Generate inline manifest content for omni/patches/inline-manifests.yaml.
# Run this after version bumps for Cilium or Argo CD, then commit the result.
#
# Requirements: helm, curl, yq (or python3)
set -euo pipefail

CILIUM_VERSION="${CILIUM_VERSION:-1.17.2}"
ARGOCD_VERSION="${ARGOCD_VERSION:-v2.14.4}"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PATCH_FILE="${SCRIPT_DIR}/../patches/inline-manifests.yaml"
TMPDIR=$(mktemp -d)
trap 'rm -rf "$TMPDIR"' EXIT

echo "==> Adding Cilium Helm repo..."
helm repo add cilium https://helm.cilium.io/ --force-update 2>/dev/null
helm repo update cilium

echo "==> Rendering Cilium ${CILIUM_VERSION}..."
helm template cilium cilium/cilium \
  --version "${CILIUM_VERSION}" \
  --namespace kube-system \
  --set kubeProxyReplacement=true \
  --set k8sServiceHost=localhost \
  --set k8sServicePort=7445 \
  --set ipam.mode=kubernetes \
  --set hubble.relay.enabled=true \
  --set hubble.ui.enabled=true \
  > "${TMPDIR}/cilium.yaml"

echo "==> Downloading Argo CD ${ARGOCD_VERSION}..."
curl -sL "https://raw.githubusercontent.com/argoproj/argo-cd/${ARGOCD_VERSION}/manifests/install.yaml" \
  > "${TMPDIR}/argocd.yaml"

CILIUM_CONTENT=$(sed 's/^/        /' "${TMPDIR}/cilium.yaml")
ARGOCD_CONTENT=$(sed 's/^/        /' "${TMPDIR}/argocd.yaml")

echo "==> Writing ${PATCH_FILE}..."
cat > "${PATCH_FILE}" <<EOF
# Talos inline manifests applied during cluster bootstrap by the first control plane node.
# These run before any workload scheduler is up, so they must be self-contained YAML.
#
# REGENERATE after Cilium/Argo CD version bumps:
#   mise run oci:generate-manifests
#
# Cilium: ${CILIUM_VERSION} — kubeProxyReplacement=true, KubePrism (localhost:7445)
# Argo CD: ${ARGOCD_VERSION} — raw install manifest + inline root Application

cluster:
  inlineManifests:
    - name: cilium
      contents: |
        # cilium v${CILIUM_VERSION} — generated $(date -u +%Y-%m-%d)
${CILIUM_CONTENT}

    - name: argocd
      contents: |
        # argocd ${ARGOCD_VERSION} — generated $(date -u +%Y-%m-%d)
${ARGOCD_CONTENT}

    - name: argocd-app-of-apps
      contents: |
        # Inline root Application. It syncs bootstrap/, which then fans out to infrastructure/.
        apiVersion: argoproj.io/v1alpha1
        kind: Application
        metadata:
          name: root
          namespace: argocd
        spec:
          project: default
          source:
            repoURL: https://github.com/syscode-labs/syscode-homelab-gitops-apps
            targetRevision: HEAD
            path: bootstrap
          destination:
            server: https://kubernetes.default.svc
            namespace: argocd
          syncPolicy:
            automated:
              prune: true
              selfHeal: true
EOF

echo "==> Done. Commit omni/patches/inline-manifests.yaml."
