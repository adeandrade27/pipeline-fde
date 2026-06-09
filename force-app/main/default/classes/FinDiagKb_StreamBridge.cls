/**
 * FinDiagKb_StreamBridge — bridge invocable for FinDiagAgent v6+ KB lookups.
 *
 * Wraps the EmployeeCopilot managed-package standard invocable
 * `EmployeeCopilot__AnswerQuestionsWithKnowledge` (underlying
 * `streamKnowledgeSearch` standard action) so it becomes addressable from
 * Agent Script DSL via `target: "apex://FinDiagKb_StreamBridge"`. The DSL
 * `target:` field only accepts `apex://`, `flow://`, `prompt://`; standard
 * invocable actions are not directly addressable, hence this bridge.
 *
 * Contract:
 *   Input  : Request.UserQuery (String, required) — normalized KB query
 *            per Bloco K2 in FinDiagAgent.agent.
 *   Output : Response.KnowledgeSummary (String) — rich-text answer with
 *            citations baked in (citationsEnabled=true const in the stock
 *            action's input schema; see SF_FinancialDiagnosticCompressed_v6
 *            plannerActions/AnswerQuestionsWithKnowledge.../input/schema.json).
 *
 * Read-only: NO DML, NO write-back to the org. KB results are read from the
 * shared Data Cloud retriever via the EmployeeCopilot stock action; this
 * bridge is a thin wrapper only.
 *
 * Bypass contract: KB lookups bypass SF_AgenticGateway per legacy contract
 * (legacy bot SF_FinancialDiagnosticCompressed v5/v6 wired the stock action
 * directly outside the gateway allow-list). No CMDT row authorizes a KB
 * path through SF_AgenticGateway; FinDiagAgent v6 K0 block enforces this at
 * the LLM-instruction layer.
 *
 * Sec posture (mirrors existing adapter style):
 *   - `with sharing` — runs under operator profile FLS on Knowledge__kav.
 *   - Bulk-safe: operates on `List<Request>` per @InvocableMethod contract.
 *   - Zero hardcoded IDs.
 *   - Test seams (`testForcedError`, `testKnowledgeSummary`) honor the
 *     existing repo pattern (`SF_AgenticGateway_FlowAdapter.testFlowResults`).
 *
 * Failure modes:
 *   - Blank UserQuery → throws BridgeException('KB_QUERY_BLANK').
 *   - Stock action not resolvable (managed-package not licensed / wrong
 *     namespace) → throws BridgeException('KB_ACTION_NOT_FOUND:...').
 *   - Invocation runtime error → throws BridgeException with the inner
 *     exception type + message.
 *   - Empty stock-action result → returns null KnowledgeSummary so the
 *     agent's Bloco K1 handles the "no articles found" branch gracefully.
 *
 * Joint design: docs/findiag-agent-v6-kb-stream-2026-05-28-sata-locked-design.md
 * Threat model: docs/findiag-agent-v6-kb-stream-2026-05-28-sec-threat-model.md
 */
