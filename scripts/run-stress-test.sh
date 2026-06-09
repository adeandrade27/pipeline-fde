#!/bin/bash
set -e

ORG="trailsignup.3907ba438cbd33@salesforce.com"
SPEC="force-app/main/default/agent-test-specs/FinDiag_StressTest.yml"
RESULTS_DIR="results"

mkdir -p "$RESULTS_DIR"

echo "=== FinDiag Stress Test ==="
echo "Org: $ORG"
echo "Spec: $SPEC"
echo ""

# Run 1: execução única
echo "--- Run 1: execução única ---"
sf agent test run-eval \
  --spec "$SPEC" \
  --target-org "$ORG" \
  --result-format human 2>&1 | tee "$RESULTS_DIR/stress-single.txt"

echo ""
echo "--- Run 2: 3 execuções paralelas (simulação de carga) ---"
for i in 1 2 3; do
  sf agent test run-eval \
    --spec "$SPEC" \
    --target-org "$ORG" \
    --json > "$RESULTS_DIR/stress-parallel-$i.json" 2>&1 &
done
wait
echo "Todas as execuções paralelas concluídas."
echo ""
echo "Resultados em: $RESULTS_DIR/"
ls -la "$RESULTS_DIR/"
