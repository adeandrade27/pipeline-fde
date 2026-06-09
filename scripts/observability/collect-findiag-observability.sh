#!/bin/bash
set -euo pipefail

ORG="${ORG:-cec-claro-sandbox}"
OUT_DIR="${OUT_DIR:-results/observability/$(date +%Y%m%d-%H%M%S)}"

mkdir -p "$OUT_DIR"

echo "== FinDiag observability snapshot =="
echo "Org: $ORG"
echo "Output: $OUT_DIR"
echo ""

echo "-- Invocation summary (last 24h) --"
sf data query \
  --target-org "$ORG" \
  --file "scripts/observability/findiag-invocation-summary.soql" \
  --result-format csv > "$OUT_DIR/invocation-summary.csv"

echo "-- Invocation errors (last 24h) --"
sf data query \
  --target-org "$ORG" \
  --file "scripts/observability/findiag-invocation-errors.soql" \
  --result-format csv > "$OUT_DIR/invocation-errors.csv"

echo ""
echo "Snapshot generated:"
ls -la "$OUT_DIR"
