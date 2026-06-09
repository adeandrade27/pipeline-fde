#!/bin/bash
# Validation script for Agent Testing Center stress test artifacts.
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

check_executable() {
    local path="$1"
    if [ ! -x "$path" ]; then
        echo "FAIL: Not executable: $path"
        ERRORS=$((ERRORS + 1))
        return 1
    fi
    echo "OK: $path is executable"
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

echo "=== Validating FinDiag_StressTest YAML ==="
YAML="$BASE/force-app/main/default/agent-test-specs/FinDiag_StressTest.yml"

check_file "$YAML" && {
    check_contains "$YAML" "name: FinDiag_StressTest"
    check_contains "$YAML" "subjectType: AGENT"
    check_contains "$YAML" "subjectName: FinDiagAgent"
    check_contains "$YAML" "testCases:"
    check_contains "$YAML" "500Hn00001sbGrYIAU"
    check_contains "$YAML" "expectedTopic: FinDiag_SubAgent"
    check_contains "$YAML" "AgentGateway"
    check_contains "$YAML" "quero resetar minha senha"
    # 5 utterances
    UTTERANCE_COUNT=$(grep -c "utterance:" "$YAML")
    if [ "$UTTERANCE_COUNT" -ne 5 ]; then
        echo "FAIL: Expected 5 utterances, found $UTTERANCE_COUNT"
        ERRORS=$((ERRORS + 1))
    else
        echo "OK: 5 utterances found"
    fi
}

echo ""
echo "=== Validating AiEvaluationDefinition XML ==="
XML="$BASE/force-app/main/default/aiEvaluationDefinitions/FinDiag_StressTest.aiEvaluationDefinition-meta.xml"

check_file "$XML" && {
    check_xml "$XML"
    check_contains "$XML" "<AiEvaluationDefinition"
    check_contains "$XML" "<subjectName>FinDiagAgent</subjectName>"
    check_contains "$XML" "<subjectType>AGENT</subjectType>"
    check_contains "$XML" "500Hn00001sbGrYIAU"
    # 5 testCases blocks
    TESTCASE_COUNT=$(grep -c "<number>" "$XML")
    if [ "$TESTCASE_COUNT" -ne 5 ]; then
        echo "FAIL: Expected 5 testCases, found $TESTCASE_COUNT"
        ERRORS=$((ERRORS + 1))
    else
        echo "OK: 5 testCases found"
    fi
}

echo ""
echo "=== Validating run-stress-test.sh ==="
SCRIPT="$BASE/scripts/run-stress-test.sh"

check_file "$SCRIPT" && {
    check_executable "$SCRIPT"
    check_contains "$SCRIPT" "sf agent test run-eval"
    check_contains "$SCRIPT" "FinDiag_StressTest.yml"
    check_contains "$SCRIPT" "trailsignup.3907ba438cbd33@salesforce.com"
    check_contains "$SCRIPT" "result-format human"
    check_contains "$SCRIPT" "--json"
}

echo ""
if [ $ERRORS -gt 0 ]; then
    echo "FAILED: $ERRORS error(s) found."
    exit 1
else
    echo "ALL CHECKS PASSED."
    exit 0
fi
