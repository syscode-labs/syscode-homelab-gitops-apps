#!/usr/bin/env bash
# Apply generated cluster inline manifests and upgrade the live Argo install.
set -euo pipefail

CLUSTER="${1:-unraid-lab}"
if [[ "$CLUSTER" == "oci-lab" || "$CLUSTER" == "unraid-lab" ]]; then
  shift || true
else
  CLUSTER="unraid-lab"
fi
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"

case "$CLUSTER" in
  oci-lab)
    MANIFESTS="$REPO_ROOT/omni/cluster-templates/patches/oci-lab-inline-manifests.yaml"
    PATCH_ID="202-cluster-oci-lab-patches/oci-lab-inline-manifests.yaml"
    ARGOCD_CONFIG=""
    ;;
  unraid-lab)
    MANIFESTS="$REPO_ROOT/clusters/$CLUSTER/omni/inline-manifests.yaml"
    PATCH_ID="200-cluster-unraid-lab-omni/patches/inline-manifests.yaml"
    ARGOCD_CONFIG="$REPO_ROOT/bootstrap/argocd-cm.yaml"
    ;;
esac

[[ -f "$MANIFESTS" ]] || {
  printf 'missing %s\n' "$MANIFESTS" >&2
  exit 1
}
[[ -z "$ARGOCD_CONFIG" || -f "$ARGOCD_CONFIG" ]] || {
  printf 'missing %s\n' "$ARGOCD_CONFIG" >&2
  exit 1
}

temporary="$(mktemp -d)"
trap 'rm -rf "$temporary"' EXIT

EFFECTIVE_MANIFESTS="$temporary/inline-manifests.yaml"
cp "$MANIFESTS" "$EFFECTIVE_MANIFESTS"

if [[ "$CLUSTER" == "unraid-lab" ]]; then
  HOMELAB_SECRETS_ROOT="${HOMELAB_SECRETS_ROOT:-$REPO_ROOT/../homelab-secrets}"
  BWS_TOKEN_FILE="$HOMELAB_SECRETS_ROOT/unraid-lab/bws-token.enc.yaml"
  [[ -f "$BWS_TOKEN_FILE" ]] || {
    printf 'missing encrypted bootstrap secret: %s\n' "$BWS_TOKEN_FILE" >&2
    exit 1
  }
  command -v sops >/dev/null || {
    printf 'sops is required to decrypt the unraid-lab bootstrap secret\n' >&2
    exit 1
  }
  sops -d "$BWS_TOKEN_FILE" >"$temporary/bws-token.yaml"
  python3 - "$temporary/bws-token.yaml" <<'PY'
import sys

import yaml

secret = yaml.safe_load(open(sys.argv[1]))
if (
    secret.get("apiVersion") != "v1"
    or secret.get("kind") != "Secret"
    or secret.get("metadata", {}).get("name") != "bws-token"
    or secret.get("metadata", {}).get("namespace") != "external-secrets"
    or "token" not in secret.get("stringData", {}) | secret.get("data", {})
):
    raise SystemExit("unexpected bws-token bootstrap Secret shape")
PY
  BWS_TOKEN="$temporary/bws-token.yaml" yq -i \
    '.cluster.inlineManifests += [{"name":"bootstrap-bws-token","contents": loadstr(strenv(BWS_TOKEN))}] |
     (.cluster.inlineManifests[-1].contents) style="literal"' "$EFFECTIVE_MANIFESTS"
fi

cat >"$temporary/configpatch.yaml" <<YAML
metadata:
  namespace: default
  type: ConfigPatches.omni.sidero.dev
  id: ${PATCH_ID}
  labels:
    omni.sidero.dev/cluster: ${CLUSTER}
spec:
  data: ""
YAML

P="$EFFECTIVE_MANIFESTS" yq -i \
  '.spec.data = loadstr(strenv(P)) | .spec.data style="literal"' "$temporary/configpatch.yaml"

