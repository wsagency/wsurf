#!/bin/sh
# Modified for WSurf by wsagency in 2026; based on Linen by Kavoye.

set -eu

if ! command -v swiftlint >/dev/null 2>&1; then
  echo "error: swiftlint is not installed. Run: brew install swiftlint" >&2
  exit 1
fi

swiftlint lint --strict --quiet

echo "swiftlint: no violations"
