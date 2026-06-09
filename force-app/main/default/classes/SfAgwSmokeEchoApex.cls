/**
 * SfAgwSmokeEchoApex — apex: smoke fixture for SF_AgenticGateway production-
 * readiness validation (scope sf-agentic-gateway-smoke-template-2026-05-29
 * WP-1, joint SA+TA technical-design §1.1).
 *
 * Contract: ISF_AgenticHandler.
 *
 * Payload schema (all keys optional; smoke probes drive each branch):
 *   {
 *     "echo":        "<String — echoed back verbatim>",
 *     "forceError":  true,   // AC-18 — throw deterministic SfAgwSmokeException
 *     "bigPayload":  true    // AC-16 — return ~60KB filler to drive truncate/spill
 *   }
 *
 * Response shape:
 *   { echo: ?, now: <epoch ms>, random: <long>, filler?: <~60KB string> }
 *
 * Sec conditions baked in (docs/sf-agentic-gateway-smoke-template-2026-05-29-sec-threat-model.md §4):
 *   - C-1: forceError throw message is a constant final String — NO interpolation
 *     of any user-supplied payload value. Same posture for the invalid-JSON
 *     branch (constant message, defense-in-depth against payload echo leakage).
 *   - C-2: `public with sharing` — record visibility is granted via permset
 *     SfAgw_Smoke_Test only; no bypass via this handler.
 *
 * Hard rules (Senior Dev hat):
 *   - Zero hardcoded Ids/rules: BIG_PAYLOAD_TARGET_BYTES + message constants
 *     are smoke-fixture sizing knobs, not business thresholds.
 *   - Governor-safe: pure compute, no SOQL, no DML, no callouts.
 *   - buildBigFiller uses String.join over a pre-sized list (O(n) alloc) instead
 *     of the quadratic `out += unit` pattern from the design sketch.
 *   - Inner exception SfAgwSmokeException — clearly attributable in audit row
 *     message field as `SfAgwSmokeException:<constant>`.
 */
public with sharing class SfAgwSmokeEchoApex implements ISF_AgenticHandler {

    /**
     * Sec C-1: forceError throw message MUST be a constant String. No payload
     * value is interpolated into the exception message. Asserted verbatim by
     * SfAgwSmokeEchoApexTest.testGivenForceErrorPayloadWhenHandleThenMessageIsConstant.
     */
    @TestVisible
    private static final String FORCE_ERROR_MESSAGE = 'AC-18: smoke forced error';

    /**
     * Defense-in-depth: invalid-JSON branch also throws a constant message;
     * `ex.getMessage()` from System.JSONException can include character-position
     * snippets that may echo user payload bytes (LINDDUN § L.1 linkability).
     */
    @TestVisible
    private static final String INVALID_JSON_MESSAGE = 'AC-1: smoke invalid JSON payload';

    /**
     * AC-16 (truncate/spill probe) — gateway truncateOrSpill kicks in around
     * the 32KB envelope ceiling; 60KB filler reliably forces the branch
     * across both `data`/`summary` and Platform Cache spill paths.
     */
    @TestVisible
    private static final Integer BIG_PAYLOAD_TARGET_BYTES = 60000;

    @TestVisible
    private static final String FILLER_UNIT = '0123456789ABCDEF';

    public class SfAgwSmokeException extends Exception {}

    public Object handle(String payloadJson) {
        Map<String, Object> payload = safeDeserialize(payloadJson);
        if (extractBooleanFlag(payload, 'forceError')) {
            throw new SfAgwSmokeException(FORCE_ERROR_MESSAGE);
        }
        Boolean big = extractBooleanFlag(payload, 'bigPayload');
        Map<String, Object> result = new Map<String, Object>{
            'echo'   => payload.get('echo'),
            'now'    => Datetime.now().getTime(),
            'random' => Crypto.getRandomLong()
        };
        if (big) {
            result.put('filler', buildBigFiller());
        }
        return result;
    }

    @TestVisible
    private static Boolean extractBooleanFlag(Map<String, Object> payload, String key) {
        if (payload == null) return false;
        Object raw = payload.get(key);
        return (raw instanceof Boolean) ? (Boolean) raw : false;
    }

    @TestVisible
    private static Map<String, Object> safeDeserialize(String payloadJson) {
        if (String.isBlank(payloadJson)) {
            return new Map<String, Object>();
        }
        try {
            Object parsed = JSON.deserializeUntyped(payloadJson);
            if (parsed instanceof Map<String, Object>) {
                return (Map<String, Object>) parsed;
            }
            throw new SfAgwSmokeException(INVALID_JSON_MESSAGE);
        } catch (System.JSONException ignore) {
            throw new SfAgwSmokeException(INVALID_JSON_MESSAGE);
        }
    }

    @TestVisible
    private static String buildBigFiller() {
        Integer copies = (BIG_PAYLOAD_TARGET_BYTES / FILLER_UNIT.length()) + 1;
        List<String> parts = new List<String>();
        for (Integer i = 0; i < copies; i++) {
            parts.add(FILLER_UNIT);
        }
        return String.join(parts, '');
    }
}