#!/usr/bin/env bash
# Apply generated unraid-lab inline manifests and upgrade the live Argo install.
set -euo pipefail

CLUSTER="unraid-lab"
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
MANIFESTS="$REPO_ROOT/clusters/$CLUSTER/omni/inline-manifests.yaml"
ARGOCD_CONFIG="$REPO_ROOT/bootstrap/argocd-cm.yaml"
PATCH_ID="202-cluster-$CLUSTER-omni/patches/inline-manifests.yaml"

[[ -f "$MANIFESTS" ]] || {
  printf 'missing %s\n' "$MANIFESTS" >&2
  exit 1
}
[[ -f "$ARGOCD_CONFIG" ]] || {
  printf 'missing %s\n' "$ARGOCD_CONFIG" >&2
  exit 1
}

temporary="$(mktemp -d)"
trap 'rm -rf "$temporary"' EXIT

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

P="$MANIFESTS" yq -i \
  '.spec.data = loadstr(strenv(P)) | .spec.data style="literal"' "$temporary/configpatch.yaml"

python3 - "$MANIFESTS" <<'PY'
import sys

import yaml

inline_manifests = yaml.safe_load(open(sys.argv[1]))["cluster"]["inlineManifests"]
for inline_manifest in inline_manifests:
    list(yaml.safe_load_all(inline_manifest["contents"]))
print("inline manifests: valid")
PY

python3 - "$MANIFESTS" "$temporary/argocd.yaml" <<'PY'
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
  KUBECONFIG="$temporary/kubeconfig" kubectl apply --server-side --force-conflicts \
    -f "$ARGOCD_CONFIG"
  KUBECONFIG="$temporary/kubeconfig" kubectl rollout status deployment/argocd-server \
    -n argocd --timeout=5m
  [[ "$(curl -ksS -o /dev/null -w '%{http_code}' --max-redirs 0 \
    https://argocd-unraid-lab.wind-bearded.ts.net)" == "200" ]] || {
    printf 'Argo CD did not become reachable without a redirect after rollout.\n' >&2
    exit 1
  }
  printf 'Argo CD upgraded from the generated manifest.\n'
else
  printf 'Inline-manifest ConfigPatch and Argo CD manifest rendered and validated; re-run with --apply to deploy.\n'
fi
