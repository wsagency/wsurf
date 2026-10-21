#!/usr/bin/env python3
# SPDX-FileCopyrightText: 2026 wsagency
# SPDX-License-Identifier: Apache-2.0
"""Proves that the WSurf test plans partition WSurfTests, and turns a plan into xcodebuild arguments.

Every top-level test suite in WSurfTests (a Swift Testing type with @Test functions or @Suite, an XCTestCase
subclass, or a free @Test function) belongs to exactly one plan:

  WSurf-Parallel.xctestplan     selectedTests: Swift Testing suites reviewed as safe in parallel test-host clones
  WSurf-Performance.xctestplan  selectedTests: the measure-based, budgeted suites (Tools/check-performance.sh)
  WSurf-Serial.xctestplan       skippedTests:  exactly the two lists above, so every other suite, including
                                every new one, runs serially by default

The check also refuses a parallel suite whose source names a window, web engine, socket, Keychain, pasteboard,
shared-defaults, shared-singleton or wall-clock-budget marker (SERIAL_MARKERS); passing it is necessary, not
sufficient. The plans are not in the WSurf scheme (more plans would make build-for-testing emit more than the one
.xctestrun that CI, check-built-identity.py and run-foreground-tests.sh expect); they run against that single
generated .xctestrun through the -only-testing/-skip-testing arguments --args prints.

usage:
  check-test-partition.py                    check the partition (exit 1 on any problem)
  check-test-partition.py --list             print each suite with its plan, kind and test count
  check-test-partition.py --args PLAN        print the xcodebuild selection arguments for PLAN, one per line
"""
import json
from pathlib import Path
import re
import sys

ROOT = Path(__file__).resolve().parent.parent
TESTS = ROOT / 'WSurfTests'
TARGET = 'WSurfTests'
PLANS = ('WSurf-Parallel', 'WSurf-Serial', 'WSurf-Performance')
# Test-host clones for WSurf-Parallel. Each clone also runs Swift Testing cases concurrently in process, so this stays
# below the core count (6 of the Pro's 10). Calibration knob: lower it if the parallel run is flaky, raise it if idle.
PARALLEL_WORKERS = 6
# Vision OCR cases skipped in every automated run (see .github/workflows/ci.yml).
OCR_SKIPS = (
    'AttachmentTests/normalizesImagesAndRecognizesText()',
    'AttachmentTests/recognizesTextWithoutANeuralEngine()',
    'AttachmentTests/recognizesScannedPDFPages()',
    'AttachmentTests/pastingAnImageCreatesARemovableAttachment()',
)
# Anything here in a suite's own source makes it SERIAL. ponytail: textual, one level deep; a helper in another
# file that opens a window is not seen, so a parallel suite is also reviewed by hand before it is listed.
SERIAL_MARKERS = re.compile(r'''\b(
    # Windows, views, display and system UI: a covered window counts as hidden in another clone.
    NSWindow | NSPanel | NSHostingView | NSHostingController | NSApp\b | NSApplication | NSView\b | NSEvent |
    NSPasteboard | NSWorkspace | NSScreen | NSAlert | NSOpenPanel | NSSavePanel | NSSound | NSAccessibility |
    # Web engines and the app types that own pages, windows or the shared WebKit data store.
    WKWebView | WKWebsiteDataStore | WKUserContentController | WKProcessPool | WKContentWorld | WebKit |
    BrowserTab | BrowserPage | BrowserWindow\w* | AppCoordinator | BrowserApplication | BrowserProfileContext |
    BrowserModel | MediaCenter | DownloadManager |
    Chromium\w* | CEF\w* | Cef\w* | HTTPFixtureServer | InteractiveWebViewConfiguration | makeConfiguration |
    ParkedTab | ComputerWorkflowFixture | DeployedWindowSessionFixture | WebViewGate | boundedWebViews |
    requiresBackForwardCache | exclusiveExternalApp | WindowCensus |
    # The MCP socket (one listener per user) and live network.
    LocalMCPEndpoint | BrowserMCPServer | MCPSocket\w* | NWListener | NWConnection | URLSession |
    # The real Keychain, and app types backed by it or by the production vault manager registry.
    SecItem\w* | Keychain\w* | kSecClass\w* | SecAccessControl\w* | LAContext |
    CredentialStore\b | MCPTrustStore\b | SecureAutofillVault | PaymentCardVault | AutofillSaveIndex | AutofillVaults |
    CredentialManager\b | AutofillSuggestions | VaultManagerFixture | IntelligenceViewModel |
    # The test host's standard defaults domain, which every clone shares.
    UserDefaults\.standard | UserDefaults\(\)\.(?!removePersistentDomain) | UserDefaults\(suiteName:\s*""\) |
    CFPreferences\w* | OpenAISettingsStore\.save | ProviderCatalog\.shared | AgentActionPolicy\(\s*\) |
    BrowserSettings\((?!\s*defaults:) | BrowserSettings\.application | useStandardTheme |
    # Other process-wide or machine-wide state.
    NotificationCenter\.default | DistributedNotificationCenter | NSUbiquitous\w* |
    ProcessInfo\.processInfo\.environment | setenv | unsetenv |
    AVAudio\w* | AVCapture\w* | SFSpeech\w* | AVSpeech\w* | VNRecognize\w* | Vision |
    Process\(\) | posix_spawn | NSUserNotification | UNUserNotificationCenter |
    NSHomeDirectory | homeDirectoryForCurrentUser | \.applicationSupportDirectory | \.cachesDirectory |
    \.libraryDirectory | \.downloadsDirectory | \.documentDirectory | \.desktopDirectory |
    temporaryDirectory\.appendingPathComponent\(""\) | NSTemporaryDirectory\(\)\s*\+ |
    \w+\.shared\.(set|reset|install|register|remove|update|replace|clear|configure|add|insert|delete|save|load|stub)\w* |
    \w+\.shared\.\w+\s*= |
    static\s+var |
    # Wall-clock upper bounds, which CPU contention from other clones can break.
    elapsed\s*< | <\s*\.milliseconds
)''', re.X)
# Checked on the raw source, since string contents are stripped before SERIAL_MARKERS runs: fixed shared paths.
RAW_MARKERS = re.compile(r'"(/tmp/|/private/|~/)')
DECL = {'class', 'struct', 'enum', 'actor', 'extension', 'protocol'}
NOT_A_NAME = {'func', 'var', 'let', 'subscript', 'init', 'deinit', 'override', 'final', 'static', 'case'}


