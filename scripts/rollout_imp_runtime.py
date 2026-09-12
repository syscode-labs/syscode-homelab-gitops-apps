#!/usr/bin/env python3
"""Safely replace stale imp-runtime OnDelete DaemonSet pods.

Use only after Argo CD has synced a new immutable runtime image. The default is
read-only. --apply deletes at most one stale pod at a time and waits for its
replacement to be Ready on the same node with the desired image digest.

The gate fails closed when any ImpVM is nonterminal. This prevents a runtime
restart while a one-use runner may be registering, claimed, or executing work.
Scale the runner pool to zero through GitOps and wait for all ImpVMs to finish
before rerunning with --apply.
"""

import argparse
import json
import re
import subprocess
import sys
import time
from typing import Any

DIGEST_RE = re.compile(r"sha256:[0-9a-f]{64}")


def kubectl(args: list[str], context: str | None, check: bool = True) -> subprocess.CompletedProcess[str]:
    command = ["kubectl"]
    if context:
        command += ["--context", context]
    command += args
    result = subprocess.run(command, capture_output=True, text=True)
    if check and result.returncode:
        raise RuntimeError(result.stderr.strip() or "kubectl command failed")
    return result


def get_json(args: list[str], context: str | None) -> dict[str, Any]:
    return json.loads(kubectl([*args, "-o", "json"], context).stdout)


def digest(image: str) -> str:
    match = DIGEST_RE.search(image)
    if not match:
        raise RuntimeError(f"expected an immutable sha256 image reference, got {image!r}")
    return match.group(0)


def ready(pod: dict[str, Any]) -> bool:
    return any(
        condition.get("type") == "Ready" and condition.get("status") == "True"
        for condition in pod.get("status", {}).get("conditions", [])
    )


def pod_digest(pod: dict[str, Any]) -> str | None:
    statuses = pod.get("status", {}).get("containerStatuses", [])
    if not statuses:
        return None
    image_id = statuses[0].get("imageID", "")
    match = DIGEST_RE.search(image_id)
    return match.group(0) if match else None


def selector_args(match_labels: dict[str, str]) -> list[str]:
    if not match_labels:
        raise RuntimeError("DaemonSet selector has no matchLabels; refusing to select pods")
    return ["-l", ",".join(f"{key}={value}" for key, value in sorted(match_labels.items()))]


def nonterminal_vms(namespace: str, context: str | None) -> list[str]:
    items = get_json(["-n", namespace, "get", "impvms.imp.dev"], context).get("items", [])
    blocked = []
    for vm in items:
        status = vm.get("status", {})
        phase = status.get("phase", "Unknown")
        exit_code = status.get("runnerExitCode")
        if phase != "Terminated" and exit_code is None:
            blocked.append(f"{vm['metadata']['name']} (phase={phase})")
    return blocked


def replacement_ready(
    namespace: str,
    selector: list[str],
    node: str,
    expected_digest: str,
    context: str | None,
    timeout_seconds: int,
) -> bool:
    deadline = time.monotonic() + timeout_seconds
    while time.monotonic() < deadline:
        pods = get_json(["-n", namespace, "get", "pods", *selector], context).get("items", [])
        candidates = [pod for pod in pods if pod.get("spec", {}).get("nodeName") == node]
        if any(ready(pod) and pod_digest(pod) == expected_digest for pod in candidates):
            return True
        time.sleep(2)
    return False


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--context", help="kubectl context; defaults to the current context")
    parser.add_argument("--namespace", default="imp-system")
    parser.add_argument("--daemonset", default="imp-runtime")
    parser.add_argument("--timeout", type=int, default=300, help="per-pod replacement timeout in seconds")
    parser.add_argument("--apply", action="store_true", help="delete stale pods after all safety gates pass")
    args = parser.parse_args()

    try:
        daemonset = get_json(["-n", args.namespace, "get", "daemonset", args.daemonset], args.context)
        if daemonset.get("spec", {}).get("updateStrategy", {}).get("type") != "OnDelete":
            raise RuntimeError("runtime DaemonSet is not OnDelete; refusing this manual rollout path")

        containers = daemonset.get("spec", {}).get("template", {}).get("spec", {}).get("containers", [])
        if len(containers) != 1:
            raise RuntimeError("expected exactly one runtime container; refusing ambiguous image verification")
        expected_digest = digest(containers[0].get("image", ""))
        selector = selector_args(daemonset["spec"]["selector"].get("matchLabels", {}))
        pods = get_json(["-n", args.namespace, "get", "pods", *selector], args.context).get("items", [])
        stale = [pod for pod in pods if pod_digest(pod) != expected_digest]

        blocked = nonterminal_vms(args.namespace, args.context)
        if blocked:
            raise RuntimeError(
                "refusing runtime rollout while ImpVMs are nonterminal: "
                + ", ".join(blocked)
                + ". Scale the runner pool to zero through GitOps and wait for cleanup first."
            )

        if not stale:
            print(f"OK: every {args.daemonset} pod already uses {expected_digest}")
            return 0

        names = ", ".join(pod["metadata"]["name"] for pod in stale)
        if not args.apply:
            print(f"DRY RUN: would replace stale pods one at a time: {names}")
            return 0

        for pod in stale:
            name = pod["metadata"]["name"]
            node = pod.get("spec", {}).get("nodeName")
            if not node:
                raise RuntimeError(f"pod {name} has no assigned node")
            print(f"Replacing {name} on {node} ...")
            kubectl(["-n", args.namespace, "delete", "pod", name, "--wait=false"], args.context)
            if not replacement_ready(args.namespace, selector, node, expected_digest, args.context, args.timeout):
                raise RuntimeError(f"replacement on {node} did not become Ready with {expected_digest}")
            print(f"OK: replacement on {node} is Ready with {expected_digest}")
    except (KeyError, RuntimeError, json.JSONDecodeError) as exc:
        print(f"FAIL: {exc}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
