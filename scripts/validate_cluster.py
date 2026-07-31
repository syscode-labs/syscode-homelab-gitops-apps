#!/usr/bin/env python3
"""Pre-merge gate check: assert every Argo CD Application on a cluster is
Synced + Healthy. Read-only — it only reads Application status, never syncs or
mutates anything.

Usage:
    python3 scripts/validate_cluster.py [--context <kube-context>] [--namespace argocd]

Exit 0 if all Applications are Synced+Healthy (and at least one exists), else 1.
Needs kubectl with a context that can read applications.argoproj.io.
"""

import argparse
import json
import subprocess
import sys
from typing import Optional


def get_applications(context: Optional[str], namespace: Optional[str]):
    cmd = ["kubectl", "get", "applications.argoproj.io", "-o", "json"]
    if namespace:
        cmd += ["-n", namespace]
    else:
        cmd += ["-A"]
    if context:
        cmd += ["--context", context]
    result = subprocess.run(cmd, capture_output=True, text=True)
    if result.returncode != 0:
        print(f"ERROR: kubectl failed:\n{result.stderr.strip()}", file=sys.stderr)
        sys.exit(2)
    return json.loads(result.stdout).get("items", [])


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--context", help="kube context (default: current)")
    ap.add_argument("--namespace", help="namespace (default: all)")
    args = ap.parse_args()

    apps = get_applications(args.context, args.namespace)
    if not apps:
        print("FAIL: no Argo CD Applications found — is Argo deployed and syncing this repo?")
        return 1

    ok = True
    width = max(len(a["metadata"]["name"]) for a in apps)
    for app in sorted(apps, key=lambda a: a["metadata"]["name"]):
        name = app["metadata"]["name"]
        status = app.get("status", {})
        sync = status.get("sync", {}).get("status", "Unknown")
        health = status.get("health", {}).get("status", "Unknown")
        good = sync == "Synced" and health == "Healthy"
        ok = ok and good
        print(f"  {'ok ' if good else 'BAD'}  {name:<{width}}  sync={sync}  health={health}")

    print("OK — all Applications Synced + Healthy" if ok else "FAILED — see BAD rows above")
    return 0 if ok else 1


if __name__ == "__main__":
    sys.exit(main())
