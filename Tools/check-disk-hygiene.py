#!/usr/bin/env python3
# SPDX-FileCopyrightText: 2026 WSurf Agency
# SPDX-License-Identifier: BUSL-1.1
"""Check the Pro disk hygiene helpers (Tools/disk-hygiene.sh, Tools/clean-pro-disk.sh) and the agent instructions.

Every case runs in its own temp directory with WSURF_CODE_SIGN_CLONE_ROOT, WSURF_TMP_ROOT(S), WSURF_REPO_ROOT and
WSURF_FREE_DISK_GB_OVERRIDE pointing into it, so the real X directory and /tmp/wsurf-cvs/pro.lock are never read or written.
"""

from __future__ import annotations  # /usr/bin/python3 is 3.9

import os
import subprocess
import tempfile
import time
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
LIBRARY = ROOT / "Tools" / "disk-hygiene.sh"
CLEANER = ROOT / "Tools" / "clean-pro-disk.sh"
OLD = time.time() - 3 * 24 * 3600


def environment(tmp: Path, **extra: str) -> dict[str, str]:
    # No inherited WSURF_* setting reaches a case: under Tools/ci-local.sh, WSURF_RUN_TMP names the caller's own run directory.
    env = {k: v for k, v in os.environ.items()
           if k not in {"GITHUB_ACTIONS", "RUNNER_ENVIRONMENT", "N"} and not k.startswith("WSURF_")}
    env.update(WSURF_CODE_SIGN_CLONE_ROOT=str(tmp / "X"), WSURF_TMP_ROOT=str(tmp / "ptmp"), TMPDIR=str(tmp / "T") + "/")
    env.update(extra)
    return env


def bash(tmp: Path, script: str, **extra: str) -> subprocess.CompletedProcess[str]:
    return subprocess.run(["/bin/bash", "-c", f'set -euo pipefail; . "{LIBRARY}"; {script}'], cwd=tmp,
                          env=environment(tmp, **extra), capture_output=True, text=True, timeout=30)


def make(path: Path, age: float | None = None) -> Path:
    path.mkdir(parents=True, exist_ok=True)
    (path / "payload").write_text("x" * 1024)
    if age is not None:
        os.utime(path, (age, age))
    return path


def check_code_sign_clone(tmp: Path) -> None:
    clones = tmp / "X"
    protected = ("io.wsagency.wsurf", "io.wsagency.wsurf.stage", "io.wsagency.wsurf.stage.1", "io.wsagency.wsurf.stage.abc",
                 "io.wsagency.wsurf.CredentialExchange")
    for name in ("io.wsagency.wsurf.ci-123", "io.wsagency.wsurf.dev-foo", *protected):
        make(clones / f"{name}.code_sign_clone")
    for name in ("io.wsagency.wsurf.ci-123", "io.wsagency.wsurf.dev-foo"):
        result = bash(tmp, f'wsurf_safe_remove_code_sign_clone "{name}"')
        assert result.returncode == 0, result
        assert not (clones / f"{name}.code_sign_clone").exists(), name
    for name in ("io.wsagency.wsurf", "io.wsagency.wsurf.", "io.wsagency.wsurf.stage", "io.wsagency.wsurf.stage.1",
                 "io.wsagency.wsurf.CredentialExchange", "../foo", "io.wsagency.wsurf.../foo", "io.wsagency.wsurf.a/b",
                 "io.wsagency.wsurf.*", "io.wsagency.wsurf.?", "io.wsagency.wsurf.[a]", "io.wsagency.wsurf.a b", "*", "",
                 # Case variants: APFS is case-insensitive, so each would name a protected directory.
                 "io.wsagency.wsurf.STAGE.abc", "io.wsagency.wsurf.Stage", "io.wsagency.wsurf.credentialexchange",
                 "io.wsagency.wsurf.CREDENTIALEXCHANGE", "IO.WSAGENCY.WSURF.foo"):
        result = bash(tmp, f'wsurf_safe_remove_code_sign_clone "{name}"')
        assert result.returncode != 0 and "refusing" in result.stderr, (name, result)
    for name in protected:
        assert (clones / f"{name}.code_sign_clone").exists(), name
    # The EXIT-trap helper skips the unsuffixed id and never fails.
    make(clones / "io.wsagency.wsurf.ci-9.code_sign_clone")
    result = bash(tmp, 'wsurf_exit_cleanup io.wsagency.wsurf io.wsagency.wsurf.ci-9 io.wsagency.wsurf.stage')
    assert result.returncode == 0, result
    assert not (clones / "io.wsagency.wsurf.ci-9.code_sign_clone").exists()
    assert (clones / "io.wsagency.wsurf.code_sign_clone").exists()


