/**
 * SfAgwSmokeCallback — async-completion callback smoke fixture for
 * SF_AgenticGateway production-readiness validation (scope sf-agentic-gateway-
 * smoke-template-2026-05-29 WP-1, joint SA+TA technical-design §1.3).
 *
 * Contract: ISF_AgenticAsyncCallback.
 *
 * Drives AC-12 (PayloadOptIn async) + AC-17 (callback fired post-Completed).
 * CMDT row `SfAgwSmokeEchoApexOptIn.AsyncCallbackHandler__c` resolves to this
 * class at WorkerCore.invokeCallbackIfConfigured.
 *
 * Sec conditions baked in:
 *   - C-2: `public with sharing` — sharing enforcement honored.
 *
 * Hard rules (Senior Dev hat — final safekeeper):
 *   - ISF_AgenticAsyncCallback docblock hard rule: "The callback MUST NOT
 *     mutate the audit row. WorkerCore re-loads / re-writes the audit row
 *     outside the callback. The audit parameter is supplied as a forensic
 *     anchor only." → audit-row mutation is OMITTED (see Sec hand-off blocker
 *     B-2 for SA+TA reconciliation re: the technical-design §1.3 / WP-1 brief
 *     that called for a `message__c` update). The `message__c` field is also
 *     LEGACY per its own field description ("Sec control C-5 mandates new
 *     writes leave this field null and populate MessageHash__c instead") —
 *     writing to it would undo prior-scope hardening.
 *   - Callback MUST NOT re-enter SF_AgenticGateway.invoke or dispatchSync;
 *     enforced upstream by SF_AgenticGateway_Limits.assertNotInCallbackScope.
 *     Smoke fixture only logs; no re-entry attempted.
 *   - Test seam `testCallLog` exposes per-callback breadcrumb
 *     `<jobId>:<asyncStatus>` for SfAgwSmokeCallbackTest assertions, mirroring
 *     the FinDiag direct-handle BDD pattern (no EventBus.deliver dependency).
 *   - Null-audit branch returns silently (no NPE, no log entry) — defensive
 *     against WorkerCore corner case where audit pointer is unset (would
 *     classify as ASYNC_CALLBACK_FAILED anyway, but smoke handler refuses to
 *     amplify into NPE).
 */
public with sharing class SfAgwSmokeCallback implements ISF_AgenticAsyncCallback {

    /**
     * Test seam — `<jobId>:<asyncStatus>` per callback invocation. Reset by
     * tests via the resetTestCallLog() helper to keep cross-test isolation
     * (Apex statics persist within a single test transaction).
     */
    @TestVisible
    private static List<String> testCallLog = new List<String>();

    public void handleCompletion(SF_AgenticInvocation__c audit, Map<String, Object> result) {
        if (audit == null) {
            return;
        }
        testCallLog.add(
            String.valueOf(audit.JobId__c) + ':' + String.valueOf(audit.AsyncStatus__c)
        );
    }

    /**
     * Test seam — clear `testCallLog` between scenarios in the same test
     * transaction. Marked @TestVisible because the static field itself is
     * private; tests need a controlled reset hook.
     */
    @TestVisible
    private static void resetTestCallLog() {
        testCallLog = new List<String>();
    }
}