#!/bin/bash
set -euo pipefail

ORG="${ORG:-cec-claro-sandbox}"
RESULTS_DIR="${RESULTS_DIR:-results/gates}"
TIMESTAMP="$(date +%Y%m%d-%H%M%S)"
OUT_DIR="$RESULTS_DIR/$TIMESTAMP"

SPECS=(
  "force-app/main/default/agent-test-specs/FinDiag_RegressionGate.yml"
  "force-app/main/default/agent-test-specs/FinDiag_AdversarialGate.yml"
  "force-app/main/default/agent-test-specs/FinDiag_StressTest.yml"
)

mkdir -p "$OUT_DIR"

echo "== FinDiag evaluation gates =="
echo "Org: $ORG"
echo "Output: $OUT_DIR"
echo ""

for spec in "${SPECS[@]}"; do
  name="$(basename "$spec" .yml)"
  echo "-- Running $name --"
  sf agent test run-eval \
    --spec "$spec" \
    --target-org "$ORG" \
    --result-format human | tee "$OUT_DIR/$name.txt"

  sf agent test run-eval \
    --spec "$spec" \
    --target-org "$ORG" \
    --json > "$OUT_DIR/$name.json"
done

echo ""
echo "All evaluation gates completed."
echo "Artifacts: $OUT_DIR"
