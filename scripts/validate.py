#!/usr/bin/env python3
"""Validate the GitOps manifests the way Argo CD will actually apply them.

Data-driven, no hardcoded chart list:
  * Every Argo `Application` with a Helm chart source is rendered with its own
    layered valueFiles (`helm template`) and the *output* is schema-checked
    (`kubeconform`). This catches bad values and wrong CRDs, not just "the file
    has a kind".
  * Every other manifest that carries a `kind` is schema-checked directly.
  * Files with no `kind` (Helm values, Talos inline-manifest patches, app.yaml
    coord files) are not Kubernetes manifests and are skipped.

Runs identically locally and in CI — `python3 scripts/validate.py`. Needs
`helm`; uses `kubeconform` when present (skips schema checks with a warning if
it is not, so `helm template` render errors still surface locally).
"""

import glob
import os
import shutil
import subprocess
import sys

import yaml

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
SEARCH_DIRS = ["bootstrap", "infrastructure", "clusters", "apps", "types"]
TOP_LEVEL = ["appset.yaml"]
KUBECONFORM = shutil.which("kubeconform")
KC_ARGS = ["-strict", "-ignore-missing-schemas", "-summary"]


def ci_error(msg: str) -> None:
    print(f"::error::{msg}" if os.environ.get("CI") else f"ERROR: {msg}")


def load_docs(path: str):
    """Return the list of mapping documents, or None on a YAML parse error."""
    with open(path) as f:
        try:
            return [d for d in yaml.safe_load_all(f) if isinstance(d, dict)]
        except yaml.YAMLError as exc:
            ci_error(f"{path}: YAML parse error: {exc}")
            return None


def helm_chart_source(app: dict):
    """(repoURL, chart, version, [valueFiles]) for the chart source, else None."""
    spec = app.get("spec", {})
    sources = spec.get("sources") or ([spec["source"]] if "source" in spec else [])
    for src in sources:
        if "chart" in src:
            value_files = [
                vf.replace("$values/", "", 1)
                for vf in src.get("helm", {}).get("valueFiles", [])
            ]
            return src["repoURL"], src["chart"], str(src.get("targetRevision", "")), value_files
    return None


def render_and_check(name: str, repo: str, chart: str, version: str, value_files) -> bool:
    """helm template the chart with its values, pipe the output to kubeconform."""
    if repo.startswith(("http://", "https://")):
        chart_ref, repo_args = chart, ["--repo", repo]
    else:  # OCI registry, e.g. ghcr.io/actions/...
        chart_ref, repo_args = f"oci://{repo.rstrip('/')}/{chart}", []

    cmd = ["helm", "template", name, chart_ref, *repo_args]
    if version:
        cmd += ["--version", version]
    for vf in value_files:
        if not os.path.exists(vf):
            ci_error(f"{name}: valueFile not found: {vf}")
            return False
        cmd += ["-f", vf]

    tmpl = subprocess.run(cmd, capture_output=True, text=True)
    if tmpl.returncode != 0:
        ci_error(f"helm template failed for {name}:\n{tmpl.stderr.strip()}")
        return False

    if not KUBECONFORM:
        return True
    check = subprocess.run(
        [KUBECONFORM, *KC_ARGS], input=tmpl.stdout, capture_output=True, text=True
    )
    sys.stdout.write(check.stdout)
    if check.returncode != 0:
        ci_error(f"kubeconform failed on rendered {name}:\n{check.stderr.strip()}")
        return False
    return True


def main() -> int:
    os.chdir(ROOT)
    files = []
    for d in SEARCH_DIRS:
        for ext in ("yaml", "yml"):
            files += glob.glob(f"{d}/**/*.{ext}", recursive=True)
    files += [f for f in TOP_LEVEL if os.path.exists(f)]

    ok = True
    schema_targets = []  # manifests with a kind, schema-checked in one batch

    for path in sorted(set(files)):
        docs = load_docs(path)
        if docs is None:
            ok = False
            continue

        # chart-app coord file (apps/*/app.yaml) consumed by appset.yaml. No kind;
        # render it the way the ApplicationSet would — chart + base values.
        # ponytail: base layer only; values/types|clusters overlays are per-cluster
        # (empty for now) and validated at sync time, not repo-wide here.
        if os.path.basename(path) == "app.yaml" and docs and "chart" in docs[0]:
            coord = docs[0]
            app = os.path.basename(os.path.dirname(path))
            base_values = f"values/base/{app}.yaml"
            value_files = [base_values] if os.path.exists(base_values) else []
            print(f"── render chart-app {app}  ({path})")
            if not render_and_check(
                app, coord["repoURL"], coord["chart"], str(coord.get("version", "")), value_files
            ):
                ok = False
            continue

        if not any("kind" in d for d in docs):
            continue  # values / Talos patch — not a k8s manifest

        for doc in docs:
            if doc.get("kind") == "Application":
                source = helm_chart_source(doc)
                if source:
                    name = doc.get("metadata", {}).get("name", "app")
                    print(f"── render Application {name}  ({path})")
                    if not render_and_check(name, *source):
                        ok = False
        schema_targets.append(path)

    if schema_targets and KUBECONFORM:
        print("── schema-check manifests")
        if subprocess.run([KUBECONFORM, *KC_ARGS, *schema_targets]).returncode != 0:
            ok = False
    elif not KUBECONFORM:
        print("WARNING: kubeconform not found — ran helm template only, skipped schema checks")

    print("OK" if ok else "FAILED")
    return 0 if ok else 1


if __name__ == "__main__":
    sys.exit(main())
