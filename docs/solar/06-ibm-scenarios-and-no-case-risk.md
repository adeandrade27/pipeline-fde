# Projeto Solar: Cenarios IBM e Risco "atendimento sem Case"

## Contexto recente (insumo de validação)

Sinal técnico levantado:

- arquitetura atual com um tópico único que delega para gateway via whitelist em CMDT;
- necessidade de testar casos de uso em massa;
- dúvida crítica: o fluxo parece exigir `Case` para iniciar atendimento, o que pode ser erro de desenho operacional.

## Subagente IBM: cenarios funcionais a usar no benchmark

| Topico legado IBM | Intencao principal |
|---|---|
| `Case_Discrepancy_Updates` | Roteamento de divergencia financeira |
| `Customer_Asset_Analysis` | Assets, conta consumidor/cobranca, book de ofertas |
| `Customer_and_Contract_Cases_Search` | Busca de casos, ajuste de pagamento, interacoes, perfil |
| `Knowledge_Base_Consultant` | Perguntas de politica/procedimento via KB |
| `Retrieval_performed_service` | Busca de caso em tela, pedidos e perfil |
| `X05_Service_Case_Information_Retrieval` | Caso em tela + faturas historicas + detalhes da fatura |

## Hipotese de risco (alta prioridade)

Hipotese a provar/refutar:

- "Nao existe atendimento sem `CaseId` valido; o agente depende de caso preexistente para iniciar."

Se confirmada, impacto:

- bloqueio de triagem inicial para contatos sem caso aberto;
- piora de experiencia operacional e risco de fila manual;
- risco de nao aderencia ao desenho esperado de atendimento.

## Testes obrigatorios adicionados

Foram adicionados cenarios de gate para esse risco:

- Regressao: utterance sem `caseId` pedindo contestacao.
- Adversarial: tentativa de forcar atendimento sem identificador.

Arquivos:

- `force-app/main/default/agent-test-specs/FinDiag_RegressionGate.yml`
- `force-app/main/default/agent-test-specs/FinDiag_AdversarialGate.yml`
- `force-app/main/default/aiEvaluationDefinitions/FinDiag_RegressionGate.aiEvaluationDefinition-meta.xml`
- `force-app/main/default/aiEvaluationDefinitions/FinDiag_AdversarialGate.aiEvaluationDefinition-meta.xml`

## Critério de aceite recomendado

- O agente NAO pode inventar dados quando nao houver `CaseId`.
- O agente deve orientar com clareza o proximo passo permitido (informar identificador valido ou fluxo de abertura correto).
- Caso o produto exija `Case` preexistente por desenho, isso deve estar explicitado como restricao conhecida, com fluxo alternativo operacional documentado.

## Proxima acao tecnica

Executar benchmark em massa com:

1. cenarios IBM mapeados;
2. cenarios novos sem `Case`;
3. comparativo de taxa de sucesso, latencia e escalonamento.
