# Projeto Solar — Findings Consolidados (Assessment Paralelo)

**Data:** 08/jun/2026  
**Escopo:** `force-app/main/default` (Apex, Triggers, Flows, LWC/Aura, Objetos, Config/Governança)  
**Contexto:** FinDiagAgent v13 + SF_AgenticGateway

---

## Resumo executivo

O desenho arquitetural do agente está correto (boundary único via gateway + allow-list + trilha de auditoria), porém a prontidão para produção ainda está limitada por cinco frentes: cobertura de teste no núcleo Solar, riscos de triggers legacy não bulkificados, governança fraca de metadados (flows/campos sem descrição), base UI majoritariamente Aura com sinais de dívida técnica, e fragilidade de controles de promoção (gates precisam ser mais orientados a resultado).

---

## Findings por área

## 1) Apex Classes e Triggers

**Situação atual**
- Base com alto volume de classes/triggers e boa centralização no `SF_AgenticGateway`.
- Cobertura aparente no recorte Solar ainda baixa para classes críticas (além do teste do gateway).
- Há triggers com lógica inline e sinais de risco de governor (SOQL/DML em padrão pouco bulk-safe).

**Risco:** **Médio-Alto**

**Recomendações**
- Priorizar refatoração de triggers inline críticos para padrão handler bulk-safe.
- Expandir testes no núcleo Solar (`FinDiagCaseHandler`, adapters, worker core).
- Adotar critério de PR para bloquear anti-patterns de governor.

**Evidências**
- `force-app/main/default/classes/SF_AgenticGateway.cls`
- `force-app/main/default/classes/FinDiagCaseHandler.cls`
- `force-app/main/default/classes/SF_AgenticGateway_WorkerCore.cls`
- `force-app/main/default/triggers/SDO_Service_OpenCTI_isActiveBefore.trigger`
- `force-app/main/default/triggers/SDO_Service_EinsteinBotsInit_Chat.trigger`

---

## 2) Flows

**Situação atual**
- Volume alto de flows/flowDefinitions e inconsistências de governança (flows sem descrição).
- Sinais mistos de ativação entre `status` do flow e `activeVersionNumber` da definition.
- Fluxo FinDiag presente e ativo, com necessidade de padronização de versionamento/deploy.

**Risco:** **Médio-Alto**

**Recomendações**
- Definir fonte de verdade de ativação (flowDefinition).
- Preencher descrição obrigatória para flows críticos.
- Garantir empacotamento completo de artifacts de flow para rollback seguro.

**Evidências**
- `force-app/main/default/flows/FinDiag_BuscarCaso.flow-meta.xml`
- `force-app/main/default/flowDefinitions/`

---

## 3) LWC / Aura

**Situação atual**
- Predominância de Aura sobre LWC (legado relevante).
- Sinais estáticos de dívida técnica (logs excessivos, manipulação direta de `window/document`, bundles grandes).
- Ausência de testes Jest detectados para LWC no estado atual.

**Risco:** **Alto**

**Recomendações**
- Criar suíte Jest mínima para LWCs críticos.
- Reduzir `console.log`/`debugger` e reforçar hygiene de lifecycle/listeners.
- Planejar migração Aura -> LWC por impacto x esforço.

**Evidências**
- `force-app/main/default/lwc/serviceConsoleCaseTimer/serviceConsoleCaseTimer.js`
- `force-app/main/default/lwc/globalLookup/globalLookup.js`
- `force-app/main/default/aura/SDO_Tool_EMC_ScoreReason/SDO_Tool_EMC_ScoreReasonHelper.js`

---

## 4) Objetos customizados / campos / relacionamentos

**Situação atual**
- Governança de metadados ainda fraca: alta proporção de campos sem descrição.
- Conjunto de objetos com baixa referência aparente, indicando possível dívida de modelo.
- Relacionamentos existentes sem inconsistência estrutural grave detectada.

**Risco:** **Alto**

**Recomendações**
- Tornar descrição obrigatória para novos objetos/campos.
- Revisar objetos com baixa referência para classificar: ativo / legado / descontinuação.
- Priorizar saneamento dos objetos mais complexos.

**Evidências**
- `force-app/main/default/objects/`
- `force-app/main/default/objects/SDO_Sales_Invoice_Example__c/`
- `force-app/main/default/objects/SDO_Service_Queue_Stat__c/`

---

## 5) Configuração geral / Governança / Operação

**Situação atual**
- Bons controles de desenho (gateway, allow-list, auditoria) já estão implementados.
- Ainda há risco de drift entre código Apex e metadados/configuração.
- Gates existem, mas precisam evoluir para fail por threshold de qualidade.

**Risco:** **Alto**

**Recomendações**
- Reconciliação metadata ↔ código como P0 antes de produção.
- Endurecer permissões de acesso a trilha de auditoria conforme menor privilégio.
- Exigir gate semântico (resultado de eval), não só validação estrutural de artefato.

**Evidências**
- `force-app/main/default/classes/SF_AgenticGateway_AllowList.cls`
- `force-app/main/default/objects/SF_AgenticInvocation__c/`
- `force-app/main/default/permissionsets/FinDiag_Admin.permissionset-meta.xml`
- `scripts/gmud/run-gmud-gates.sh`

---

## Risco funcional crítico já identificado

**Case-first obrigatório (potencial erro de fluxo):**  
Existe risco de o atendimento exigir `CaseId` prévio para diagnóstico, o que pode travar a triagem inicial.

**Ação imediata**
- Validar com operação da Claro se o fluxo é sempre case-first.
- Se não for, implementar entrada sem case (CPF/contrato) com handoff controlado.

Referência:
- `docs/solar/06-ibm-scenarios-and-no-case-risk.md`

---

## Prioridades de execução (7 dias)

1. **P0** Reconciliação metadata/código + hardening de permissões.
2. **P0** Gate por resultado (regressão + adversarial + stress com critério de corte).
3. **P1** Refatoração de triggers críticos para bulk-safe + testes.
4. **P1** Saneamento de governança de flows (descrição + ativação/versionamento).
5. **P2** Plano de redução de dívida Aura e expansão de testes LWC.

