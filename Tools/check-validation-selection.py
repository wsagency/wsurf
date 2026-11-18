#!/usr/bin/env python3
# SPDX-FileCopyrightText: 2026 wsagency
# SPDX-License-Identifier: BUSL-1.1

"""Exercise quick selection and result checking without compiling the app."""

import importlib.util
import json
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest


def selector():
    path = Path(__file__).with_name('select-validation-tests.py')
    if not path.is_file():
        raise AssertionError('validation selector must supply a quick plan and check its results')
    spec = importlib.util.spec_from_file_location('selector', path)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


def suite(name, file, *cases):
    return {'files': {file}, 'cases': [f'{name}/{case}()' for case in cases]}


SUITES = {
    'LogicTests': suite('LogicTests', 'WSurfTests/LogicTests.swift', 'logicWorks'),
    'SmokeTests': suite('SmokeTests', 'WSurfTests/SmokeTests.swift', 'launch', 'navigate'),
    'NewTests': suite('NewTests', 'WSurfTests/NewTests.swift', 'newFeatureWorks'),
    'MenuTests': suite('MenuTests', 'WSurfTests/MenuTests.swift', 'showMenu'),
    'WindowTests': suite('WindowTests', 'WSurfTests/WindowTests.swift', 'focusWindow', 'largeFixture'),
    'ResourcePerformanceTests': suite('ResourcePerformanceTests', 'WSurfTests/ResourcePerformanceTests.swift', 'measure'),
}
POLICY = {
    'smoke': ['SmokeTests/launch()'],
    'areas': [
        {'paths': ['WSurf/UI/*'], 'suites': ['WindowTests']},
        {'paths': ['WSurf/UI/Menu.swift'], 'suites': ['MenuTests', 'WindowTests']},
        {'paths': ['docs/*'], 'suites': []},
    ],
    'minor_cases': ['WindowTests/largeFixture()'],
    'conditional_skips': [],
}


class SelectionTests(unittest.TestCase):
    def setUp(self):
        self.select = selector()

    def quick(self, paths, extra=()):
        return self.select.quick_selection(SUITES, ['LogicTests'], ['ResourcePerformanceTests'], [], POLICY, paths, extra)

    def test_changed_ui_and_new_test_are_combined_with_core_once(self):
        selected, _ = self.quick(['WSurf/UI/Menu.swift', 'WSurfTests/NewTests.swift'])
        self.assertEqual(set(selected), {'LogicTests', 'SmokeTests/launch()', 'MenuTests', 'WindowTests', 'NewTests'})
        self.assertEqual(len(selected), 5)

    def test_selecting_a_suite_does_not_include_its_minor_only_case(self):
        chosen, _ = self.quick(['WSurf/UI/Menu.swift'])
        run = self.select.test_run(SUITES, chosen, POLICY['minor_cases'])
        self.assertIn('-skip-testing:WSurfTests/WindowTests/largeFixture()', run['arguments'])
        self.assertIn('WindowTests/focusWindow()', run['cases'])
        for case in ('WindowTests/largeFixture()', 'SmokeTests/navigate()', 'ResourcePerformanceTests/measure()'):
            self.assertNotIn(case, run['cases'])

    def test_unmapped_paths_require_an_explicit_choice(self):
        with self.assertRaisesRegex(ValueError, 'Unknown.swift'):
            self.quick(['WSurf/Unknown.swift'])
        chosen, _ = self.quick(['WSurf/Unknown.swift'], ['MenuTests'])
        self.assertIn('MenuTests', chosen)
        with self.assertRaisesRegex(ValueError, 'BadTests'):
            self.quick([], ['BadTests'])

    def test_missing_duplicate_and_unexpectedly_skipped_cases_fail(self):
        expected = ['SmokeTests/launch()', 'MenuTests/showMenu()']
        good = [('SmokeTests/launch()', 'Passed'), ('MenuTests/showMenu()', 'Passed')]
        self.assertEqual(self.select.result_problems(expected, good), [])
        for bad in (good[:1], good + good[:1], [good[0], ('MenuTests/showMenu()', 'Skipped')]):
            self.assertTrue(self.select.result_problems(expected, bad))


