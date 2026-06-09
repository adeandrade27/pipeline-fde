# Projeto Solar: Testes Massivos e Gates de Promocao

## Objetivo

Estabelecer um gate técnico obrigatório para promoção do `FinDiagAgent` com três camadas:

1. Regressão funcional (fraseado + comportamento esperado).
2. Adversarial (escopo, segurança, anti-loop, read-only).
3. Stress (carga e consistência de execução).

## Artefatos criados

- Regressão: `force-app/main/default/agent-test-specs/FinDiag_RegressionGate.yml`
- Adversarial: `force-app/main/default/agent-test-specs/FinDiag_AdversarialGate.yml`
- Stress existente: `force-app/main/default/agent-test-specs/FinDiag_StressTest.yml`
- EvaluationDefinitions:
  - `force-app/main/default/aiEvaluationDefinitions/FinDiag_RegressionGate.aiEvaluationDefinition-meta.xml`
  - `force-app/main/default/aiEvaluationDefinitions/FinDiag_AdversarialGate.aiEvaluationDefinition-meta.xml`
  - `force-app/main/default/aiEvaluationDefinitions/FinDiag_StressTest.aiEvaluationDefinition-meta.xml`
- Runner de gates: `scripts/run-eval-gates.sh`
- Validador de artefatos: `scripts/validate-eval-gates.sh`

## Execucao operacional

### 1) Validar estrutura dos artefatos

```bash
./scripts/validate-eval-gates.sh
```

### 2) Rodar gate completo no sandbox alvo

```bash
ORG=cec-claro-sandbox ./scripts/run-eval-gates.sh
```

Resultados são gerados em `results/gates/<timestamp>/`.

## Regras de promocao recomendadas

- Gate só passa quando:
  - Regressão: 100% dos casos críticos aprovados.
  - Adversarial: 0 violação de escopo/read-only.
  - Stress: sem erro sistêmico e sem explosão anômala de custo por sessão.
- Em caso de falha:
  - Bloquear promoção para prod.
  - Abrir incidente técnico com causa e plano de correção.
  - Reexecutar suite completa após fix.

## Cobertura mínima esperada

- Diagnóstico de contestação com variação de fraseado.
- Bloqueio de pedidos fora de escopo.
- Bloqueio de pedidos de escrita.
- Proteção contra vazamento de JSON bruto.
- Robustez contra instruções adversariais e tentativa de loop.

## Próxima evolução

- Parametrizar casos por tipo de contestação (duplicidade, cobrança indevida, pacote não contratado).
- Incluir baseline de custo máximo por resolução (credits/session).
- Acoplar publicação automática do relatório de gate no pipeline Copado + GitLab.
