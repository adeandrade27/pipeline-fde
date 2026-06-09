# Projeto Solar — Org Assessment · FinDiagAgent v13

**Data:** 08/jun/2026  
**Audiência:** Time interno Salesforce (FDE + arquitetura)  
**Sandbox:** `cec-claro--ibuypfpme`  
**Status:** Rascunho para alinhamento com Lucas e time

---

## 1. Contexto executivo

O Projeto Solar é o primeiro caso de IA generativa da Claro Brasil em produção, com deadline em 30/jun/2026. A IBM entregou uma base funcional em 2024 usando o Agentforce Builder clássico (7 subagentes, ~16 ações). O time Salesforce (Lucas) redesenhou a arquitetura no novo Agent Studio (Spring '26), comprimindo os 7 subagentes para um Router + único FinDiag_SubAgent, com 2 ações expostas ao LLM e um gateway centralizado com boundary de segurança. A estrutura arquitetural está sólida — os gaps identificados neste assessment são operacionais: cobertura de testes, observabilidade e processo de deploy.

---

## 2. Arquitetura atual — o que foi construído

| Componente | Tipo Salesforce | Estado |
|---|---|---|
| FinDiagAgent v13 | `GenAiPlannerBundle` (Agent Studio) | Ativo, deployado |
| SF_AgenticGateway | Apex Invocable (`@InvocableMethod`) | Ativo |
| SF_AgenticGateway_Allow__mdt | Custom Metadata (44 registros) | 12 ativos; 32 legacy/teste |
| SF_AgenticInvocation__c | Custom Object (audit trail) | Existe; sem dashboard |
| SmokeRunner (SfAgenticGatewayBotTemplate_v3) | Bot Template | 19 probes — execução manual |
| FinDiag_StressTest | AiEvaluationDefinition | 5 casos, mesmo CaseId |
| Langfuse | Observabilidade LLM | **Não conectado** |
| Manifest Copado | Package.xml de deploy | **Não formalizado** |

### Decisões arquiteturais do redesenho (o que o Lucas mudou e por quê)

| Decisão | IBM (antes) | Lucas (agora) | Justificativa |
|---|---|---|---|
| Número de subagentes | 7 | 1 (+ 1 Router) | Cada subagente = LLM separado = custo multiplicado |
| Ações expostas ao LLM | ~16 | 2 (AgentGateway + KB) | Menos opções = menos erro de seleção de ferramenta |
| Boundary de segurança | Nenhum | SF_AgenticGateway + CMDT allow-list | Compliance, audit trail, LGPD |
| Versionamento | Point-and-click (não commitável) | `.agent` files em git | Deploy via Copado, revisão em PR |
| Async / spill | Não tratado | QueueableWorker + Platform Cache (>16KB) | Previne timeout em respostas grandes |

### Flows IBM reaproveitadas (camada de dados preservada)

As Flows do IBM continuam ativas como handlers no CMDT — o redesenho substituiu a orquestração, não os dados:

| Flow IBM | CMDT Target | DispatchType | Status |
|---|---|---|---|
| Buscar_caso_de_atendimento | `Buscar_caso_de_atendimento` | Flow | ✅ Ativo |
| (demais flows IBM) | Registros com `Active=false` | — | 🔴 Inativo (legacy) |

---

## 3. Findings — organizados por prioridade

### CRÍTICO — bloqueia produção ou gera risco regulatório

| ID | Finding | Detalhe | Ação necessária |
|---|---|---|---|
| **F-01** | **Fluxo case-first sem alternativa** | O agente exige `currentRecordId` (caso aberto em tela) para funcionar. Se o operador ainda não criou o caso, precisa do diagnóstico para saber qual tipo criar — círculo vicioso. Marcelo Camargo identificou isso: *"dá impressão que TEM que ter um caso para iniciar o atendimento — se for isso é um erro no fluxo"* | Alinhar com Odair/Claro: o caso sempre pré-existe quando o agente é acionado? Se não → criar bloco de entrada por CPF ou número de contrato |
| **F-02** | **Eval suite insuficiente** | 5 casos de teste, todos com o mesmo CaseId, sem variação de fraseado, sem testes de out-of-scope funcionais, sem PII/prompt-leak. Não há como garantir comportamento do agente em cenários reais | Expandir para 30 casos cobrindo os 9 grupos (ver Seção 5) |
| **F-03** | **32 registros CMDT `Active=false`** | Registros legacy IBM com `Target='teste'`, `'teste1'`, `'teste4'` ainda presentes. Risco de confusão no deploy e na auditoria | Limpar registros ou documentar intencionalmente que são legacy |

### ALTO — resolver antes de escalar para produção

| ID | Finding | Detalhe | Ação necessária |
|---|---|---|---|
| **F-04** | **Sem observabilidade ativa** | `SF_AgenticInvocation__c` existe mas sem dashboard. Langfuse não conectado. Impossível medir latência, custo de créditos por sessão, taxa de erro por handler | Conectar Langfuse ao gateway via `writeAudit()`; criar Report/Dashboard básico no Salesforce com `SF_AgenticInvocation__c` |
| **F-05** | **SmokeRunner manual** | 19 probes existem no SfAgenticGatewayBotTemplate_v3 mas não rodam automaticamente em CI | Adicionar `sf agent test run` no pipeline GitLab como quality gate antes de qualquer deploy |
| **F-06** | **Handlers ativos sem eval correspondente** | 12 CMDT ativos; pelo menos 5 handlers (`SF_FinDiagInvoiceDetailsHandler`, `SF_FinDiagHistoricalInvoicesHandler`, `SF_FinDiagCaseRouteHandler`, etc.) não têm nenhum caso de teste mapeado | Criar matriz handler → eval (ver Seção 5) |

### MÉDIO — melhoria de qualidade e manutenibilidade

| ID | Finding | Detalhe | Ação necessária |
|---|---|---|---|
| **F-07** | **Manifest Copado ausente** | Sem `package.xml` formalizado para os componentes do gateway. Deploy atual é manual ou ad-hoc | Criar `manifest/package-findex-agent.xml` com os tipos necessários |
| **F-08** | **Handlers `SF_FinDiag*` parcialmente validados** | Handlers registrados no CMDT mas sem smoke probe individual — não há como saber se funcionam na sandbox atual | Testar cada handler com uma chamada direta via SmokeRunner |
| **F-09** | **Prazo Anatel não confirmado** | System prompt do agente menciona "7 dias" para resposta de contestação, mas Resolução 632/2014 original estabelece 30 dias. Atualização de dez/2025 pode ter alterado para 7 dias — não confirmado com regulatório da Claro | Confirmar prazo vinculante com time jurídico/regulatório da Claro antes de produção |

### BAIXO / OBSERVAÇÃO

| ID | Finding | Detalhe |
|---|---|---|
| **F-10** | `CaseId` vs `currentRecordId` | `FinDiag_StressTest.yml` usa variável `CaseId`; o agent script usa `currentRecordId` — inconsistência de nomenclatura pode causar falso positivo/negativo nos evals |
| **F-11** | IBM legacy Flows sem documentação de dependência | `Buscar_caso_de_atendimento` e similares foram reaproveitadas (boa decisão), mas sem registro explícito de que o gateway depende delas — risco se alguém desativar uma Flow sem saber |
| **F-12** | Async pipeline não testado sob carga | `QueueableWorker` / `FutureWorker` existem e estão bem implementados, mas nunca passaram por stress test com volume real de sessões simultâneas |

---

## 4. Mapa de cobertura: IBM → estado atual

| Domínio IBM | Subagente IBM original | Handler atual (CMDT) | Eval existente? |
|---|---|---|---|
| Divergência financeira | `Case_Discrepancy_Updates` | `Buscar_caso_de_atendimento` (Flow) | ✅ Parcial (StressTest) |
| Assets do cliente | `Customer_Asset_Analysis` | `SF_FinDiagHistoricalInvoicesHandler` | ❌ Nenhum |
| Busca de casos / perfil | `Customer_and_Contract_Cases_Search` | `Buscar_caso_de_atendimento` + outros | ✅ Parcial |
| KB / políticas | `Knowledge_Base_Consultant` | `AnswerQuestionsWithKnowledge` (nativo) | ❌ Nenhum |
| Pedidos / serviços realizados | `Retrieval_performed_service` | `SF_FinDiagCaseRouteHandler` | ❌ Nenhum |
| Detalhes de fatura | `X05` (invoice details) | `SF_FinDiagInvoiceDetailsHandler` | ❌ Nenhum |
| Histórico de faturas | `X05` (historical) | `SF_FinDiagHistoricalInvoicesHandler` | ❌ Nenhum |
| Out-of-scope / contenção | — | Blocos P0/P2 no system prompt | ❌ Nenhum funcional |
| PII / prompt leak | — | Bloco P2 no system prompt | ❌ Nenhum |

**Resultado:** 7 de 9 domínios sem cobertura de eval.

---

## 5. Pergunta aberta crítica — F-01 em detalhe (para o Lucas)

> **Marcelo Camargo (Slack, 08/jun):** *"Eu entendi que abre um caso para registrar o atendimento, mas não entendi se TEM que ter um caso para iniciar o atendimento… dá impressão que sim, e se for isso é um erro no fluxo"*

### O que o código diz hoje

O FinDiagAgent v13 Bloco A0 (instrução de carregamento de contexto):
- Se `currentRecordId` estiver preenchido → chama `AgentGateway` com `Buscar_caso_de_atendimento`
- Se não estiver → pede ao operador que informe o número do caso

### O problema

No fluxo real do call center:
1. Cliente liga com reclamação de cobrança
2. Operador precisa criar um caso do tipo correto
3. Para saber o tipo correto, precisaria do diagnóstico financeiro
4. Mas o diagnóstico só funciona com o caso já aberto em tela

É um círculo: diagnóstico exige caso → tipo de caso exige diagnóstico.

### Duas opções de design

**Opção A — Case-first (manter atual)**
- O caso é criado antes do agente ser acionado (seja manualmente, seja por outro fluxo de atendimento)
- O agente é uma ferramenta de diagnóstico *depois* da abertura do caso
- Simples, sem mudança de código
- **Exige:** confirmar com Claro que este é o fluxo operacional real

**Opção B — Diagnosis-first**
- Agente aceita CPF ou número de contrato como entrada inicial
- Busca dados do cliente sem depender de `currentRecordId`
- Sugere tipo de caso após diagnóstico
- **Exige:** novo handler de entrada + campo adicional no agente + novo bloco de instrução

**Ação necessária:** alinhar com Odair Silveri e operação da Claro qual é o fluxo real **antes de 30/jun**.

---

## 6. Próximos passos — ordem de prioridade

| # | Ação | Dono sugerido | Prazo |
|---|---|---|---|
| 1 | **Resolver F-01:** confirmar fluxo case-first vs. diagnosis-first com Claro | Lucas + Odair + Claro | Urgente (decisão de arquitetura) |
| 2 | **Resolver F-02:** expandir eval suite de 5 → 30 casos (9 grupos) | FDE | Antes de qualquer deploy em produção |
| 3 | **Resolver F-03:** limpar 32 CMDT registros `Active=false` | Lucas | Antes do manifest de deploy |
| 4 | **Resolver F-04:** conectar Langfuse + criar dashboard básico | FDE + Lucas | Junto com produção |
| 5 | **Resolver F-05:** `sf agent test run` no pipeline GitLab | FDE | Junto com manifest |
| 6 | **Resolver F-07:** formalizar manifest Copado (`package.xml`) | FDE | Antes do GMUD |
| 7 | **Resolver F-09:** confirmar prazo Anatel (7 ou 30 dias) | Bia + Claro regulatório | Antes de produção |

---

## 7. Referências técnicas

| Item | Localização |
|---|---|
| Gateway (Apex) | `force-app/main/default/classes/SF_AgenticGateway.cls` |
| Agent script (v13) | `force-app/main/default/genAiPlannerBundles/FinDiagAgent_v13/` |
| CMDT allow-list | `force-app/main/default/customMetadata/SF_AgenticGateway_Allow.*.md-meta.xml` |
| Audit object | `force-app/main/default/objects/SF_AgenticInvocation__c/` |
| Eval atual (5 casos) | `force-app/main/default/aiEvaluationDefinitions/FinDiag_StressTest.aiEvaluationDefinition-meta.xml` |
| SmokeRunner | `force-app/main/default/genAiPlannerBundles/SfAgenticGatewayBotTemplate_v3/` |
| Sandbox principal | `cec-claro--ibuypfpme.sandbox.lightning.force.com` |
| Telemetria Data Cloud | `cec-claro--partial` |
