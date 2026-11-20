#!/usr/bin/env python3
# SPDX-FileCopyrightText: 2026 WSurf Agency
# SPDX-License-Identifier: BUSL-1.1

"""Exercise the driver across a lost response without contacting either host."""
from pathlib import Path
import runpy
import unittest
from unittest.mock import patch


PAIR = runpy.run_path(str(Path(__file__).with_name("settings_pair.py")))
TAGS = {"studio": "6f49a885-1f87-4752-b7aa-3a42a1cb7907", "air": "a93cbd56-dcea-4e3c-ab31-58581c2a4eed"}
STATUS = {"begin": "PASS Studio wrote 125%.", "answer": "PASS Air acknowledged the trial at 150%.",
          "confirm": "PASS Studio read the 150% reply.\nPASS explicit-owner metadata matched its full-record tag.",
          "cleanup": "PASS Studio verified the stored reset."}


class PairTests(unittest.TestCase):
    def setUp(self):
        self.state = {"tags": {}, "next": 0, "steps": []}
        self.calls = []

    def invoke(self, role, verb, peer):
        self.calls.append((role, verb, peer))
        return TAGS[role] if verb == "tag" else STATUS[verb]

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
            ("studio", "tag", None), ("air", "tag", None), ("studio", "begin", TAGS["air"]),
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


if __name__ == "__main__":
    unittest.main()
