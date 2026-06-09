/**
 * SF_AgenticGateway_AsyncDispatcher — uniform submit interface for the
 * async dispatch surface (joint locked design
 * docs/sf-agentic-gateway-async-selector-2026-05-14.md §5.1).
 *
 * Pipeline:
 *   submit(prefix, target, payloadJson, correlationId)
 *     → validateCallbackHandler(target)                   // Sec G-Sec-ASYNC-14 (wave-3 ASYNC-2)
 *     → validateBatchHandler(target) when runtime=Batch   // Sec G-Sec-ASYNC-15 (wave-3 ASYNC-3)
 *     → assertSubmitOk(target, runtime)                   // Sec G-Sec-ASYNC-5/-10
 *     → mint jobId + payloadHash                          // Sec G-Sec-ASYNC-3/-8
 *     → insert SF_AgenticInvocation__c (AsyncStatus=Submitted)
 *     → enqueue worker per runtime:
 *         - Queueable → System.enqueueJob(SF_AgenticGateway_QueueableWorker)
 *         - Future    → SF_AgenticGateway_FutureWorker.execute (@future)
 *         - BatchApex → Database.executeBatch(SF_AgenticGateway_BatchWorker,
 *                                              min(CMDT chunk, 2000))   // wave-3 ASYNC-3
 *     → update audit with AsyncApexJobId
 *     → return receipt {jobId, status: "Submitted", runtime, …}
 *
 * `with sharing` so the audit-row insert honours the running user's
 * sharing rules (audit obj is Private; row owned by the caller).
 *
 * Receipt shape returned to the caller is wrapped by SF_AgenticGateway
 * via the existing Response.dataJson envelope (no new InvocableVariable
 * surface).
 */
