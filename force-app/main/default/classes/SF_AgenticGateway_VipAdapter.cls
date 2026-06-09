/**
 * SF_AgenticGateway_VipAdapter — trampoline IP + DR dispatches through the
 * org-resident `Solar_GenericVIPCallout` (read-only dependency, byte-for-
 * byte unchanged on disk and in org).
 *
 * Method-name + input-key contract LOCKED from
 * docs/sf-agentic-gateway-multidispatch-2026-05-08-vip-audit.md (WP-0):
 *
 *   IP  → Solar_GenericVIPCallout instance.invokeMethod(
 *           'invokeIntegrationProcedure',
 *           {vipName, ipInput, ipOptions},
 *           output, options) → output['data'] or output['error']
 *   DR  → Solar_GenericVIPCallout instance.invokeMethod(
 *           'invokeDataRaptorLoad',
 *           {drName, drInput, isBulk},
 *           output, options) → output['data'] or output['error']
 *
 * Sec C-2: this adapter NEVER reflects into private members of
 * Solar_GenericVIPCallout. Only the published `invokeMethod` Action
 * Framework entry point is used.
 *
 * Sec G-Sec-5: target name flows verbatim from CMDT lookup; no string
 * concat with agent-supplied content.
 */
public with sharing class SF_AgenticGateway_VipAdapter implements IAgenticAdapter {

    public class VipAdapterException extends Exception {}

    /**
     * WP-L-Dispatcher-Drift Phase 1 (audit findings L-5 + L-6 +
     * Sec card § Card · WP-L-Dispatcher-Drift assertion (a)):
     * polymorphic dispatch entry. Unique among the 6 adapters in
     * that it carries TWO sync entry points (`invokeIp` +
     * `invokeDr`); `dispatch` reads `args.get('prefix')` to
     * disambiguate between them — `'ip'` routes to `invokeIp`,
     * `'dr'` routes to `invokeDr`. The dispatchType picklist token
     * passed to `assertBundleActive` matches the resolved prefix
     * (`IP` or `DR`) so the per-prefix CMDT row gating stays
     * 1:1-mapped (a CMDT row with `DispatchType__c=IP` cannot
     * authorise a `dr:` dispatch and vice-versa). Adapter code
     * prefix in the error message is `IP` or `DR` for forensic
     * distinguishability per the wave-3 deterministic error-code
     * pattern density.
     *
     * The wave-3 Sec G-Sec-5 contract (target name flows verbatim
     * from CMDT lookup; never reflected) is preserved inside the
     * static `invokeIp` / `invokeDr` / `invokeInternal` methods —
     * this dispatch wrapper is the AllowList propagation layer ONLY.
     */
    public Object dispatch(String target, Map<String, Object> args) {
        String prefix = (String) args.get('prefix');
        String dispatchType =
            SF_AgenticGateway_PrefixMapper.toCmdtPicklist(prefix);
        String adapterCode =
            'dr'.equalsIgnoreCase(prefix) ? 'DR' : 'IP';
        SF_AgenticGateway_AllowList.assertBundleActive(
            target, dispatchType, adapterCode);
        String payloadJson = (String) args.get('payloadJson');
        Integer maxBatch = args.get('maxBatch') instanceof Integer
            ? (Integer) args.get('maxBatch') : 1;
        if ('dr'.equalsIgnoreCase(prefix)) {
            return invokeDr(target, payloadJson, maxBatch);
        }
        return invokeIp(target, payloadJson, maxBatch);
    }

    private static final String IP_DISPATCH = 'invokeIntegrationProcedure';
    private static final String DR_DISPATCH = 'invokeDataRaptorLoad';

    private static final String KEY_VIP_NAME = 'vipName';
    private static final String KEY_IP_INPUT = 'ipInput';
    private static final String KEY_IP_OPTIONS = 'ipOptions';

    private static final String KEY_DR_NAME = 'drName';
    private static final String KEY_DR_INPUT = 'drInput';
    private static final String KEY_DR_ISBULK = 'isBulk';
    private static final String KEY_DR_RESERIALIZE = 'reserialize';

    private static final String OUT_DATA = 'data';
    private static final String OUT_ERROR = 'error';

    private static final String OPT_KEY_OPTIONS = 'options';

    /**
     * @TestVisible test seam — when non-null, `invokeIp` / `invokeDr` skip
     * the Solar_GenericVIPCallout call entirely and return this map per
     * row. Test classes set this in `@isTest` methods to avoid org-side
     * dependency on a live Vlocity IP/DR.
     */
    @TestVisible
    private static Map<String, Object> testVipResult = null;

    /** @TestVisible test seam — when non-null, simulates an `error` row from VIP. */
    @TestVisible
    private static String testVipError = null;

    public static Map<String, Object> invokeIp(String vipName, String payloadJson, Integer maxBatch) {
        return invokeInternal(IP_DISPATCH, vipName, payloadJson, maxBatch, true);
    }

    public static Map<String, Object> invokeDr(String drName, String payloadJson, Integer maxBatch) {
        return invokeInternal(DR_DISPATCH, drName, payloadJson, maxBatch, false);
    }

    private static Map<String, Object> invokeInternal(
        String methodName,
        String target,
        String payloadJson,
        Integer maxBatch,
        Boolean isIp
    ) {
        SF_AgenticGateway_Limits.assertPayloadSizeOk(payloadJson);
        SF_AgenticGateway_Limits.assertCalloutOk();
        SF_AgenticGateway_Limits.assertCpuOk();
        SF_AgenticGateway_Limits.assertHeapOk();

        if (String.isBlank(target)) {
            throw new VipAdapterException('VIP_TARGET_BLANK');
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
                    items.add(new Map<String, Object>{ 'value' => item });
                }
            }
        } else {
            items.add(parsed);
        }

        List<Map<String, Object>> rowResults = new List<Map<String, Object>>();
        for (Map<String, Object> item : items) {
            SF_AgenticGateway_Limits.assertCalloutOk();
            SF_AgenticGateway_Limits.assertCpuOk();
            SF_AgenticGateway_Limits.assertHeapOk();

            Map<String, Object> inputs = isIp
                ? buildIpInputs(target, item)
                : buildDrInputs(target, item);

            Map<String, Object> options = (item.get(OPT_KEY_OPTIONS) instanceof Map<String, Object>)
                ? (Map<String, Object>) item.get(OPT_KEY_OPTIONS)
                : new Map<String, Object>();

            Map<String, Object> output = new Map<String, Object>();

            if (testVipResult != null || testVipError != null) {
                if (testVipError != null) {
                    output.put(OUT_ERROR, testVipError);
                } else {
                    output.put(OUT_DATA, testVipResult);
                }
            } else {
                try {
                    Solar_GenericVIPCallout dispatcher = new Solar_GenericVIPCallout();
                    dispatcher.invokeMethod(methodName, inputs, output, options);
                } catch (Exception solarEx) {
                    output.put(OUT_ERROR, solarEx.getTypeName() + ': ' + solarEx.getMessage());
                }
            }

            Object errVal = output.get(OUT_ERROR);
            String errStr = (errVal == null) ? null : String.valueOf(errVal);
            if (String.isNotBlank(errStr)) {
                rowResults.add(new Map<String, Object>{
                    'success' => false,
                    'message' => errStr
                });
            } else {
                rowResults.add(new Map<String, Object>{
                    'success' => true,
                    'output' => output.get(OUT_DATA)
                });
            }
        }

        if (isBatch) {
            return new Map<String, Object>{ 'results' => rowResults };
        }
        return rowResults.isEmpty()
            ? new Map<String, Object>{ 'success' => false, 'message' => 'VIP_NO_RESULT' }
            : rowResults[0];
    }

    private static Map<String, Object> buildIpInputs(String vipName, Map<String, Object> item) {
        Map<String, Object> ipOptions = (item.get(OPT_KEY_OPTIONS) instanceof Map<String, Object>)
            ? (Map<String, Object>) item.get(OPT_KEY_OPTIONS)
            : new Map<String, Object>();

        Map<String, Object> ipInput = new Map<String, Object>();
        for (String key : item.keySet()) {
            if (key != OPT_KEY_OPTIONS) {
                ipInput.put(key, item.get(key));
            }
        }

        return new Map<String, Object>{
            KEY_VIP_NAME => vipName,
            KEY_IP_INPUT => ipInput,
            KEY_IP_OPTIONS => ipOptions
        };
    }

    private static Map<String, Object> buildDrInputs(String drName, Map<String, Object> item) {
        Object drInput = item.containsKey('input') ? item.get('input') : item;
        Object isBulkRaw = item.get(KEY_DR_ISBULK);
        Boolean isBulk = (isBulkRaw instanceof Boolean) ? (Boolean) isBulkRaw : false;
        Object reserializeRaw = item.get(KEY_DR_RESERIALIZE);
        Boolean reserialize = (reserializeRaw instanceof Boolean) ? (Boolean) reserializeRaw : false;

        return new Map<String, Object>{
            KEY_DR_NAME => drName,
            KEY_DR_INPUT => drInput,
            KEY_DR_ISBULK => isBulk,
            KEY_DR_RESERIALIZE => reserialize
        };
    }
}