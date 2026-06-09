# Projeto Solar Baseline: Legado vs Novo + Ownership

## Escopo deste baseline

Este documento consolida o estado atual dos artefatos no repositório para apoiar as decisões de go-live do `FinDiagAgent`, comparando:

- arquitetura legada orientada a múltiplos tópicos/ações;
- arquitetura nova com compressão de superfície (`AgentGateway` + KB);
- fronteira de responsabilidade (`IBM` vs `Lucas/FDE` vs `Claro`).

## Inventário técnico atual (repositório)

- Agente principal em uso: `force-app/main/default/bots/FinDiagAgent/v13.botVersion-meta.xml`.
- Planner bundle atual: `force-app/main/default/genAiPlannerBundles/FinDiagAgent_v13/FinDiagAgent_v13.genAiPlannerBundle`.
- Função central de ação: `force-app/main/default/genAiFunctions/AgentGateway/AgentGateway.genAiFunction-meta.xml`.
- Plugin tópico de diagnóstico: `force-app/main/default/genAiPlugins/FinDiag_SubAgent.genAiPlugin-meta.xml`.
- Boundary de execução: `force-app/main/default/classes/SF_AgenticGateway.cls`.
- Allow-list/roteamento determinístico: `force-app/main/default/customMetadata/SF_AgenticGateway_Allow.Buscar_caso_de_atendimento.md-meta.xml`.
- Harness de smoke/stress: `force-app/main/default/bots/SfAgenticGatewayBotTemplate/SfAgenticGatewayBotTemplate.bot-meta.xml`.

## Paridade funcional (As-Is x To-Be)

| Dimensão | Legado IBM (As-Is) | Novo FinDiag (To-Be) | Status |
|---|---|---|---|
| Orquestração | Múltiplos subagentes e ações por tema | `agent_router` + `FinDiag_SubAgent` | Melhorado |
| Superfície de ação | Alta (N ações on-demand) | Baixa (1 ação global + KB) | Melhorado |
| Determinismo | Mais dependente do planner por ação | Dispatch centralizado no gateway e allow-list | Melhorado |
| Governança | Distribuída por metadados/tópicos | Concentrada em `SF_AgenticGateway` + CMDT | Melhorado |
| Auditoria | Fragmentada | `SF_AgenticInvocation__c` como ledger único | Melhorado |
| Prontidão de testes | Predominantemente manual | Base inicial de stress/eval no repo | Parcial |
| Observabilidade operacional | Não consolidada | Instrumentação prevista no gateway + Data Cloud | Parcial |

## Ownership matrix (proposta operacional)

| Bloco | Dono primário | Co-responsável | Critério de aceite |
|---|---|---|---|
| Agente legado (estrutura original, tópicos históricos) | IBM | Claro | Paridade funcional documentada |
| Novo Agent Script (`FinDiagAgent_v13`) | Lucas/FDE | Claro | Evals e regressão aprovados |
| `SF_AgenticGateway` (boundary e adapters) | Lucas/FDE | Arquitetura Claro | Stress + segurança + auditoria |
| Allow-list CMDT (`SF_AgenticGateway_Allow__mdt`) | FDE | Operações Claro | Revisão de privilégio mínimo |
| Operação e promoção para prod | Operações Claro | FDE + IBM | Gate GMUD completo |
| Observabilidade (dashboards/alertas) | Claro (ops/SRE) | FDE | Alertas e runbooks validados |

## Fronteira IBM x Lucas/FDE (ação imediata)

1. Congelar a baseline legada em uma lista de cenários de referência.
2. Executar benchmark reproduzível legado vs novo no mesmo conjunto de casos.
3. Assinar matriz RACI por trilha (agente, gateway, dados, testes, operação).
4. Tratar pendências de IBM como backlog com SLA e dono explícito.

## Riscos abertos na baseline

- Divergência documental sobre `DispatchType` esperado para `Buscar_caso_de_atendimento` (Flow em narrativa, `apex` no CMDT atual).
- Instruções e descrições mistas em inglês/português, com risco de drift de comportamento.
- Lacuna de “evidência de prontidão” para GMUD se não houver suite de regressão + stress versionada.

## Saída esperada desta fase

- Documento de paridade assinado tecnicamente.
- Matriz de ownership com dono, prazo e critério de aceite por bloco.
- Lista única de gaps impeditivos para go-live e responsável por fechamento.
