#!/usr/bin/env bash
# Deliver OCI's Harbor registry mirrors through Omni without committing LAN
# addressing. HARBOR_REGISTRY_ENDPOINT must be a private host:port value in
# gitignored omni/secrets.env (or SECRETS_ENV); example value intentionally
# omitted. The endpoint is persisted only in Omni's encrypted config store.
set -euo pipefail

CLUSTER="oci-lab"
YQ="${YQ:-yq}"
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
ENV_FILE="${SECRETS_ENV:-$REPO_ROOT/omni/secrets.env}"

[ -f "$ENV_FILE" ] || { echo "missing $ENV_FILE" >&2; exit 1; }
set -a; . "$ENV_FILE"; set +a

ENDPOINT="${HARBOR_REGISTRY_ENDPOINT:?set in gitignored omni/secrets.env}"
case "$ENDPOINT" in
  *[!A-Za-z0-9.:-]* | *://* | :* | *:) echo "HARBOR_REGISTRY_ENDPOINT must be host:port" >&2; exit 1 ;;
esac

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

cat > "$TMP/patch.yaml" <<YAML
machine:
  registries:
    mirrors:
      docker.io:
        endpoints: ["http://${ENDPOINT}/v2/proxy-dockerhub"]
        overridePath: true
      ghcr.io:
        endpoints: ["http://${ENDPOINT}/v2/proxy-ghcr"]
        overridePath: true
      quay.io:
        endpoints: ["http://${ENDPOINT}/v2/proxy-quay"]
        overridePath: true
      registry.k8s.io:
        endpoints: ["http://${ENDPOINT}/v2/proxy-k8s"]
        overridePath: true
YAML

cat > "$TMP/configpatch.yaml" <<YAML
metadata:
  namespace: default
  type: ConfigPatches.omni.sidero.dev
  id: 500-cluster-${CLUSTER}-harbor-registry-mirror
  labels:
    omni.sidero.dev/cluster: ${CLUSTER}
spec:
  data: ""
YAML

P="$TMP/patch.yaml" "$YQ" -i '.spec.data = loadstr(strenv(P)) | .spec.data style="literal"' "$TMP/configpatch.yaml"

if [ "${1:-}" = "--apply" ]; then
  omnictl apply -f "$TMP/configpatch.yaml"
  echo "==> applied private Harbor registry mirror for ${CLUSTER}"
else
  "$YQ" eval '.' "$TMP/configpatch.yaml"
  echo "==> dry-run only; re-run with --apply to push the ConfigPatch"
fi
