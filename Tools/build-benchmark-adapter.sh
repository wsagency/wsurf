#!/bin/bash
# Modified for WSurf by wsagency in 2026; based on Linen by Kavoye.
set -euo pipefail
cd "$(dirname "$0")/.."
wsurf_benchmark_dd="${WSURF_BENCHMARK_DERIVED_DATA:-build/BenchmarkDD}"
wsurf_source_before="$(python3 Tools/benchmark-provenance.py hash)"
xcodebuild build-for-testing -project WSurf.xcodeproj -scheme WSurf \
  -destination 'platform=macOS,arch=arm64' -derivedDataPath "$wsurf_benchmark_dd" \
  -skipMacroValidation -skipPackagePluginValidation \
  CODE_SIGN_STYLE=Manual CODE_SIGN_IDENTITY=- CODE_SIGNING_REQUIRED=NO CODE_SIGN_ENTITLEMENTS=

if [[ "$wsurf_source_before" != "$(python3 Tools/benchmark-provenance.py hash)" ]]; then
  echo "Sources changed during the build. Rebuild before benchmarking." >&2
  exit 1
fi
python3 Tools/benchmark-provenance.py write