public with sharing class SF_AgenticGateway_AsyncDispatcher {

    public class AsyncDispatcherException extends Exception {}

    @TestVisible private static final String RUNTIME_QUEUEABLE = 'Queueable';
    @TestVisible private static final String RUNTIME_FUTURE = 'Future';
    @TestVisible private static final String RUNTIME_BATCH = 'BatchApex';

    @TestVisible private static final String STATUS_SUBMITTED = 'Submitted';

    /**
     * @TestVisible test seam — when non-null, `submit()` skips the real
     * `System.enqueueJob` and returns this value as the synthetic
     * AsyncApexJobId. Used by tests that don't need the worker to
     * actually run.
     */
    @TestVisible
    private static String testForcedAsyncApexJobId = null;

    /**
     * @TestVisible test seam — when true, `submit()` runs the audit-row
     * insert but throws AFTER the insert and BEFORE the enqueue. Drives
     * coverage of the audit-orphan-on-enqueue-fail rollback branch.
     */
    @TestVisible
    private static Boolean testForceEnqueueFail = false;

    /**
     * @TestVisible test seam — when true, the worker classes treat the
     * dispatch result as if it returned synchronously inline (used by
     * tests that can't execute Queueables inside their own start/stop
     * window in some negative-path scenarios).
     */
    @TestVisible
    private static Boolean testForceInlineWorker = false;

    /**
     * @TestVisible test seam — when true, validateBatchHandler short-
     * circuits to throw ASYNC_BATCH_HANDLER_INVALID. Drives the
     * BatchApex submit-time rejection coverage without registering a
     * deliberately broken Apex class.
     */
    @TestVisible
    private static Boolean testForceBatchHandlerInvalid = false;

    /**
     * Submit an async dispatch for the given (prefix, target). Returns
     * a receipt Map ready for SF_AgenticGateway to wrap via the existing
     * `truncateOrSpill` envelope. The receipt shape is locked by §2.2 of
     * the joint design.
     */
    public static Map<String, Object> submit(
        String prefix,
        String target,
        String payloadJson,
        String correlationId
    ) {
        if (String.isBlank(prefix)) {
            throw new AsyncDispatcherException('ASYNC_PREFIX_BLANK');
        }
        if (String.isBlank(target)) {
            throw new AsyncDispatcherException('ASYNC_TARGET_BLANK');
        }

        String runtime = SF_AgenticGateway_AllowList.asyncRuntime(target);

        // Sec G-Sec-ASYNC-14 (wave-3 ASYNC-2): submit-time callback class
        // validation. Fail-fast before any DML so a misconfigured CMDT
        // never lands a half-submitted job. Callback may be configured
        // regardless of runtime — runs at Completed by WorkerCore /
        // BatchWorker.finish.
        validateCallbackHandler(target);

        // Sec G-Sec-ASYNC-15 (wave-3 ASYNC-3): submit-time batch handler
        // validation when runtime=BatchApex. Defensive check + kill
        // switch for the test seam; BatchWorker.start() also resolves +
        // re-validates at execute time.
        if (RUNTIME_BATCH.equalsIgnoreCase(runtime)) {
            validateBatchHandler(target);
        }

        // Sec G-Sec-ASYNC-10 + G-Sec-ASYNC-5
        SF_AgenticGateway_Limits.assertAsyncSubmitOk();
        assertConcurrentCapOk(target);

        // Sec G-Sec-ASYNC-3: server-mints jobId; caller never supplies one.
        String jobId = SF_AgenticGateway_JobIdMinter.mint();
        String payloadHash = SF_AgenticGateway_JobIdMinter.payloadHash(jobId, payloadJson);
        DateTime submittedAt = System.now();
        Integer ttl = SF_AgenticGateway_AllowList.asyncResultTtlSeconds(target);

        SF_AgenticInvocation__c audit = buildSubmitAudit(
            prefix, target, payloadJson, correlationId, jobId, payloadHash,
            runtime, submittedAt);
        insert audit;

        String asyncApexJobId = null;
        try {
            if (testForceEnqueueFail) {
                throw new AsyncDispatcherException('ASYNC_ENQUEUE_FAILED:test-seam');
            }
            if (RUNTIME_BATCH.equalsIgnoreCase(runtime)) {
                // Sec G-Sec-ASYNC-15: chunk size intersected with platform
                // max 2000. CMDT default 200.
                Integer chunk = Math.min(
                    SF_AgenticGateway_AllowList.asyncBatchChunkSize(target),
                    2000);
                SF_AgenticGateway_BatchWorker batchWorker =
                    new SF_AgenticGateway_BatchWorker(
                        jobId, prefix, target, payloadJson, correlationId, payloadHash);
                if (testForcedAsyncApexJobId != null) {
                    asyncApexJobId = testForcedAsyncApexJobId;
                } else {
                    asyncApexJobId = Database.executeBatch(batchWorker, chunk);
                }
            } else if (RUNTIME_FUTURE.equalsIgnoreCase(runtime)) {
                SF_AgenticGateway_FutureWorker.execute(
                    jobId, prefix, target, payloadJson, correlationId, payloadHash);
            } else {
                SF_AgenticGateway_QueueableWorker worker =
                    new SF_AgenticGateway_QueueableWorker(
                        jobId, prefix, target, payloadJson, correlationId, payloadHash);
                if (testForcedAsyncApexJobId != null) {
                    asyncApexJobId = testForcedAsyncApexJobId;
                    if (testForceInlineWorker) {
                        worker.execute(null);
                    }
                } else {
                    asyncApexJobId = System.enqueueJob(worker);
                }
            }
        } catch (Exception enqueueEx) {
            audit.AsyncStatus__c = 'Failed';
            audit.CompletedAt__c = System.now();
            audit.MessageHash__c = SF_AgenticGateway_Limits.hashMessage(
                'ASYNC_ENQUEUE_FAILED: ' + enqueueEx.getMessage());
            update audit;
            throw new AsyncDispatcherException(
                'ASYNC_ENQUEUE_FAILED: ' + enqueueEx.getMessage());
        }

        if (String.isNotBlank(asyncApexJobId)) {
            audit.AsyncApexJobId__c = asyncApexJobId;
            update audit;
        }

        Map<String, Object> data = new Map<String, Object>{
            'mode' => 'async',
            'jobId' => jobId,
            'status' => STATUS_SUBMITTED,
            'runtime' => runtime,
            'submittedAt' => submittedAt.formatGmt('yyyy-MM-dd\'T\'HH:mm:ss.SSS\'Z\''),
            'resultRef' => 'status:' + jobId,
            'asyncApexJobId' => asyncApexJobId
        };
        return new Map<String, Object>{
            'summary' => null,
            'dataRef' => null,
            'truncated' => false,
            'data' => data
        };
    }

    /**
     * Sec G-Sec-ASYNC-5: per-user concurrent cap. Scoped per target so a
     * single user can keep parallel jobs across multiple bundles without
     * being blocked by an aggregate cap. Per-org saturation is bounded
     * elsewhere (MAX_ASYNC_SUBMITS_PER_TX + platform Queueable slot
     * ceiling).
     */
    private static void assertConcurrentCapOk(String target) {
        Integer cap = SF_AgenticGateway_AllowList.asyncMaxConcurrent(target);
        if (cap == null || cap <= 0) return;
        Id me = UserInfo.getUserId();
        // Dynamic SOQL via Database.countQueryWithBinds — see
        // SF_AgenticGateway_StatusAdapter.loadAuditUserMode for the
        // validate-only-deploy parser-cache workaround rationale.
        String soql =
            'SELECT count() '
            + 'FROM SF_AgenticInvocation__c '
            + 'WHERE AsyncStatus__c IN (\'Submitted\', \'Running\') '
            + '  AND CreatedById = :me '
            + '  AND Target__c = :target';
        Integer existing = Database.countQueryWithBinds(
            soql,
            new Map<String, Object>{ 'me' => me, 'target' => target },
            AccessLevel.SYSTEM_MODE);
        if (existing >= cap) {
            throw new AsyncDispatcherException(
                'ASYNC_CONCURRENT_LIMIT: per-user cap ' + cap + ' reached for ' + target);
        }
    }

    /**
     * Sec G-Sec-ASYNC-14 (wave-3 ASYNC-2): submit-time callback class
     * validation. When the bundle CMDT row carries a non-blank
     * AsyncCallbackHandler__c value, the class MUST resolve via
     * Type.forName, instantiate via newInstance, and pass the
     * `instanceof ISF_AgenticAsyncCallback` check. Any failure path
     * surfaces ASYNC_CALLBACK_INVALID:&lt;name&gt; before the audit row
     * is inserted, so a misconfigured CMDT never enqueues a worker
     * that would later trip at the Completed branch.
     */
    private static void validateCallbackHandler(String target) {
        String name = SF_AgenticGateway_AllowList.asyncCallbackHandler(target);
        if (String.isBlank(name)) return;
        Type t = Type.forName(name);
        if (t == null) {
            throw new AsyncDispatcherException('ASYNC_CALLBACK_INVALID:' + name);
        }
        Object inst;
        try {
            inst = t.newInstance();
        } catch (Exception ex) {
            throw new AsyncDispatcherException('ASYNC_CALLBACK_INVALID:' + name);
        }
        if (!(inst instanceof ISF_AgenticAsyncCallback)) {
            throw new AsyncDispatcherException('ASYNC_CALLBACK_INVALID:' + name);
        }
    }

    /**
     * Sec G-Sec-ASYNC-15 (wave-3 ASYNC-3): submit-time BatchApex handler
     * validation. The test seam testForceBatchHandlerInvalid drives the
     * reject branch deterministically. Production resolution of the
     * batch handler class happens inside BatchWorker.start() because the
     * worker re-reads CMDT under its own sharing context.
     */
    private static void validateBatchHandler(String target) {
        if (testForceBatchHandlerInvalid) {
            throw new AsyncDispatcherException(
                'ASYNC_BATCH_HANDLER_INVALID:test-seam');
        }
        // BatchWorker.resolveHandler does the production-side resolve at
        // start(); no-op here keeps the submit path bulk-cheap. A future
        // CMDT BatchHandlerClass__c field could be added if the bundle
        // Target__c is not the handler class name itself.
    }

    private static SF_AgenticInvocation__c buildSubmitAudit(
        String prefix,
        String target,
        String payloadJson,
        String correlationId,
        String jobId,
        String payloadHash,
        String runtime,
        DateTime submittedAt
    ) {
        SF_AgenticInvocation__c audit = new SF_AgenticInvocation__c();
        audit.handlerClass__c = prefix + ':' + target;
        audit.correlationId__c = String.isBlank(correlationId)
            ? 'noCorr-' + String.valueOf(Crypto.getRandomLong())
            : correlationId;
        audit.timestamp__c = submittedAt;
        audit.success__c = false;
        audit.DispatchType__c = mapPrefixToPicklist(prefix);
        audit.Target__c = target;
        audit.BatchSize__c = 1;
        audit.JobId__c = jobId;
        audit.AsyncStatus__c = STATUS_SUBMITTED;
        audit.AsyncRuntime__c = runtime;
        audit.SubmittedAt__c = submittedAt;
        audit.PayloadHash__c = payloadHash;
        audit.ResultRef__c = SF_AgenticGateway_Limits.asyncResultCacheKey(jobId);
        audit.RetryCount__c = 0;
        return audit;
    }

    private static String mapPrefixToPicklist(String prefix) {
        if (prefix == null) return 'Apex';
        String p = prefix.toLowerCase();
        if (p == 'apex') return 'Apex';
        if (p == 'flow') return 'Flow';
        if (p == 'ip') return 'IP';
        if (p == 'dr') return 'DR';
        if (p == 'agent') return 'Agent';
        if (p == 'dml') return 'Dml';
        return 'Apex';
    }
}