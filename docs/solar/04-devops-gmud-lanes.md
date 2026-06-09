# Projeto Solar: DevOps + GMUD com Lanes por Risco

## Objetivo

Conectar a esteira de agente (`FinDiagAgent`) à operação Copado + GitLab com evidência automática para GMUD, mantendo separação por risco:

- `ConfigLane` para mudanças de prompt/instrução/tópico;
- `CodeLane` para Apex/Flow/integrações.

## Lanes e política de promoção

| Lane | Tipo de mudança | Gate mínimo | Aprovação |
|---|---|---|---|
| ConfigLane | Agent Script, instruções, descrições, ajustes de tópico | `validate-eval-gates` + `run-eval-gates` | Dono funcional + arquiteto FDE |
| CodeLane | `SF_AgenticGateway`, handlers, Flows, CMDT, integração | Todos os gates + observabilidade + evidência de stress | GMUD completa + Operações |

## Automação implementada

- Script único de evidência GMUD: `scripts/gmud/run-gmud-gates.sh`
- Pipeline de referência GitLab: `.gitlab-ci.solar.yml`
- Gates utilizados:
  - `scripts/validate-fase1-metadata.sh`
  - `scripts/validate-stress-test.sh`
  - `scripts/validate-eval-gates.sh`
  - `scripts/run-eval-gates.sh`
  - `scripts/observability/collect-findiag-observability.sh`

## Execução local para pacote de aprovação

```bash
ORG=cec-claro-sandbox ./scripts/gmud/run-gmud-gates.sh
```

Saída: `results/gmud/<timestamp>/` com evidências técnicas consolidadas.

## Checklist de evidência para GMUD

1. Resultado de validação de metadados críticos (gateway/invocation/cmdt).
2. Resultado de regressão/adversarial/stress.
3. Snapshot de observabilidade (erro/latência/invocação).
4. Plano de rollback e kill switch referenciado.
5. Dono técnico e dono operacional da mudança.

## Critério de bloqueio

Não promover quando houver qualquer uma das condições:

- falha em qualquer gate de validação;
- violação de escopo/read-only no adversarial;
- erro sistêmico no stress test;
- ausência de evidência observável anexada.

## Responsabilidades

- FDE: garantir saúde dos gates e correções técnicas.
- Operações Claro: decisão final de promoção e execução em produção.
- IBM (quando aplicável): fechamento de pendências legadas dentro da fronteira acordada.
