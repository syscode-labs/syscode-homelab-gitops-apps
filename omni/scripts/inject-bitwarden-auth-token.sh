#!/usr/bin/env bash
# Bootstrap OCI External Secrets' Bitwarden provider token through Omni, never Git.
#
# Secret zero is applied twice deliberately: the ConfigPatch restores it on a
# future cluster bootstrap and kubectl restores it immediately on a running
# cluster. Neither path prints the token or persists it in this repository.
set -euo pipefail

CLUSTER="oci-lab"
NAMESPACE="oci-pivot-system"
SECRET="bw-auth-token"
STORE="bitwarden-oci"
EXTERNAL_SECRET="unraid-lab-cluster"
PROJECT_ID="e3948052-3ef9-4cab-9f09-b4a100eb52a6"
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"

if [[ "${1:-}" != "--apply" ]]; then
  printf 'Usage: %s --apply\n' "${0##*/}" >&2
  printf 'Creates/updates OCI secret zero through an Omni ConfigPatch and the live API, then waits for ESO readiness.\n' >&2
  exit 2
fi

[[ -r "$HOME/.bws_token" ]] || {
  printf 'missing readable BWS token file: %s/.bws_token\n' "$HOME" >&2
  exit 1
}
# Allow an explicit pinned CLI for an Omni backend upgrade. Prefer the matching
# local 1.11 client when it is installed; the PATH shim can lag the backend.
if [[ -n "${OMNICTL_BIN:-}" ]]; then
  OMNICTL="$OMNICTL_BIN"
elif [[ -x "$HOME/.local/share/mise/installs/omnictl/1.11.0/omnictl" ]]; then
  OMNICTL="$HOME/.local/share/mise/installs/omnictl/1.11.0/omnictl"
else
  OMNICTL="$(command -v omnictl)"
fi
[[ -x "$OMNICTL" ]] || { printf 'omnictl executable is unavailable: %s\n' "$OMNICTL" >&2; exit 1; }
command -v kubectl >/dev/null
command -v bws >/dev/null

BWS_ACCESS_TOKEN="$(<"$HOME/.bws_token")"
export BWS_ACCESS_TOKEN
# Validate that this token can see the exact project configured in bitwarden-oci;
# discard BWS output because it can contain operational metadata not needed here.
bws project list --output json | python3 -c \
  'import json, sys; projects = json.load(sys.stdin); raise SystemExit(0 if any(p.get("id") == sys.argv[1] for p in projects) else "BWS token cannot access the configured ESO project")' \
  "$PROJECT_ID" >/dev/null
unset BWS_ACCESS_TOKEN

workdir="$(mktemp -d)"
trap 'rm -rf "$workdir"; unset BWS_TOKEN' EXIT
BWS_TOKEN="$(<"$HOME/.bws_token")"

# Build the manifest with kubectl rather than interpolating the token into YAML:
# this preserves every token byte and keeps it out of Git and stdout.
printf '%s' "$BWS_TOKEN" >"$workdir/token"
chmod 600 "$workdir/token"
kubectl -n "$NAMESPACE" create secret generic "$SECRET" \
  --from-file="token=$workdir/token" --dry-run=client -o yaml >"$workdir/secret.yaml"
chmod 600 "$workdir/secret.yaml"

python3 - "$workdir/secret.yaml" "$workdir/configpatch.yaml" "$CLUSTER" <<'PY'
import sys
from pathlib import Path
import yaml

class Literal(str):
    pass

def represent_literal(dumper, data):
    return dumper.represent_scalar("tag:yaml.org,2002:str", data, style="|")

yaml.SafeDumper.add_representer(Literal, represent_literal)
secret_path, configpatch_path, cluster = map(Path, sys.argv[1:]) if False else (Path(sys.argv[1]), Path(sys.argv[2]), sys.argv[3])
contents = secret_path.read_text()
list(yaml.safe_load_all(contents))
patch = {"cluster": {"inlineManifests": [{"name": "oci-bitwarden-auth-token", "contents": Literal(contents)}]}}
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
PY
chmod 600 "$workdir/configpatch.yaml"

"$OMNICTL" apply -f "$workdir/configpatch.yaml" >/dev/null
"$OMNICTL" kubeconfig "$workdir/kubeconfig" --cluster "$CLUSTER" --merge=false --force >/dev/null

# Do not use a manifest in repository state. The token remains only in process
# memory, the short-lived 0600 file, the authorized live Secret, and Omni.
# Recreate from the token file through a pipe for the live repair; no token-bearing
# manifest is printed or retained outside the private temporary directory.
kubectl -n "$NAMESPACE" create secret generic "$SECRET" \
  --from-file="token=$workdir/token" --dry-run=client -o yaml | \
  KUBECONFIG="$workdir/kubeconfig" kubectl apply --server-side \
    --field-manager=oci-secret-zero-bootstrap -f - >/dev/null

KUBECONFIG="$workdir/kubeconfig" kubectl wait --for=condition=Ready \
  "clustersecretstore/${STORE}" --timeout=5m >/dev/null
KUBECONFIG="$workdir/kubeconfig" kubectl -n argocd annotate \
  "externalsecret/${EXTERNAL_SECRET}" "force-sync=$(date +%s)" --overwrite >/dev/null
KUBECONFIG="$workdir/kubeconfig" kubectl -n argocd wait --for=condition=Ready \
  "externalsecret/${EXTERNAL_SECRET}" --timeout=5m >/dev/null

# Metadata-only evidence: no Secret values are decoded or printed.
KUBECONFIG="$workdir/kubeconfig" kubectl -n "$NAMESPACE" get secret "$SECRET" \
  -o go-template='secret={{.metadata.namespace}}/{{.metadata.name}} keys={{range $key, $_ := .data}}{{$key}},{{end}} owners={{range .metadata.ownerReferences}}{{.kind}}/{{.name}},{{end}}{{"\n"}}'
KUBECONFIG="$workdir/kubeconfig" kubectl get "clustersecretstore/${STORE}" \
  -o jsonpath='store={.metadata.name} ready={.status.conditions[?(@.type=="Ready")].status}{"\n"}'
KUBECONFIG="$workdir/kubeconfig" kubectl -n argocd get "externalsecret/${EXTERNAL_SECRET}" \
  -o jsonpath='externalsecret={.metadata.name} ready={.status.conditions[?(@.type=="Ready")].status}{"\n"}'
KUBECONFIG="$workdir/kubeconfig" kubectl -n argocd get secret "$EXTERNAL_SECRET" \
  -o go-template='secret={{.metadata.namespace}}/{{.metadata.name}} keys={{range $key, $_ := .data}}{{$key}},{{end}} owners={{range .metadata.ownerReferences}}{{.kind}}/{{.name}},{{end}}{{"\n"}}'
