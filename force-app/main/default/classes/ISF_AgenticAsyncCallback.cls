/**
 * ISF_AgenticAsyncCallback — wave-3 FU-AGW-ASYNC-2 (G-Sec-ASYNC-14).
 *
 * Reflective callback contract invoked by SF_AgenticGateway_WorkerCore at
 * the Completed terminal transition, when the bundle CMDT row carries a
 * non-blank AsyncCallbackHandler__c. WorkerCore resolves the class via
 * Type.forName, asserts instanceof this interface, then invokes
 * handleCompletion within an enterCallbackScope / exitCallbackScope
 * try/finally.
 *
 * HARD RULES (enforced by SF_AgenticGateway_Limits + dispatchSync):
 *   - The callback MUST NOT re-enter SF_AgenticGateway.invoke or
 *     SF_AgenticGateway.dispatchSync. Limits.assertNotInCallbackScope()
 *     fires at the top of dispatchSync, and assertCallbackDispatchCountOk
 *     caps the per-Tx counter at 0. Reentry surfaces
 *     LimitExceededException("CALLBACK_REENTRY_BLOCKED"), which is
 *     re-classified by WorkerCore as ASYNC_CALLBACK_FAILED:&lt;TypeName&gt;
 *     and flips the audit row to Failed.
 *   - The callback MUST NOT mutate the audit row. WorkerCore re-loads /
 *     re-writes the audit row outside the callback. The audit parameter
 *     is supplied as a forensic anchor only.
 *   - The callback MUST be CMDT-registered (SF_AgenticGateway_Allow__mdt
 *     .AsyncCallbackHandler__c) — Type.forName + interface check happens
 *     at submit time (AsyncDispatcher.validateCallbackHandler) and again
 *     at invoke time (WorkerCore.invokeCallbackIfConfigured).
 *
 * Exceptions thrown by handleCompletion are caught by WorkerCore and
 * flip the audit to AsyncStatus__c='Failed' with message
 * 'ASYNC_CALLBACK_FAILED:&lt;TypeName&gt;:&lt;truncated 256 char msg&gt;'.
 */
public interface ISF_AgenticAsyncCallback {

    /**
     * Invoked once after the worker writes the Completed audit row + PE.
     *
     * @param audit  the audit row just written by WorkerCore. Read-only
     *               by contract; callback MUST NOT mutate.
     * @param result the wrapped envelope produced by truncateOrSpill
     *               (keys: data / summary / dataRef / truncated). When
     *               the result was spilled to Platform Cache, `data` is
     *               null and `dataRef` carries the cache key the
     *               callback may pull via Cache.Org.getPartition.
     */
    void handleCompletion(SF_AgenticInvocation__c audit, Map<String, Object> result);
}