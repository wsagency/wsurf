#!/usr/bin/env python3
# SPDX-FileCopyrightText: 2026 wsagency
# SPDX-License-Identifier: BUSL-1.1

"""Exercise quick selection and result checking without compiling the app."""

import importlib.util
from pathlib import Path
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


if __name__ == '__main__':
    unittest.main()
