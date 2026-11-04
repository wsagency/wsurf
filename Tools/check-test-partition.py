#!/usr/bin/env python3
# SPDX-FileCopyrightText: 2026 wsagency
# SPDX-License-Identifier: BUSL-1.1
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
  check-test-partition.py --verify-results F...   compare the cases of the CI runs (xcresulttool get test-results tests, one
                                             JSON file per run) with the cases the sources declare

CI does not run the Serial plan in one host. One WebKit Networking process serves about 183 persistent stores and then
opens no store's databases, so the Serial suites run in three parts (Tools/serial-parts.json, the split the local gate
uses), each in a host of its own, and a fourth run covers the Parallel and Performance suites (serially, as CI always did):

  WSurf-Serial-1 .. WSurf-Serial-3   -only-testing of the suites of that part (ChromiumLoadBenchmarkTests is skipped: its
                                     XCTest measure block crashes the host)
  WSurf-Rest                         -only-testing of every Parallel and Performance suite

The check proves the parts are disjoint and together equal the Serial suites, and, test by test, that the cases they
select equal the Serial cases named as Xcode names them (Swift Testing cases carry their argument labels:
`name(engine:popups:)`). --verify-results is the same comparison on what actually ran.
"""
import collections
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
SERIAL_PARTS = ROOT / 'Tools/serial-parts.json'
SERIAL_PART_PLANS = ('WSurf-Serial-1', 'WSurf-Serial-2', 'WSurf-Serial-3')
REST_PLAN = 'WSurf-Rest'
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
    # The real Keychain, and app types backed by it. CredentialManager and VaultManagerFixture are not markers: the fixture
    # makes no window and stubs every prompt, and its managers use fresh profiles under the per-process test directory.
    SecItem\w* | Keychain\w* | kSecClass\w* | SecAccessControl\w* | LAContext |
    CredentialStore\b | MCPTrustStore\b | SecureAutofillVault | PaymentCardVault | AutofillSaveIndex | AutofillVaults |
    AutofillSuggestions | IntelligenceViewModel |
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


def parameter_labels(code, name):
    """The argument labels of test function `name` as Xcode prints them in a case's name: `()`, `(engine:)`, `(shown:other:)`, `(_:)`.
    Read from comment- and string-stripped source: the parameter list after `func name`, split at its top-level commas (commas inside
    (), [] and <> do not), the label being the first word of each parameter. Every `func name(` in the file must agree."""
    found = set()
    for match in re.finditer(r'func\s+' + re.escape(name) + r'\s*(?:<[^>(]*>)?\s*\(', code):
        depth, current, params, k = 1, '', [], match.end()
        while k < len(code) and depth:
            ch = code[k]
            if code.startswith('->', k):
                current += '->'
                k += 2
                continue
            if ch in '([<':
                depth += 1
            elif ch in ')]>':
                depth -= 1
                if depth == 0:
                    break
            if ch == ',' and depth == 1:
                params.append(current)
                current = ''
            else:
                current += ch
            k += 1
        if current.strip():
            params.append(current)
        labels = []
        for param in params:
            word = re.match(r'\s*([A-Za-z_][A-Za-z0-9_]*)', param)
            assert word and ':' in param, 'unreadable parameter of test %s: %s' % (name, param.strip()[:60])
            labels.append(word.group(1))
        found.add(tuple(labels))
    assert len(found) == 1, 'test %s: %s declaration(s) in one file disagree on their labels' % (name, len(found))
    return '(' + ''.join(label + ':' for label in next(iter(found))) + ')'


def inventory():
    """Maps each top-level suite name to its kind, test count and contributing files."""
    facts = []
    supers = {}
    for path in sorted(TESTS.rglob('*.swift')):
        suites, tests, classes = scan(path.read_text())
        supers.update(classes)
        facts.append((path, suites, tests, strip(path.read_text())))
    xctest = set()
    changed = True
    while changed:
        changed = False
        for name, inherits in supers.items():
            if name not in xctest and any(s == 'XCTestCase' or s in {x[-1] for x in xctest} for s in inherits):
                xctest.add(name)
                changed = True
    found = {}
    for path, suites, tests, code in facts:
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
            # Xcode's name of the case: the innermost suite, the function and, for Swift Testing, its argument labels.
            labels = parameter_labels(code, name) if kind == 'swift-testing' else '()'
            entry.setdefault('cases', []).append('%s/%s%s' % (owner[-1] if owner else key, name, labels))
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


def serial_parts():
    """(skipped suites, the three parts' suite lists) from Tools/serial-parts.json."""
    data = json.loads(SERIAL_PARTS.read_text())
    assert set(data) == {'skippedSuites', 'parts'} and len(data['parts']) == len(SERIAL_PART_PLANS), SERIAL_PARTS
    return data['skippedSuites'], data['parts']


def serial_parts_problems(suites, par, perf):
    """Problems with the split: the parts must be disjoint, sorted, and together equal the Serial suites; the skipped suites sit in part 1;
    and, compared as case names with their argument labels, the cases the parts select (less the skipped suites) equal the Serial cases."""
    skipped, parts = serial_parts()
    problems = []
    serial = set(suites) - set(par) - set(perf)
    flat = [name for part in parts for name in part]
    for number, part in enumerate(parts, 1):
        if part != sorted(part):
            problems.append('serial-parts.json part %d is not sorted' % number)
    for name in sorted(n for n, c in collections.Counter(flat).items() if c > 1):
        problems.append('serial-parts.json lists a suite twice: ' + name)
    for name in sorted(serial - set(flat)):
        problems.append('Serial suite in no part (add it to Tools/serial-parts.json, part 2 is the lightest): ' + name)
    for name in sorted(set(flat) - serial):
        problems.append('serial-parts.json names a suite that is not a Serial suite: ' + name)
    for name in skipped:
        if name not in parts[0]:
            problems.append('skipped suite is not in part 1: ' + name)
    parts_cases = collections.Counter(c for part in parts for n in part if n in suites and n not in skipped for c in suites[n].get('cases', []))
    serial_cases = collections.Counter(c for n in serial if n not in skipped for c in suites[n].get('cases', []))
    for case in sorted(serial_cases - parts_cases):
        problems.append('case of a Serial suite in no part: ' + case)
    for case in sorted(parts_cases - serial_cases):
        problems.append('case in a part that is not a Serial case: ' + case)
    return problems


def expected_cases(suites, par, perf):
    """Every case a CI run executes: all suites, less the skipped suites and the per-test OCR skips."""
    skipped, _ = serial_parts()
    cases = collections.Counter(c for n, info in suites.items() if n not in skipped for c in info.get('cases', []))
    for test in OCR_SKIPS:
        cases[test] -= 1
    return +cases


def executed_cases(path):
    """The Test Case nodes of one `xcresulttool get test-results tests` export, named innermost suite / case."""
    found = []

    def walk(node, suite):
        if node.get('nodeType') == 'Test Suite':
            suite = node.get('name')
        if node.get('nodeType') == 'Test Case':
            found.append('%s/%s' % (suite, node.get('name')))
            return
        for child in node.get('children', []):
            walk(child, suite)
    for root in json.loads(Path(path).read_text()).get('testNodes', []):
        walk(root, None)
    return found


def display_names():
    """{display name: type name} of the suites declared `@Suite("Display name") struct Type`: an export names such a suite by its display name."""
    found = {}
    pattern = re.compile(r'@Suite\(\s*"([^"]+)"[^)]*\)\s*(?:@\w+(?:\([^)]*\))?\s*|(?:final|private|fileprivate|public|internal)\s+)*(?:struct|class|enum|actor)\s+(\w+)')
    for path in TESTS.rglob('*.swift'):
        for display, type_name in pattern.findall(path.read_text()):
            assert found.setdefault(display, type_name) == type_name, 'two suites share the display name ' + display
    return found


def verify_results(paths):
    names = display_names()
    suites = inventory()
    parallel, _, performance = load()
    expected = expected_cases(suites, parallel.get('selectedTests', []), performance.get('selectedTests', []))
    ran = collections.Counter(c for path in paths for c in (names.get(x.split('/')[0], x.split('/')[0]) + '/' + x.split('/', 1)[1]
                                                            for x in executed_cases(path)))
    problems = ['ran twice or more: ' + c for c in sorted(c for c, n in ran.items() if n > 1)]
    problems += ['declared but did not run: ' + c for c in sorted(expected - ran)[:50]]
    problems += ['ran but not declared: ' + c for c in sorted(ran - expected)[:50]]
    for problem in problems:
        print('error: ' + problem, file=sys.stderr)
    print(json.dumps({'ran': sum(ran.values()), 'expected': sum(expected.values()), 'runs': len(paths)}, sort_keys=True))
    return 1 if problems else 0


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
    problems += serial_parts_problems(suites, par, perf)
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
    elif name in SERIAL_PART_PLANS:
        skipped, parts = serial_parts()
        part = parts[SERIAL_PART_PLANS.index(name)]
        selection = ['-skip-testing:%s/%s' % (TARGET, s) for s in part if s in skipped]
        selection += ['-only-testing:%s/%s' % (TARGET, s) for s in part if s not in skipped]
        flags = ['-parallel-testing-enabled', 'NO']
    elif name == REST_PLAN:
        selection = ['-only-testing:%s/%s' % (TARGET, s) for s in sorted(parallel['selectedTests'] + performance['selectedTests'])]
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
    if argv[:1] == ['--verify-results'] and len(argv) > 1:
        return verify_results(argv[1:])
    if argv:
        print(__doc__, file=sys.stderr)
        return 2
    return check()


if __name__ == '__main__':
    raise SystemExit(main(sys.argv[1:]))
