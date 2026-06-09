/**
 * SF_AgenticGateway_WorkerCore — shared worker body for the Queueable
 * and @future paths (joint locked design
 * docs/sf-agentic-gateway-async-selector-2026-05-14.md §5.1 / §5.2).
 *
 * Single source of truth for:
 *   - audit-row USER_MODE load + payload-hash re-check (Sec G-Sec-ASYNC-2/-8)
 *   - CMDT re-validation (catches mid-flight deactivation; Sec G-Sec-ASYNC-12)
 *   - governor pre-check (Sec G-Sec-ASYNC-11)
 *   - dispatch via SF_AgenticGateway.dispatchSync (re-runs G-Sec-DML / G-Sec-AGENT
 *     inside the worker Tx)
 *   - truncateOrSpill + Platform Cache write
 *   - audit transition Submitted → Running → Completed / Failed
 *
 * `without sharing` because the worker is the dispatcher: USER_MODE SOQL
 * on the audit-row read re-asserts the per-user boundary (Sec
 * G-Sec-ASYNC-2). Downstream adapters carry their own sharing context.
 *
 * WP-L-Retry-Hardening (2026-05-27 — Sec G-Sec-ASYNC-15 AMENDED, closes CWE-754 retry amplification):
 *   - `runWorker` entry: concurrent-cap re-check via
 *     `SF_AgenticGateway_Limits.assertConcurrentCapOk()` immediately
 *     after the audit-row load + before any payload/bundle/governor
 *     gate. On `CONCURRENT_CAP_EXCEEDED` the worker transitions the
 *     audit to Failed via `handleFailure` + emits the Failed PE +
 *     returns — never reaches `dispatchSync`. Second-line defense
 *     against cross-Tx fan-out under retry storms (wave-3 per-Tx cap
 *     suite is the FIRST line).
 *   - `runWorker` entry: replay-guard via per-jobId `lastAttemptHash`
 *     persisted to Platform Cache (`SF_AgenticGateway_Limits.recordAttemptHash`
 *     / `loadAttemptHash`). Computed deterministically from the audit-
 *     row identity tuple `(JobId__c, PayloadHash__c, RetryCount__c,
 *     AsyncStatus__c)` via `computeAttemptHash`. When the cached hash
 *     matches the current-row hash AND `AsyncStatus__c=='Retrying'`,
 *     the worker short-circuits BEFORE dispatch — same
 *     `(jobId, payload, retryCount, status)` tuple never executes
 *     twice (CWE-799 sibling closure of CWE-754).
 *   - "Persisted to audit" Sec assertion (c) honored via Platform Cache
 *     backstop this WP; `LastAttemptHash__c` SObject field deferred to
 *     follow-on `FU-AGW-LASTATTEMPTHASH-FIELD-1` (Analyst-owned XML;
 *     WBS row 269 file list omits new field-meta — architectural-
 *     equivalence ruling §1 in WP-L-Retry-Hardening delivery, 12th-
 *     instance cluster flag).
 *   - PRESERVED: 7× USER_MODE DML invariant (5 in WorkerCore lines
 *     199/220/420/467/530 + 2 in CallbackInvoker per WP-SATA-5), 4-field
 *     PE payload, `PEOperationId__c` capture, `constantTimeEqualsHex`
 *     wire on `assertPayloadHashOk`, emit*Callback facade pass-through
 *     (SATA-5), Stage A SATA-1 loadAudit fail-loud (LIMIT 2 +
 *     JOB_ID_COLLISION).
 *
 * WP-L-WorkerCore-Audit (2026-05-26 — Sec G-Sec-DML-7 + G-Sec-ASYNC-13):
 *   - 6× `update audit;` → `Database.update(audit, AccessLevel.USER_MODE)`
 *     symmetry pass (CWE-732 USER_MODE preservation per call site —
 *     prior bare `update audit;` implicitly ran SYSTEM_MODE, breaking
 *     the loadAudit USER_MODE contract directional symmetry).
 *   - `emitPlatformEvent`: capture `Database.SaveResult` from
 *     `EventBus.publish(ev)` + persist platform-issued PE row Id into
 *     new `PEOperationId__c` field on audit row (forensic correlation
 *     of PE delivery vs audit state). PE publish failure leaves
 *     `PEOperationId__c = null` (G-Sec-ASYNC-13 PE-never-fails-worker
 *     contract preserved). Architectural-equivalence ruling: the Sec
 *     card wording `EventBus.getOperationIds(SaveResult)` is platform-
 *     impossible at API 66.0 (Spring '26) — no such method exists on
 *     the Apex `EventBus` class; canonical synchronous publish-time
 *     identifier is `Database.SaveResult.getId()` which returns the
 *     18-char Salesforce SObject Id (prefix `0a3...`) of the published
 *     `SF_AgenticGateway_Async__e` PE row — operator-intent preserved
 *     (forensic correlation), length contract honored (18-char).
 *   - `MessageHash__c` dropped from PE writer payload (PE schema
 *     tightening per G-Sec-ASYNC-13 — QW-2 lift; subscriber consumes
 *     only `{JobId__c, Status__c}` per WP-L-Subscriber structural
 *     insulation discovery, so no subscriber regression).
 *   - FU-AGW-CWE208-WORKERCORE-1: `assertPayloadHashOk` wires
 *     `SF_AgenticGateway_Limits.constantTimeEqualsHex` for both hash
 *     equality probes (CWE-208 timing-side-channel closure — mirrors
 *     WP-SATA-2 `verifyMessageHash` fix).
 */
