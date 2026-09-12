#!/usr/bin/env python3
import contextlib
import importlib.util
import io
import pathlib
import sys
import unittest
from unittest.mock import patch

SCRIPT = pathlib.Path(__file__).with_name("rollout_imp_runtime.py")
spec = importlib.util.spec_from_file_location("rollout_imp_runtime", SCRIPT)
if spec is None or spec.loader is None:
    raise RuntimeError(f"cannot load {SCRIPT}")
rollout = importlib.util.module_from_spec(spec)
spec.loader.exec_module(rollout)


class RolloutGateTests(unittest.TestCase):
    def test_refuses_to_delete_when_a_runner_vm_is_nonterminal(self):
        daemonset = {
            "spec": {
                "updateStrategy": {"type": "OnDelete"},
                "selector": {"matchLabels": {"app": "imp-runtime"}},
                "template": {
                    "spec": {
                        "containers": [
                            {"image": "ghcr.io/example/imp@sha256:" + "a" * 64}
                        ]
                    }
                },
            }
        }
        stale_pod = {
            "metadata": {"name": "imp-runtime-old"},
            "spec": {"nodeName": "runner-node"},
            "status": {"containerStatuses": [{"imageID": "sha256:" + "b" * 64}]},
        }
        running_vm = {
            "metadata": {"name": "github-runner-active"},
            "status": {"phase": "Running", "runnerHandoffAccepted": True},
        }
        responses = iter([daemonset, {"items": [stale_pod]}, {"items": [running_vm]}])

        with (
            patch.object(rollout, "get_json", side_effect=lambda *_: next(responses)),
            patch.object(sys, "argv", ["rollout_imp_runtime.py", "--apply"]),
            patch.object(rollout, "kubectl") as kubectl,
            contextlib.redirect_stderr(io.StringIO()),
        ):
            self.assertEqual(rollout.main(), 1)

        kubectl.assert_not_called()


if __name__ == "__main__":
    unittest.main()