def check_run_tmpdir(tmp: Path) -> None:
    (tmp / "T").mkdir()
    lock = tmp / "T" / "wsurf-cvs" / "pro.lock"
    lock.parent.mkdir()
    lock.touch()
    result = bash(tmp, 'wsurf_setup_run_tmpdir; trap wsurf_exit_cleanup EXIT; touch "${TMPDIR}file"; '
                       'echo "$WSURF_RUN_TMP"; echo "$TMPDIR"')
    assert result.returncode == 0, result
    run_tmp, tmpdir = result.stdout.split()
    assert Path(run_tmp).name.startswith("wsurf-run-") and Path(run_tmp).parent == tmp / "T", run_tmp
    assert tmpdir == run_tmp + "/", tmpdir
    assert not Path(run_tmp).exists(), "the run's TMPDIR survived its EXIT trap"
    # A nested run makes a sibling, not a child: Chromium's AF_UNIX socket paths under TMPDIR are limited to 104 bytes.
    nested = bash(tmp, 'wsurf_setup_run_tmpdir; outer="$WSURF_RUN_TMP"; wsurf_setup_run_tmpdir; '
                       'echo "$(dirname "$outer") $(dirname "$WSURF_RUN_TMP")"; rm -rf "$outer" "$WSURF_RUN_TMP"')
    assert nested.returncode == 0, nested
    outer_parent, inner_parent = nested.stdout.split()
    assert outer_parent == inner_parent == str(tmp / "T"), nested.stdout
    assert lock.exists(), "the simulated Pro lock was removed"
    # The cleanup refuses any directory that is not a wsurf-run-* directory, so the lock directory is safe.
    result = bash(tmp, f'WSURF_RUN_TMP="{lock.parent}" wsurf_cleanup_run_tmpdir')
    assert result.returncode != 0 and lock.exists(), result


def check_disk_guard(tmp: Path) -> None:
    make(tmp / "X" / "io.wsagency.wsurf.big.code_sign_clone")
    make(tmp / "ptmp" / "wsurf-d4-leftover")
    low = bash(tmp, "wsurf_preflight_disk_guard", WSURF_FREE_DISK_GB_OVERRIDE="12")
    assert low.returncode == 1, low
    assert "below the 30 GB minimum" in low.stderr, low
    assert "io.wsagency.wsurf.big.code_sign_clone" in low.stderr and "wsurf-d4-leftover" in low.stderr, low
    assert bash(tmp, "wsurf_preflight_disk_guard", WSURF_FREE_DISK_GB_OVERRIDE="30").returncode == 0
    hosted = bash(tmp, "wsurf_preflight_disk_guard", WSURF_FREE_DISK_GB_OVERRIDE="20", RUNNER_ENVIRONMENT="github-hosted")
    assert hosted.returncode == 0 and "warning" in hosted.stdout, hosted
    hosted_low = bash(tmp, "wsurf_preflight_disk_guard", WSURF_FREE_DISK_GB_OVERRIDE="9", RUNNER_ENVIRONMENT="github-hosted")
    assert hosted_low.returncode == 1, hosted_low