public with sharing class FinDiagKb_StreamBridge {

    public class BridgeException extends Exception {}

    public class Request {
        @InvocableVariable(
            label='User Query'
            description='Normalized KB query (per Bloco K2 in FinDiagAgent.agent). Passed verbatim to the EmployeeCopilot stock action as `query` input.'
            required=true)
        public String userQuery;
    }

    public class Response {
        @InvocableVariable(
            label='Knowledge Summary'
            description='Rich-text KB answer with citations baked in by Einstein Trust Layer + EmployeeCopilot stock action (citationsEnabled=true const). Display directly to the operator; do NOT remove or paraphrase citations. Null when no articles matched.')
        public String knowledgeSummary;
    }

    /**
     * Stock action invocation contract.
     */
    private static final String STD_ACTION_TYPE = 'standardInvocableAction';
    private static final String STD_ACTION_NAME = 'streamKnowledgeSearch';
    private static final String IN_QUERY = 'query';
    private static final String OUT_SUMMARY = 'knowledgeSummary';

    /**
     * @TestVisible test seam — when non-null, `stream` returns this string
     * for every input row (skips the platform invocable call). Mirrors the
     * `SF_AgenticGateway_FlowAdapter.testFlowResults` seam style.
     */
    @TestVisible
    private static String testKnowledgeSummary = null;

    /**
     * @TestVisible test seam — when non-null, `stream` throws a
     * BridgeException with this message (skips the platform invocable call).
     */
    @TestVisible
    private static String testForcedError = null;

    /**
     * @TestVisible test seam — when non-null, `invokeStandardAction`
     * treats this map as the platform invocable's
     * `Invocable.Action.Result.getOutputParameters()` (successful row) and
     * exercises the output-parsing branch
     * (`extractSummary(Map<String, Object>)`) without hitting the real
     * `Invocable.Action` API. Pair with `testForcedSuccessfulResultMap`
     * = true to hit the success branch; null leaves the seam inactive.
     */
    @TestVisible
    private static Map<String, Object> testOutputParameters = null;

    /**
     * @TestVisible test seam — when true (and `testOutputParameters` is
     * non-null), `invokeStandardAction` bypasses the platform invocable
     * call entirely and routes through the output-parsing branch using
     * `testOutputParameters` as the synthetic result outputs map.
     */
    @TestVisible
    private static Boolean testForcedSuccessfulResultMap = false;

    /**
     * Bridge entry point — bulk-safe per @InvocableMethod contract. The DSL
     * action wiring in FinDiagAgent.agent invokes this method once per
     * agent turn; bulk-shape is preserved for native multi-row scenarios.
     */
    @InvocableMethod(
        label='FinDiag KB Stream Bridge'
        description='Wraps EmployeeCopilot AnswerQuestionsWithKnowledge (streamKnowledgeSearch) for FinDiagAgent v6 KB lookups. Read-only; bypasses SF_AgenticGateway per legacy contract.'
        category='Agentforce'
        callout=true)
    public static List<Response> stream(List<Request> requests) {
        List<Response> responses = new List<Response>();
        if (requests == null || requests.isEmpty()) {
            return responses;
        }
        for (Request req : requests) {
            Response resp = new Response();
            resp.knowledgeSummary = invokeStandardAction(
                req == null ? null : req.userQuery);
            responses.add(resp);
        }
        return responses;
    }

    /**
     * Invokes the EmployeeCopilot stock action and extracts the
     * `knowledgeSummary` rich-text output. Citations are baked into the
     * rich-text by the stock action via the input-schema const
     * `citationsEnabled=true`; this bridge does NOT re-format or extract
     * citation IDs (Bloco K1 in FinDiagAgent.agent specifies passthrough).
     */
    private static String invokeStandardAction(String userQuery) {
        if (testForcedError != null) {
            throw new BridgeException(testForcedError);
        }
        if (testKnowledgeSummary != null) {
            return testKnowledgeSummary;
        }
        if (testForcedSuccessfulResultMap == true) {
            return extractSummary(testOutputParameters);
        }

        if (String.isBlank(userQuery)) {
            throw new BridgeException('KB_QUERY_BLANK');
        }

        Invocable.Action a;
        try {
            a = Invocable.Action.createCustomAction(STD_ACTION_TYPE, STD_ACTION_NAME);
        } catch (Exception createEx) {
            throw new BridgeException(
                'KB_ACTION_NOT_FOUND:' + STD_ACTION_NAME +
                ' (' + createEx.getMessage() + ')');
        }
        if (a == null) {
            throw new BridgeException('KB_ACTION_NOT_FOUND:' + STD_ACTION_NAME);
        }

        a.setInvocationParameter(IN_QUERY, userQuery);

        List<Invocable.Action.Result> results;
        try {
            results = a.invoke();
        } catch (Exception invokeEx) {
            throw new BridgeException(
                invokeEx.getTypeName() + ': ' + invokeEx.getMessage());
        }

        if (results == null || results.isEmpty() || !results[0].isSuccess()) {
            return null;
        }

        return extractSummary(results[0].getOutputParameters());
    }

    /**
     * Extracts the `knowledgeSummary` output value from the stock action's
     * result map. Returns null when the map is null OR the key is missing
     * OR the value is null. Defensive String.valueOf wraps non-string
     * values (the stock action returns rich-text, but Apex may surface it
     * as Object). Visible to the test class for direct branch coverage of
     * the output-parsing edge cases.
     */
    @TestVisible
    private static String extractSummary(Map<String, Object> outputs) {
        if (outputs == null) return null;
        Object summary = outputs.get(OUT_SUMMARY);
        return summary == null ? null : String.valueOf(summary);
    }
}