def strip(src):
    """Returns src with comments and string-literal contents removed and line breaks kept."""
    out, n = [], len(src)

    def string(i, hashes):
        # src[i] is the opening quote run; returns the index after the closing delimiter.
        triple = src.startswith('"""', i)
        quote = '"""' if triple else '"'
        i += len(quote)
        close = quote + '#' * hashes
        escape = '\\' + '#' * hashes
        while i < n:
            if src.startswith(close, i):
                return i + len(close)
            if src.startswith(escape, i):
                i += len(escape)
                if i < n and src[i] == '(':
                    i = code(i + 1, ')')
                else:
                    i += 1
                continue
            if src[i] == '\n':
                out.append('\n')
            i += 1
        return i

    def code(i, until=None):
        depth = 0
        while i < n:
            c = src[i]
            if src.startswith('//', i):
                j = src.find('\n', i)
                i = n if j < 0 else j
            elif src.startswith('/*', i):
                level, i = 1, i + 2
                while i < n and level:
                    if src.startswith('/*', i):
                        level, i = level + 1, i + 2
                    elif src.startswith('*/', i):
                        level, i = level - 1, i + 2
                    else:
                        if src[i] == '\n':
                            out.append('\n')
                        i += 1
            elif c == '#' and (raw := re.match(r'(#+)"', src[i:])):
                hashes = len(raw.group(1))
                out.append('""')
                i = string(i + hashes, hashes)
            elif c == '"':
                out.append('""')
                i = string(i, 0)
            else:
                if until and c == '(':
                    depth += 1
                elif until and c == ')':
                    if depth == 0:
                        return i + 1
                    depth -= 1
                if not until:
                    out.append(c)
                i += 1
        return i

    code(0)
    return ''.join(out)


TOKEN = re.compile(r'[A-Za-z_][A-Za-z0-9_]*(?:\.[A-Za-z_][A-Za-z0-9_]*)*|@|\{|\}|\(|\)|:|,|<|>|\n|\S')


