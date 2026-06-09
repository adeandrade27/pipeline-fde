#!/bin/bash
# Validation script for Fase 1 metadata: SF_AgenticInvocation__c + SF_AgenticGateway_Allow__mdt
# Returns non-zero on any failure.

set +e

BASE="/Users/adeandrade/communication/commu/force-app/main/default"
ERRORS=0

check_file() {
    local path="$1"
    if [ ! -f "$path" ]; then
        echo "FAIL: Missing file: $path"
        ERRORS=$((ERRORS + 1))
        return 1
    fi
    # Check well-formed XML
    if ! xmllint --noout "$path" 2>/dev/null; then
        echo "FAIL: Malformed XML: $path"
        ERRORS=$((ERRORS + 1))
        return 1
    fi
    echo "OK: $path"
    return 0
}

check_contains() {
    local path="$1"
    local pattern="$2"
    if ! grep -q "$pattern" "$path" 2>/dev/null; then
        echo "FAIL: '$pattern' not found in $path"
        ERRORS=$((ERRORS + 1))
    fi
}

echo "=== Validating SF_AgenticInvocation__c ==="
OBJ1="$BASE/objects/SF_AgenticInvocation__c"

check_file "$OBJ1/SF_AgenticInvocation__c.object-meta.xml" && {
    check_contains "$OBJ1/SF_AgenticInvocation__c.object-meta.xml" "deploymentStatus>Deployed"
    check_contains "$OBJ1/SF_AgenticInvocation__c.object-meta.xml" "sharingModel>ReadWrite"
    check_contains "$OBJ1/SF_AgenticInvocation__c.object-meta.xml" "<type>AutoNumber</type>"
}

for field in Target__c HandlerClass__c DispatchType__c InputJson__c OutputJson__c Status__c SessionId__c DurationMs__c; do
    check_file "$OBJ1/fields/${field}.field-meta.xml"
done

# Check specific field types
check_contains "$OBJ1/fields/Target__c.field-meta.xml" "<type>Text</type>"
check_contains "$OBJ1/fields/Target__c.field-meta.xml" "<length>255</length>"
check_contains "$OBJ1/fields/InputJson__c.field-meta.xml" "<type>LongTextArea</type>"
check_contains "$OBJ1/fields/InputJson__c.field-meta.xml" "<length>131072</length>"
check_contains "$OBJ1/fields/OutputJson__c.field-meta.xml" "<type>LongTextArea</type>"
check_contains "$OBJ1/fields/DispatchType__c.field-meta.xml" "<type>Picklist</type>"
check_contains "$OBJ1/fields/DispatchType__c.field-meta.xml" "apex"
check_contains "$OBJ1/fields/DispatchType__c.field-meta.xml" "flow"
check_contains "$OBJ1/fields/DispatchType__c.field-meta.xml" "dml"
check_contains "$OBJ1/fields/DispatchType__c.field-meta.xml" "agent"
check_contains "$OBJ1/fields/Status__c.field-meta.xml" "<type>Picklist</type>"
check_contains "$OBJ1/fields/Status__c.field-meta.xml" "Pending"
check_contains "$OBJ1/fields/Status__c.field-meta.xml" "Success"
check_contains "$OBJ1/fields/Status__c.field-meta.xml" "Error"
check_contains "$OBJ1/fields/DurationMs__c.field-meta.xml" "<type>Number</type>"
check_contains "$OBJ1/fields/DurationMs__c.field-meta.xml" "<precision>18</precision>"

echo ""
echo "=== Validating SF_AgenticGateway_Allow__mdt ==="
OBJ2="$BASE/objects/SF_AgenticGateway_Allow__mdt"

check_file "$OBJ2/SF_AgenticGateway_Allow__mdt.object-meta.xml" && {
    check_contains "$OBJ2/SF_AgenticGateway_Allow__mdt.object-meta.xml" "SF Agentic Gateway Allow"
}

for field in Target__c HandlerClass__c DispatchType__c AsyncMode__c MaxBatchSize__c; do
    check_file "$OBJ2/fields/${field}.field-meta.xml"
done

check_contains "$OBJ2/fields/Target__c.field-meta.xml" "<type>Text</type>"
check_contains "$OBJ2/fields/AsyncMode__c.field-meta.xml" "<type>Checkbox</type>"
check_contains "$OBJ2/fields/AsyncMode__c.field-meta.xml" "<defaultValue>false</defaultValue>"
check_contains "$OBJ2/fields/MaxBatchSize__c.field-meta.xml" "<type>Number</type>"
check_contains "$OBJ2/fields/MaxBatchSize__c.field-meta.xml" "<precision>18</precision>"

echo ""
echo "=== Validating CMDT Record ==="
CMDT_REC="$BASE/customMetadata/SF_AgenticGateway_Allow.Buscar_caso_de_atendimento.md-meta.xml"
check_file "$CMDT_REC" && {
    check_contains "$CMDT_REC" "Buscar caso de atendimento"
    check_contains "$CMDT_REC" "FinDiagCaseHandler"
    check_contains "$CMDT_REC" "Buscar_caso_de_atendimento"
}

echo ""
if [ $ERRORS -gt 0 ]; then
    echo "FAILED: $ERRORS error(s) found."
    exit 1
else
    echo "ALL CHECKS PASSED."
    exit 0
fi
