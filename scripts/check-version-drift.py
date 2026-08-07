#!/usr/bin/env python3
"""Fail if any version-bearing file disagrees with omni/versions.yaml.

versions.yaml is the hand-owned declaration of what should run. Every other
version reference in this repo is derived from it and must agree. Without this
check, editing versions.yaml in a way that needs no new image (flipping a
cluster back to a version already built, say) leaves the derived files stale,
because nothing rebuilds them — the build workflow only opens a PR when it has
an image to build.

That is the failure this repo already lived through: the ledger and machine
classes moved to v1.14.0-beta.1 while oci-lab.yaml stayed on v1.13.7, and
nothing failed until a cluster refused its config.

Runs identically locally and in CI — `python3 scripts/check-version-drift.py`.
"""

import os
import re
import sys

import yaml

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))

# Files owned by a cluster: which cluster, and which versions to check.
# unraid-lab's machine classes and template are generated in omni-on-unraid
# from this same file, so they are deliberately absent here.
OCI_LAB_FILES = [
    "omni/cluster-templates/oci-lab.yaml",
    "omni/machine-classes/control-plane.yaml",
    "omni/machine-classes/worker.yaml",
]


def resolve(versions, cluster):
    """Resolve (talos, kubernetes) for a cluster.

    Kubernetes is never inherited across a diverging Talos target: a cluster
    that overrides talos without kubernetes cannot keep the global Kubernetes
    pin, which belongs to a different Talos minor.
    """
    entry = (versions.get("clusters") or {}).get(cluster) or {}
    talos = entry.get("talos") or versions.get("talos")
    k8s = entry.get("kubernetes")
    if k8s is None:
        if entry.get("talos") and entry["talos"] != versions.get("talos"):
            return talos, None  # caller reports: needs an explicit pin
        k8s = versions.get("kubernetes")
    return talos, k8s


def main():
    path = os.path.join(ROOT, "omni/versions.yaml")
    with open(path) as fh:
        versions = yaml.safe_load(fh) or {}

    if not versions.get("talos") or not versions.get("kubernetes"):
        print("ERROR: omni/versions.yaml must set both talos and kubernetes")
        return 1

    talos, k8s = resolve(versions, "oci-lab")
    errors = []

    if k8s is None:
        errors.append(
            "oci-lab overrides talos to %s but sets no kubernetes version. "
            "Derive it from that Talos release and pin it explicitly — the "
            "global kubernetes pin belongs to a different Talos minor." % talos
        )
        k8s = ""

    for rel in OCI_LAB_FILES:
        full = os.path.join(ROOT, rel)
        if not os.path.exists(full):
            errors.append("%s: missing" % rel)
            continue
        text = open(full).read()

        if "machine-classes" in rel:
            found = re.findall(r"^\s*installImage:.*:(\S+)$", text, re.M)
            if not found:
                errors.append("%s: no installImage found" % rel)
            for tag in found:
                # Tags may carry a variant suffix, e.g. v1.13.7-libvirt.
                if not tag.startswith(talos):
                    errors.append(
                        "%s: installImage tag %s does not match oci-lab's "
                        "Talos pin %s" % (rel, tag, talos)
                    )
        else:
            doc = yaml.safe_load(text) or {}
            got_talos = (doc.get("talos") or {}).get("version")
            got_k8s = (doc.get("kubernetes") or {}).get("version")
            if got_talos != talos:
                errors.append(
                    "%s: talos.version is %s, versions.yaml says %s"
                    % (rel, got_talos, talos)
                )
            if got_k8s != k8s:
                errors.append(
                    "%s: kubernetes.version is %s, versions.yaml says %s"
                    % (rel, got_k8s, k8s)
                )

    if errors:
        print("Version drift against omni/versions.yaml:\n")
        for err in errors:
            print("  - %s" % err)
        print(
            "\nversions.yaml is the source of truth. Update the derived files "
            "to match it, or correct the pin."
        )
        return 1

    print("No version drift. oci-lab: Talos %s, Kubernetes %s" % (talos, k8s))
    return 0