def scan(source):
    """Returns the @Suite types, the test functions and the class inheritance lists declared in one file."""
    code = strip(source)
    tokens = TOKEN.findall(code)
    stack = []  # each entry: (kind, name parts) for declarations, None for other braces
    pending = None  # declaration seen, waiting for its opening brace
    attribute = None
    suites, tests, supers = [], [], {}
    i = 0
    while i < len(tokens):
        t = tokens[i]
        if t == '@' and i + 1 < len(tokens):
            name = tokens[i + 1].split('.')[-1]
            if name in ('Test', 'Suite'):
                attribute = name
            i += 2
            continue
        if t in DECL and pending is None and i + 1 < len(tokens) and tokens[i + 1] not in NOT_A_NAME \
                and re.match(r'[A-Za-z_]', tokens[i + 1]):
            inherits = []
            j = i + 2
            while j < len(tokens) and tokens[j] != '{':
                if re.match(r'[A-Za-z_]', tokens[j]):
                    inherits.append(tokens[j].split('.')[-1])
                j += 1
            pending = (t, tuple(tokens[i + 1].split('.')), inherits, attribute == 'Suite')
            attribute = None
            i += 2
            continue
        if t == '{':
            if pending:
                kind, name, inherits, is_suite = pending
                outer = next((e[1] for e in reversed(stack) if e), ())
                if any(e is None for e in stack):
                    full = None  # a type declared inside a function body is never a suite
                elif kind == 'extension':
                    full = name
                else:
                    full = outer + name
                if full and kind == 'class':
                    supers[full] = inherits
                if full and is_suite:
                    suites.append(full)
                stack.append((kind, full) if full else None)
                pending = None
            else:
                stack.append(None)
        elif t == '}':
            if stack:
                stack.pop()
        elif t == 'func' and i + 1 < len(tokens):
            owner = stack[-1] if stack else ('file', ())
            name = tokens[i + 1]
            if owner and owner[0] != 'protocol':
                if attribute == 'Test':
                    tests.append((owner[1], name, 'swift-testing'))
                elif name.startswith('test') and i + 3 < len(tokens) and tokens[i + 2] == '(' and tokens[i + 3] == ')':
                    tests.append((owner[1], name, 'xctest-candidate'))
            attribute = None
        i += 1
    return suites, tests, supers


def inventory():
    """Maps each top-level suite name to its kind, test count and contributing files."""
    facts = []
    supers = {}
    for path in sorted(TESTS.rglob('*.swift')):
        suites, tests, classes = scan(path.read_text())
        supers.update(classes)
        facts.append((path, suites, tests))
    xctest = set()
    changed = True
    while changed:
        changed = False
        for name, inherits in supers.items():
            if name not in xctest and any(s == 'XCTestCase' or s in {x[-1] for x in xctest} for s in inherits):
                xctest.add(name)
                changed = True
    found = {}
    for path, suites, tests in facts:
        rel = str(path.relative_to(ROOT))
        for full in suites:
            entry = found.setdefault(full[0], {'kind': 'swift-testing', 'tests': 0, 'files': set()})
            entry['files'].add(rel)
        for owner, name, kind in tests:
            if kind == 'xctest-candidate':
                if owner not in xctest:
                    continue
                kind = 'xctest'
            key = owner[0] if owner else name + '()'
            entry = found.setdefault(key, {'kind': kind, 'tests': 0, 'files': set()})
            entry['kind'] = kind if entry['tests'] == 0 else entry['kind']
            entry['tests'] += 1
            entry['files'].add(rel)
    # A file that only extends a suite still contributes its source to that suite's marker scan.
    for path in sorted(TESTS.rglob('*.swift')):
        rel = str(path.relative_to(ROOT))
        for match in re.finditer(r'^\s*(?:@\w+\s+)*extension\s+([A-Za-z_]\w*)', strip(path.read_text()), re.M):
            if match.group(1) in found:
                found[match.group(1)]['files'].add(rel)
    return found


def serial_marker(rel):
    text = (ROOT / rel).read_text()
    return SERIAL_MARKERS.search(strip(text)) or RAW_MARKERS.search(text)


def load():
    """Returns the one WSurfTests target entry of each plan, in PLANS order."""
    targets = []
    for name in PLANS:
        [target] = json.loads((ROOT / (name + '.xctestplan')).read_text())['testTargets']
        assert target['target']['name'] == TARGET, name
        targets.append(target)
    return targets


def suite_of(identifier):
    return identifier.split('/')[0]


def self_test():
    """Proves the lexer on the constructs that broke naive brace counting."""
    source = (
        'let a = "x { \\(f("}")) y"\n/* { /* } */ */\nlet r = #"raw " { "#\nlet m = """\n{ "\n"""\n'
        '@Suite(.serialized) struct S {\n  @Test(arguments: [1]) func t(_ n: Int) { let f = { } }\n'
        '  struct Inner { @Test func u() {} }\n  func helper() { struct Local { @Test func no() {} } }\n}\n'
        'class Base: XCTestCase { func testA() {} func testWith(_ x: Int) {} }\nextension S { @Test func v() {} }\n'
    )
    code = strip(source)
    assert code.count('{') == code.count('}'), code
    suites, tests, supers = scan(source)
    assert suites == [('S',)], suites
    assert [(o, n) for o, n, k in tests if k == 'swift-testing'] == [(('S',), 't'), (('S', 'Inner'), 'u'), (('S',), 'v')], tests
    assert [(o, n) for o, n, k in tests if k == 'xctest-candidate'] == [(('Base',), 'testA')], tests
    assert supers[('Base',)] == ['XCTestCase'], supers


