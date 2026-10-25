#!/usr/bin/env python3
# SPDX-FileCopyrightText: 2026 wsagency
# SPDX-License-Identifier: Apache-2.0
"""Compares the strings the Swift compiler extracts with the keys of the app's string catalogs.

Ground truth is the build's own extraction: with SWIFT_EMIT_LOC_STRINGS = YES (the app target) every Swift file
compiles to a `<File>.stringsdata` next to its object file, listing each localizable literal per table, as Xcode
itself reads it when it syncs a catalog. That covers Text/Button/Label/Toggle/Picker/Section titles, .help(),
LocalizedStringKey, LocalizedStringResource, String(localized:) and NSLocalizedString, with every interpolation
already turned into its format specifier (%@, %lld, %1$@ ...). No regular expression stands in for the compiler for the
app, so the build must have run first (xcodebuild build or build-for-testing, with the derived data path given here).

One gap the build leaves, covered by a text scan: the Swift package targets (Packages/*/Sources) emit no stringsdata, yet
their String(localized: "...") literals are looked up in the app's catalog at run time. The scan cannot know the type of
an interpolation, so each \\(...) matches any one specifier (%@, %lld ...), and a package literal is reported as missing
when no catalog key fits that pattern. Only String(localized:) with its literal on one line is read (all of them today).
Passing SWIFT_EMIT_LOC_STRINGS=YES to xcodebuild should make the compiler extract the package targets too (untried).

  missing  a key the code uses that its catalog (WSurf/<Table>.xcstrings) does not have
  stale    a catalog key no extracted literal uses; only reported, never removed, because a key can still be
           reached dynamically (LocalizedStringKey(variable), a key read from data) or by a target that does not
           emit strings. Each stale key says whether its quoted text still appears in a Swift source file.

usage:
  check-string-catalog.py [--derived-data DIR] [--strict]
  check-string-catalog.py --self-test

  --derived-data DIR   the xcodebuild -derivedDataPath of an up to date build (default: build/DD)
  --strict             exit 1 when a key is missing (default is report mode: exit 0 whatever it finds)

Exit 2 means there was nothing to check (no stringsdata for the app sources, or an unreadable catalog).
A stringsdata file whose Swift source no longer exists is an orphan of an older build and is skipped.
Not covered: the WSurfCredentialExchange extension (its own bundle, no catalog) and tests. Blind spot: the compiler does not
extract every literal that is localized at run time (the second branch of a ternary into a LocalizedStringResource, later
switch-case tuples, String(localized:) with a ternary inside). A key used only there is never reported missing, and a catalog
key for it is listed as stale; the "quoted text in source" note on a stale key marks that case.
"""
import json
from pathlib import Path
import re
import sys

ROOT = Path(__file__).resolve().parent.parent
APP = ROOT / 'WSurf'
PACKAGES = ROOT / 'Packages'
SPECIFIER = r'%(?:\d+\$)?(?:@|l*[dfux])'
ESCAPES = {'n': '\n', 't': '\t', '"': '"', '\\': '\\'}
CALL = 'String(localized: "'
HOLE = '\0'  # stands for one interpolation in a decoded literal


def extracted(derived_data: Path) -> tuple[dict[str, dict[str, list[tuple[str, int]]]], int, int]:
    """Returns ({table: {key: [(file, line)]}}, stringsdata files read, orphans skipped) for the app sources."""
    uses: dict[str, dict[str, list[tuple[str, int]]]] = {}
    read = orphans = 0
    for path in sorted((derived_data / 'Build/Intermediates.noindex').glob('**/Objects-normal/*/*.stringsdata')):
        data = json.loads(path.read_text(encoding='utf-8'))
        source = Path(data['source'])
        if APP not in source.parents:
            continue  # another target (tests, packages), or a build of another checkout
        if not source.exists():
            orphans += 1
            continue
        read += 1
        for table, entries in data['tables'].items():
            for entry in entries:
                where = (str(source.relative_to(ROOT)), entry['location']['startingLine'])
                uses.setdefault(table, {}).setdefault(entry['key'], []).append(where)
    return uses, read, orphans


def decode(line: str, start: int) -> str | None:
    """The string literal that begins at line[start] (just after its opening quote), each interpolation as HOLE."""
    out: list[str] = []
    depth = 0
    i = start
    while i < len(line):
        c = line[i]
        if depth:  # inside \( ... ): only parentheses matter
            depth += (c == '(') - (c == ')')
        elif c == '\\':
            nxt = line[i + 1:i + 2]
            if nxt == '(':
                out.append(HOLE)
                depth = 1
            elif nxt == 'u' and line[i + 2:i + 3] == '{':
                end = line.index('}', i)
                out.append(chr(int(line[i + 3:end], 16)))
                i = end - 1
            else:
                out.append(ESCAPES.get(nxt, nxt))
            i += 1
        elif c == '"':
            return ''.join(out)
        else:
            out.append(c)
        i += 1
    return None  # the literal runs past this line


