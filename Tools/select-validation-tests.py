#!/usr/bin/env python3
# SPDX-FileCopyrightText: 2026 wsagency
# SPDX-License-Identifier: BUSL-1.1

"""Plan quick or minor validation, and check the results of each selected run."""

import argparse
from collections import Counter, defaultdict
from fnmatch import fnmatchcase
import json
from pathlib import Path
import runpy
import subprocess
import sys


ROOT = Path(__file__).resolve().parent.parent
PARTITION = runpy.run_path(str(ROOT / 'Tools/check-test-partition.py'))
SERIAL = PARTITION['SERIAL_PART_PLANS']
REST = PARTITION['REST_PLAN']
MINOR_BENCHMARKS = {
    'WebKit-Resources': (['ResourceBenchmarkTests'], []),
    'Chromium-Resources': (['ChromiumResourceBenchmarkTests'], []),
    'Chromium-First-Tab': (['EngineBenchmarkTests/startingChromiumForTheFirstTab()'], []),
    'Chromium-Engine': (['EngineBenchmarkTests'], ['EngineBenchmarkTests/startingChromiumForTheFirstTab()']),
    'Vault-Scale': (['VaultMoveBenchmark', 'VaultVerificationBenchmark'], []),
}


def matches(value, patterns):
    return any(fnmatchcase(value, pattern) for pattern in patterns)


def suite_name(selector):
    return selector.split('/', 1)[0]


def checked_selector(suites, selector):
    name = suite_name(selector)
    if name not in suites or ('/' in selector and selector not in suites[name]['cases']):
        raise ValueError(f'Unknown test selection {selector}')
    return selector


def quick_selection(suites, parallel, performance, excluded, policy, paths, extra):
    deferred = set(performance) | set(excluded)
    choices = set(parallel) | set(policy['smoke'])
    unresolved = []
    test_files = defaultdict(set)
    for name, info in suites.items():
        for path in info['files']:
            test_files[path].add(name)
    for path in paths:
        affected = test_files.get(path, set())
        rules = [rule for rule in policy['areas'] if matches(path, rule['paths'])]
        choices.update(affected)
        for rule in rules:
            choices.update(rule['suites'])
        if not affected and not rules:
            unresolved.append(path)
    if unresolved and not extra:
        raise ValueError('Choose --suite for the affected area or update Tools/validation-tests.json for: ' + ', '.join(unresolved))
    for choice in choices | set(extra):
        checked_selector(suites, choice)
    choices = {choice for choice in choices if suite_name(choice) not in deferred}
    choices.update(extra)
    # One suite filter already includes its individually selected cases.
    return sorted(choice for choice in choices if '/' not in choice or suite_name(choice) not in choices), unresolved


def test_run(suites, choices, exclusions):
    cases = []
    for choice in choices:
        scope = [choice] if '/' in choice else suites[choice]['cases']
        cases.extend(case for case in scope if case not in exclusions)
    selected_suites = {suite_name(choice) for choice in choices}
    args = ['-parallel-testing-enabled', 'NO']
    args.extend(f'-only-testing:WSurfTests/{choice}' for choice in choices)
    args.extend(f'-skip-testing:WSurfTests/{case}' for case in sorted(exclusions) if suite_name(case) in selected_suites)
    return {'arguments': args, 'cases': sorted(cases)}


def result_problems(expected, actual, allowed_skips=()):
    missing = Counter(expected) - Counter(name for name, _ in actual)
    extra = Counter(name for name, _ in actual) - Counter(expected)
    problems = [f'Missing test: {name}' for name in sorted(missing)]
    problems += [f'Unexpected or repeated test: {name}' for name in sorted(extra)]
    for name, outcome in actual:
        if outcome == 'Passed' or (outcome == 'Skipped' and matches(name, allowed_skips)):
            continue
        problems.append(f'{name}: {outcome or "no result"}')
    return problems


def git(*args):
    return subprocess.check_output(['git', '-C', str(ROOT), *args], text=True).strip()


