/**
 * SF_AgenticGateway_AgentAdapter — invokes Agentforce agents from the
 * gateway via the platform-standard
 * `Invocable.Action.createCustomAction('generateAiAgentResponse',
 * <agentApiName>)` action.
 *
 * Locked design: docs/sf-agentic-gateway-agent-dispatch-2026-05-12.md
 *
 * Surface contract (mirrors SF_AgenticGateway_FlowAdapter shape):
 *
 *   Single payload : {"userMessage":"...", "sessionId":"<optional>"}
 *   Batch payload  : {"batch":[{"userMessage":"...","sessionId":"..."}, ...]}
 *
 *   Per-row result : {success:true,  output:{agentResponse:"...", sessionId:"..."}}
 *                  | {success:false, message:"AGENT_ERROR: <code>: <text>"}
 *
 * Sec controls (see §3 of the locked design):
 *   G-Sec-AGENT-1: SF_AgenticGateway_Limits.assertAgentDispatchCountOk per row
 *                  caps recursive agent fan-out at MAX_AGENT_DISPATCHES_PER_TX=3.
 *   G-Sec-AGENT-2: assertCalloutOk pre-checked per row (LLM call → callout).
 *   G-Sec-AGENT-3: agent runs under the logged-in user's permissions; this
 *                  adapter NEVER impersonates.
 *   G-Sec-AGENT-4: prompt-injection defense lives in the callee agent's
 *                  guardrails — `userMessage` flows verbatim.
 *
 * sessionId resolution (hybrid):
 *   - Caller-supplied value wins (multi-turn continuity).
 *   - When omitted, derived via SF_AgenticGateway_Limits.deriveAgentSessionId
 *     from correlationId + agentApiName → cross-correlation isolation, no
 *     session bleed.
 */
