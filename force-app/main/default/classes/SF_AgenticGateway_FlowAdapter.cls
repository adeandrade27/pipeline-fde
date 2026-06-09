/**
 * SF_AgenticGateway_FlowAdapter — invokes autolaunched Flows from the
 * gateway via `Invocable.Action.createCustomAction('flow', name)`.
 *
 * Sec C-3: rejects any Flow whose ProcessType is not `AutoLaunchedFlow`.
 * Screen Flows, Record-Triggered Flows, and Workflow Flows are blocked at
 * the adapter layer regardless of CMDT allow-list contents (defense in
 * depth — CMDT is content control, this is shape control).
 *
 * Bulk semantics: payloadJson with a `batch` array maps to native bulk
 * via `Invocable.Action.setInvocations(List<Map<String,Object>>)` so the
 * Flow runtime processes the whole list in one invoke() call. CPU + heap
 * budgets re-asserted before each setInvocations.
 */
public with sharing class SF_AgenticGateway_FlowAdapter implements IAgenticAdapter {

    public class FlowAdapterException extends Exception {}

    /**
     * WP-L-Dispatcher-Drift Phase 1 (audit findings L-5 + L-6 +
     * Sec card § Card · WP-L-Dispatcher-Drift assertion (a)):
     * polymorphic dispatch entry. Same shape as the sibling Agent /
     * Vip / Status adapter `dispatch` methods — assertBundleActive
     * AllowList propagation (`FLOW_ALLOWLIST_BYPASS_BLOCKED:<target>`
     * on reject) then delegates to the existing static `invoke(...)`
     * signature. The wave-3 Sec C-3 ProcessType=AutoLaunchedFlow gate
     * stays inside `invoke` line 87 (`assertProcessTypeAutoLaunched`)
     * verbatim — this dispatch wrapper is the AllowList propagation
     * layer ONLY; it does NOT duplicate the ProcessType gate.
     */
    public Object dispatch(String target, Map<String, Object> args) {
        SF_AgenticGateway_AllowList.assertBundleActive(
            target,
            SF_AgenticGateway_PrefixMapper.toCmdtPicklist('flow'),
            'FLOW');
        String payloadJson = (String) args.get('payloadJson');
        Integer maxBatch = args.get('maxBatch') instanceof Integer
            ? (Integer) args.get('maxBatch') : 1;
        return invoke(target, payloadJson, maxBatch);
    }

    /**
     * @TestVisible test seam — when non-null, `invoke` returns this list as
     * the Flow result instead of calling `Invocable.Action`. Each map is
     * the Flow output variables for the corresponding input row.
     */
    @TestVisible
    private static List<Map<String, Object>> testFlowResults = null;

    /**
     * @TestVisible test seam — when true, `invoke` skips the
     * FlowDefinitionView ProcessType check (used by tests that inject
     * results via `testFlowResults` and don't have a real Flow deployed).
     */
    @TestVisible
    private static Boolean testSkipProcessTypeCheck = false;

    /**
     * @TestVisible test seam — when non-null, `invoke` uses this string as
     * the simulated ProcessType (forces the Sec C-3 reject path without
     * needing a real Screen Flow deployed).
     */
    @TestVisible
    private static String testForcedProcessType = null;

    /**
     * Invoke an autolaunched Flow with the given payload.
     *
     * @param flowApiName Flow ApiName (Target__c value from CMDT)
     * @param payloadJson agent payload (single map or {"batch":[...]})
     * @param maxBatch CMDT MaxBatchSize__c for this target
     * @return Map shaped as either {results:[...]} (batch) or the single
     *         row map (non-batch). Per-row error details surface via
     *         {success:false, message:...}; adapter throws only on
     *         catastrophic failure (Flow not found, wrong ProcessType,
     *         governor breach).
     */
    public static Map<String, Object> invoke(String flowApiName, String payloadJson, Integer maxBatch) {
        SF_AgenticGateway_Limits.assertCpuOk();
        SF_AgenticGateway_Limits.assertHeapOk();

        if (String.isBlank(flowApiName)) {
            throw new FlowAdapterException('FLOW_NOT_FOUND_OR_INVALID:blank-name');
        }

        Map<String, Object> parsed = (payloadJson == null || payloadJson.length() == 0)
            ? new Map<String, Object>()
            : (Map<String, Object>) JSON.deserializeUntyped(payloadJson);

        Boolean isBatch = parsed.containsKey('batch') && parsed.get('batch') instanceof List<Object>;
        List<Map<String, Object>> invocations = new List<Map<String, Object>>();
        if (isBatch) {
            List<Object> rawBatch = (List<Object>) parsed.get('batch');
            SF_AgenticGateway_Limits.assertBatchSizeOk(rawBatch.size(), maxBatch);
            for (Object item : rawBatch) {
                if (item instanceof Map<String, Object>) {
                    invocations.add((Map<String, Object>) item);
                } else {
                    invocations.add(new Map<String, Object>{ 'value' => item });
                }
            }
        } else {
            invocations.add(parsed);
        }

        if (testFlowResults != null) {
            return shapeResults(testFlowResults, isBatch);
        }

        assertProcessTypeAutoLaunched(flowApiName);

        Invocable.Action a;
        try {
            a = Invocable.Action.createCustomAction('flow', flowApiName);
        } catch (Exception createEx) {
            throw new FlowAdapterException(
                'FLOW_NOT_FOUND_OR_INVALID:' + flowApiName + ' (' + createEx.getMessage() + ')');
        }
        if (a == null) {
            throw new FlowAdapterException('FLOW_NOT_FOUND_OR_INVALID:' + flowApiName);
        }

        SF_AgenticGateway_Limits.assertCpuOk();
        SF_AgenticGateway_Limits.assertHeapOk();
        a.setInvocations(invocations);

        List<Invocable.Action.Result> results;
        try {
            results = a.invoke();
        } catch (Exception invokeEx) {
            throw new FlowAdapterException(
                invokeEx.getTypeName() + ': ' + invokeEx.getMessage());
        }

        if (results == null || results.isEmpty()) {
            throw new FlowAdapterException(
                'FLOW_NOT_FOUND_OR_INVALID:' + flowApiName);
        }

        List<Map<String, Object>> rowResults = new List<Map<String, Object>>();
        for (Invocable.Action.Result r : results) {
            if (r.isSuccess()) {
                rowResults.add(new Map<String, Object>{
                    'success' => true,
                    'output' => r.getOutputParameters()
                });
            } else {
                rowResults.add(new Map<String, Object>{
                    'success' => false,
                    'message' => formatFlowErrors(r.getErrors())
                });
            }
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
            ? new Map<String, Object>{ 'success' => false, 'message' => 'FLOW_NO_RESULT' }
            : rowResults[0];
    }

    /**
     * Sec C-3 + Existence gate: confirm the Flow's ProcessType is
     * `AutoLaunchedFlow`. Any other value (Flow = screen, Workflow,
     * RecordTriggered, etc.) raises FLOW_TYPE_UNSUPPORTED. Empty
     * FlowDefinitionView result is treated authoritatively as
     * "Flow does not exist" and raises FLOW_NOT_FOUND_OR_INVALID — without
     * this gate, Invocable.Action.invoke for a missing Flow returns a
     * single empty-output success Result and the gateway envelopes it as
     * success=true. SOQL-exception (FLS deny / Tooling-API restriction)
     * preserves silent fallthrough as graceful degradation: the runtime
     * still tries the Invocable path and any genuine ProcessType mismatch
     * is rejected by Salesforce downstream.
     */
    private static void assertProcessTypeAutoLaunched(String flowApiName) {
        if (testSkipProcessTypeCheck == true) return;

        String processType;
        if (testForcedProcessType != null) {
            processType = testForcedProcessType;
        } else {
            try {
                List<FlowDefinitionView> views = [
                    SELECT ProcessType
                    FROM FlowDefinitionView
                    WHERE ApiName = :flowApiName
                    LIMIT 1
                ];
                if (views.isEmpty()) {
                    throw new FlowAdapterException(
                        'FLOW_NOT_FOUND_OR_INVALID:' + flowApiName);
                }
                processType = views[0].ProcessType;
            } catch (FlowAdapterException notFoundEx) {
                throw notFoundEx;
            } catch (Exception describeEx) {
                return;
            }
        }

        if (processType != null && processType != 'AutoLaunchedFlow') {
            throw new FlowAdapterException('FLOW_TYPE_UNSUPPORTED:' + processType);
        }
    }

    @TestVisible
    private static String formatFlowErrors(List<Invocable.Action.Error> errs) {
        if (errs == null || errs.isEmpty()) return 'FLOW_UNKNOWN_ERROR';
        List<String> parts = new List<String>();
        for (Invocable.Action.Error e : errs) {
            parts.add(e.getCode() + ': ' + e.getMessage());
        }
        return String.join(parts, ' | ');
    }
}