def check_pass_artifacts(tmp: Path) -> None:
    out = tmp / "out"
    results = out / "results"
    make(results / "WSurf-Rest.xcresult")
    make(out / "TestResults.xcresult")
    evidence = [out / "validation-plan.json", out / "verified-results.sha256", out / "xcode-version.txt",
                results / "WSurf-Rest-tests.json"]
    for path in evidence:
        path.write_text("{}")
    build = tmp / "build"
    cache = make(build / "DD" / "SourcePackages")
    make(build / "DD" / "Build")
    make(build / "DD-oop")
    kept = bash(tmp, f'wsurf_cleanup_pass_artifacts "{out}"', GITHUB_ACTIONS="true")
    assert kept.returncode == 0 and (results / "WSurf-Rest.xcresult").exists(), "GitHub Actions must keep the bundles"
    result = bash(tmp, f'wsurf_cleanup_pass_artifacts "{out}" "{build / "DD"}" "{build / "DD-oop"}"',
                  WSURF_SOURCE_PACKAGES_CACHE=str(cache))
    assert result.returncode == 0, result
    assert not (results / "WSurf-Rest.xcresult").exists() and not (out / "TestResults.xcresult").exists()
    assert all(path.exists() for path in evidence), "evidence was removed"
    assert cache.exists() and not (build / "DD" / "Build").exists() and not (build / "DD-oop").exists()

    # Refused targets: a worktree root (a mistyped WSURF_OOP_DERIVED_DATA=$PWD), $HOME, / and any directory outside
    # build/. The worktree and home sit under build/, so only their own rule refuses them. A fake rm comes first on PATH,
    # so a broken guard only records what it would have removed.
    worktree = build / "worktree"
    subprocess.run(["git", "init", "-q", str(worktree)], check=True)
    home = make(build / "home")
    other = make(tmp / "other")
    fake = tmp / "fakebin"
    fake.mkdir()
    (fake / "rm").write_text(f'#!/bin/sh\necho "$@" >> "{tmp / "rm.log"}"\n')
    (fake / "rm").chmod(0o755)
    path = f'{fake}:{os.environ["PATH"]}'
    for target in (worktree, home, Path("/"), other):
        refused = bash(tmp, f'wsurf_cleanup_pass_artifacts "{out}" "{target}"', HOME=str(home), PATH=path)
        assert refused.returncode == 1 and "refusing" in refused.stderr, (target, refused)
    assert not (tmp / "rm.log").exists(), (tmp / "rm.log").read_text()
    assert worktree.exists() and home.exists() and other.exists()

    failed = tmp / "failed"
    old = make(failed / "a" / "old.xcresult", OLD)
    new = make(failed / "b" / "new.xcresult")
    result = bash(tmp, f'wsurf_prune_old_failed_xcresults "{failed}"')
    assert result.returncode == 0, result
    assert not old.exists() and new.exists()


def check_instructions() -> None:
    claude = (ROOT / "CLAUDE.md").read_text()
    agents = (ROOT / "AGENTS.md").read_text()
    assert "@AGENTS.md" in claude, "CLAUDE.md must include AGENTS.md"
    assert "## Pro Disk Hygiene Rules (MANDATORY" in agents
    for needle in ("code_sign_clone", "wsurf-run-XXXXXX", "/tmp/wsurf-cvs/pro.lock", ".xcresult", "git worktree prune",
                   "30 GB", "wsurf-site", ".github/workflows/deploy-site.yml", "CLOUDFLARE_API_TOKEN",
                   ".well-known/apple-app-site-association", "_headers", "wrangler.jsonc"):
        assert needle in agents, f"AGENTS.md lacks {needle}"


