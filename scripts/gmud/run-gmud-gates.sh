#!/bin/bash
set -euo pipefail

ORG="${ORG:-cec-claro-sandbox}"
EVIDENCE_DIR="${EVIDENCE_DIR:-results/gmud/$(date +%Y%m%d-%H%M%S)}"

mkdir -p "$EVIDENCE_DIR"

echo "== GMUD evidence run =="
echo "Org: $ORG"
echo "Evidence dir: $EVIDENCE_DIR"

echo ""
echo "-- Step 1: Validate metadata hardening artifacts --"
./scripts/validate-fase1-metadata.sh | tee "$EVIDENCE_DIR/validate-fase1-metadata.txt"

echo ""
echo "-- Step 2: Validate stress assets --"
./scripts/validate-stress-test.sh | tee "$EVIDENCE_DIR/validate-stress-test.txt"

echo ""
echo "-- Step 3: Validate eval gate assets --"
./scripts/validate-eval-gates.sh | tee "$EVIDENCE_DIR/validate-eval-gates.txt"

echo ""
echo "-- Step 4: Run eval gates (regression/adversarial/stress) --"
RESULTS_DIR="$EVIDENCE_DIR" ORG="$ORG" ./scripts/run-eval-gates.sh | tee "$EVIDENCE_DIR/run-eval-gates.txt"

echo ""
echo "-- Step 5: Capture observability snapshot --"
OUT_DIR="$EVIDENCE_DIR/observability" ORG="$ORG" ./scripts/observability/collect-findiag-observability.sh | tee "$EVIDENCE_DIR/collect-observability.txt"

echo ""
echo "GMUD evidence package generated at: $EVIDENCE_DIR"
