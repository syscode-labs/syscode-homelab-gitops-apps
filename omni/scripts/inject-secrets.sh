#!/usr/bin/env bash
# Deliver unraid-lab bootstrap secrets through Omni — NOT through git.
#
# Reads values from a gitignored file (omni/secrets.env), builds the k8s Secret
# manifests each app expects, wraps them in a Talos machine-config patch, and
# applies it to Omni as a ConfigPatch for the unraid-lab cluster. The secrets then
# live only in Omni's encrypted config store and in the cluster — never committed.
#
# Usage:
#   omni/scripts/inject-secrets.sh            # dry-run: print the ConfigPatch, validate
#   omni/scripts/inject-secrets.sh --apply    # push to Omni (needs omnictl auth)
#
# Requirements: yq (mikefarah v4), omnictl (with OMNICONFIG). Fill omni/secrets.env
# from omni/secrets.env.example first. harbor-mirror-robot is intentionally NOT here
# — it's a Harbor robot account, created after Harbor is running (add it later).
set -euo pipefail

CLUSTER="unraid-lab"
YQ="${YQ:-yq}"
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
ENV_FILE="${SECRETS_ENV:-$REPO_ROOT/omni/secrets.env}"

[ -f "$ENV_FILE" ] || { echo "missing $ENV_FILE — copy omni/secrets.env.example and fill it" >&2; exit 1; }
set -a; . "$ENV_FILE"; set +a

TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT

# k8s manifests (namespaces are idempotent; keeps a fresh bootstrap self-contained).
cat > "$TMP/manifests.yaml" <<YAML
apiVersion: v1
kind: Namespace
metadata:
  name: harbor
---
apiVersion: v1
kind: Secret
metadata:
  name: harbor-admin-password
  namespace: harbor
type: Opaque
stringData:
  HARBOR_ADMIN_PASSWORD: "${HARBOR_ADMIN_PASSWORD:?set in secrets.env}"
---
apiVersion: v1
kind: Namespace
metadata:
  name: arc-runners
---
apiVersion: v1
kind: Secret
metadata:
  name: arc-gha-secret
  namespace: arc-runners
type: Opaque
stringData:
  github_app_id: "${GITHUB_APP_ID:?set in secrets.env}"
  github_app_installation_id: "${GITHUB_APP_INSTALLATION_ID:?set in secrets.env}"
  github_app_private_key: |
$(printf '%s\n' "${GITHUB_APP_PRIVATE_KEY:?set in secrets.env}" | sed 's/^/    /')
---
apiVersion: v1
kind: Namespace
metadata:
  name: tailscale
---
apiVersion: v1
kind: Secret
metadata:
  name: operator-oauth
  namespace: tailscale
type: Opaque
stringData:
  client_id: "${TS_OAUTH_CLIENT_ID:?set in secrets.env}"
  client_secret: "${TS_OAUTH_CLIENT_SECRET:?set in secrets.env}"
YAML

# Wrap manifests -> Talos inline-manifest patch -> Omni ConfigPatch (yq handles the
# nested block scalars, so no hand-indentation).
printf 'cluster:\n  inlineManifests: []\n' > "$TMP/patch.yaml"
MF="$TMP/manifests.yaml" "$YQ" -i \
  '.cluster.inlineManifests += [{"name":"bootstrap-secrets","contents": loadstr(strenv(MF))}] |
   (.cluster.inlineManifests[0].contents) style="literal"' "$TMP/patch.yaml"

cat > "$TMP/configpatch.yaml" <<YAML
metadata:
  namespace: default
  type: ConfigPatches.omni.sidero.dev
  id: 500-cluster-${CLUSTER}-bootstrap-secrets
  labels:
    omni.sidero.dev/cluster: ${CLUSTER}
spec:
  data: ""
YAML
P="$TMP/patch.yaml" "$YQ" -i '.spec.data = loadstr(strenv(P)) | .spec.data style="literal"' "$TMP/configpatch.yaml"

# Validate: the inner manifests must be well-formed k8s YAML.
python3 -c "import yaml,sys; list(yaml.safe_load_all(open('$TMP/manifests.yaml'))); print('manifests: valid')"

if [ "${1:-}" = "--apply" ]; then
  omnictl apply -f "$TMP/configpatch.yaml"
  echo "==> applied ConfigPatch 500-cluster-${CLUSTER}-bootstrap-secrets (secrets now in Omni, delivered to cluster)"
else
  echo "----- ConfigPatch (dry-run; secret values redacted below) -----"
  sed -E 's/(HARBOR_ADMIN_PASSWORD|client_secret|github_app_private_key).*/\1: <redacted>/' "$TMP/configpatch.yaml"
  echo "----- re-run with --apply to push to Omni -----"
fi