def check_cleaner(tmp: Path) -> None:
    clones = tmp / "X"
    for name in ("io.wsagency.wsurf", "io.wsagency.wsurf.stage", "io.wsagency.wsurf.stage.abc", "io.wsagency.wsurf.ci-1"):
        make(clones / f"{name}.code_sign_clone")
    ptmp = tmp / "ptmp"
    lock = ptmp / "wsurf-cvs" / "pro.lock"
    lock.parent.mkdir(parents=True)
    lock.touch()
    os.utime(lock.parent, (OLD, OLD))
    stale = make(ptmp / "wsurf-d4-old", OLD)
    fresh = make(ptmp / "wsurf-run-fresh0")
    # An old wsurf-run-* entry that resolves into wsurf-cvs is never a candidate.
    link = ptmp / "wsurf-run-lock00"
    link.symlink_to(lock.parent)
    os.utime(link, (OLD, OLD), follow_symlinks=False)
    repo = tmp / "repo"
    git = ["git", "-c", "user.name=t", "-c", "user.email=t@example.invalid"]
    subprocess.run([*git, "init", "-q", "-b", "main", str(repo)], check=True)
    (repo / ".gitignore").write_text("build/\n")  # as in the real repository, so build output is not a change
    subprocess.run([*git, "-C", str(repo), "add", ".gitignore"], check=True)
    subprocess.run([*git, "-C", str(repo), "commit", "-q", "-m", "init"], check=True)
    subprocess.run(["git", "-C", str(repo), "worktree", "add", "-q", "-b", "feature/merged", str(tmp / "merged")], check=True)
    subprocess.run(["git", "-C", str(repo), "worktree", "add", "-q", "-b", "feature/dirty", str(tmp / "dirty")], check=True)
    subprocess.run([*git, "-C", str(tmp / "merged"), "commit", "-q", "--allow-empty", "-m", "work"], check=True)
    subprocess.run([*git, "-C", str(repo), "merge", "-q", "--no-ff", "-m", "merge", "feature/merged"], check=True)
    subprocess.run(["git", "-C", str(repo), "update-ref", "refs/remotes/origin/main", "HEAD"], check=True)
    # Just branched from origin/main, with no commit yet: a new task, not a merged one.
    subprocess.run(["git", "-C", str(repo), "worktree", "add", "-q", "-b", "feature/fresh", str(tmp / "fresh")], check=True)
    (tmp / "dirty" / "work.txt").write_text("uncommitted")
    old_result = make(tmp / "merged" / "build" / "ci-local" / "1" / "old.xcresult", OLD)
    env = environment(tmp, WSURF_TMP_ROOTS=str(ptmp), WSURF_REPO_ROOT=str(repo))

    dry = subprocess.run([str(CLEANER)], env=env, capture_output=True, text=True, timeout=30)
    assert dry.returncode == 0, dry
    for needle in ("io.wsagency.wsurf.ci-1.code_sign_clone", "wsurf-d4-old", "old.xcresult", "Would free"):
        assert needle in dry.stdout, (needle, dry.stdout)
    assert "merged and clean" in dry.stdout and "keep (uncommitted changes" in dry.stdout, dry.stdout
    assert "merged and clean" not in "".join(l for l in dry.stdout.splitlines() if "/fresh" in l), dry.stdout
    assert "keep (no commits beyond origin/main" in dry.stdout, dry.stdout
    for needle in ("io.wsagency.wsurf.code_sign_clone", "stage", "wsurf-cvs", "wsurf-run-fresh0", "wsurf-run-lock00"):
        assert needle not in dry.stdout.replace("merged and clean", ""), (needle, dry.stdout)
    assert (clones / "io.wsagency.wsurf.ci-1.code_sign_clone").exists() and stale.exists() and old_result.exists()

    # --apply without a lock wrapper refuses and removes nothing.
    unlocked = subprocess.run([str(CLEANER), "--apply"], env={**env, "WSURF_PRO_LOCK": ""}, capture_output=True,
                              text=True, timeout=30)
    assert unlocked.returncode == 2 and stale.exists(), unlocked
    # --apply runs through the lock wrapper: a fake one records that it was used, then runs the cleaner.
    wrapper = tmp / "with-lock.sh"
    wrapper.write_text(f'#!/bin/sh\ntouch "{tmp / "locked"}"\nexec "$@"\n')
    wrapper.chmod(0o755)
    applied = subprocess.run([str(CLEANER), "--apply"], env={**env, "WSURF_PRO_LOCK": str(wrapper)}, capture_output=True,
                             text=True, timeout=30)
    assert applied.returncode == 0 and (tmp / "locked").exists(), applied
    assert not (clones / "io.wsagency.wsurf.ci-1.code_sign_clone").exists() and not stale.exists()
    assert not old_result.exists() and fresh.exists()
    for name in ("io.wsagency.wsurf", "io.wsagency.wsurf.stage", "io.wsagency.wsurf.stage.abc"):
        assert (clones / f"{name}.code_sign_clone").exists(), name
    assert lock.exists() and link.is_symlink() and (tmp / "merged").exists() and (tmp / "dirty" / "work.txt").exists()


def main() -> None:
    check_instructions()
    for case in (check_code_sign_clone, check_run_tmpdir, check_disk_guard, check_pass_artifacts, check_cleaner):
        with tempfile.TemporaryDirectory(prefix="wsurf-disk-hygiene-") as directory:
            case(Path(directory).resolve())
    print("disk hygiene: helpers, cleaner and agent instructions hold")


if __name__ == "__main__":
    main()