def make_plan(tier, base_ref, extra):
    head = git('rev-parse', 'HEAD')
    tree = git('rev-parse', 'HEAD^{tree}')
    if git('status', '--porcelain'):
        raise ValueError('Commit the source to validate before running CI. Use focused Xcode tests during edits.')
    suites = PARTITION['inventory']()
    parallel, _, performance = PARTITION['load']()
    omitted, parts = PARTITION['serial_parts']()
    policy = json.loads((ROOT / 'Tools/validation-tests.json').read_text())
    parallel = parallel['selectedTests']
    performance = performance['selectedTests']
    manifest = {'tier': tier, 'head': head, 'tree': tree, 'runs': {}}
    runs = manifest['runs']
    if tier == 'minor':
        if extra:
            raise ValueError('--suite is only for quick validation')
        runs.update({name: {'arguments': PARTITION['arguments'](name)} for name in (*SERIAL, REST)})
        for name, (choices, exclusions) in MINOR_BENCHMARKS.items():
            runs[name] = test_run(suites, choices, exclusions)
        return manifest
    base = git('rev-parse', '--verify', '--end-of-options', (base_ref or 'origin/main') + '^{commit}')
    if git('merge-base', base, head) != base:
        raise ValueError(f'Validation base {base} must be an ancestor of {head}')
    paths = git('diff', '--name-only', '--no-renames', '-z', base, head, '--').split('\0')
    paths = [path for path in paths if path]
    choices, unresolved = quick_selection(suites, parallel, performance, omitted, policy, paths, extra)
    exclusions = set(PARTITION['OCR_SKIPS']) | (set(policy['minor_cases']) - set(extra))
    for case in policy['minor_cases']:
        checked_selector(suites, case)
    placements = [(name, set(group)) for name, group in zip(SERIAL, parts)]
    placements.append((REST, set(parallel) | set(performance)))
    for name, group in placements:
        selected = [choice for choice in choices if suite_name(choice) in group]
        if not selected:
            continue
        run = test_run(suites, selected, exclusions)
        if run['cases']:
            runs[name] = run
    if not runs:
        raise ValueError('The quick run selected no tests')
    manifest.update(base=base, paths=paths, explicit_paths=unresolved, selection=choices,
                    allowed_skips=policy['conditional_skips'],
                    deferred=['full functional matrix', 'coverage', 'performance budgets', 'minor resource benchmarks'])
    return manifest


def actual_cases(result, aliases):
    def visit(node, suite=''):
        if node['nodeType'] == 'Test Suite':
            suite = aliases.get(node['name'], node['name'])
        if node['nodeType'] == 'Test Case':
            yield f"{suite}/{node['name']}", node.get('result')
            return
        for child in node.get('children', []):
            yield from visit(child, suite)
    for node in json.loads(result.read_text())['testNodes']:
        yield from visit(node)


def check_source(manifest):
    if (manifest['head'] != git('rev-parse', 'HEAD') or manifest['tree'] != git('rev-parse', 'HEAD^{tree}')
            or git('status', '--porcelain')):
        raise ValueError('Validation plan does not belong to this clean source tree')


def verify(manifest, results):
    aliases = PARTITION['display_names']()
    count = Counter()
    minor = manifest['tier'] == 'minor'
    failed = minor and PARTITION['verify_results']([results / f'{name}-tests.json' for name in (*SERIAL, REST)]) != 0
    for name, run in manifest['runs'].items():
        if 'cases' not in run:
            continue
        actual = list(actual_cases(results / f'{name}-tests.json', aliases))
        count.update(outcome for _, outcome in actual)
        problems = result_problems(run['cases'], actual, manifest.get('allowed_skips', ()))
        if problems:
            failed = True
            print(f'{name}: {len(problems)} result mismatches', file=sys.stderr)
            print('\n'.join(problems[:25]), file=sys.stderr)
    if minor:
        print(f"Minor benchmark results: {count['Passed']} passed, {count['Skipped']} skipped.")
    else:
        print(f"Quick results: {count['Passed']} passed, {count['Skipped']} skipped. Deferred: {', '.join(manifest['deferred'])}.")
    return int(failed)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    mode = parser.add_subparsers(dest='command', required=True)
    plan = mode.add_parser('plan')
    plan.add_argument('--tier', choices=('quick', 'minor'), required=True)
    plan.add_argument('--base')
    plan.add_argument('--suite', action='append', default=[])
    for command in ('runs', 'args', 'verify'):
        action = mode.add_parser(command)
        action.add_argument('manifest', type=Path)
        if command == 'args':
            action.add_argument('run')
        if command == 'verify':
            action.add_argument('results', type=Path)
    args = parser.parse_args()
    try:
        if args.command == 'plan':
            print(json.dumps(make_plan(args.tier, args.base, args.suite), indent=2))
            return 0
        manifest = json.loads(args.manifest.read_text())
        if args.command == 'runs':
            print('\n'.join(manifest['runs']))
        elif args.command == 'args':
            print('\n'.join(manifest['runs'][args.run]['arguments']))
        else:
            check_source(manifest)
            return verify(manifest, args.results)
    except (ValueError, OSError, KeyError, subprocess.CalledProcessError) as error:
        print(f'error: {error}', file=sys.stderr)
        return 1
    return 0


if __name__ == '__main__':
    raise SystemExit(main())
