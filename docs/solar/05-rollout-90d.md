# Projeto Solar: Plano de Rollout (Go-Live + 90 dias)

## Objetivo

Executar rollout controlado do `FinDiagAgent` com expansão progressiva de escopo, preservando estabilidade e governança.

## Fase 0: Pré-Go-Live (D-10 a D-1)

- Rodar pacote de evidência GMUD:
  - `ORG=cec-claro-sandbox ./scripts/gmud/run-gmud-gates.sh`
- Confirmar:
  - regressão/adversarial/stress aprovados;
  - observabilidade ativa e alertas calibrados;
  - rollback e kill switch validados;
  - dono operacional de plantão definido.

Saída obrigatória:

- pacote de evidência em `results/gmud/<timestamp>/`;
- decisão formal de go/no-go.

## Fase 1: Go-Live (até 30/jun)

Escopo:

- 1 tipo de contestação prioritária;
- janela de operação controlada;
- fallback humano pronto.

Critérios de sucesso:

- estabilidade sem incidente crítico;
- SLA regulatório dentro do alvo definido;
- custo por resolução dentro do orçamento de piloto.

Critérios de rollback imediato:

- taxa de erro acima do limite acordado;
- degradação sustentada de latência;
- evidência de comportamento fora de escopo.

## Fase 2: +30 dias (estabilização)

Objetivo:

- reduzir variância operacional e consolidar tuning.

Ações:

- revisão semanal de métricas;
- ajuste de prompt/roteamento baseado em dados;
- fechamento de pendências IBM/FDE com prazo.

Saída:

- baseline de produção estável para expansão de escopo.

## Fase 3: +60 dias (expansão controlada)

Objetivo:

- incluir novos tipos de contestação mantendo controle de risco.

Ações:

- acrescentar novos cenários na suíte de gate;
- validar impacto de custo por resolução;
- expandir cobertura de regressão para novos fluxos.

Saída:

- cobertura funcional ampliada sem regressão de estabilidade.

## Fase 4: +90 dias (otimização)

Objetivo:

- otimizar custo, latência e qualidade de resolução.

Ações:

- otimização de dispatch/handlers no gateway;
- redução de escalonamento indevido;
- revisão de thresholds de alerta com base no histórico.

Saída:

- operação sustentável com controle técnico e financeiro.

## KPIs de acompanhamento

- taxa de resolução correta;
- taxa de escalonamento;
- tempo médio de diagnóstico;
- custo por resolução (credits/session);
- taxa de erro por invocação;
- P95 de latência por dispatch.

## Cadência operacional recomendada

- Diário (operação): monitoramento de incidentes e erro/latência.
- Semanal (tático): revisão de KPIs e backlog de melhoria.
- Quinzenal (governança): revisão de risco e readiness de expansão.
- Mensal (executivo): evolução de valor entregue e custo operacional.