python3 - "$EFFECTIVE_MANIFESTS" <<'PY'
import sys

import yaml

inline_manifests = yaml.safe_load(open(sys.argv[1]))["cluster"]["inlineManifests"]
for inline_manifest in inline_manifests:
    list(yaml.safe_load_all(inline_manifest["contents"]))
print("inline manifests: valid")
PY

python3 - "$EFFECTIVE_MANIFESTS" "$temporary/argocd.yaml" <<'PY'
import sys
from pathlib import Path

import yaml

manifests_path = Path(sys.argv[1])
argocd_path = Path(sys.argv[2])
inline_manifests = yaml.safe_load(manifests_path.read_text())["cluster"]["inlineManifests"]
argocd_manifest = next(
    manifest["contents"] for manifest in inline_manifests if manifest["name"] == "argocd"
)
list(yaml.safe_load_all(argocd_manifest))
argocd_path.write_text(argocd_manifest)
print("Argo CD manifest: valid")
PY

# Tailscale terminates TLS before forwarding to argocd-server:80. Confirm the
# generated bootstrap disables Argo's own HTTP-to-HTTPS redirect before apply.
python3 - "$temporary/argocd.yaml" <<'PY'
import sys

import yaml

for manifest in yaml.safe_load_all(open(sys.argv[1])):
    if manifest and manifest.get("kind") == "Deployment" and manifest["metadata"]["name"] == "argocd-server":
        containers = manifest["spec"]["template"]["spec"]["containers"]
        args = next(container.get("args", []) for container in containers if container["name"] == "argocd-server")
        if "--insecure" in args:
            print("Argo CD TLS-termination setting: valid")
            break
else:
    raise SystemExit("argocd-server is missing --insecure; refusing to deploy a redirect loop")
PY

if [[ "${1:-}" == "--apply" ]]; then
  omnictl get "ConfigPatches.omni.sidero.dev" "$PATCH_ID" -n default -o json \
    >"$temporary/existing-configpatch.json"
  python3 - "$temporary/existing-configpatch.json" "$PATCH_ID" "$CLUSTER" <<'PY'
import json
import sys

configpatch_path, expected_id, expected_cluster = sys.argv[1:]
with open(configpatch_path) as configpatch_file:
    configpatch = json.load(configpatch_file)

metadata = configpatch["metadata"]
if (
    metadata["id"] != expected_id
    or metadata["namespace"] != "default"
    or metadata.get("labels", {}).get("omni.sidero.dev/cluster") != expected_cluster
):
    raise SystemExit("refusing to update an unexpected ConfigPatch")
PY
  omnictl apply -f "$temporary/configpatch.yaml"
  printf 'Inline-manifest ConfigPatch applied to Omni.\n'
  omnictl kubeconfig "$temporary/kubeconfig" --cluster "$CLUSTER" --merge=false --force
  KUBECONFIG="$temporary/kubeconfig" kubectl apply --server-side --force-conflicts \
    -f "$temporary/argocd.yaml"
  if [[ -n "$ARGOCD_CONFIG" ]]; then
    KUBECONFIG="$temporary/kubeconfig" kubectl apply --server-side --force-conflicts \
      -f "$ARGOCD_CONFIG"
  fi
  KUBECONFIG="$temporary/kubeconfig" kubectl rollout status deployment/argocd-server \
    -n argocd --timeout=5m
  if [[ "$CLUSTER" == "unraid-lab" ]]; then
    [[ "$(curl -ksS -o /dev/null -w '%{http_code}' --max-redirs 0 \
      https://argocd-unraid-lab.wind-bearded.ts.net)" == "200" ]] || {
      printf 'Argo CD did not become reachable without a redirect after rollout.\n' >&2
      exit 1
    }
  fi
  printf 'Argo CD upgraded from the generated manifest.\n'
else
  printf 'Inline-manifest ConfigPatch and Argo CD manifest rendered and validated; re-run with --apply to deploy.\n'
fi
