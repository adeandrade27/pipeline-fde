#!/bin/bash
# Validation script for FinDiag evaluation gate assets.
# Returns non-zero on any failure.

set +e

BASE="/Users/adeandrade/communication/commu"
ERRORS=0

check_file() {
    local path="$1"
    if [ ! -f "$path" ]; then
        echo "FAIL: Missing file: $path"
        ERRORS=$((ERRORS + 1))
        return 1
    fi
    echo "OK: $path exists"
    return 0
}

check_xml() {
    local path="$1"
    if ! xmllint --noout "$path" 2>/dev/null; then
        echo "FAIL: Malformed XML: $path"
        ERRORS=$((ERRORS + 1))
        return 1
    fi
    echo "OK: $path is valid XML"
    return 0
}

check_contains() {
    local path="$1"
    local pattern="$2"
    if ! grep -qF -- "$pattern" "$path" 2>/dev/null; then
        echo "FAIL: '$pattern' not found in $path"
        ERRORS=$((ERRORS + 1))
    fi
}

check_utterance_count() {
    local path="$1"
    local expected="$2"
    local count
    count=$(grep -c "utterance:" "$path")
    if [ "$count" -ne "$expected" ]; then
        echo "FAIL: Expected $expected utterances, found $count in $path"
        ERRORS=$((ERRORS + 1))
    else
        echo "OK: $expected utterances found in $path"
    fi
}

check_xml_case_count() {
    local path="$1"
    local expected="$2"
    local count
    count=$(grep -c "<number>" "$path")
    if [ "$count" -ne "$expected" ]; then
        echo "FAIL: Expected $expected testCases, found $count in $path"
        ERRORS=$((ERRORS + 1))
    else
        echo "OK: $expected testCases found in $path"
    fi
}

echo "=== Validating evaluation specs ==="
REG_SPEC="$BASE/force-app/main/default/agent-test-specs/FinDiag_RegressionGate.yml"
ADV_SPEC="$BASE/force-app/main/default/agent-test-specs/FinDiag_AdversarialGate.yml"
STR_SPEC="$BASE/force-app/main/default/agent-test-specs/FinDiag_StressTest.yml"

check_file "$REG_SPEC" && {
    check_contains "$REG_SPEC" "subjectName: FinDiagAgent"
    check_contains "$REG_SPEC" "expectedTopic: FinDiag_SubAgent"
    check_utterance_count "$REG_SPEC" 6
}
check_file "$ADV_SPEC" && {
    check_contains "$ADV_SPEC" "subjectName: FinDiagAgent"
    check_contains "$ADV_SPEC" "expectedTopic: FinDiag_SubAgent"
    check_utterance_count "$ADV_SPEC" 6
}
check_file "$STR_SPEC"

echo ""
echo "=== Validating evaluation definitions ==="
REG_XML="$BASE/force-app/main/default/aiEvaluationDefinitions/FinDiag_RegressionGate.aiEvaluationDefinition-meta.xml"
ADV_XML="$BASE/force-app/main/default/aiEvaluationDefinitions/FinDiag_AdversarialGate.aiEvaluationDefinition-meta.xml"

check_file "$REG_XML" && {
    check_xml "$REG_XML"
    check_contains "$REG_XML" "<subjectName>FinDiagAgent</subjectName>"
    check_xml_case_count "$REG_XML" 6
}
check_file "$ADV_XML" && {
    check_xml "$ADV_XML"
    check_contains "$ADV_XML" "<subjectName>FinDiagAgent</subjectName>"
    check_xml_case_count "$ADV_XML" 6
}

echo ""
echo "=== Validating gate runner ==="
RUNNER="$BASE/scripts/run-eval-gates.sh"
check_file "$RUNNER" && {
    if [ ! -x "$RUNNER" ]; then
        echo "FAIL: Not executable: $RUNNER"
        ERRORS=$((ERRORS + 1))
    else
        echo "OK: $RUNNER is executable"
    fi
    check_contains "$RUNNER" "sf agent test run-eval"
    check_contains "$RUNNER" "FinDiag_RegressionGate.yml"
    check_contains "$RUNNER" "FinDiag_AdversarialGate.yml"
    check_contains "$RUNNER" "FinDiag_StressTest.yml"
}

echo ""
if [ $ERRORS -gt 0 ]; then
    echo "FAILED: $ERRORS error(s) found."
    exit 1
else
    echo "ALL CHECKS PASSED."
    exit 0
fi