class ReleaseSelectionTests(unittest.TestCase):
    def setUp(self):
        self.directory = tempfile.TemporaryDirectory()
        self.addCleanup(self.directory.cleanup)
        self.repo = Path(self.directory.name)
        self.git('init', '-q')
        self.git('-c', 'user.name=Fixture', '-c', 'user.email=fixture@example.test', 'commit', '-q', '--allow-empty', '-m', 'Base')
        self.git('-c', 'user.name=Fixture', '-c', 'user.email=fixture@example.test', 'tag', '-a', 'v0.1.28', '-m', 'Published')
        self.git('tag', 'v0.9.6')
        self.git('-c', 'user.name=Fixture', '-c', 'user.email=fixture@example.test', 'commit', '-q', '--allow-empty', '-m', 'Candidate')

    def git(self, *args):
        return subprocess.check_output(['git', '-c', 'commit.gpgSign=false', '-c', 'tag.gpgSign=false',
                                        '-c', 'core.hooksPath=/dev/null', *args], cwd=self.repo, text=True).strip()

    def classify(self, tag, published):
        script = Path(__file__).with_name('select-release-validation.py')
        if not script.is_file():
            raise AssertionError('release validation must choose its tier from published releases')
        self.git('tag', tag)
        records = [dict(tag_name=name, draft=False, prerelease=False) for name in published]
        records.extend([dict(tag_name='tip', draft=False, prerelease=True), dict(tag_name='v9.9', draft=True, prerelease=False)])
        return subprocess.run([sys.executable, str(script), '--tag', tag], cwd=self.repo, input=json.dumps([records]),
                              capture_output=True, text=True)

    def test_patch_uses_the_published_annotated_tag_as_its_base(self):
        run = self.classify('v0.1.29', ['v0.1.28'])
        self.assertEqual(run.returncode, 0, run.stderr)
        self.assertEqual(dict(line.split('=', 1) for line in run.stdout.splitlines()),
                         {'tier': 'quick', 'source': self.git('rev-parse', 'HEAD'),
                          'base': self.git('rev-parse', 'v0.1.28^{commit}')})

    def test_first_release_and_minor_change_require_the_full_tier(self):
        for tag, published in [('v0.1.29', []), ('v0.2.29', ['v0.1.28']), ('v1.0', ['v0.1.28'])]:
            with self.subTest(tag=tag):
                run = self.classify(tag, published)
                self.assertEqual(run.returncode, 0, run.stderr)
                self.assertIn('tier=minor\n', run.stdout)

    def test_invalid_or_decreasing_version_fails(self):
        for tag in ['v0.1.bad', 'v0.1.27']:
            with self.subTest(tag=tag):
                run = self.classify(tag, ['v0.1.28'])
                self.assertNotEqual(run.returncode, 0)
                self.assertEqual(run.stdout, '')

    def test_new_patch_or_minor_cannot_reuse_previous_build_commit(self):
        self.git('checkout', '-q', '--detach', 'v0.1.28')
        for tag in ['v0.1.29', 'v0.2.29']:
            with self.subTest(tag=tag):
                run = self.classify(tag, ['v0.1.28'])
                self.assertNotEqual(run.returncode, 0)
                self.assertEqual(run.stdout, '')

    def test_preview_includes_a_changed_area_from_an_intervening_canceled_run(self):
        self.git('tag', 'tip', 'v0.1.28')
        (self.repo / 'Vault.swift').write_text('change from the canceled run')
        self.git('add', 'Vault.swift')
        self.git('-c', 'user.name=Fixture', '-c', 'user.email=fixture@example.test', 'commit', '-qm', 'Vault change')
        (self.repo / 'README.md').write_text('change from the newest push')
        self.git('add', 'README.md')
        self.git('-c', 'user.name=Fixture', '-c', 'user.email=fixture@example.test', 'commit', '-qm', 'Docs change')
        module = selector()
        module.ROOT = self.repo
        base, paths = module.comparison(self.git('rev-parse', 'HEAD'), '@preview')
        self.assertEqual(base, self.git('rev-parse', 'tip^{commit}'))
        self.assertEqual(paths, ['README.md', 'Vault.swift'])


if __name__ == '__main__':
    unittest.main()