def package_literals() -> list[tuple[str, str, int]]:
    """Returns (decoded literal, file, line of its first use) for each distinct String(localized: "...") in the package sources."""
    found: dict[str, tuple[str, int]] = {}
    for path in sorted(PACKAGES.glob('*/Sources/**/*.swift')):
        for number, line in enumerate(path.read_text(encoding='utf-8').splitlines(), 1):
            at = line.find(CALL)
            if at >= 0 and (text := decode(line, at + len(CALL))) is not None:
                found.setdefault(text, (str(path.relative_to(ROOT)), number))
    return [(text, file, line) for text, (file, line) in found.items()]


def pattern(literal: str) -> re.Pattern[str]:
    return re.compile('^' + SPECIFIER.join(re.escape(part) for part in literal.split(HOLE)) + '$')


def compare(used: set[str], catalog: dict[str, dict], patterns=()) -> tuple[list[str], list[str]]:
    """Returns (missing, stale) keys, each sorted. A catalog entry marked manual, or that a package literal fits, is never stale."""
    missing = sorted(used - catalog.keys())
    stale = sorted(k for k, v in catalog.items()
                   if k not in used and v.get('extractionState') != 'manual' and not any(p.match(k) for p in patterns))
    return missing, stale


def swift_text() -> str:
    return '\n'.join(p.read_text(encoding='utf-8') for d in (APP, PACKAGES) for p in sorted(d.glob('**/*.swift')))


def show(text: str) -> str:
    return json.dumps(text, ensure_ascii=False).replace('\\u0000', '\\(…)')


def report(derived_data: Path, strict: bool) -> int:
    uses, read, orphans = extracted(derived_data)
    if not read:
        print(f'error: no .stringsdata for {APP.relative_to(ROOT)} under {derived_data}; build first', file=sys.stderr)
        return 2
    print(f'stringsdata: {read} files from {derived_data}' + (f' ({orphans} orphans skipped)' if orphans else ''))
    literals = package_literals()
    patterns = [pattern(text) for text, _, _ in literals]
    sources = None
    total_missing = 0
    for table in sorted(uses):
        catalog_path = APP / f'{table}.xcstrings'
        if not catalog_path.exists():
            print(f'{table}: no {catalog_path.relative_to(ROOT)} (extracted keys: {len(uses[table])})')
            continue
        catalog = json.loads(catalog_path.read_text(encoding='utf-8'))['strings']
        in_package = [lit for lit, p in zip(literals, patterns) if table == 'Localizable' and not any(p.match(k) for k in catalog)]
        missing, stale = compare(set(uses[table]), catalog, patterns if table == 'Localizable' else [])
        total_missing += len(missing) + len(in_package)
        print(f'\n{table}: {len(uses[table])} keys used, {len(catalog)} in the catalog, '
              f'{len(missing)} missing, {len(stale)} stale'
              + (f', {len(in_package)} package literals missing' if table == 'Localizable' else ''))
        for key in missing:
            file, line = min(uses[table][key])
            print(f'  missing {json.dumps(key, ensure_ascii=False)}  {file}:{line}'
                  + (f' (+{len(uses[table][key]) - 1} more)' if len(uses[table][key]) > 1 else ''))
        for text, file, line in in_package:
            print(f'  missing {show(text)}  {file}:{line}  [package literal, specifiers unchecked]')
        if stale and sources is None:
            sources = swift_text()
        for key in stale:
            notes = [n for n, on in (('marked stale', catalog[key].get('extractionState') == 'stale'),
                                     ('quoted text in source', json.dumps(key, ensure_ascii=False) in (sources or ''))) if on]
            print(f'  stale   {json.dumps(key, ensure_ascii=False)}' + (f'  [{", ".join(notes)}]' if notes else ''))
    return 1 if strict and total_missing else 0


def self_test() -> None:
    patterns = [pattern(decode(r'x = String(localized: "“\(name)” \(a.b(1, 2)) \u{2019} \"q\"")', len(r'x = ' + CALL)))]
    assert patterns[0].match('“%@” %lld ’ "q"') and not patterns[0].match('“%@” ’ "q"')
    assert decode('"open', 1) is None
    missing, stale = compare({'a', 'b'}, {'b': {}, 'c': {}, 'd': {'extractionState': 'manual'}, 'e': {'extractionState': 'stale'},
                                          'f %lld': {}}, [pattern('f ' + HOLE)])
    assert (missing, stale) == (['a'], ['c', 'e']), (missing, stale)
    print('check-string-catalog: self-test passed')


def main() -> int:
    args = sys.argv[1:]
    if args == ['--self-test']:
        self_test()
        return 0
    derived_data = ROOT / 'build/DD'
    if '--derived-data' in args:
        derived_data = Path(args[args.index('--derived-data') + 1]).resolve()
    return report(derived_data, '--strict' in args)


if __name__ == '__main__':
    sys.exit(main())
