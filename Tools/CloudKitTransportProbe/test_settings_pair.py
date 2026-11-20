#!/usr/bin/env python3
# SPDX-FileCopyrightText: 2026 WSurf Agency
# SPDX-License-Identifier: BUSL-1.1

"""Exercise the driver across a lost response without contacting either host."""
import base64
import hashlib
import json
from pathlib import Path
import runpy
from tempfile import TemporaryDirectory
import unittest
from unittest.mock import patch


PAIR = runpy.run_path(str(Path(__file__).with_name("settings_pair.py")))
TAGS = {"studio": "6f49a885-1f87-4752-b7aa-3a42a1cb7907", "air": "a93cbd56-dcea-4e3c-ab31-58581c2a4eed"}
ACCOUNT = "a" * 64
RECEIPT = base64.b64encode(b"synthetic Studio receipt").decode()
STATUS = {"begin": "PASS Studio wrote 125%.", "answer": "PASS Air acknowledged the trial at 150%.",
          "confirm": "PASS Studio read the 150% reply.\nPASS explicit-owner metadata matched its full-record tag.",
          "cleanup": "PASS Studio verified the stored reset."}


class PairTests(unittest.TestCase):
    def setUp(self):
        self.state = {"tags": {}, "next": 0, "steps": []}
        self.calls = []

    def invoke(self, role, verb, peer):
        self.calls.append((role, verb, peer))
        return {"tag": TAGS[role], "account": ACCOUNT, "reserve": RECEIPT, **STATUS}[verb]

    def run_driver(self, invoke):
        with patch("builtins.print"):
            PAIR["drive"](self.state, lambda: None, invoke)

    def test_restarts_after_a_lost_confirmation_without_starting_another_record(self):
        def interrupted(role, verb, peer):
            if verb == "confirm":
                raise KeyboardInterrupt
            return self.invoke(role, verb, peer)

        with self.assertRaises(KeyboardInterrupt):
            self.run_driver(interrupted)
        self.assertEqual(self.state["next"], 2)
        self.run_driver(self.invoke)
        self.assertEqual(self.calls, [
            ("studio", "tag", None), ("air", "tag", None), ("studio", "account", None), ("air", "account", None),
            ("studio", "reserve", TAGS["air"]), ("studio", "begin", TAGS["air"]),
            ("air", "answer", TAGS["studio"]), ("studio", "confirm", TAGS["air"]), ("studio", "cleanup", TAGS["air"])])
        self.assertEqual(self.state["next"], 4)

    def test_failed_answer_cleans_owned_record_and_keeps_failure(self):
        def refuse(role, verb, peer):
            if verb == "answer":
                raise RuntimeError("wrong record")
            return self.invoke(role, verb, peer)

        with self.assertRaisesRegex(RuntimeError, "wrong record"):
            self.run_driver(refuse)
        self.assertTrue(self.state["aborted"])
        self.assertEqual(self.calls[-1], ("studio", "cleanup", TAGS["air"]))
        with self.assertRaisesRegex(RuntimeError, "failed trial"):
            self.run_driver(self.invoke)

    def test_other_command_output_cannot_stand_in_for_a_confirmed_value(self):
        def wrong_reply(role, verb, peer):
            return "PASS" if verb == "confirm" else self.invoke(role, verb, peer)

        with self.assertRaisesRegex(RuntimeError, "unexpected result"):
            self.run_driver(wrong_reply)
        self.assertEqual(self.state["next"], 2)

    def test_two_aliases_to_one_model_are_refused_before_cloud_work(self):
        with self.assertRaisesRegex(ValueError, "same product model"):
            self.run_driver(lambda *_: TAGS["studio"])
        self.assertEqual(self.state["next"], 0)

    def test_different_account_on_air_stops_before_any_mutation(self):
        def switched(role, verb, peer):
            return "b" * 64 if (role, verb) == ("air", "account") else self.invoke(role, verb, peer)
        with self.assertRaises(PAIR["OriginalAccountRequired"]):
            self.run_driver(switched)
        self.assertEqual(self.state["account"], ACCOUNT)
        self.assertNotIn("studio_receipt", self.state)
        self.assertEqual(self.state["steps"], [])
        self.assertNotIn(("studio", "begin", TAGS["air"]), self.calls)

    def test_account_change_after_lost_first_write_preserves_original_receipt_for_resume(self):
        def lost_reply(role, verb, peer):
            if verb == "begin":
                self.assertEqual((self.state["account"], self.state["studio_receipt"]), (ACCOUNT, RECEIPT))
                raise PAIR["OriginalAccountRequired"]("original Apple Account required")
            return self.invoke(role, verb, peer)
        with self.assertRaises(PAIR["OriginalAccountRequired"]):
            self.run_driver(lost_reply)
        self.assertEqual(self.state["next"], 0)
        self.assertNotIn("aborted", self.state)
        self.assertNotIn(("studio", "cleanup", TAGS["air"]), self.calls)
        self.run_driver(self.invoke)
        self.assertEqual(self.state["next"], 4)
        self.assertEqual(self.calls.count(("studio", "reserve", TAGS["air"])), 1)

    def test_old_unbound_evidence_is_retained_without_contacting_a_host(self):
        with TemporaryDirectory() as folder:
            path = Path(folder) / "settings-trial.json"
            archive = Path(folder) / "probe.zip"
            archive.write_bytes(b"old test archive")
            digest = hashlib.sha256(archive.read_bytes()).hexdigest()
            hosts = {"studio": "studio", "air": "air"}
            original = json.dumps({"source": {"archive_sha256": digest, "commit": "old", "hosts": hosts}, "next": 0})
            path.write_text(original)
            with self.assertRaisesRegex(ValueError, "predates account-bound receipts"):
                PAIR["run"](archive, digest, path, hosts, "old")
            self.assertEqual(path.read_text(), original)

    def test_recovers_same_trial_after_both_remote_stages_are_lost(self):
        stages = {}
        staged = []
        writes = []
        interrupted = False

        def remote(host, args, *, stdin=None):
            nonlocal interrupted
            if stdin is not None:
                staged.append(host)
                stages[host] = f"/tmp/wsurf-settings-{host}-{len(staged)}"
                return stages[host]
            if args[3] != stages.get(host):
                return PAIR["remote"]("local", [*args[:3], str(Path(folder) / "purged"), *args[4:]])
            verb = args[5].removeprefix("settings-")
            if verb == "tag":
                return TAGS[host]
            if verb == "account":
                return ACCOUNT
            if verb == "reserve":
                return RECEIPT
            if verb == "begin":
                saved = json.loads(path.read_text())
                self.assertEqual((saved["account"], saved["studio_receipt"]), (ACCOUNT, RECEIPT))
            if verb == "answer" and not interrupted:
                interrupted = True
                raise KeyboardInterrupt
            writes.append((host, verb, args[6], args[-1]))
            return STATUS[verb]

        with TemporaryDirectory() as folder:
            path = Path(folder) / "settings-trial.json"
            archive = Path(folder) / "probe.zip"
            archive.write_bytes(b"test archive")
            digest = hashlib.sha256(archive.read_bytes()).hexdigest()
            args = (archive, digest, path, {"studio": "studio", "air": "air"}, "test-commit")
            with patch.dict(PAIR["run"].__globals__, {"remote": remote}), patch("builtins.print"), patch("time.sleep"):
                with self.assertRaises(KeyboardInterrupt):
                    PAIR["run"](*args)
                before = json.loads(path.read_text())
                self.assertEqual(before["next"], 1)
                stages.clear()
                PAIR["run"](*args)
                after = json.loads(path.read_text())
        self.assertEqual(after["next"], 4)
        self.assertEqual(after["nonce"], before["nonce"])
        self.assertEqual(before["studio_receipt"], RECEIPT)
        self.assertEqual([entry[1] for entry in writes], ["begin", "answer", "confirm", "cleanup"])
        self.assertTrue(all(nonce == before["nonce"] and proof == RECEIPT for _, _, nonce, proof in writes))
        self.assertGreater(staged.count("studio"), 1)
        self.assertGreater(staged.count("air"), 1)


if __name__ == "__main__":
    unittest.main()
