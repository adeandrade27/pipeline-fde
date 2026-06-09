#!/usr/bin/env bash
# Testa cada um dos 12 handlers do SF_AgenticGateway individualmente via Anonymous Apex
# Não depende do agente estar ativo. Cada invocação grava em SF_AgenticInvocation__c.
#
# Uso: bash scripts/test_handlers.sh
# Resultados: scripts/handler-results/

set -euo pipefail

ORG="cec-claro-sandbox"
CASE_ID="500Hn00001sbGrYIAU"
OUTPUT_DIR="scripts/handler-results/$(date +%Y%m%d_%H%M%S)"

mkdir -p "${OUTPUT_DIR}"

echo "===== Teste de Handlers — SF_AgenticGateway ====="
echo "CaseId : ${CASE_ID}"
echo "Output : ${OUTPUT_DIR}/"
echo "=================================================="

run_handler() {
  local name="$1"
  local handler="$2"
  local payload="$3"
  local apex_file="${OUTPUT_DIR}/${name}.apex"
  local result_file="${OUTPUT_DIR}/${name}.json"

  printf "\n[TEST] %-55s" "${name}"

  # Gerar Apex anônimo
  cat > "${apex_file}" << APEX
SF_AgenticGateway.Request req = new SF_AgenticGateway.Request();
req.handlerClass = '${handler}';
req.payloadJson  = '${payload}';
req.correlationId = 'smoke${name}';
List<SF_AgenticGateway.Request> reqs = new List<SF_AgenticGateway.Request>{ req };
List<SF_AgenticGateway.Response> resps = SF_AgenticGateway.invoke(reqs);
SF_AgenticGateway.Response r = resps[0];
System.debug('RESULT::' + JSON.serialize(r));
APEX

  RESULT=$(sf apex run \
    --file "${apex_file}" \
    --target-org "${ORG}" \
    --json 2>&1)

  echo "${RESULT}" > "${result_file}"

  # Extrair success e message do debug log
  SUCCESS=$(echo "${RESULT}" | python3 -c "
import sys, json
try:
    d = json.load(sys.stdin)
    logs = d.get('result', {}).get('logs', '') or ''
    if 'RESULT::' in logs:
        chunk = logs.split('RESULT::')[-1].split('\n')[0].strip()
        obj = json.loads(chunk)
        s = obj.get('success', None)
        msg = (obj.get('dataJson') or obj.get('message') or '')[:120]
        print(f'{s}|{msg}')
    else:
        print('null|no debug output')
except Exception as e:
    print(f'null|parse error: {e}')
" 2>/dev/null || echo "null|script error")

  STATUS="${SUCCESS%%|*}"
  MSG="${SUCCESS#*|}"

  if [[ "${STATUS}" == "True" ]]; then
    printf " ✓  %s\n" "${MSG:0:80}"
  elif [[ "${STATUS}" == "False" ]]; then
    printf " ✗  %s\n" "${MSG:0:80}"
  else
    printf " ?  %s\n" "${MSG:0:80}"
  fi
}

# Payloads corretos por handler (schemas extraídos via Tooling API + FlowVersion metadata)
# Valores de teste baseados no CaseId 500Hn00001sbGrYIAU da sandbox

# h01: IN=referenceCase
run_handler "h01CaseInfo" \
  "flow:Buscar_caso_de_atendimento" \
  "{\\\"referenceCase\\\":\\\"${CASE_ID}\\\"}"

# h02: IN=startDate, endDate, operatorCode, contractNumber
run_handler "h02HistInvoices" \
  "apex:SF_FinDiagHistoricalInvoicesHandler" \
  "{\\\"startDate\\\":\\\"2026-01-01\\\",\\\"endDate\\\":\\\"2026-06-01\\\",\\\"operatorCode\\\":\\\"CLARO\\\",\\\"contractNumber\\\":\\\"123456\\\"}"

# h03: IN=invoiceId, contractNumber, operatorCode
run_handler "h03InvDetails" \
  "apex:SF_FinDiagInvoiceDetailsHandler" \
  "{\\\"invoiceId\\\":\\\"INV-001\\\",\\\"contractNumber\\\":\\\"123456\\\",\\\"operatorCode\\\":\\\"CLARO\\\"}"

# h04: IN=varCaseId, varDescricaoAnalise
run_handler "h04FinRoute" \
  "flow:Agentforce_Roteamento_Divergencia_Financeira" \
  "{\\\"varCaseId\\\":\\\"${CASE_ID}\\\",\\\"varDescricaoAnalise\\\":\\\"cliente contesta cobrança indevida de R\$150\\\"}"

# h05: IN=IDdaconta, orderReference
run_handler "h05Assets" \
  "flow:Buscar_Dados_Assets" \
  "{\\\"IDdaconta\\\":\\\"001000000000001\\\",\\\"orderReference\\\":\\\"ORD-001\\\"}"

# h06: IN=caseBillingAccount, caseConsumerAccount
run_handler "h06Account" \
  "flow:Buscar_informacoes_da_Conta" \
  "{\\\"caseBillingAccount\\\":\\\"001000000000001\\\",\\\"caseConsumerAccount\\\":\\\"001000000000002\\\"}"

# h07: IN=varAno, varCidade, varMes, varProduto
run_handler "h07Ofertas" \
  "flow:Buscar_Book_Ofertas" \
  "{\\\"varAno\\\":2026,\\\"varCidade\\\":\\\"São Paulo\\\",\\\"varMes\\\":\\\"06\\\",\\\"varProduto\\\":\\\"FIXO\\\"}"

# h08: NOT IN ALLOW-LIST — documenta o gap
run_handler "h08UserProfile" \
  "flow:Buscar_perfil_do_usuario" \
  "{\\\"caseId\\\":\\\"${CASE_ID}\\\"}"

# h09: IN=contractReference
run_handler "h09CaseHistory" \
  "flow:Buscar_casos_do_cliente_ou_contrato" \
  "{\\\"contractReference\\\":\\\"CONT-001\\\"}"

# h10: IN=accountReference, caseReference
run_handler "h10Ajuste" \
  "flow:Buscar_Ajuste_de_Pagamento" \
  "{\\\"accountReference\\\":\\\"001000000000001\\\",\\\"caseReference\\\":\\\"${CASE_ID}\\\"}"

# h11: IN=orderReference
run_handler "h11Interactions" \
  "flow:Buscar_Customer_Interaction_do_pedido_order" \
  "{\\\"orderReference\\\":\\\"ORD-001\\\"}"

# h12: IN=caseReference, customerInterectionReference
run_handler "h12Topics" \
  "flow:Buscar_Customer_Interection_Topic_do_caso" \
  "{\\\"caseReference\\\":\\\"${CASE_ID}\\\",\\\"customerInterectionReference\\\":\\\"INT-001\\\"}"

# ── Resultado final ───────────────────────────────────────────────────────────
echo ""
echo "===== Sumário ====="
PASS=$(grep -l '"success":true\|"success": true' "${OUTPUT_DIR}"/*.json 2>/dev/null | wc -l | tr -d ' ')
FAIL=$(grep -l '"success":false\|"success": false' "${OUTPUT_DIR}"/*.json 2>/dev/null | wc -l | tr -d ' ')
echo "✓ Pass : ${PASS}"
echo "✗ Fail : ${FAIL}"
echo ""
echo "Invocações gravadas no SF_AgenticInvocation__c:"
echo "  sf data query \\"
echo "    --query \"SELECT Id,Target,Status,DurationMs,CreatedDate FROM SF_AgenticInvocation__c WHERE CorrelationId__c LIKE 'smoke%' ORDER BY CreatedDate DESC LIMIT 20\" \\"
echo "    --target-org ${ORG}"
