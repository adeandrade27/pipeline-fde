# Projeto Solar: Observabilidade Operacional + Runbook

## Objetivo

Padronizar o monitoramento e a resposta a incidentes do `FinDiagAgent` com foco em:

- estabilidade operacional;
- rastreabilidade do `SF_AgenticGateway`;
- prontidão para rollback/kill switch sob GMUD.

## Fontes de telemetria

### 1) Camada transacional (Salesforce)

- Objeto de auditoria: `SF_AgenticInvocation__c`.
- Campos mínimos para operação:
  - `Target__c`
  - `HandlerClass__c`
  - `DispatchType__c`
  - `Status__c`
  - `DurationMs__c`
  - `SessionId__c`

### 2) Camada de IA/negócio

- Data Cloud (sessões, action-steps e custo por sessão).
- Stack do cliente (Langfuse/LandFuse + ferramentas complementares).

## Scripts operacionais

- Snapshot de operação (últimas 24h):
  - `scripts/observability/collect-findiag-observability.sh`
- Consultas:
  - `scripts/observability/findiag-invocation-summary.soql`
  - `scripts/observability/findiag-invocation-errors.soql`

Execução:

```bash
ORG=cec-claro-sandbox ./scripts/observability/collect-findiag-observability.sh
```

## SLOs e alertas recomendados

- Erro por invocação (`Status__c='Error'`) acima de 2% em 15 min.
- P95 de `DurationMs__c` acima do baseline acordado por 3 janelas consecutivas.
- Crescimento abrupto de action-steps/session (sinal de loop de agente).
- Saturação de integrações externas (timeout/retries anormais).

## Runbook de incidente (L1/L2)

1. Confirmar escopo do incidente (apenas `FinDiagAgent` ou plataforma ampla).
2. Coletar snapshot (`collect-findiag-observability.sh`) e anexar ao ticket.
3. Identificar padrão:
   - falha isolada de handler;
   - degradação de latência;
   - crescimento de erro por tipo de dispatch.
4. Aplicar mitigação:
   - reduzir tráfego para cenário crítico;
   - desviar para atendimento humano quando necessário;
   - ativar rollback/kill switch conforme severidade.
5. Comunicar status para operação/GMUD com evidência.

## Rollback operacional (versão anterior estável)

Estratégia:

- Reativar versão anterior estável do bot (`BotVersion`) aprovada pela operação.
- Reexecutar sanity checks da suíte de gate.
- Confirmar redução de erro/latência antes de normalizar o tráfego.

Checklist mínimo:

- versão alvo validada em sandbox;
- change ticket aprovado;
- evidência pré/pós rollback anexada;
- comunicação formal para time de operações.

## Kill switch (modo segurança)

Objetivo: interromper rapidamente a capacidade de atendimento do agente quando houver risco de impacto de negócio.

Ações:

1. Desativar versão ativa do agente (ou remover roteamento para o agente) conforme processo de ops.
2. Direcionar fluxo para fallback humano/canal legado.
3. Manter captura de evidência técnica para RCA.
4. Só reativar após validação de correção + gate completo aprovado.

## Evidência obrigatória para GMUD

- Relatório de erros e latência antes/depois da mudança.
- Resultado da suíte de regressão/adversarial/stress.
- Registro de decisão operacional (rollback/kill switch, quando aplicável).
- Plano de prevenção recorrente (ação de hardening e dono).