def selftest():
    g = {"talos": "v1.13.7", "kubernetes": "v1.36.3"}

    v = dict(g, clusters={"a": {}})
    assert resolve(v, "a") == ("v1.13.7", "v1.36.3"), "inherit both"

    v = dict(g, clusters={"a": None})
    assert resolve(v, "a") == ("v1.13.7", "v1.36.3"), "null entry inherits"

    v = dict(g, clusters={})
    assert resolve(v, "missing") == ("v1.13.7", "v1.36.3"), "absent cluster inherits"

    # Diverging Talos must not silently keep the global Kubernetes pin.
    v = dict(g, clusters={"a": {"talos": "v1.14.0"}})
    assert resolve(v, "a") == ("v1.14.0", None), "diverged talos needs explicit k8s"

    v = dict(g, clusters={"a": {"talos": "v1.14.0", "kubernetes": "v1.37.0"}})
    assert resolve(v, "a") == ("v1.14.0", "v1.37.0"), "both overridden"

    # Restating the global pin is not divergence.
    v = dict(g, clusters={"a": {"talos": "v1.13.7"}})
    assert resolve(v, "a") == ("v1.13.7", "v1.36.3"), "redundant pin still inherits"

    print("selftest ok")
    return 0


def write():
    """Repair the derived, owned files from versions.yaml, the source of
    truth. The counterpart to main(): where main() reports drift, --write
    makes the derived files agree with versions.yaml so the gate goes green.

    Conservative by design:
      * It only edits files this repo owns and that versions.yaml drives
        (oci-lab's machine classes and cluster template). It never touches
        omni/talos-image.yaml, a machine-owned build ledger.
      * It refuses to write when oci-lab's Kubernetes version cannot be
        resolved (a talos override with no explicit kubernetes pin), so it can
        never invent a pairing that violates the Kubernetes-never-inherited
        rule.
    """
    path = os.path.join(ROOT, "omni/versions.yaml")
    with open(path) as fh:
        versions = yaml.safe_load(fh) or {}

    if not versions.get("talos") or not versions.get("kubernetes"):
        print("ERROR: omni/versions.yaml must set both talos and kubernetes")
        return 1

    talos, k8s = resolve(versions, "oci-lab")
    if k8s is None:
        print(
            "ERROR: oci-lab overrides talos to %s with no kubernetes pin; "
            "cannot write a pairing. Pin kubernetes in versions.yaml first."
            % talos
        )
        return 1

    if _write(talos, k8s):
        print(
            "Rewrote derived files to match omni/versions.yaml "
            "(oci-lab: Talos %s, Kubernetes %s)." % (talos, k8s)
        )
        return 0
    print("No drift to repair; files already agree with omni/versions.yaml.")
    return 0


def _write(talos, k8s):
    changed = False
    for rel in OCI_LAB_FILES:
        full = os.path.join(ROOT, rel)
        if not os.path.exists(full):
            continue
        text = open(full).read()
        new = text

        if "machine-classes" in rel:
            # Swap the installer image tag (e.g. :v1.13.7) for the pinned Talos
            # version, preserving the image path and any variant suffix that
            # precedes the tag.
            new = re.sub(
                r"(\binstallImage:\s*\S+):(v\d[\w.-]*)",
                lambda m: "%s:%s" % (m.group(1), talos),
                new,
            )
        else:
            # Rewrite talos.version and kubernetes.version top-level blocks.
            # Scope each to its own block so a boundary `version:` line in a
            # nested document is never conflated with the one we mean.
            new = re.sub(
                r"(?m)^kubernetes:\s*\n(\s*version:)\s*\S+",
                lambda m: "kubernetes:\n%s %s" % (m.group(1), k8s),
                new,
            )
            new = re.sub(
                r"(?m)^talos:\s*\n(\s*version:)\s*\S+",
                lambda m: "talos:\n%s %s" % (m.group(1), talos),
                new,
            )

        if new != text:
            with open(full, "w") as fh:
                fh.write(new)
            changed = True
            print("  rewrote %s" % rel)
    return changed


if __name__ == "__main__":
    if "--selftest" in sys.argv:
        sys.exit(selftest())
    if "--write" in sys.argv:
        sys.exit(write())
    sys.exit(main())
