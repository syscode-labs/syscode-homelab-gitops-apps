#!/usr/bin/env bash
# Expose unauthenticated etcd metrics only to the cluster's control planes.
# The companion Cilium policy restricts Pod-to-node traffic to Grafana Alloy.
set -euo pipefail

CLUSTER="unraid-lab"
PATCH_ID="520-cluster-${CLUSTER}-etcd-metrics"

temporary="$(mktemp -d)"
trap 'rm -rf "$temporary"' EXIT

cat >"$temporary/patch.yaml" <<'YAML'
cluster:
  etcd:
    extraArgs:
      listen-metrics-urls: http://0.0.0.0:2381
---
apiVersion: v1alpha1
kind: NetworkRuleConfig
name: etcd-metrics
portSelector:
  ports:
    - 2381
  protocol: tcp
ingress:
  - subnet: 192.168.122.109/32
  - subnet: 192.168.122.190/32
  - subnet: 192.168.122.214/32
YAML

python3 - "$temporary/patch.yaml" "$temporary/configpatch.yaml" "$CLUSTER" "$PATCH_ID" <<'PY'
import sys
from pathlib import Path

import yaml


class Literal(str):
    pass


def represent_literal(dumper, data):
    return dumper.represent_scalar("tag:yaml.org,2002:str", data, style="|")


yaml.SafeDumper.add_representer(Literal, represent_literal)

patch_path, configpatch_path, cluster, patch_id = map(Path, sys.argv[1:])
patch = patch_path.read_text()
list(yaml.safe_load_all(patch))
configpatch = {
    "metadata": {
        "namespace": "default",
        "type": "ConfigPatches.omni.sidero.dev",
        "id": str(patch_id),
        "labels": {"omni.sidero.dev/cluster": str(cluster)},
    },
    "spec": {"data": Literal(patch)},
}
configpatch_path.write_text(yaml.safe_dump(configpatch, sort_keys=False))
print("Talos etcd metrics patch: valid")
PY

if [[ "${1:-}" == "--apply" ]]; then
  omnictl apply -f "$temporary/configpatch.yaml"
  printf 'Etcd metrics ConfigPatch applied. Reboot control-plane nodes one at a time before enabling the Grafana scrape.\n'
else
  printf 'Etcd metrics ConfigPatch rendered and validated; re-run with --apply to push to Omni.\n'
fi
