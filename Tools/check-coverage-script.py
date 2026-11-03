#!/usr/bin/env python3
# SPDX-FileCopyrightText: 2026 wsagency
# SPDX-License-Identifier: BUSL-1.1
"""Check Tools/check-coverage.sh against a fake `xcrun` that prints a canned `xccov view --report --only-targets` listing.

WSurf.app missing or under the floor fails; a package target (WSurfVault, WSurfCore) missing from the report only warns, naming
the target and the bundle; a package target in the report and under the floor fails. Every target is reported either way.
"""

import os
import subprocess
import tempfile
from pathlib import Path

SCRIPT = Path(__file__).resolve().parent / "check-coverage.sh"
HEADER = "ID Name          # Source Files Coverage\n-- ------------- -------------- -------------------\n"


def listing(**coverage: str) -> str:
    """The `--only-targets` table for the given target names (keyword names use `_` for `.`)."""
    rows = [f"{i}  {name.replace('_', '.')}  10  {value}% (1/2)\n" for i, (name, value) in enumerate(coverage.items())]
    return HEADER + "".join(rows)


def check(root: Path, report: str, *args: str, summary: bool = False) -> subprocess.CompletedProcess[str]:
    bin_dir = root / "bin"
    bin_dir.mkdir(exist_ok=True)
    (root / "report.txt").write_text(report)
    fake = bin_dir / "xcrun"
    fake.write_text(f'#!/bin/sh\ncat "{root}/report.txt"\n')
    fake.chmod(0o755)
    bundle = root / "Results.xcresult"
    bundle.mkdir(exist_ok=True)
    env = {k: v for k, v in os.environ.items() if not k.startswith("GITHUB_")}
    env["PATH"] = f"{bin_dir}:{env['PATH']}"
    if summary:
        env["GITHUB_STEP_SUMMARY"] = str(root / "summary.md")
    return subprocess.run(
        ["/bin/sh", str(SCRIPT), str(bundle), *args], env=env, capture_output=True, text=True, timeout=60
    )


def main() -> None:
    with tempfile.TemporaryDirectory() as tmp:
        root = Path(tmp)
        full = listing(WSurf_app="57.84", WSurfCore="86.51", WSurfVault="61.20")

        done = check(root, full, "24.0", summary=True)
        assert done.returncode == 0, done
        for line in ("WSurf.app coverage: 57.84%", "WSurfVault coverage: 61.20%", "WSurfCore coverage: 86.51%"):
            assert line in done.stdout, done.stdout
        assert "WARNING" not in done.stderr, done.stderr
        summary = (root / "summary.md").read_text()
        assert "WSurfVault: **61.20%**" in summary, summary

        # A package target left out of the report: a warning that names the target and the bundle, exit 0, the rest still read.
        no_vault = check(root, listing(WSurf_app="57.84", WSurfCore="86.51"), "24.0", summary=True)
        assert no_vault.returncode == 0, no_vault
        assert "WARNING: WSurfVault is not in the coverage report of" in no_vault.stderr, no_vault.stderr
        assert "Results.xcresult" in no_vault.stderr, no_vault.stderr
        assert "WSurf.app coverage: 57.84%" in no_vault.stdout and "WSurfCore coverage: 86.51%" in no_vault.stdout, no_vault.stdout
        assert "WSurfVault: **not in the report**" in (root / "summary.md").read_text()

        no_core = check(root, listing(WSurf_app="57.84", WSurfVault="61.20"), "24.0")
        assert no_core.returncode == 0 and "WARNING: WSurfCore is not in" in no_core.stderr, no_core

        none = check(root, listing(WSurf_app="57.84"), "24.0")
        assert none.returncode == 0, none
        assert "WSurfVault is not in" in none.stderr and "WSurfCore is not in" in none.stderr, none.stderr

        env = {**os.environ, "PATH": f"{root / 'bin'}:{os.environ['PATH']}", "GITHUB_ACTIONS": "true"}
        annotated = subprocess.run(
            ["/bin/sh", str(SCRIPT), str(root / "Results.xcresult"), "24.0"],
            env=env,
            capture_output=True,
            text=True,
            timeout=60,
        )
        assert annotated.returncode == 0 and "::warning title=Coverage::WSurfVault" in annotated.stdout, annotated

        # The app target is required.
        no_app = check(root, listing(WSurfCore="86.51", WSurfVault="61.20"), "24.0")
        assert no_app.returncode == 1 and "could not read coverage for WSurf.app" in no_app.stderr, no_app
        assert "WSurfCore coverage: 86.51%" in no_app.stdout, no_app.stdout

        # Below the floor fails for every target that is in the report, the others are still reported.
        low_app = check(root, listing(WSurf_app="23.99", WSurfCore="86.51", WSurfVault="61.20"), "24.0")
        assert low_app.returncode == 1 and "WSurf.app coverage is 23.99%" in low_app.stderr, low_app
        assert "WSurfVault coverage: 61.20%" in low_app.stdout, low_app.stdout
        low_core = check(root, listing(WSurf_app="57.84", WSurfCore="12.00", WSurfVault="61.20"), "24.0")
        assert low_core.returncode == 1 and "WSurfCore coverage is 12.00%" in low_core.stderr, low_core
        assert "WSurf.app coverage: 57.84%" in low_core.stdout and "WSurfVault coverage: 61.20%" in low_core.stdout

        # The floor is inclusive, and a single TARGET argument is checked on its own.
        assert check(root, listing(WSurf_app="24.00", WSurfCore="24.00", WSurfVault="24.00"), "24.0").returncode == 0
        only_vault = check(root, listing(WSurf_app="57.84"), "24.0", "WSurfVault")
        assert only_vault.returncode == 0 and "WSurfVault is not in" in only_vault.stderr, only_vault

        missing_bundle = subprocess.run(
            ["/bin/sh", str(SCRIPT), str(root / "nowhere.xcresult")], capture_output=True, text=True, timeout=60
        )
        assert missing_bundle.returncode == 1 and "result bundle not found" in missing_bundle.stderr, missing_bundle
    print("coverage: a missing package target warns, the app target and any floor breach fail")


if __name__ == "__main__":
    main()
