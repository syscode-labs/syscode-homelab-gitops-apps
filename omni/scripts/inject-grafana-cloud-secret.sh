#!/usr/bin/env bash
# Store the Grafana Cloud destination credential in Omni, never Git.
set -euo pipefail

CLUSTER="unraid-lab"
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
ENV_FILE="${SECRETS_ENV:-$REPO_ROOT/omni/secrets.env}"
YQ="${YQ:-yq}"

[[ -f "$ENV_FILE" ]] || {
  printf 'missing %s\n' "$ENV_FILE" >&2
  exit 1
}
set -a
# shellcheck source=/dev/null
. "$ENV_FILE"
set +a

for name in \
  GRAFANA_CLOUD_METRICS_USERNAME GRAFANA_CLOUD_METRICS_TOKEN \
  GRAFANA_CLOUD_LOGS_USERNAME GRAFANA_CLOUD_LOGS_TOKEN \
  GRAFANA_CLOUD_OTLP_USERNAME GRAFANA_CLOUD_OTLP_TOKEN \
  GRAFANA_CLOUD_FLEET_USERNAME GRAFANA_CLOUD_FLEET_TOKEN; do
  [[ -n "${!name:-}" ]] || {
    printf 'set %s in %s\n' "$name" "$ENV_FILE" >&2
    exit 1
  }
done

temporary="$(mktemp -d)"
trap 'rm -rf "$temporary"' EXIT

cat >"$temporary/manifests.yaml" <<YAML
apiVersion: v1
kind: Namespace
metadata:
  name: monitoring
---
apiVersion: v1
kind: Secret
metadata:
  name: grafana-cloud
  namespace: monitoring
type: Opaque
stringData:
  metrics-username: "${GRAFANA_CLOUD_METRICS_USERNAME}"
  metrics-password: "${GRAFANA_CLOUD_METRICS_TOKEN}"
  logs-username: "${GRAFANA_CLOUD_LOGS_USERNAME}"
  logs-password: "${GRAFANA_CLOUD_LOGS_TOKEN}"
  otlp-username: "${GRAFANA_CLOUD_OTLP_USERNAME}"
  otlp-password: "${GRAFANA_CLOUD_OTLP_TOKEN}"
  fleet-username: "${GRAFANA_CLOUD_FLEET_USERNAME}"
  fleet-password: "${GRAFANA_CLOUD_FLEET_TOKEN}"
YAML

printf 'cluster:\n  inlineManifests: []\n' >"$temporary/patch.yaml"
MF="$temporary/manifests.yaml" "$YQ" -i \
  '.cluster.inlineManifests += [{"name":"grafana-cloud-secret","contents": loadstr(strenv(MF))}] |
   (.cluster.inlineManifests[0].contents) style="literal"' "$temporary/patch.yaml"

cat >"$temporary/configpatch.yaml" <<YAML
metadata:
  namespace: default
  type: ConfigPatches.omni.sidero.dev
  id: 510-cluster-${CLUSTER}-grafana-cloud-secret
  labels:
    omni.sidero.dev/cluster: ${CLUSTER}
spec:
  data: ""
YAML
P="$temporary/patch.yaml" "$YQ" -i \
  '.spec.data = loadstr(strenv(P)) | .spec.data style="literal"' "$temporary/configpatch.yaml"

python3 -c "import yaml; list(yaml.safe_load_all(open('$temporary/manifests.yaml'))); print('manifests: valid')"

if [[ "${1:-}" == "--apply" ]]; then
  omnictl apply -f "$temporary/configpatch.yaml"
  printf 'Grafana Cloud secret ConfigPatch applied to Omni.\n'
else
  printf 'Grafana Cloud secret ConfigPatch rendered and validated; re-run with --apply to push to Omni.\n'
fi
