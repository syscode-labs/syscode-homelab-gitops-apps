#!/usr/bin/env bash
# Bootstrap the Bitwarden operator's machine token through Omni, never Git.
set -euo pipefail

CLUSTER="unraid-lab"
BWS_ACCESS_TOKEN="${BWS_ACCESS_TOKEN:-$(security find-generic-password -w -a "$USER" -s BWS_ACCESS_TOKEN)}"

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
  name: bw-auth-token
  namespace: monitoring
type: Opaque
stringData:
  token: "${BWS_ACCESS_TOKEN}"
YAML

python3 - "$temporary/manifests.yaml" "$temporary/configpatch.yaml" "$CLUSTER" <<'PY'
import sys
from pathlib import Path

import yaml


class Literal(str):
    pass


def represent_literal(dumper, data):
    return dumper.represent_scalar("tag:yaml.org,2002:str", data, style="|")


yaml.SafeDumper.add_representer(Literal, represent_literal)

manifests_path = Path(sys.argv[1])
configpatch_path = Path(sys.argv[2])
cluster = sys.argv[3]
manifests = manifests_path.read_text()
list(yaml.safe_load_all(manifests))

patch = {
    "cluster": {
        "inlineManifests": [
            {"name": "bitwarden-auth-token", "contents": Literal(manifests)}
        ]
    }
}
configpatch = {
    "metadata": {
        "namespace": "default",
        "type": "ConfigPatches.omni.sidero.dev",
        "id": f"510-cluster-{cluster}-bitwarden-auth-token",
        "labels": {"omni.sidero.dev/cluster": cluster},
    },
    "spec": {"data": Literal(yaml.safe_dump(patch, sort_keys=False))},
}
configpatch_path.write_text(yaml.safe_dump(configpatch, sort_keys=False))
print("manifests: valid")
PY

if [[ "${1:-}" == "--apply" ]]; then
  omnictl apply -f "$temporary/configpatch.yaml"
  printf 'Bitwarden auth-token ConfigPatch applied to Omni.\n'
else
  printf 'Bitwarden auth-token ConfigPatch rendered and validated; re-run with --apply to push to Omni.\n'
fi