public without sharing class SF_AgenticGateway_WorkerCore {

    public class WorkerCoreException extends Exception {}

    private static final String STATUS_RUNNING = 'Running';
    private static final String STATUS_COMPLETED = 'Completed';
    private static final String STATUS_FAILED = 'Failed';
    private static final String STATUS_RETRYING = 'Retrying';
    @TestVisible private static final Integer MAX_MESSAGE_CHARS = 256;
    private static final String CACHE_PARTITION = 'local.SfAgentic';

    // Wave-3 ASYNC-1 (G-Sec-ASYNC-13): PE Status__c value emitted on
    // each terminal transition. Kept distinct from STATUS_RETRYING /
    // STATUS_COMPLETED / STATUS_FAILED because PE values are operational
    // only — never enumerated by the audit picklist.
    private static final String PE_STATUS_COMPLETED = 'Completed';
    private static final String PE_STATUS_FAILED = 'Failed';
    private static final String PE_STATUS_RETRIED = 'Retried';

    /**
     * @TestVisible test seam — when non-null, `runWorker` returns this
     * value instead of dispatching to the real `dispatchSync` switch.
     * Lets tests assert audit + cache transitions without coupling to
     * the actual adapter behaviour.
     */
    @TestVisible
    private static Object testForcedResult = null;

    /**
     * @TestVisible test seam — when non-null, `runWorker` throws this
     * message at the dispatch step. Drives the Failed-status branch.
     */
    @TestVisible
    private static String testForcedDispatchError = null;

    /**
     * @TestVisible test seam — when true, the audit-row lookup returns
     * null (simulates a row that disappeared between submit and
     * execute, e.g. admin hard-deleted). Drives the orphan-job branch.
     */
    @TestVisible
    private static Boolean testForceAuditNotFound = false;

    /**
     * @TestVisible test seam — when true, the CMDT row appears
     * deactivated to the worker (regardless of real CMDT state).
     */
    @TestVisible
    private static Boolean testForceBundleDeactivated = false;

    /**
     * @TestVisible test seam — when true, the payload-hash check fails
     * regardless of real hash equality.
     */
    @TestVisible
    private static Boolean testForcePayloadTampered = false;

    /**
     * @TestVisible test seam — when true, the governor pre-check fails.
     */
    @TestVisible
    private static Boolean testForceGovernorPrecheckFail = false;

    /**
     * @TestVisible test seam — when true, the Platform Cache write is
     * skipped (simulates unprovisioned partition). Audit still flips to
     * Completed; status: read will return Expired on cache miss.
     */
    @TestVisible
    private static Boolean testSkipCacheWrite = false;

    /**
     * @TestVisible test seam — when non-null, invokeCallbackIfConfigured
     * uses this name instead of querying AllowList.asyncCallbackHandler.
     * Lets tests register a callback against a non-CMDT target.
     */
    @TestVisible
    private static String testForcedCallbackHandlerName = null;

    /**
     * @TestVisible test seam — when true, emitPlatformEvent throws
     * inside its try/catch so the swallow path is exercised. PE
     * delivery failure NEVER fails the worker (G-Sec-ASYNC-13).
     */
    @TestVisible
    private static Boolean testForcePeEmitFailure = false;

    /**
     * @TestVisible test seam — when true, classifyTransient returns
     * true regardless of the exception. Drives the retry branch
     * without a real transient exception in scope.
     */
    @TestVisible
    private static Boolean testForceTransientClassification = false;

    /**
     * @TestVisible test seam — when true, the retry-Queueable enqueue
     * step is skipped. The audit row still flips to Retrying +
     * RetryCount__c bumps, but no chained Queueable runs (tests can't
     * always enqueue a second Queueable inside Test.startTest).
     */
    @TestVisible
    private static Boolean testSkipRetryEnqueue = false;

    /**
     * @TestVisible test seam — when true, invokeCallbackIfConfigured
     * forces the callback to throw before handleCompletion returns.
     * Drives ASYNC_CALLBACK_FAILED audit coverage.
     */
    @TestVisible
    private static Boolean testForceCallbackThrow = false;

    /**
     * @TestVisible test seam — when non-null, loadAudit returns this
     * pre-built list instead of running the live SOQL. Lets tests
     * exercise the fail-loud JOB_ID_COLLISION path (multi-row return)
     * without bypassing the platform schema-unique constraint at
     * insert time (which is impossible to relax at runtime in Apex
     * once the field-meta &lt;unique&gt;true&lt;/unique&gt; has been
     * deployed). Production callers never set this; the seam ONLY
     * intercepts the SOQL boundary inside loadAudit.
     */
    @TestVisible
    private static List<SF_AgenticInvocation__c> testForcedAuditRows = null;

    /**
     * Shared body for QueueableWorker.execute + FutureWorker.execute.
     * Never throws — all errors funnel into the Failed audit branch.
     */
    public static void runWorker(
        String jobId,
        String prefix,
        String target,
        String payloadJson,
        String correlationId,
        String expectedHash
    ) {
        SF_AgenticInvocation__c audit = loadAudit(jobId);
        if (audit == null) {
            // Orphan worker — audit row disappeared between submit + execute.
            // Best-effort log; cannot persist to a non-existent row.
            System.debug(LoggingLevel.WARN,
                '[SF_AgenticGateway_WorkerCore] audit not found for jobId=' + jobId);
            return;
        }

        // WP-L-Retry-Hardening G-Sec-ASYNC-15 AMENDED — concurrent-cap
        // re-check at runWorker entry. SECOND-LINE defense against cross-
        // Tx fan-out under retry storms (wave-3 per-Tx cap suite is the
        // FIRST line). On `CONCURRENT_CAP_EXCEEDED` transition the audit
        // to Failed via the canonical handleFailure path + emit Failed PE
        // + return WITHOUT dispatching. Wrapped in the SAME try shape as
        // the production gate suite below so the existing handleException
        // envelope routes the error to retry-or-fail per classifyTransient
        // (decision-table entry `LimitExceededException:CONCURRENT_CAP_EXCEEDED`
        // returns false → permanent Failed, no retry amplification).
        try {
            SF_AgenticGateway_Limits.assertConcurrentCapOk();
        } catch (SF_AgenticGateway_Limits.LimitExceededException capEx) {
            handleException(audit, capEx, jobId, prefix, target, payloadJson,
                correlationId, expectedHash);
            return;
        }

        // WP-L-Retry-Hardening G-Sec-ASYNC-15 AMENDED — replay-guard via
        // per-jobId attempt-hash. Same `(jobId, payload, retryCount,
        // status)` tuple never executes twice (CWE-799 sibling closure
        // of CWE-754). Short-circuit only when the audit row is in
        // Retrying state AND the cached hash matches the current-row
        // hash — covers the trampoline re-enqueue → worker-re-execute
        // duplicate-delivery case without disrupting first-attempt
        // runs (Retrying gate ensures we never short-circuit a Submitted
        // → Running first dispatch).
        String currentAttemptHash =
            SF_AgenticGateway_Limits.computeAttemptHash(audit);
        if (STATUS_RETRYING.equals(audit.AsyncStatus__c)
                && currentAttemptHash != null) {
            String cachedAttemptHash =
                SF_AgenticGateway_Limits.loadAttemptHash(jobId);
            if (SF_AgenticGateway_Limits.constantTimeEqualsHex(
                    currentAttemptHash, cachedAttemptHash)) {
                System.debug(LoggingLevel.INFO,
                    '[SF_AgenticGateway_WorkerCore] replay-guard short-circuit'
                    + ' jobId=' + jobId
                    + ' retryCount=' + audit.RetryCount__c);
                return;
            }
        }

        try {
            assertPayloadHashOk(audit, payloadJson, expectedHash, jobId);
            assertBundleStillActive(audit.Target__c);
            assertWorkerGovernorPrecheck();

            audit.AsyncStatus__c = STATUS_RUNNING;
            audit.StartedAt__c = System.now();
            Database.update(audit, AccessLevel.USER_MODE);

            Integer maxBatch = SF_AgenticGateway_AllowList.maxBatch(target);
            Object rawResult;
            if (testForcedResult != null) {
                rawResult = testForcedResult;
            } else if (testForcedDispatchError != null) {
                throw new WorkerCoreException(testForcedDispatchError);
            } else {
                rawResult = SF_AgenticGateway.dispatchSync(
                    prefix, target, payloadJson, correlationId, maxBatch);
            }

            Map<String, Object> wrapped = SF_AgenticGateway_Limits.truncateOrSpill(
                rawResult, correlationId);
            writeToResultCache(audit, wrapped);

            audit.AsyncStatus__c = STATUS_COMPLETED;
            audit.CompletedAt__c = System.now();
            audit.success__c = true;
            audit.Truncated__c = (Boolean) wrapped.get('truncated');
            Database.update(audit, AccessLevel.USER_MODE);

            // Wave-3 ASYNC-1 (G-Sec-ASYNC-13): emit operational PE so
            // downstream subscribers (Custom Notification + ops dashboards)
            // observe the terminal transition. Guarded by CMDT kill
            // switch. PE failure NEVER fails the worker.
            emitPlatformEvent(audit, PE_STATUS_COMPLETED);

            // Wave-3 ASYNC-2 (G-Sec-ASYNC-14): reflective callback
            // invoke when AsyncCallbackHandler__c is configured.
            // enterCallbackScope / exitCallbackScope try/finally guards
            // any nested gateway dispatch.
            invokeCallbackIfConfigured(audit, wrapped);

        } catch (Exception e) {
            handleException(audit, e, jobId, prefix, target, payloadJson,
                correlationId, expectedHash);
        }
    }

    private static SF_AgenticInvocation__c loadAudit(String jobId) {
        if (testForceAuditNotFound) return null;
        List<SF_AgenticInvocation__c> rows;
        if (testForcedAuditRows != null) {
            // Test seam interception — bypass SOQL to exercise the
            // fail-loud JOB_ID_COLLISION path without breaking the
            // platform schema-unique constraint at insert time.
            rows = testForcedAuditRows;
        } else {
            // Dynamic SOQL via Database.queryWithBinds — see
            // SF_AgenticGateway_StatusAdapter.loadAuditUserMode for the
            // validate-only-deploy parser-cache workaround rationale.
            // USER_MODE preserved via AccessLevel.USER_MODE.
            // LIMIT 2 (not LIMIT 1) — schema-level <unique>true</unique>
            // on JobId__c guarantees max 1 row in practice; LIMIT 2 lets
            // loadAudit fail-loud on any future regression that produces
            // >1 row instead of silently picking row[0]. Defense in depth
            // per Sec G-Sec-DML-15 extended (PO AC-P0-1 Scenario 1d).
            String soql =
                'SELECT Id, Target__c, DispatchType__c, AsyncStatus__c, AsyncRuntime__c, '
                + 'AsyncApexJobId__c, SubmittedAt__c, StartedAt__c, CompletedAt__c, '
                + 'ResultRef__c, PayloadHash__c, JobId__c, correlationId__c, '
                + 'RetryCount__c, MessageHash__c '
                + 'FROM SF_AgenticInvocation__c '
                + 'WHERE JobId__c = :jobId '
                + 'LIMIT 2';
            rows = (List<SF_AgenticInvocation__c>)
                Database.queryWithBinds(
                    soql,
                    new Map<String, Object>{ 'jobId' => jobId },
                    AccessLevel.USER_MODE);
        }
        if (rows.size() > 1) {
            throw new WorkerCoreException('JOB_ID_COLLISION:' + jobId);
        }
        return rows.isEmpty() ? null : rows[0];
    }

    /**
     * Sec G-Sec-ASYNC-8: re-hash live audit row against the submit-time
     * expectedHash. Any drift = tamper signal.
     *
     * FU-AGW-CWE208-WORKERCORE-1 (WP-L-WorkerCore-Audit 2026-05-26):
     * both hash equality probes route through
     * `SF_AgenticGateway_Limits.constantTimeEqualsHex` so the byte-by-
     * byte compare leaks no timing information about WHERE the first
     * mismatch occurs (CWE-208 timing closure — mirrors WP-SATA-2
     * `verifyMessageHash` hardening). The helper short-circuits on
     * length mismatch then XOR-accumulates over codepoints for the
     * equal-length path.
     */
    private static void assertPayloadHashOk(
        SF_AgenticInvocation__c audit,
        String payloadJson,
        String expectedHash,
        String jobId
    ) {
        if (testForcePayloadTampered) {
            throw new WorkerCoreException('ASYNC_PAYLOAD_TAMPERED:test-seam');
        }
        String live = SF_AgenticGateway_JobIdMinter.payloadHash(jobId, payloadJson);
        if (!SF_AgenticGateway_Limits.constantTimeEqualsHex(live, expectedHash)
            || !SF_AgenticGateway_Limits.constantTimeEqualsHex(
                live, audit.PayloadHash__c)) {
            throw new WorkerCoreException('ASYNC_PAYLOAD_TAMPERED');
        }
    }

    /**
     * Sec G-Sec-ASYNC-12: re-validate the CMDT row at worker execute time.
     * The bundle may have been deactivated between submit and execute;
     * we reject rather than dispatch to a now-disallowed handler.
     */
    private static void assertBundleStillActive(String target) {
        if (testForceBundleDeactivated) {
            throw new WorkerCoreException('BUNDLE_DEACTIVATED:' + target);
        }
        SF_AgenticGateway_Allow__mdt row = SF_AgenticGateway_AllowList.lookup(target);
        if (row == null || row.Active__c != true) {
            throw new WorkerCoreException('BUNDLE_DEACTIVATED:' + target);
        }
    }

    /**
     * Sec G-Sec-ASYNC-11: cheap CPU + callout pre-check at worker entry.
     * Idempotent abort lets a saturated org fail-fast without partial
     * dispatch.
     */
    private static void assertWorkerGovernorPrecheck() {
        if (testForceGovernorPrecheckFail) {
            throw new WorkerCoreException('WORKER_GOVERNOR_PRECHECK:test-seam');
        }
        // Reuse existing budget gates (70% CPU, 80% callouts).
        SF_AgenticGateway_Limits.assertCpuOk();
        SF_AgenticGateway_Limits.assertCalloutOk();
    }

    private static void writeToResultCache(
        SF_AgenticInvocation__c audit,
        Map<String, Object> wrapped
    ) {
        if (testSkipCacheWrite) return;
        if (String.isBlank(audit.ResultRef__c)) return;
        Integer ttl = SF_AgenticGateway_AllowList.asyncResultTtlSeconds(audit.Target__c);
        try {
            Cache.OrgPartition partition = Cache.Org.getPartition(CACHE_PARTITION);
            // Cache value: the wrapped envelope itself, so StatusAdapter can
            // re-emit the same shape (data + truncated + dataRef + summary).
            partition.put(audit.ResultRef__c, JSON.serialize(wrapped), ttl);
        } catch (Exception cacheEx) {
            // Cache failure is non-fatal — StatusAdapter returns Expired
            // on cache miss, which is the same shape as TTL elapsed.
            System.debug(LoggingLevel.WARN,
                '[SF_AgenticGateway_WorkerCore] cache write failed: ' + cacheEx.getMessage());
        }
    }

    /**
     * Wave-3 ASYNC-4 (G-Sec-ASYNC-15): exception router. Classifies the
     * exception as transient vs permanent via Limits.classifyTransient.
     * On transient AND retries remaining → bump RetryCount__c, flip
     * AsyncStatus__c='Retrying', emit Retried PE, schedule a retry
     * Queueable via SF_AgenticGateway_RetryScheduler with exponential
     * backoff. Otherwise → existing handleFailure path + Failed PE.
     */
    private static void handleException(
        SF_AgenticInvocation__c audit,
        Exception e,
        String jobId,
        String prefix,
        String target,
        String payloadJson,
        String correlationId,
        String expectedHash
    ) {
        if (audit == null) return;
        Boolean isTransient = testForceTransientClassification
            || SF_AgenticGateway_Limits.classifyTransient(e);
        Integer currentRetry = (audit.RetryCount__c == null)
            ? 0 : audit.RetryCount__c.intValue();
        Integer maxRetries = SF_AgenticGateway_Limits.effectiveMaxRetries(
            SF_AgenticGateway_AllowList.asyncMaxRetries(audit.Target__c));

        if (isTransient && currentRetry < maxRetries) {
            attemptRetry(audit, e, jobId, prefix, target, payloadJson,
                correlationId, expectedHash, currentRetry);
        } else {
            handleFailure(audit, e);
            emitPlatformEvent(audit, PE_STATUS_FAILED);
        }
    }

    /**
     * Wave-3 ASYNC-4: transient retry branch. RetryCount++, status flip
     * to Retrying, PE emit Status=Retried, schedule retry Queueable.
     * Delay is approximate wall-clock (best-effort) because the platform
     * does not expose a true scheduled-delay Queueable without
     * System.scheduleBatch + a Schedulable wrapper. RetryScheduler
     * documents the approximation.
     */
    private static void attemptRetry(
        SF_AgenticInvocation__c audit,
        Exception e,
        String jobId,
        String prefix,
        String target,
        String payloadJson,
        String correlationId,
        String expectedHash,
        Integer currentRetry
    ) {
        try {
            Integer nextRetry = currentRetry + 1;
            Integer delaySeconds = SF_AgenticGateway_Limits.retryBackoffSeconds(
                nextRetry);
            audit.RetryCount__c = nextRetry;
            audit.AsyncStatus__c = STATUS_RETRYING;
            audit.message__c = sanitizeMessage(e);
            audit.MessageHash__c = SF_AgenticGateway_Limits.hashMessage(
                audit.message__c);
            Database.update(audit, AccessLevel.USER_MODE);

            emitPlatformEvent(audit, PE_STATUS_RETRIED);

            if (testSkipRetryEnqueue) return;
            System.enqueueJob(new SF_AgenticGateway_RetryScheduler(
                jobId, prefix, target, payloadJson, correlationId, expectedHash,
                delaySeconds));
        } catch (Exception retryEx) {
            System.debug(LoggingLevel.WARN,
                '[SF_AgenticGateway_WorkerCore.attemptRetry] swallow: '
                + retryEx.getMessage());
            // Fall back to terminal Failed if the retry plumbing itself
            // throws — never leave the audit row dangling.
            handleFailure(audit, e);
            emitPlatformEvent(audit, PE_STATUS_FAILED);
        }
    }

    private static String sanitizeMessage(Exception e) {
        String raw = (e == null) ? 'UNKNOWN_WORKER_ERROR' : e.getMessage();
        String typeName = (e == null) ? 'WorkerError' : e.getTypeName();
        String composed = typeName + ': ' + (raw == null ? '' : raw);
        return composed.length() > MAX_MESSAGE_CHARS
            ? composed.substring(0, MAX_MESSAGE_CHARS)
            : composed;
    }

    /**
     * Sec G-Sec-ASYNC-7: Failed branch never leaks stack traces. Message
     * is truncated to MAX_MESSAGE_CHARS, lower-cardinality `MessageHash__c`
     * keyed via the gateway HMAC helper for forensic grouping.
     */
    private static void handleFailure(SF_AgenticInvocation__c audit, Exception e) {
        if (audit == null) return;
        try {
            String raw = (e == null) ? 'UNKNOWN_WORKER_ERROR' : e.getMessage();
            String typeName = (e == null) ? 'WorkerError' : e.getTypeName();
            String composed = typeName + ': ' + (raw == null ? '' : raw);
            String truncated = composed.length() > MAX_MESSAGE_CHARS
                ? composed.substring(0, MAX_MESSAGE_CHARS)
                : composed;
            audit.AsyncStatus__c = STATUS_FAILED;
            audit.CompletedAt__c = System.now();
            audit.success__c = false;
            audit.message__c = truncated;
            audit.MessageHash__c = SF_AgenticGateway_Limits.hashMessage(composed);
            Database.update(audit, AccessLevel.USER_MODE);
        } catch (Exception logEx) {
            System.debug(LoggingLevel.WARN,
                '[SF_AgenticGateway_WorkerCore] failure-write swallowed: '
                + logEx.getMessage());
        }
    }

    /**
     * Wave-3 ASYNC-1 (G-Sec-ASYNC-13): operational Platform Event emit.
     * Four-field payload (JobId, Status, Runtime, CorrelationId) —
     * never the original payload, never the error body. Guarded by
     * per-bundle CMDT AsyncPublishEnabled__c kill switch (default
     * false). PE delivery failure NEVER fails the worker.
     *
     * WP-L-WorkerCore-Audit (2026-05-26 — G-Sec-ASYNC-13 PE schema
     * tightening + QW-2 lift):
     *   - `MessageHash__c` dropped from PE payload (was 5-field, now
     *     4-field). Subscriber consumes only {JobId__c, Status__c} per
     *     WP-L-Subscriber 14:46Z structural-insulation discovery — no
     *     subscriber regression.
     *   - `Database.SaveResult` captured from `EventBus.publish(ev)`;
     *     platform-issued 18-char PE row Id (prefix `0a3...`) persisted
     *     into `audit.PEOperationId__c` via USER_MODE DML for forensic
     *     correlation of PE delivery vs audit row state.
     *   - PE publish failure (any throw, OR `sr.isSuccess()==false`)
     *     leaves `audit.PEOperationId__c = null` (best-effort null-set
     *     via USER_MODE DML when reachable); PE-emit-never-fails-worker
     *     contract preserved per existing swallow-and-log pattern.
     *
     * Architectural-equivalence ruling — Sec card wording
     * `EventBus.getOperationIds(SaveResult)` is platform-impossible at
     * API 66.0 Spring '26 (no such method on Apex `EventBus` class per
     * https://developer.salesforce.com/docs/atlas.en-us.apexref.meta/apexref/apex_class_System_eventbus.htm).
     * Canonical synchronous publish-time identifier is
     * `Database.SaveResult.getId()` which returns the 18-char Salesforce
     * SObject Id of the published PE row (prefix `0a3...` matches Sec
     * card "PE operation id" wording verbatim). Operator-intent
     * preserved (forensic correlation), length contract honored
     * (18-char), at the same call-site, same semantic.
     */
    @TestVisible
    private static void emitPlatformEvent(
        SF_AgenticInvocation__c audit,
        String status
    ) {
        if (audit == null) return;
        if (!SF_AgenticGateway_AllowList.asyncPublishEnabled(audit.Target__c)) {
            return;
        }
        try {
            if (testForcePeEmitFailure) {
                throw new WorkerCoreException('PE_FORCED_FAILURE:test-seam');
            }
            SF_AgenticGateway_Async__e ev = new SF_AgenticGateway_Async__e();
            ev.JobId__c = audit.JobId__c;
            ev.Status__c = status;
            ev.Runtime__c = audit.AsyncRuntime__c;
            ev.CorrelationId__c = audit.correlationId__c;
            Database.SaveResult sr = EventBus.publish(ev);
            audit.PEOperationId__c = (sr != null && sr.isSuccess())
                ? String.valueOf(sr.getId())
                : null;
            Database.update(audit, AccessLevel.USER_MODE);
        } catch (Exception peEx) {
            System.debug(LoggingLevel.WARN,
                '[SF_AgenticGateway_WorkerCore] PE emit failed: '
                + peEx.getMessage());
        }
    }

    /**
     * Wave-3 ASYNC-2 (G-Sec-ASYNC-14) + WP-SATA-5 G-Sec-ASYNC-14-batch:
     * 3-line facade pass-through to SF_AgenticGateway_CallbackInvoker.
     * The full reflective ISF_AgenticAsyncCallback resolution +
     * enterCallbackScope/exitCallbackScope try/finally + markInvalid /
     * markFailed audit-row writes now live in the shared invoker so
     * the BatchWorker.finish path (CWE-440 closure) hits the exact
     * same code path as the wave-3 Queueable + @future runtimes.
     *
     * Backward-compat: the @TestVisible seams
     * `testForcedCallbackHandlerName` + `testForceCallbackThrow`
     * stay on WorkerCore (existing wave-3
     * SF_AgenticGatewayCallbackReentryTest references read them at
     * `SF_AgenticGateway_WorkerCore.*`). The facade propagates those
     * proxy values into the SF_AgenticGateway_CallbackInvoker
     * counterpart fields immediately before delegating; the
     * authoritative resolution + throw fork run inside the invoker.
     */
    @TestVisible
    private static void invokeCallbackIfConfigured(
        SF_AgenticInvocation__c audit,
        Map<String, Object> result
    ) {
        if (testForcedCallbackHandlerName != null) {
            SF_AgenticGateway_CallbackInvoker.setTestForcedCallbackHandlerName(
                testForcedCallbackHandlerName);
        }
        if (testForceCallbackThrow) {
            SF_AgenticGateway_CallbackInvoker.setTestForceCallbackThrow(true);
        }
        SF_AgenticGateway_CallbackInvoker.invoke(audit, result);
    }
}