def check():
    self_test()
    suites = inventory()
    parallel, serial, performance = load()
    problems = []
    par = parallel.get('selectedTests', [])
    perf = performance.get('selectedTests', [])
    skipped = serial.get('skippedTests', [])
    for label, entries in (('WSurf-Parallel', par), ('WSurf-Performance', perf), ('WSurf-Serial', skipped)):
        if len(entries) != len(set(entries)):
            problems.append(label + ' lists a test twice')
        if entries != sorted(entries):
            problems.append(label + ' is not sorted')
    for label, entries in (('WSurf-Parallel', par), ('WSurf-Performance', perf)):
        for entry in entries:
            if '/' in entry:
                problems.append(label + ' selects part of a suite: ' + entry)
            elif entry not in suites:
                problems.append(label + ' names no suite in WSurfTests: ' + entry)
        if 'skippedTests' in (parallel if label == 'WSurf-Parallel' else performance):
            problems.append(label + ' must select, not skip')
    if 'selectedTests' in serial:
        problems.append('WSurf-Serial must skip, not select')
    both = set(par) & set(perf)
    if both:
        problems.append('in both Parallel and Performance: ' + ', '.join(sorted(both)))
    if set(skipped) != set(par) | set(perf):
        problems.append('WSurf-Serial skippedTests must be exactly Parallel + Performance; differs by: '
                        + ', '.join(sorted(set(skipped) ^ (set(par) | set(perf)))))
    for label, target in zip(PLANS, (parallel, serial, performance)):
        if target.get('parallelizable', False) != (label == 'WSurf-Parallel'):
            problems.append(label + ' has the wrong parallelizable setting')
    for name in par:
        if name in suites and suites[name]['kind'] == 'xctest':
            problems.append('XCTest class in WSurf-Parallel (keep XCTest serial): ' + name)
        for rel in sorted(suites.get(name, {}).get('files', ())):
            hit = serial_marker(rel)
            if hit:
                problems.append('parallel suite ' + name + ' names a serial marker in ' + rel + ': ' + hit.group().strip())
    perf_tests = set(re.findall(r"check_average \\\n  '([^/']+)/", (ROOT / 'Tools/check-performance.sh').read_text()))
    perf_tests |= {s for s in suites if s.endswith('PerformanceTests')}
    if perf_tests != set(perf):
        problems.append('WSurf-Performance must be exactly the budgeted and *PerformanceTests suites; differs by: '
                        + ', '.join(sorted(perf_tests ^ set(perf))))
    for test in OCR_SKIPS:
        if suite_of(test) in par or suite_of(test) in perf:
            problems.append('OCR exclusion is outside the serial plan: ' + test)
    serial_count = len(set(suites) - set(par) - set(perf))
    counts = {'suites': len(suites), 'parallel': len(par), 'serial': serial_count, 'performance': len(perf),
              'tests': sum(s['tests'] for s in suites.values()),
              'parallelTests': sum(suites[s]['tests'] for s in par if s in suites),
              'performanceTests': sum(suites[s]['tests'] for s in perf if s in suites)}
    counts['serialTests'] = counts['tests'] - counts['parallelTests'] - counts['performanceTests']
    for problem in problems:
        print('error: ' + problem, file=sys.stderr)
    print(json.dumps(counts, sort_keys=True))
    return 1 if problems else 0


def arguments(name):
    parallel, serial, performance = load()
    if name == 'WSurf-Parallel':
        selection = ['-only-testing:%s/%s' % (TARGET, s) for s in parallel['selectedTests']]
        flags = ['-parallel-testing-enabled', 'YES', '-parallel-testing-worker-count', str(PARALLEL_WORKERS)]
    elif name == 'WSurf-Performance':
        selection = ['-only-testing:%s/%s' % (TARGET, s) for s in performance['selectedTests']]
        flags = ['-parallel-testing-enabled', 'NO']
    elif name == 'WSurf-Serial':
        selection = ['-skip-testing:%s/%s' % (TARGET, s) for s in serial['skippedTests']]
        flags = ['-parallel-testing-enabled', 'NO']
    else:
        raise SystemExit('unknown plan: ' + name)
    return flags + selection + ['-skip-testing:%s/%s' % (TARGET, t) for t in OCR_SKIPS]


def main(argv):
    if argv[:1] == ['--list']:
        suites = inventory()
        parallel, _, performance = load()
        for name, info in sorted(suites.items()):
            group = 'PARALLEL' if name in parallel.get('selectedTests', []) else \
                'PERFORMANCE' if name in performance.get('selectedTests', []) else 'SERIAL'
            print('\t'.join([group, name, info['kind'], str(info['tests']), ','.join(sorted(info['files']))]))
        return 0
    if argv[:1] == ['--args'] and len(argv) == 2:
        print('\n'.join(arguments(argv[1])))
        return 0
    if argv:
        print(__doc__, file=sys.stderr)
        return 2
    return check()


if __name__ == '__main__':
    raise SystemExit(main(sys.argv[1:]))