public with sharing class SF_AgenticGateway_AgentAdapter implements IAgenticAdapter {

    public class AgentAdapterException extends Exception {}

    /**
     * WP-L-Dispatcher-Drift Phase 1 (audit findings L-5 + L-6 +
     * Sec card § Card · WP-L-Dispatcher-Drift assertion (a)):
     * polymorphic dispatch entry. Unpacks the canonical args Map +
     * propagates the AllowList gate at adapter entry
     * (`AGENT_ALLOWLIST_BYPASS_BLOCKED:<target>` on reject — matches
     * sibling deterministic-code-shape pattern density of
     * WP-SATA-3 `DISPATCH_SYNC_BYPASS_BLOCKED:<prefix>:<target>`) +
     * delegates to the existing static `invoke(...)` signature so
     * every wave-3 caller (`SF_AgenticGateway.dispatchSync` legacy
     * paths + `WorkerCore.runWorker` async path + existing test
     * classes) continues to work verbatim through the static path.
     *
     * This adapter-entry AllowList check is defense-in-depth on top
     * of the wave-3 `SF_AgenticGateway.invokeOne` line 215 entry-time
     * gate + WP-SATA-3 `dispatchSync` line 315 runtime re-check; the
     * third gate fires only for in-namespace callers reaching the
     * adapter `dispatch` instance method directly (test seam, future
     * polymorphic router caller). Legitimate runtime callers
     * (gateway + WorkerCore) are already cleared by the entry-time
     * gate so this re-check is the THIRD line of identical verdict.
     */
    public Object dispatch(String target, Map<String, Object> args) {
        SF_AgenticGateway_AllowList.assertBundleActive(
            target,
            SF_AgenticGateway_PrefixMapper.toCmdtPicklist('agent'),
            'AGENT');
        String payloadJson = (String) args.get('payloadJson');
        Integer maxBatch = args.get('maxBatch') instanceof Integer
            ? (Integer) args.get('maxBatch') : 1;
        String correlationId = (String) args.get('correlationId');
        return invoke(target, payloadJson, maxBatch, correlationId);
    }

    private static final String ACTION_NAME = 'generateAiAgentResponse';
    private static final String IN_USER_MESSAGE = 'userMessage';
    private static final String IN_SESSION_ID = 'sessionId';
    private static final String OUT_AGENT_RESPONSE = 'agentResponse';
    private static final String OUT_SESSION_ID = 'sessionId';

    /**
     * @TestVisible test seam — when non-null, `invoke` returns this list as
     * the canned agent results instead of calling the platform invocable
     * action. Each map is the agent output parameters for the corresponding
     * input row.
     */
    @TestVisible
    private static List<Map<String, Object>> testAgentResults = null;

    /**
     * @TestVisible test seam — when non-null, every row short-circuits to a
     * failure with this message wrapped in `AGENT_ERROR: <msg>`. Exercises
     * the error-row surface without needing a deployed agent.
     */
    @TestVisible
    private static String testForcedError = null;

    /**
     * Invoke an Agentforce agent with the given payload.
     *
     * @param agentApiName  Agent API name (Target__c from CMDT)
     * @param payloadJson   Single {userMessage,sessionId?} or {batch:[...]} JSON
     * @param maxBatch      CMDT MaxBatchSize__c for this target
     * @param correlationId Gateway correlationId (used in derived sessionId)
     * @return Map shaped as either {results:[...]} (batch) or the single
     *         row map (non-batch). Catastrophic failures raise
     *         AgentAdapterException; per-row agent errors surface in the
     *         row map as success=false with the message prefixed
     *         "AGENT_ERROR: ".
     */
    public static Map<String, Object> invoke(
        String agentApiName,
        String payloadJson,
        Integer maxBatch,
        String correlationId
    ) {
        SF_AgenticGateway_Limits.assertCpuOk();
        SF_AgenticGateway_Limits.assertHeapOk();

        if (String.isBlank(agentApiName)) {
            throw new AgentAdapterException('AGENT_NOT_FOUND_OR_INVALID:blank-name');
        }

        Map<String, Object> parsed = (payloadJson == null || payloadJson.length() == 0)
            ? new Map<String, Object>()
            : (Map<String, Object>) JSON.deserializeUntyped(payloadJson);

        Boolean isBatch = parsed.containsKey('batch') && parsed.get('batch') instanceof List<Object>;
        List<Map<String, Object>> items = new List<Map<String, Object>>();
        if (isBatch) {
            List<Object> rawBatch = (List<Object>) parsed.get('batch');
            SF_AgenticGateway_Limits.assertBatchSizeOk(rawBatch.size(), maxBatch);
            for (Object item : rawBatch) {
                if (item instanceof Map<String, Object>) {
                    items.add((Map<String, Object>) item);
                } else {
                    items.add(new Map<String, Object>{ IN_USER_MESSAGE => String.valueOf(item) });
                }
            }
        } else {
            items.add(parsed);
        }

        List<Map<String, Object>> rowResults = new List<Map<String, Object>>();
        Integer rowIdx = 0;
        for (Map<String, Object> item : items) {
            SF_AgenticGateway_Limits.assertAgentDispatchCountOk();
            SF_AgenticGateway_Limits.assertCalloutOk();
            SF_AgenticGateway_Limits.assertCpuOk();
            SF_AgenticGateway_Limits.assertHeapOk();

            String userMessage = (item.get(IN_USER_MESSAGE) == null)
                ? null
                : String.valueOf(item.get(IN_USER_MESSAGE));
            Object rawSid = item.get(IN_SESSION_ID);
            String sessionId = (rawSid == null || String.isBlank(String.valueOf(rawSid)))
                ? SF_AgenticGateway_Limits.deriveAgentSessionId(correlationId, agentApiName)
                : String.valueOf(rawSid);

            if (testForcedError != null) {
                rowResults.add(new Map<String, Object>{
                    'success' => false,
                    'message' => 'AGENT_ERROR: ' + testForcedError
                });
                rowIdx++;
                continue;
            }

            if (testAgentResults != null) {
                Map<String, Object> cannedRow = (rowIdx < testAgentResults.size())
                    ? testAgentResults[rowIdx]
                    : new Map<String, Object>{
                        OUT_AGENT_RESPONSE => null,
                        OUT_SESSION_ID => sessionId
                    };
                rowResults.add(new Map<String, Object>{
                    'success' => true,
                    'output' => new Map<String, Object>{
                        OUT_AGENT_RESPONSE => cannedRow.get(OUT_AGENT_RESPONSE),
                        OUT_SESSION_ID => cannedRow.containsKey(OUT_SESSION_ID)
                            ? cannedRow.get(OUT_SESSION_ID)
                            : sessionId
                    }
                });
                rowIdx++;
                continue;
            }

            Invocable.Action a;
            try {
                a = Invocable.Action.createCustomAction(ACTION_NAME, agentApiName);
            } catch (Exception createEx) {
                throw new AgentAdapterException(
                    'AGENT_NOT_FOUND_OR_INVALID:' + agentApiName + ' (' + createEx.getMessage() + ')');
            }
            if (a == null) {
                throw new AgentAdapterException('AGENT_NOT_FOUND_OR_INVALID:' + agentApiName);
            }

            a.setInvocationParameter(IN_USER_MESSAGE, userMessage);
            a.setInvocationParameter(IN_SESSION_ID, sessionId);

            List<Invocable.Action.Result> results;
            try {
                results = a.invoke();
            } catch (Exception invokeEx) {
                throw new AgentAdapterException(
                    invokeEx.getTypeName() + ': ' + invokeEx.getMessage());
            }

            if (results == null || results.isEmpty()) {
                rowResults.add(new Map<String, Object>{
                    'success' => false,
                    'message' => 'AGENT_NO_RESULT'
                });
                rowIdx++;
                continue;
            }

            Invocable.Action.Result r = results[0];
            if (r.isSuccess()) {
                Map<String, Object> outParams = r.getOutputParameters();
                String returnedSid = (outParams != null && outParams.get(OUT_SESSION_ID) != null)
                    ? String.valueOf(outParams.get(OUT_SESSION_ID))
                    : sessionId;
                Object agentResponse = (outParams == null)
                    ? null
                    : outParams.get(OUT_AGENT_RESPONSE);
                rowResults.add(new Map<String, Object>{
                    'success' => true,
                    'output' => new Map<String, Object>{
                        OUT_AGENT_RESPONSE => agentResponse,
                        OUT_SESSION_ID => returnedSid
                    }
                });
            } else {
                rowResults.add(new Map<String, Object>{
                    'success' => false,
                    'message' => 'AGENT_ERROR: ' + formatAgentErrors(r.getErrors())
                });
            }
            rowIdx++;
        }

        return shapeResults(rowResults, isBatch);
    }

    private static Map<String, Object> shapeResults(
        List<Map<String, Object>> rowResults,
        Boolean isBatch
    ) {
        if (isBatch) {
            return new Map<String, Object>{ 'results' => rowResults };
        }
        return rowResults.isEmpty()
            ? new Map<String, Object>{ 'success' => false, 'message' => 'AGENT_NO_RESULT' }
            : rowResults[0];
    }

    @TestVisible
    private static String formatAgentErrors(List<Invocable.Action.Error> errs) {
        if (errs == null || errs.isEmpty()) return 'AGENT_UNKNOWN_ERROR';
        List<String> parts = new List<String>();
        for (Invocable.Action.Error e : errs) {
            parts.add(e.getCode() + ': ' + e.getMessage());
        }
        return String.join(parts, ' | ');
    }
}