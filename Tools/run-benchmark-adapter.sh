#!/bin/bash
# Modified for WSurf by wsagency in 2026; based on Linen by Kavoye.
set -euo pipefail
cd "$(dirname "$0")/.."
wsurf_benchmark_dd="${WSURF_BENCHMARK_DERIVED_DATA:-build/BenchmarkDD}"
: "${BAB_CONTROL_URL:?Missing benchmark control URL}"
: "${BAB_CONTROL_TOKEN:?Missing benchmark control token}"
export TEST_RUNNER_BAB_CONTROL_URL="$BAB_CONTROL_URL"
export TEST_RUNNER_BAB_CONTROL_TOKEN="$BAB_CONTROL_TOKEN"
export TEST_RUNNER_BAB_PROVIDER_KEY="${BAB_PROVIDER_KEY:?Missing selected provider key}"
python3 Tools/benchmark-provenance.py verify
# TEST_RUNNER_BAB_LINEN_* is the browser-agent-bench consumer contract.
export TEST_RUNNER_BAB_LINEN_REVISION="$(git rev-parse HEAD)"
export TEST_RUNNER_BAB_LINEN_SOURCE_SHA256="$(python3 Tools/benchmark-provenance.py hash)"
exec xcodebuild test-without-building -project WSurf.xcodeproj -scheme WSurf \
  -destination 'platform=macOS,arch=arm64' -derivedDataPath "$wsurf_benchmark_dd" \
  -only-testing:WSurfTests/BrowserAgentBenchWorker -parallel-testing-enabled NO \
  -default-test-execution-time-allowance 300 -maximum-test-execution-time-allowance 300 \
  CODE_SIGN_STYLE=Manual CODE_SIGN_IDENTITY=- CODE_SIGNING_REQUIRED=NO CODE_SIGN_ENTITLEMENTS=
