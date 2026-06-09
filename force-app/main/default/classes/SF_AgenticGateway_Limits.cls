/**
 * SF_AgenticGateway_Limits — pure-static governor + payload guards for the
 * multidispatch gateway. Encodes the architectural caps from the SA+TA joint
 * design (docs/sf-agentic-gateway-multidispatch-2026-05-08-design.md §5.1)
 * and the Sec controls C-5 (HMAC message hash) + C-6 (Platform Cache
 * spillover) from the threat model.
 *
 * No SOQL inside the hot path; the lone CMDT SOQL is single-Tx-cached.
 * DML is restricted to one fail-loud Platform Event publish on the
 * HMAC-master-missing degraded path (see § WP-SATA-2 below).
 * `without sharing` because it owns no data and is invoked from both
 * `with sharing` adapters and the gateway dispatcher; sharing decisions
 * stay with the callers.
 *
 * Constants are deliberately compile-time. They represent gateway
 * architectural caps (NOT business rules); moving to CMDT is a follow-up
 * optimization that requires a separate design + Sec sub-gate.
 *
 * Wave-5 additions (docs/sf-agentic-gateway-query-adapter-2026-05-20.md):
 *   - 4 query: constants (MAX_QUERIES_PER_CALL=5, MAX_QUERY_ROWS_PER_CALL=200,
 *     MAX_QUERY_DISPATCHES_PER_TX=5, MAX_QUERY_DEPTH=3)
 *   - queryDispatchCount counter + assertQueryDispatchCountOk + assertQueriesOk
 *     + assertQueryRowsOk
 *   - testForceQueryDispatchFail seam
 *
 * Wave-3 additions (docs/sf-agentic-gateway-wave-3-2026-05-20-technical-design.md
 * §3.5 / §5.2 / §6):
 *   - G-Sec-ASYNC-14: callback re-entry guard — `inCallbackScope` flag +
 *     `callbackDispatchCount` counter + `enterCallbackScope` /
 *     `exitCallbackScope` (try/finally seam from WorkerCore) +
 *     `assertNotInCallbackScope` (invoked at top of `SF_AgenticGateway.dispatchSync`).
 *   - G-Sec-ASYNC-15: retry storm cap — `MAX_RETRIES_HARD_CAP=5` +
 *     `classifyTransient(Exception)` whitelist + `retryBackoffSeconds(attempt)`
 *     (2^n × 30s capped 480s) + `effectiveMaxRetries(cmdtValue)` intersection.
 *   - G-Sec-SEC-1: Protected CMDT HMAC key cache — `getHmacKeyCurrent` +
 *     `getHmacKeyPrevious` + `getHmacRotatedAt` + `ensureHmacCacheLoaded`
 *     (single-SOQL-per-Tx evidence via `hmacCacheLoadCount`).
 *   - G-Sec-SEC-2: dual-key rotation grace — `verifyMessageHash(msg, expected)`
 *     accepts the previous key for `SEC_PREVIOUS_KEY_GRACE_DAYS=30` after
 *     `RotatedAt__c`; rejects beyond the cutoff.
 *   - `hashMessage` + `deriveAgentSessionId` rewired to consume the cached
 *     current key via `getHmacKeyCurrent()` so HMAC rotation propagates
 *     without redeploy.
 *   - Test seams: `setMockHmacKey(current, previous, rotatedAt)`,
 *     `testForceHmacCacheMiss`, `hmacCacheLoadCount` counter; `resetTestSeams`
 *     extended to drop the HMAC + callback state.
 *
 * WP-L-Retry-Hardening additions (docs/sf-agentic-gateway-fixes-2026-05-26-wp-l-retry-hardening-delivery.md,
 * G-Sec-ASYNC-15 AMENDED — closes CWE-754 4xx retry amplification):
 *   - `RETRY_DECISION_TABLE` static-init `Map<String, Boolean>` decision-table
 *     keyed `<ExceptionTypeName>:<MessagePrefixToken>` (empty token = match
 *     any). Consulted FIRST in `classifyTransient`, BEFORE the wave-3 +
 *     WP-SATA-3 substring envelope; on miss falls through to the envelope
 *     (architectural-equivalence ruling §1 in WP-L-Retry-Hardening delivery
 *     — Sec card "CMDT decision-table" intent honored via Apex Map; CMDT
 *     XML deferred to FU-AGW-RETRY-DECISION-MDT-1 because WBS row 269 file
 *     list omits CMDT XML / new field-meta — Analyst lane).
 *   - `assertConcurrentCapOk` — Platform Cache CAS-narrowed counter for the
 *     per-org concurrent async-worker cap (G-Sec-ASYNC-15 sibling closure of
 *     the race window where two WorkerCore.runWorker hops both pass the
 *     wave-3 per-Tx cap because each runs in a fresh Tx). Throws
 *     `LimitExceededException('CONCURRENT_CAP_EXCEEDED:' + currentCount +
 *     ':' + cap)`. ~0.5ms per check.
 *   - `computeAttemptHash(SF_AgenticInvocation__c)` — HMAC-SHA256 over
 *     `JobId__c|PayloadHash__c|RetryCount__c|AsyncStatus__c` under the
 *     message-auth-derived key; 64-char hex. Used by RetryScheduler +
 *     WorkerCore replay guard so the same `(jobId, retryCount, payload)`
 *     tuple never executes twice (CWE-799 sibling closure).
 *   - `recordAttemptHash(jobId, hash)` + `loadAttemptHash(jobId)` —
 *     Platform Cache org-partition store keyed `'retry-attempt:' +
 *     sanitisedJobId`, TTL = `RETRY_ATTEMPT_HASH_TTL_SECONDS` (default
 *     900s; > max retry envelope 60+120+240+480+480=1380s collision
 *     window minus delivery jitter — generous enough for the 5-hop
 *     trampoline to remember every prior attempt). NO PII; hash-only.
 *
 * WP-L-Hmac-Hardening additions (docs/sf-agentic-gateway-fixes-2026-05-26-wp-l-hmac-hardening-delivery.md,
 * L-10 G-Sec-SEC-2.1 wired closure + L-4 partial truncation lift):
 *   - `sanitizeMessage(String msg)` — public static centralised helper
 *     that caps `msg` to `MAX_MESSAGE_CHARS=256` chars. Canonical
 *     landing for the scattered `String.substring(0, Math.min(256,
 *     msg.length()))` truncation pattern across the audit-row writer
 *     surface (`WorkerCore.sanitizeMessage` + `WorkerCore.handleFailure`
 *     + `CallbackInvoker.markInvalid` + `CallbackInvoker.markFailed`
 *     + `QueryAdapter` reject envelope). Null-safe (returns null);
 *     shorter-than-cap inputs pass through unchanged so forensic-SOQL
 *     consumers can still operate on the raw-length-bounded surface.
 *     Call-site adoption deferred to FU-AGW-SANITIZE-MSG-CALLSITE-1
 *     because WBS row 288 file-list scopes THIS WP to `Limits.cls`
 *     only (L-4 partial framing); `WorkerCore.cls` Wave 2 serialization
 *     CLOSED per TL WBS § Cross-WP file overlap risk matrix line 471
 *     (SATA-1 → SATA-5 → L-WorkerCore-Audit → L-Retry-Hardening → Stage
 *     C tail) so further WorkerCore.cls edits are sequenced to Stage C.
 *   - L-10 G-Sec-SEC-2.1 verified ALREADY WIRED by WP-SATA-2 — every
 *     `verifyMessageHash` codepath (current-key full-hex + current-key
 *     16-char truncated + previous-key full-hex + previous-key 16-char
 *     truncated) routes through `constantTimeEqualsHex`. Mirror wire
 *     on `WorkerCore.assertPayloadHashOk` landed via WP-L-WorkerCore-
 *     Audit / FU-AGW-CWE208-WORKERCORE-1. Zero remaining `String.equals`
 *     /`==` hash-compare sites discoverable via `rg` across
 *     `force-app/main/default/classes/`; L-10 closure verified by
 *     `testGivenTamperedHexHashWhenVerifyThenConstantTimeReject` +
 *     existing `SF_AgenticGatewayHmacRotationTest` envelope transitivity.
 *
 * WP-SATA-2 additions (docs/sf-agentic-gateway-fixes-2026-05-26-technical-design.md
 * §XL-2 + sec-threat-model.md § Card · WP-SATA-2, gates
 * G-Sec-SEC-1.1 / -2.1 / -2.2 / -2.3):
 *   - HKDF-style derived sub-keys with distinct salts `JOBID_MINTER_SALT`
 *     (`'jobid-minter'`) and `MESSAGE_AUTH_SALT` (`'message-auth'`) so the
 *     audit-payload-bind key and the message-auth key cannot be confused
 *     even if the master CMDT row is misconfigured (defensive separation
 *     per PM Gate 1 row #2).
 *   - `getJobIdMinterHmacKey()` + `getJobIdMinterHmacKeyPrevious()` derive
 *     from `cachedHmacCurrent` / `cachedHmacPrevious` via single-step
 *     HMAC-SHA256 (salt-as-message, master-as-key) and cache the hex
 *     result for the rest of the Tx.
 *   - `constantTimeEqualsHex(a, b)` — short-circuit on length mismatch,
 *     otherwise XOR-accumulate over codepoints (CWE-208 timing closure;
 *     equal-length constant-time path). Used by `verifyMessageHash` in
 *     place of the prior fast-fail short-circuit comparison.
 *   - Prior compile-time HMAC fallback constant REMOVED (CWE-798 closure).
 *     `getHmacKeyCurrent()` on blank master now (a) logs `LoggingLevel.ERROR`,
 *     (b) emits Platform Event `SF_AgenticGateway_Async__e
 *     Status__c='HMAC_KEY_MISSING'` for on-call alerting, and (c) returns
 *     `null` so the JobIdMinter fail-loud throws `JOBID_HMAC_KEY_UNAVAILABLE`
 *     instead of silently authenticating with a deploy-time literal.
 *   - Test seams added: `cachedJobIdMinterKey` / `cachedJobIdMinterKeyPrevious`
 *     statics + `hmacKeyMissingEventCount` counter (incremented in the
 *     event-emit path so tests can assert without a PE subscriber);
 *     `resetTestSeams` cleans all three.
 */
public without sharing class SF_AgenticGateway_Limits {

    @TestVisible private static final Integer MAX_PAYLOAD_BYTES = 32768;
    @TestVisible private static final Integer MAX_RESPONSE_BYTES = 16384;
    @TestVisible private static final Integer MAX_BATCH_HARD_CAP = 50;
    @TestVisible private static final Integer MAX_DISPATCHES_PER_TX = 20;
    // Sec G-Sec-AGENT-1 (docs/sf-agentic-gateway-agent-dispatch-2026-05-12.md §3):
    // Agent dispatches trigger LLM callouts under the hood (seconds of wall-
    // clock + dollar cost each). Cap recursive agent fan-out per Tx tighter
    // than the general dispatch counter to keep a single user turn bounded.
    @TestVisible private static final Integer MAX_AGENT_DISPATCHES_PER_TX = 3;

    // Sec G-Sec-DML-6/8/10 (docs/sf-agentic-gateway-dml-adapter-2026-05-14.md §5):
    // Multi-SObject DML adapter caps. Groups/records caps bound a single call;
    // dispatch cap bounds recursive DML fan-out per Tx. Rows-budget gate trips
    // before the platform DML-row ceiling so the adapter fails fast with a
    // governor-shaped error instead of an opaque platform breach.
    @TestVisible private static final Integer MAX_DML_GROUPS_PER_CALL = 5;
    @TestVisible private static final Integer MAX_DML_RECORDS_PER_CALL = 50;
    @TestVisible private static final Integer MAX_DML_DISPATCHES_PER_TX = 5;
    @TestVisible private static final Decimal DML_ROWS_BUDGET_PCT = 0.80;

    // Sec G-Sec-ASYNC-10 (docs/sf-agentic-gateway-async-selector-2026-05-14.md §6):
    // Per-Tx async submit counter — bounds how many async receipts a single
    // user turn can emit. Independent of dispatch/agent/dml counters so the
    // failure mode is unambiguously async-shaped.
    @TestVisible private static final Integer MAX_ASYNC_SUBMITS_PER_TX = 10;

    // Sec G-Sec-QUERY-6/8/10/13 (docs/sf-agentic-gateway-query-adapter-2026-05-20.md):
    // Per-Tx query adapter caps. Queries-per-call caps bundle size; rows-per-call
    // caps each individual LIMIT; dispatch-per-Tx caps recursive query fan-out
    // (mirrors DML topology); depth caps parent dot traversal in projections.
    @TestVisible private static final Integer MAX_QUERIES_PER_CALL = 5;
    @TestVisible private static final Integer MAX_QUERY_ROWS_PER_CALL = 200;
    @TestVisible private static final Integer MAX_QUERY_DISPATCHES_PER_TX = 5;
    @TestVisible private static final Integer MAX_QUERY_DEPTH = 3;

    // Wave-3 G-Sec-ASYNC-15 (docs/sf-agentic-gateway-wave-3-2026-05-20-technical-design.md
    // §5.2): retry storm cap. WorkerCore intersects the CMDT per-bundle
    // `AsyncMaxRetries__c` with this hard cap via `effectiveMaxRetries`.
    @TestVisible private static final Integer MAX_RETRIES_HARD_CAP = 5;

    // WP-L-Retry-Hardening G-Sec-ASYNC-15 AMENDED: per-org concurrent
    // async-worker cap. CAS-narrowed against the Platform Cache org
    // partition. Default 5 keeps headroom for the platform Queueable
    // concurrency ceiling (50 chained) while bounding the simultaneous
    // worker fan-out a single bundle can sustain. Operator-tunable via
    // SF_AgenticGateway_AllowList future `MaxConcurrentAsyncJobs__c` per-
    // bundle CMDT field (FU-AGW-CONCURRENT-CAP-PERBUNDLE-1; deferred to
    // wave-4 — beyond WBS row 269 file list scope).
    @TestVisible private static final Integer MAX_CONCURRENT_ASYNC_JOBS = 5;

    // WP-L-Retry-Hardening G-Sec-ASYNC-15 AMENDED: Platform Cache TTL for
    // the per-jobId attempt-hash replay-guard store. 900s = 15 min, which
    // exceeds the full retry envelope wall-clock budget (60+120+240+480+
    // 480 = 1380s in worst-case; the +120s margin absorbs delivery jitter
    // between WorkerCore.handleException → RetryScheduler.execute hops).
    @TestVisible private static final Integer RETRY_ATTEMPT_HASH_TTL_SECONDS = 900;

    // Wave-3 G-Sec-SEC-2 (docs/sf-agentic-gateway-wave-3-2026-05-20-technical-design.md
    // §6): rotation grace window for previous-key acceptance. After this
    // many days past `RotatedAt__c` the previous key is rejected.
    @TestVisible private static final Integer SEC_PREVIOUS_KEY_GRACE_DAYS = 30;

    @TestVisible private static final Decimal CPU_BUDGET_PCT = 0.70;
    @TestVisible private static final Decimal HEAP_BUDGET_PCT = 0.70;
    @TestVisible private static final Decimal SOQL_BUDGET_PCT = 0.80;
    @TestVisible private static final Decimal DML_BUDGET_PCT = 0.80;
    @TestVisible private static final Decimal CALLOUT_BUDGET_PCT = 0.80;

    private static final String CACHE_PARTITION = 'local.SfAgentic';
    private static final Integer CACHE_TTL_SECONDS = 300;
    private static final Integer SUMMARY_CHARS = 256;
    private static final Integer FALLBACK_TRUNCATE_BYTES = 16384;

    // WP-L-Hmac-Hardening L-4 partial: canonical message-truncation cap
    // for audit-row `message__c` writes across the gateway. Wave-3
    // baseline scattered `String.substring(0, Math.min(256, ...))` ad-
    // hoc at every audit-write call site (WorkerCore.sanitizeMessage +
    // WorkerCore.handleFailure + CallbackInvoker.markInvalid +
    // CallbackInvoker.markFailed + QueryAdapter reject envelope);
    // `sanitizeMessage` below is the centralised landing. 256 chars
    // matches the SObject `SF_AgenticInvocation__c.message__c` column
    // width per existing Wave 2 schema baseline + the forensic-SOQL
    // bounded-prefix `WHERE message__c LIKE 'CODE:%'` pattern density.
    // NOTE: `SF_AgenticGateway_DmlAdapter.truncateMessage` keeps its
    // own 255-char cap because `SF_AgenticGateway_DmlResult__c.
    // Message__c` is a text(255) column (different semantic surface);
    // adopting `sanitizeMessage` over there would lift truncation to
    // 256 and risk a 1-char overflow at deploy time — DG7 KISS +
    // preserve-DG10-firewall ruling = leave 255-char DmlAdapter helper
    // intact (FU-AGW-DML-RESULT-MSG-WIDEN-1 future Analyst-lane field
    // widening tracks the column extension separately).
    @TestVisible private static final Integer MAX_MESSAGE_CHARS = 256;

    // WP-SATA-2 G-Sec-SEC-1.1: HKDF-style salts for sub-key derivation
    // from the master HMAC stored in `SF_AgenticGateway_Secret.HMACKey`.
    // Distinct salts guarantee the audit-payload-bind key and the
    // message-auth key cannot collide even under a misconfigured master
    // (defensive separation per PM Gate 1 row #2).
    @TestVisible private static final String JOBID_MINTER_SALT = 'jobid-minter';
    @TestVisible private static final String MESSAGE_AUTH_SALT = 'message-auth';

    // WP-SATA-2 G-Sec-SEC-1.1: Platform Event Status__c literal used by
    // the fail-loud HMAC-master-missing emitter. 16 characters — fits the
    // `SF_AgenticGateway_Async__e.Status__c` text(16) column exactly.
    @TestVisible private static final String HMAC_KEY_MISSING_STATUS = 'HMAC_KEY_MISSING';

    private static Integer dispatchCount = 0;
    private static Integer agentDispatchCount = 0;
    private static Integer dmlDispatchCount = 0;
    private static Integer asyncSubmitCount = 0;
    private static Integer queryDispatchCount = 0;

    // Wave-3 G-Sec-ASYNC-14: callback re-entry guard state. Counter +
    // flag are Tx-scoped so a single user turn cannot chain dispatch ←
    // callback ← dispatch. WorkerCore wraps the reflective callback in
    // a try/finally that calls enterCallbackScope / exitCallbackScope.
    private static Integer callbackDispatchCount = 0;
    @TestVisible private static Boolean inCallbackScope = false;

    // Wave-3 G-Sec-SEC-1 / G-Sec-SEC-2: per-Tx HMAC dual-key cache.
    // `hmacCacheLoadCount` counts ONLY real SOQL invokes so tests can
    // assert single-SOQL-per-Tx without coupling to `Limits.getQueries()`
    // (other in-Tx queries would perturb that counter).
    @TestVisible private static Integer hmacCacheLoadCount = 0;
    @TestVisible private static Boolean hmacCacheLoaded = false;
    @TestVisible private static String cachedHmacCurrent;
    @TestVisible private static String cachedHmacPrevious;
    @TestVisible private static Datetime cachedHmacRotatedAt;

    // WP-SATA-2 G-Sec-SEC-1.1: per-Tx derived sub-key cache. Hex-encoded
    // result of HMAC-SHA256(message=salt, key=master). One slot per salt
    // surface. Null until first derive; only filled when the master is
    // present (blank master → fail-loud path; cache stays null).
    @TestVisible private static String cachedJobIdMinterKey = null;
    @TestVisible private static String cachedJobIdMinterKeyPrevious = null;

    // WP-SATA-2 G-Sec-SEC-1.1: fail-loud counter — increments inside the
    // PE-emit path so tests can assert blast-radius without subscribing
    // to the Platform Event. Reset by `resetTestSeams`.
    @TestVisible private static Integer hmacKeyMissingEventCount = 0;

    // WP-L-Retry-Hardening G-Sec-ASYNC-15 AMENDED: decision-table for
    // retry classification. Keys are `<ExceptionTypeName>:<MessagePrefixToken>`
    // (empty token = match any message under that exception type). Walked
    // FIRST in `classifyTransient`; on miss the call falls through to the
    // wave-3 + WP-SATA-3 substring envelope so non-listed exceptions
    // preserve baseline behavior (no behavioral regression).
    //
    // 4xx-class permanent-failure codes (BUNDLE_INACTIVE / BUNDLE_DEACTIVATED
    // / DISPATCH_SYNC_BYPASS_BLOCKED) are duplicated here EXPLICITLY for
    // shape clarity at decision-table review time even though the WP-SATA-3
    // substring envelope at lines ~617-625 already catches them — DG6
    // belt-and-suspenders on the canonical permanent-failure surface.
    //
    // Operator hotfix: future entries land via redeploy of this Map (or via
    // CMDT migration per FU-AGW-RETRY-DECISION-MDT-1 deferred to wave-4
    // because WBS row 269 file list omits CMDT XML — Analyst lane).
    @TestVisible
    private static final Map<String, Boolean> RETRY_DECISION_TABLE =
        new Map<String, Boolean>{
            'SF_AgenticGatewayException:BUNDLE_INACTIVE' => false,
            'SF_AgenticGatewayException:BUNDLE_DEACTIVATED' => false,
            'SF_AgenticGatewayException:DISPATCH_SYNC_BYPASS_BLOCKED' => false,
            'WorkerCoreException:BUNDLE_DEACTIVATED' => false,
            'WorkerCoreException:ASYNC_PAYLOAD_TAMPERED' => false,
            'WorkerCoreException:JOB_ID_COLLISION' => false,
            'LimitExceededException:CALLBACK_REENTRY_BLOCKED' => false,
            'LimitExceededException:CONCURRENT_CAP_EXCEEDED' => false,
            'LimitExceededException:GOVERNOR_BUDGET_EXCEEDED' => false,
            'System.CalloutException:' => true,
            'System.QueryException:UNABLE_TO_LOCK_ROW' => true,
            'System.DmlException:UNABLE_TO_LOCK_ROW' => true
        };

    // WP-L-Retry-Hardening G-Sec-ASYNC-15 AMENDED: test seam — when set
    // (non-null entry per key shape `<TypeName>:<Token>`), the decision-table
    // walk short-circuits to this map BEFORE the production
    // `RETRY_DECISION_TABLE`. Lets tests inject `(ExceptionType, Token,
    // verdict)` triples without recompiling the production Map. Reset by
    // `resetTestSeams`.
    @TestVisible private static Map<String, Boolean> testForcedRetryDecisions =
        new Map<String, Boolean>();

    // WP-L-Retry-Hardening G-Sec-ASYNC-15 AMENDED: test seam — when true,
    // `assertConcurrentCapOk` short-circuits to throw without exercising
    // the Platform Cache CAS counter. Drives the CONCURRENT_CAP_EXCEEDED
    // assertion path in deterministic test envelopes (Platform Cache
    // partition may not be provisioned in scratch orgs).
    @TestVisible private static Boolean testForceConcurrentCapFail = false;

    // WP-L-Retry-Hardening G-Sec-ASYNC-15 AMENDED: test seam — when true,
    // `recordAttemptHash` + `loadAttemptHash` bypass Platform Cache and
    // use a Tx-scoped in-memory Map instead. Drives deterministic replay-
    // guard coverage in test orgs without Platform Cache provisioned.
    @TestVisible private static Boolean testForceAttemptHashInMemory = false;

    // WP-L-Retry-Hardening G-Sec-ASYNC-15 AMENDED: in-memory fallback for
    // `testForceAttemptHashInMemory`. Tx-scoped. Reset by `resetTestSeams`.
    @TestVisible private static Map<String, String> inMemoryAttemptHashes =
        new Map<String, String>();

    // WP-L-Retry-Hardening G-Sec-ASYNC-15 AMENDED: counters — used by tests
    // to assert that the CAS counter incremented exactly once per legitimate
    // pass, and that the replay-guard store wrote / read the expected
    // number of times. Reset by `resetTestSeams`.
    @TestVisible private static Integer concurrentCapCheckCount = 0;
    @TestVisible private static Integer attemptHashStoreCount = 0;
    @TestVisible private static Integer attemptHashLoadCount = 0;

    /**
     * @TestVisible test seams — when true, the corresponding assert*
     * helper short-circuits to throw LimitExceededException without
     * waiting for the real platform Limits to breach. Used exclusively by
     * SF_AgenticGatewayMultiTest to exercise AC-7 governor abort paths
     * (no other clean way to force a 70% CPU breach inside a unit test).
     */
    @TestVisible private static Boolean testForceCpuFail = false;
    @TestVisible private static Boolean testForceHeapFail = false;
    @TestVisible private static Boolean testForceSoqlFail = false;
    @TestVisible private static Boolean testForceDmlFail = false;
    @TestVisible private static Boolean testForceCalloutFail = false;
    @TestVisible private static Boolean testForceAgentDispatchFail = false;
    @TestVisible private static Boolean testForceDmlDispatchFail = false;
    @TestVisible private static Boolean testForceAsyncSubmitFail = false;
    @TestVisible private static Boolean testForceQueryDispatchFail = false;

    /**
     * @TestVisible test seam — forces truncateOrSpill to behave as if the
     * Platform Cache partition is unavailable (drives the fallback branch
     * coverage when the test org has the partition provisioned).
     */
    @TestVisible private static Boolean testForceCacheFailure = false;

    /**
     * Wave-3 G-Sec-SEC-1 test seam — when true, `ensureHmacCacheLoaded`
     * skips the real Protected-CMDT SOQL so the fallback constant path
     * is exercised deterministically. Counter `hmacCacheLoadCount`
     * stays at 0 because no real SOQL ran.
     */
    @TestVisible private static Boolean testForceHmacCacheMiss = false;

    @TestVisible
    private static void resetDispatchCount() {
        dispatchCount = 0;
        agentDispatchCount = 0;
        dmlDispatchCount = 0;
        asyncSubmitCount = 0;
        queryDispatchCount = 0;
        callbackDispatchCount = 0;
    }

    @TestVisible
    private static void resetTestSeams() {
        testForceCpuFail = false;
        testForceHeapFail = false;
        testForceSoqlFail = false;
        testForceDmlFail = false;
        testForceCalloutFail = false;
        testForceAgentDispatchFail = false;
        testForceDmlDispatchFail = false;
        testForceAsyncSubmitFail = false;
        testForceQueryDispatchFail = false;
        testForceCacheFailure = false;
        testForceHmacCacheMiss = false;
        dispatchCount = 0;
        agentDispatchCount = 0;
        dmlDispatchCount = 0;
        asyncSubmitCount = 0;
        queryDispatchCount = 0;
        callbackDispatchCount = 0;
        inCallbackScope = false;
        hmacCacheLoaded = false;
        hmacCacheLoadCount = 0;
        cachedHmacCurrent = null;
        cachedHmacPrevious = null;
        cachedHmacRotatedAt = null;
        cachedJobIdMinterKey = null;
        cachedJobIdMinterKeyPrevious = null;
        hmacKeyMissingEventCount = 0;
        testForcedRetryDecisions = new Map<String, Boolean>();
        testForceConcurrentCapFail = false;
        testForceAttemptHashInMemory = false;
        inMemoryAttemptHashes = new Map<String, String>();
        concurrentCapCheckCount = 0;
        attemptHashStoreCount = 0;
        attemptHashLoadCount = 0;
    }

    public class LimitExceededException extends Exception {}

    /** Throws when CPU budget exceeded. Message: GOVERNOR_BUDGET_EXCEEDED:CPU. */
    public static void assertCpuOk() {
        if (testForceCpuFail) {
            throw new LimitExceededException('GOVERNOR_BUDGET_EXCEEDED:CPU');
        }
        Decimal used = Limits.getCpuTime();
        Decimal cap = Limits.getLimitCpuTime();
        if (used > CPU_BUDGET_PCT * cap) {
            throw new LimitExceededException('GOVERNOR_BUDGET_EXCEEDED:CPU');
        }
    }

    public static void assertHeapOk() {
        if (testForceHeapFail) {
            throw new LimitExceededException('GOVERNOR_BUDGET_EXCEEDED:HEAP');
        }
        Decimal used = Limits.getHeapSize();
        Decimal cap = Limits.getLimitHeapSize();
        if (used > HEAP_BUDGET_PCT * cap) {
            throw new LimitExceededException('GOVERNOR_BUDGET_EXCEEDED:HEAP');
        }
    }

    public static void assertSoqlOk() {
        if (testForceSoqlFail) {
            throw new LimitExceededException('GOVERNOR_BUDGET_EXCEEDED:SOQL');
        }
        if (Limits.getQueries() > SOQL_BUDGET_PCT * Limits.getLimitQueries()) {
            throw new LimitExceededException('GOVERNOR_BUDGET_EXCEEDED:SOQL');
        }
    }

    public static void assertDmlOk() {
        if (testForceDmlFail) {
            throw new LimitExceededException('GOVERNOR_BUDGET_EXCEEDED:DML');
        }
        if (Limits.getDmlStatements() > DML_BUDGET_PCT * Limits.getLimitDmlStatements()) {
            throw new LimitExceededException('GOVERNOR_BUDGET_EXCEEDED:DML');
        }
    }

    public static void assertCalloutOk() {
        if (testForceCalloutFail) {
            throw new LimitExceededException('GOVERNOR_BUDGET_EXCEEDED:CALLOUT');
        }
        if (Limits.getCallouts() > CALLOUT_BUDGET_PCT * Limits.getLimitCallouts()) {
            throw new LimitExceededException('GOVERNOR_BUDGET_EXCEEDED:CALLOUT');
        }
    }

    /**
     * Pre-parse byte estimate (UTF-16 chars × 2). Reject before JSON.deserialize
     * to avoid JSON-bomb DoS (Sec T-7).
     */
    public static void assertPayloadSizeOk(String payloadJson) {
        if (payloadJson == null) return;
        Integer approxBytes = payloadJson.length() * 2;
        if (approxBytes > MAX_PAYLOAD_BYTES) {
            throw new LimitExceededException('GOVERNOR_BUDGET_EXCEEDED:PAYLOAD');
        }
    }

    public static void assertBatchSizeOk(Integer requested, Integer cmdtMax) {
        Integer effectiveCap = Math.min(
            (cmdtMax == null ? 1 : cmdtMax),
            MAX_BATCH_HARD_CAP);
        if (requested > effectiveCap) {
            throw new LimitExceededException('GOVERNOR_BUDGET_EXCEEDED:BATCH');
        }
    }

    /**
     * Per-transaction dispatch counter. The gateway invokes once per Request
     * in a List<Request>; a single agent turn could enqueue many dispatches
     * (chained planner steps). Cap at 20 to keep CPU + heap within budget.
     */
    public static void assertDispatchCountOk() {
        dispatchCount++;
        if (dispatchCount > MAX_DISPATCHES_PER_TX) {
            throw new LimitExceededException('GOVERNOR_BUDGET_EXCEEDED:DISPATCH');
        }
    }

    /**
     * Sec G-Sec-AGENT-1: per-Tx agent dispatch counter. Tighter than the
     * general dispatch cap because each agent invocation runs an LLM callout
     * (seconds of wall-clock + dollar cost). Designed to allow planner →
     * specialist → reviewer chains while blocking runaway recursion.
     */
    public static void assertAgentDispatchCountOk() {
        if (testForceAgentDispatchFail) {
            throw new LimitExceededException('GOVERNOR_BUDGET_EXCEEDED:AGENT_DISPATCH');
        }
        agentDispatchCount++;
        if (agentDispatchCount > MAX_AGENT_DISPATCHES_PER_TX) {
            throw new LimitExceededException('GOVERNOR_BUDGET_EXCEEDED:AGENT_DISPATCH');
        }
    }

    /**
     * Sec G-Sec-DML-10: per-Tx DML adapter dispatch counter. Caps recursive
     * agent → DML fan-out (e.g. planner agent calls dml: → another agent →
     * dml: → ...). Tighter than the general dispatch cap because a single
     * DML dispatch may touch up to MAX_DML_RECORDS_PER_CALL rows across
     * heterogeneous SObjects in one Tx.
     */
    public static void assertDmlDispatchCountOk() {
        if (testForceDmlDispatchFail) {
            throw new LimitExceededException('GOVERNOR_BUDGET_EXCEEDED:DML_DISPATCH');
        }
        dmlDispatchCount++;
        if (dmlDispatchCount > MAX_DML_DISPATCHES_PER_TX) {
            throw new LimitExceededException('GOVERNOR_BUDGET_EXCEEDED:DML_DISPATCH');
        }
    }

    /**
     * Sec G-Sec-ASYNC-10: per-Tx async submit counter. Caps how many
     * async receipts a single user turn can emit so a single planner
     * call cannot saturate the platform Queueable slot ceiling across
     * a loop. Independent of dispatch/agent/dml counters so the failure
     * mode is unambiguously async-shaped.
     */
    public static void assertAsyncSubmitOk() {
        if (testForceAsyncSubmitFail) {
            throw new LimitExceededException('GOVERNOR_BUDGET_EXCEEDED:ASYNC_SUBMIT');
        }
        asyncSubmitCount++;
        if (asyncSubmitCount > MAX_ASYNC_SUBMITS_PER_TX) {
            throw new LimitExceededException('GOVERNOR_BUDGET_EXCEEDED:ASYNC_SUBMIT');
        }
    }

    /**
     * Sec G-Sec-QUERY-6: cap distinct queries per QueryAdapter call.
     * Bounds the fan-out shape of a single `query:<bundle>` payload.
     * Null `requested` is a no-op (caller hasn't parsed queries yet).
     */
    public static void assertQueriesOk(Integer requested) {
        if (requested != null && requested > MAX_QUERIES_PER_CALL) {
            throw new LimitExceededException(
                'GOVERNOR_BUDGET_EXCEEDED:QUERY_QUERIES');
        }
    }

    /**
     * Sec G-Sec-QUERY-8: cap LIMIT per individual query inside the bundle.
     * Adapter intersects with the per-bundle CMDT `MaxQueryRows__c` so
     * any admin-misconfigured CMDT value stays bounded.
     */
    public static void assertQueryRowsOk(Integer requested) {
        if (requested != null && requested > MAX_QUERY_ROWS_PER_CALL) {
            throw new LimitExceededException(
                'GOVERNOR_BUDGET_EXCEEDED:QUERY_ROWS');
        }
    }

    /**
     * Sec G-Sec-QUERY-10: per-Tx query adapter dispatch counter. Caps
     * recursive agent → query fan-out (mirrors DML topology). Tighter
     * than the general dispatch cap because a single query dispatch may
     * touch up to MAX_QUERIES_PER_CALL × MAX_QUERY_ROWS_PER_CALL rows
     * across heterogeneous SObjects in one Tx.
     */
    public static void assertQueryDispatchCountOk() {
        if (testForceQueryDispatchFail) {
            throw new LimitExceededException(
                'GOVERNOR_BUDGET_EXCEEDED:QUERY_DISPATCH');
        }
        queryDispatchCount++;
        if (queryDispatchCount > MAX_QUERY_DISPATCHES_PER_TX) {
            throw new LimitExceededException(
                'GOVERNOR_BUDGET_EXCEEDED:QUERY_DISPATCH');
        }
    }

    /**
     * Sec C-6 / G-Sec-ASYNC-6 anchor: derive a Platform Cache key for
     * the async result hydration path. Sanitised to [A-Za-z0-9_] ≤ 50
     * chars to match the org partition's key constraints. Stable for a
     * given jobId — StatusAdapter reads with the same derivation.
     */
    public static String asyncResultCacheKey(String jobId) {
        if (String.isBlank(jobId)) return 'async__noJob';
        String cleaned = jobId.replaceAll('[^A-Za-z0-9_]', '_');
        String prefixed = 'async__' + cleaned;
        return prefixed.length() > 50 ? prefixed.substring(0, 50) : prefixed;
    }

    /**
     * Sec G-Sec-DML-6: cap distinct groups per DML adapter call. Bounds the
     * fan-out shape of a single `dml:<bundle>` payload. Null `requested` is
     * a no-op (caller hasn't parsed groups yet).
     */
    public static void assertDmlGroupsOk(Integer requested) {
        if (requested != null && requested > MAX_DML_GROUPS_PER_CALL) {
            throw new LimitExceededException('GOVERNOR_BUDGET_EXCEEDED:DML_GROUPS');
        }
    }

    /**
     * Sec G-Sec-DML-8: cap total records across all groups in one DML call.
     * Null `requested` is a no-op. Records ceiling is the same as the
     * general batch hard cap so the dml: surface inherits the gateway's
     * volume contract.
     */
    public static void assertDmlRecordsOk(Integer requested) {
        if (requested != null && requested > MAX_DML_RECORDS_PER_CALL) {
            throw new LimitExceededException('GOVERNOR_BUDGET_EXCEEDED:DML_RECORDS');
        }
    }

    /**
     * Pre-DML guard: trip when `Limits.getDmlRows()` exceeds 80% of platform
     * cap. Called between groups in the DML adapter so a long chained-DML
     * payload aborts before the platform breaches.
     */
    public static void assertDmlRowsOk() {
        if (Limits.getDmlRows() > DML_ROWS_BUDGET_PCT * Limits.getLimitDmlRows()) {
            throw new LimitExceededException('GOVERNOR_BUDGET_EXCEEDED:DML_ROWS');
        }
    }

    /**
     * Deterministic sessionId derivation for the Agent dispatch surface
     * (docs/sf-agentic-gateway-agent-dispatch-2026-05-12.md §2). Used by
     * SF_AgenticGateway_AgentAdapter when the caller omits an explicit
     * sessionId in the payload — the derived value isolates sessions by
     * correlationId + agentApiName so cross-correlation bleed is impossible.
     *
     * Wave-3 SEC-1 rewire: consumes the cached HMAC current key via
     * `getHmacKeyCurrent()` so admin-controlled rotation propagates without
     * redeploy. The key is reused for isolation only (not authentication;
     * the Agentforce runtime owns real session identity).
     *
     * WP-SATA-2 fail-loud null contract: when the master HMAC key is
     * unavailable, `getHmacKeyCurrent()` returns null + fires the
     * HMAC_KEY_MISSING Platform Event. `computeHmacHex` then returns
     * null and THIS method returns null too rather than NPE'ing on
     * `hex.length()`. AgentAdapter callers MUST handle the null case
     * (caller-side fallback OR fail-loud throw — caller's choice).
     */
    public static String deriveAgentSessionId(String correlationId, String agentApiName) {
        String corr = (correlationId == null) ? '' : correlationId;
        String agent = (agentApiName == null) ? '' : agentApiName;
        String hex = computeHmacHex(corr + '|' + agent, getHmacKeyCurrent());
        if (hex == null) return null;
        return hex.length() > 32 ? hex.substring(0, 32) : hex;
    }

    /**
     * Sec C-5: HMAC-SHA256 with gateway-scoped key, hex-encoded, truncated
     * to 16 chars (32 hex chars worth of state but truncated for column
     * width). Raw error messages NEVER reach the audit table.
     *
     * Wave-3 SEC-1 rewire: consumes the cached HMAC current key via
     * `getHmacKeyCurrent()`; rotation flows from the Protected CMDT
     * row `SF_AgenticGateway_Secret.HMACKey` without code redeploy.
     *
     * WP-SATA-2 fail-loud null contract: returns null when the master
     * HMAC key is unavailable (getHmacKeyCurrent() returned null +
     * HMAC_KEY_MISSING PE already fired). Audit writers MUST treat
     * a null hash as a degraded-Tx signal — preferred behavior is
     * still to persist the audit row (success__c=false +
     * message__c='HMAC_KEY_MISSING' shape) so the operator dashboard
     * surfaces the gap. NEVER substitute a placeholder hash.
     */
    public static String hashMessage(String msg) {
        if (String.isBlank(msg)) return null;
        String hex = computeHmacHex(msg, getHmacKeyCurrent());
        if (hex == null) return null;
        return hex.length() > 16 ? hex.substring(0, 16) : hex;
    }

    /**
     * Wave-3 SEC-1 / SEC-2 helper — HMAC-SHA256 of `msg` under `key`,
     * hex-encoded (untruncated). Callers truncate to the column width
     * they need. Returns null when either input is null/blank so the
     * caller can defensively short-circuit.
     */
    private static String computeHmacHex(String msg, String key) {
        if (msg == null || String.isBlank(key)) return null;
        Blob mac = Crypto.generateMac(
            'HmacSHA256',
            Blob.valueOf(msg),
            Blob.valueOf(key));
        return EncodingUtil.convertToHex(mac);
    }

    /**
     * Wave-3 G-Sec-ASYNC-14: callback re-entry block. WorkerCore wraps
     * the reflective callback invoke in a try/finally that calls
     * `enterCallbackScope` / `exitCallbackScope`. While `inCallbackScope`
     * is true any caller of `SF_AgenticGateway.dispatchSync` MUST trip
     * `assertNotInCallbackScope` so a callback cannot re-enter the
     * gateway (counter cap = 0 re-dispatches).
     */
    public static void enterCallbackScope() {
        inCallbackScope = true;
        callbackDispatchCount++;
    }

    public static void exitCallbackScope() {
        inCallbackScope = false;
        callbackDispatchCount = 0;
    }

    /**
     * Wave-3 G-Sec-ASYNC-14: re-entry assertion. Throws
     * `LimitExceededException('CALLBACK_REENTRY_BLOCKED')` exactly —
     * test class `SF_AgenticGatewayCallbackReentryTest.testCallbackBlocksReentry`
     * matches that message verbatim. Callers (dispatchSync entry) invoke
     * this BEFORE any prefix-switch so every adapter is covered.
     */
    public static void assertNotInCallbackScope() {
        if (inCallbackScope) {
            throw new LimitExceededException('CALLBACK_REENTRY_BLOCKED');
        }
    }

    /**
     * Wave-3 G-Sec-ASYNC-15 + WP-L-Retry-Hardening AMENDED — transient-
     * exception classifier with CMDT-shape decision-table consulted FIRST,
     * wave-3 + WP-SATA-3 substring envelope SECOND.
     *
     * Order of operations (preserve-all-prior-contracts discipline):
     *   1. Null short-circuit (wave-3) → false.
     *   2. Test seam `testForcedRetryDecisions` Map walk — lets tests
     *      inject `(ExceptionType, MessagePrefixToken) → verdict` triples
     *      without recompiling the production Map.
     *   3. `RETRY_DECISION_TABLE` static-init Map walk — production
     *      decision-table; deterministic shape that an operator can hotfix
     *      by Apex redeploy of this Map (or by CMDT migration per
     *      FU-AGW-RETRY-DECISION-MDT-1 deferred to wave-4 because WBS row
     *      269 file list omits CMDT XML — Analyst lane).
     *   4. WP-SATA-3 Phase 1 permanent-failure substring envelope
     *      (BUNDLE_INACTIVE / BUNDLE_DEACTIVATED / DISPATCH_SYNC_BYPASS_BLOCKED
     *      → false) — PRESERVED VERBATIM. The decision-table walk above
     *      duplicates these entries for shape clarity, but the envelope
     *      stays as the canonical defense-in-depth substring guard for any
     *      future wrapping exception (CalloutException / DmlException) that
     *      preserves the deterministic error-code prefix in its message.
     *   5. Wave-3 baseline transient heuristics (UNABLE_TO_LOCK_ROW
     *      QueryException / DmlException; CalloutException blanket;
     *      LimitException with CALLOUT substring) — PRESERVED VERBATIM.
     *
     * CWE-754 closure: 4xx-class CMDT misconfigurations + dispatchSync
     * AllowList bypass throws now match the decision-table EXPLICITLY at
     * step 3 (RETRY_DECISION_TABLE entries) so the verdict is observable
     * at decision-table review time, not buried in a substring scan. The
     * step-4 envelope remains as backstop for wrapped exceptions.
     */
    public static Boolean classifyTransient(Exception e) {
        if (e == null) return false;
        String msg = (e.getMessage() == null) ? '' : e.getMessage();
        String typeName = (e.getTypeName() == null) ? '' : e.getTypeName();
        // Apex `Exception.getTypeName()` returns the fully-qualified
        // namespaced name (e.g. `SF_AgenticGateway.SF_AgenticGatewayException`
        // / `System.CalloutException`). Normalize to simple name + System.*
        // form for decision-table key shape stability.
        String simpleType = typeName.contains('.')
            ? typeName.substring(typeName.lastIndexOf('.') + 1)
            : typeName;
        String systemType = typeName.startsWith('System.')
            ? typeName : ('System.' + simpleType);

        // (2a) Test-seam EXPLICIT-token pass — walked FIRST so hotfix
        //      overrides (e.g. `System.CalloutException:UNAVAILABLE` →
        //      false) shadow both the substring envelope AND the
        //      production catch-all.
        Boolean seamExplicit = walkRetryDecisionMap(
            testForcedRetryDecisions, simpleType, systemType, msg, true);
        if (seamExplicit != null) return seamExplicit;
        // (2b) Production decision-table EXPLICIT-token pass — operator-
        //      editable via redeploy (or CMDT migration
        //      FU-AGW-RETRY-DECISION-MDT-1 wave-4).
        Boolean tableExplicit = walkRetryDecisionMap(
            RETRY_DECISION_TABLE, simpleType, systemType, msg, true);
        if (tableExplicit != null) return tableExplicit;

        // (3) WP-SATA-3 Phase 1 — permanent-failure short-circuit
        //     (G-Sec-DML-17 sibling closure of G-Sec-ASYNC-15 amendment).
        //     N-4 fix (sf-agentic-gateway-fixes-2026-05-26 RM Phase 1
        //     round 2): runs BEFORE the type-match catch-all pass so a
        //     wrapping exception whose catch-all says transient (e.g.
        //     System.CalloutException carrying `BUNDLE_INACTIVE` in
        //     the message) STILL classifies non-transient. The
        //     explicit-token passes above keep the override seam — an
        //     operator who *wants* CalloutException:BUNDLE_INACTIVE to
        //     be transient can add that explicit-token entry and it
        //     still wins. PRESERVED VERBATIM otherwise — substring
        //     match catches the canonical SF_AgenticGatewayException
        //     form AND any future wrapping (CalloutException /
        //     DmlException) where the message keeps the deterministic
        //     error-code prefix.
        if (msg.contains('BUNDLE_INACTIVE')
                || msg.contains('BUNDLE_DEACTIVATED')
                || msg.contains('DISPATCH_SYNC_BYPASS_BLOCKED')) {
            return false;
        }

        // (4a) Test-seam CATCH-ALL pass.
        Boolean seamCatchAll = walkRetryDecisionMap(
            testForcedRetryDecisions, simpleType, systemType, msg, false);
        if (seamCatchAll != null) return seamCatchAll;
        // (4b) Production decision-table CATCH-ALL pass.
        Boolean tableCatchAll = walkRetryDecisionMap(
            RETRY_DECISION_TABLE, simpleType, systemType, msg, false);
        if (tableCatchAll != null) return tableCatchAll;

        // (5) Wave-3 baseline transient heuristics — PRESERVED VERBATIM.
        if (e instanceof System.QueryException && msg.contains('UNABLE_TO_LOCK_ROW')) return true;
        if (e instanceof System.DmlException && msg.contains('UNABLE_TO_LOCK_ROW')) return true;
        if (e instanceof System.CalloutException) return true;
        if (e instanceof System.LimitException && msg.toUpperCase().contains('CALLOUT')) return true;
        return false;
    }

    /**
     * WP-L-Retry-Hardening G-Sec-ASYNC-15 AMENDED — decision-table walker.
     * Returns the matching verdict if either `<simpleType>:<msgPrefixToken>`
     * OR `<systemType>:<msgPrefixToken>` OR `<simpleType>:` (catch-all)
     * keys hit; null if no entry matches (caller falls through to the
     * substring envelope + baseline heuristics).
     *
     * MessagePrefixToken match is `String.contains(token)` so future
     * deterministic-code-prefix tokens (DML_FIELD_NOT_AUTHORIZED,
     * QUERY_FIELD_NOT_AUTHORIZED, etc.) work without parser changes.
     * Empty-token entry (`<TypeName>:`) is the catch-all for that type.
     *
     * N-4 amendment (sf-agentic-gateway-fixes-2026-05-26 RM Phase 1
     * round 2): walker now takes an `explicitTokenPass` flag so the
     * caller can interleave the WP-SATA-3 substring envelope between
     * the two passes (explicit-token first, envelope, then catch-all).
     * Closes the bug where `System.CalloutException:` catch-all
     * shadowed the envelope for messages like
     * `Upstream returned BUNDLE_INACTIVE for bundle X`.
     */
    private static Boolean walkRetryDecisionMap(
        Map<String, Boolean> table,
        String simpleType,
        String systemType,
        String msg,
        Boolean explicitTokenPass
    ) {
        if (table == null || table.isEmpty()) return null;
        for (String key : table.keySet()) {
            Integer colon = key.indexOf(':');
            if (colon <= 0) continue;
            String keyType = key.substring(0, colon);
            String keyToken = key.substring(colon + 1);
            Boolean isExplicit = keyToken.length() != 0;
            if (explicitTokenPass != isExplicit) continue;
            if (!(keyType.equals(simpleType) || keyType.equals(systemType))) continue;
            if (isExplicit) {
                if (msg.contains(keyToken)) return table.get(key);
            } else {
                return table.get(key);
            }
        }
        return null;
    }

    /**
     * WP-L-Retry-Hardening G-Sec-ASYNC-15 AMENDED — Platform Cache CAS-
     * narrowed concurrent-async-worker cap. Closes the race window where
     * two WorkerCore.runWorker hops both pass the wave-3 per-Tx dispatch
     * cap because each runs in a fresh Tx (different governor scopes).
     *
     * CAS narrowing (NOT a true atomic CAS; Apex Platform Cache exposes
     * no compare-and-swap primitive at API 66.0 — `Cache.OrgPartition`
     * methods are atomic per-call but compose non-atomically):
     *   1. Read current count from cache key `'concurrent:gateway'`.
     *   2. If >= MAX_CONCURRENT_ASYNC_JOBS → throw immediately (no write).
     *   3. Else `put` the incremented count + re-read to detect a racing
     *      writer; if re-read count > cap, throw (race-loser path).
     *
     * Counter is best-effort — under extreme concurrency two racing
     * writers may both observe count=cap-1, both increment to cap, with
     * the second `put` overwriting the first. The re-read narrows the
     * window to single-digit milliseconds. The PRIMARY containment is
     * still the wave-3 MAX_DISPATCHES_PER_TX + MAX_RETRIES_HARD_CAP +
     * MAX_ASYNC_SUBMITS_PER_TX cap suite; this is the SECOND-LINE defense
     * against cross-Tx fan-out under retry storms.
     *
     * Counter decrements are intentionally NOT implemented this WP —
     * decrement on success requires a try/finally wrapping the entire
     * runWorker body which is out of scope per WBS row 269 (touches
     * `attemptRetry` + `handleFailure` envelope; trampoline owns
     * decrement via TTL expiry instead). FU-AGW-CONCURRENT-CAP-DEC-1
     * tracks runWorker try/finally decrement for wave-4.
     *
     * Test seam `testForceConcurrentCapFail=true` short-circuits to throw
     * deterministically without Platform Cache provisioning.
     */
    public static void assertConcurrentCapOk() {
        concurrentCapCheckCount++;
        if (testForceConcurrentCapFail) {
            throw new LimitExceededException(
                'CONCURRENT_CAP_EXCEEDED:' + MAX_CONCURRENT_ASYNC_JOBS
                + ':' + MAX_CONCURRENT_ASYNC_JOBS);
        }
        Integer cap = MAX_CONCURRENT_ASYNC_JOBS;
        Integer currentCount = 0;
        try {
            Cache.OrgPartition partition = Cache.Org.getPartition(CACHE_PARTITION);
            Object raw = partition.get('concurrent:gateway');
            if (raw instanceof Integer) {
                currentCount = (Integer) raw;
            } else if (raw != null) {
                currentCount = Integer.valueOf(String.valueOf(raw));
            }
            if (currentCount >= cap) {
                throw new LimitExceededException(
                    'CONCURRENT_CAP_EXCEEDED:' + currentCount + ':' + cap);
            }
            Integer next = currentCount + 1;
            partition.put('concurrent:gateway', next, CACHE_TTL_SECONDS);
            // CAS-narrow: re-read to detect a racing writer. Window is
            // sub-millisecond on the same Apex Tx; cross-Tx race is the
            // residual escape per the design.
            Object reread = partition.get('concurrent:gateway');
            Integer rereadCount = 0;
            if (reread instanceof Integer) {
                rereadCount = (Integer) reread;
            } else if (reread != null) {
                rereadCount = Integer.valueOf(String.valueOf(reread));
            }
            if (rereadCount > cap) {
                throw new LimitExceededException(
                    'CONCURRENT_CAP_EXCEEDED:' + rereadCount + ':' + cap);
            }
        } catch (LimitExceededException lex) {
            throw lex;
        } catch (Exception cacheEx) {
            // Cache failure is non-fatal — the wave-3 per-Tx cap suite is
            // still the PRIMARY containment. Log + pass through so the
            // worker proceeds; CAS-narrow degrades to baseline wave-3.
            System.debug(LoggingLevel.WARN,
                '[SF_AgenticGateway_Limits.assertConcurrentCapOk] cache unavailable: '
                + cacheEx.getMessage());
        }
    }

    /**
     * WP-L-Retry-Hardening G-Sec-ASYNC-15 AMENDED — replay-guard attempt-
     * hash computation. HMAC-SHA256 over the audit row's identity tuple
     * `JobId__c|PayloadHash__c|RetryCount__c|AsyncStatus__c` under the
     * message-auth-derived key (NOT the JobIdMinter key — those are
     * distinct surfaces per WP-SATA-2 HKDF separation). 64-char hex.
     *
     * Two retries of the SAME `(jobId, payload, retryCount, status)`
     * tuple produce identical hashes; WorkerCore checks the cached hash
     * before dispatching to short-circuit replays (CWE-799 sibling
     * closure of CWE-754 retry amplification).
     *
     * Null-safe: returns null when `audit` is null OR when
     * `getHmacKeyCurrent()` returns null (master HMAC unavailable —
     * the wave-3 + WP-SATA-2 fail-loud PE already fired upstream). The
     * caller (RetryScheduler / WorkerCore) MUST treat null as a
     * degraded-Tx signal — preferred behavior is to skip the replay-guard
     * write/check (best-effort) and continue with the wave-3 retry
     * envelope, since hash-store-degradation should NOT block the worker.
     */
    public static String computeAttemptHash(SF_AgenticInvocation__c audit) {
        if (audit == null) return null;
        String key = getHmacKeyCurrent();
        if (String.isBlank(key)) return null;
        String jobId = (audit.JobId__c == null) ? '' : audit.JobId__c;
        String payloadHash = (audit.PayloadHash__c == null) ? '' : audit.PayloadHash__c;
        Integer retryCount = (audit.RetryCount__c == null) ? 0
            : audit.RetryCount__c.intValue();
        String status = (audit.AsyncStatus__c == null) ? '' : audit.AsyncStatus__c;
        String tuple = jobId + '|' + payloadHash + '|' + String.valueOf(retryCount)
            + '|' + status;
        return computeHmacHex(tuple, key);
    }

    /**
     * WP-L-Retry-Hardening G-Sec-ASYNC-15 AMENDED — Platform Cache write
     * for the per-jobId attempt-hash. Key: `'retry-attempt:' +
     * sanitisedJobId` (alphanumeric + underscore only, ≤ 50 chars per
     * the partition constraint). TTL: `RETRY_ATTEMPT_HASH_TTL_SECONDS`
     * (default 900s — exceeds full 5-hop retry envelope wall-clock).
     *
     * Best-effort: cache failure is non-fatal (log + pass-through). The
     * replay-guard short-circuit becomes a no-op if the store fails;
     * the wave-3 retry envelope still applies.
     *
     * Test seam `testForceAttemptHashInMemory=true` routes to the
     * `inMemoryAttemptHashes` Tx-scoped Map instead of Platform Cache
     * for deterministic test orgs without the partition provisioned.
     */
    public static void recordAttemptHash(String jobId, String hash) {
        if (String.isBlank(jobId) || String.isBlank(hash)) return;
        attemptHashStoreCount++;
        String key = attemptHashCacheKey(jobId);
        if (testForceAttemptHashInMemory) {
            inMemoryAttemptHashes.put(key, hash);
            return;
        }
        try {
            Cache.OrgPartition partition = Cache.Org.getPartition(CACHE_PARTITION);
            partition.put(key, hash, RETRY_ATTEMPT_HASH_TTL_SECONDS);
        } catch (Exception cacheEx) {
            System.debug(LoggingLevel.WARN,
                '[SF_AgenticGateway_Limits.recordAttemptHash] cache unavailable: '
                + cacheEx.getMessage());
        }
    }

    /**
     * WP-L-Retry-Hardening G-Sec-ASYNC-15 AMENDED — Platform Cache read
     * for the per-jobId attempt-hash. Returns null on cache miss / cache
     * failure / unprovisioned partition. Caller (WorkerCore replay guard)
     * compares the returned hash against `computeAttemptHash(audit)`;
     * equal-hash + AsyncStatus__c=='Retrying' = replay → short-circuit.
     */
    public static String loadAttemptHash(String jobId) {
        if (String.isBlank(jobId)) return null;
        attemptHashLoadCount++;
        String key = attemptHashCacheKey(jobId);
        if (testForceAttemptHashInMemory) {
            return inMemoryAttemptHashes.get(key);
        }
        try {
            Cache.OrgPartition partition = Cache.Org.getPartition(CACHE_PARTITION);
            Object raw = partition.get(key);
            return (raw == null) ? null : String.valueOf(raw);
        } catch (Exception cacheEx) {
            System.debug(LoggingLevel.WARN,
                '[SF_AgenticGateway_Limits.loadAttemptHash] cache unavailable: '
                + cacheEx.getMessage());
            return null;
        }
    }

    /**
     * WP-L-Retry-Hardening G-Sec-ASYNC-15 AMENDED — cache key sanitiser
     * for the per-jobId attempt-hash store. Mirrors `asyncResultCacheKey`
     * sanitisation rules (alphanumeric + underscore only, ≤ 50 chars).
     */
    private static String attemptHashCacheKey(String jobId) {
        String cleaned = jobId.replaceAll('[^A-Za-z0-9_]', '_');
        String prefixed = 'retry_attempt__' + cleaned;
        return prefixed.length() > 50 ? prefixed.substring(0, 50) : prefixed;
    }

    /**
     * Wave-3 G-Sec-ASYNC-15: exponential backoff seconds for retry
     * attempt N. Returns 60 / 120 / 240 / 480 / 480 / ... (2^attempt × 30
     * capped at 480). Caller passes `nextRetry = currentRetry + 1` so
     * attempt=1 maps to 60s, attempt=2 to 120s, etc.
     */
    public static Integer retryBackoffSeconds(Integer attempt) {
        Integer n = (attempt == null || attempt < 0) ? 0 : attempt;
        Integer base = 1;
        for (Integer i = 0; i < n && base < 16; i++) {
            base = base * 2;
        }
        return Math.min(480, base * 30);
    }

    /**
     * Wave-3 G-Sec-ASYNC-15: intersect the per-bundle CMDT
     * `AsyncMaxRetries__c` with `MAX_RETRIES_HARD_CAP=5`. Null / negative
     * CMDT collapses to 0 (retries disabled by default).
     */
    public static Integer effectiveMaxRetries(Integer cmdtValue) {
        Integer eff = (cmdtValue == null || cmdtValue < 0) ? 0 : cmdtValue;
        return Math.min(eff, MAX_RETRIES_HARD_CAP);
    }

    /**
     * Wave-3 G-Sec-SEC-1 + WP-SATA-2 G-Sec-SEC-1.1: cached current HMAC
     * master key. Loads from the Protected CMDT row
     * `SF_AgenticGateway_Secret.HMACKey` once per Tx. When the row is
     * missing / blank / SOQL failed, **no fallback constant is returned**
     * — the prior compile-time fallback literal was a CWE-798 hardcoded
     * credential and is GONE in WP-SATA-2. Instead this method now:
     * (a) logs `LoggingLevel.ERROR`, (b) emits
     * Platform Event `SF_AgenticGateway_Async__e Status__c='HMAC_KEY_MISSING'`
     * via `emitHmacKeyMissingEvent` for on-call alerting, (c) returns
     * `null`. Downstream callers (`hashMessage`, `verifyMessageHash`,
     * `getJobIdMinterHmacKey`, `deriveAgentSessionId`) MUST be null-safe
     * — the design contract is fail-loud, not silent-fallback.
     */
    public static String getHmacKeyCurrent() {
        ensureHmacCacheLoaded();
        if (String.isBlank(cachedHmacCurrent)) {
            System.debug(LoggingLevel.ERROR,
                '[SF_AgenticGateway_Limits] HMAC current master key blank — fail-loud (no fallback)');
            emitHmacKeyMissingEvent();
            return null;
        }
        return cachedHmacCurrent;
    }

    /**
     * Wave-3 G-Sec-SEC-2: cached previous HMAC key (may be null). Read
     * by `verifyMessageHash` during the rotation grace window.
     */
    public static String getHmacKeyPrevious() {
        ensureHmacCacheLoaded();
        return cachedHmacPrevious;
    }

    /**
     * Wave-3 G-Sec-SEC-2: rotation timestamp; null until first rotation.
     * `verifyMessageHash` rejects previous-key matches when
     * `(now - rotatedAt) > SEC_PREVIOUS_KEY_GRACE_DAYS`.
     */
    public static Datetime getHmacRotatedAt() {
        ensureHmacCacheLoaded();
        return cachedHmacRotatedAt;
    }

    /**
     * Wave-3 G-Sec-SEC-1: single-SOQL-per-Tx cache loader. Protected CMDT
     * is read in System Mode by design — Protected visibility blocks the
     * row from any non-System read, which is exactly the gateway HMAC
     * isolation contract (arch guide §6 sharing matrix). USER_MODE here
     * would break the Protected-CMDT read semantics.
     *
     * Test seam `testForceHmacCacheMiss=true` short-circuits before the
     * SOQL so the fallback branch is exercised deterministically. The
     * counter `hmacCacheLoadCount` increments ONLY on the real SOQL
     * branch so the test stays decoupled from `Limits.getQueries()`.
     */
    private static void ensureHmacCacheLoaded() {
        if (hmacCacheLoaded) return;
        if (testForceHmacCacheMiss) {
            hmacCacheLoaded = true;
            System.debug(LoggingLevel.WARN,
                '[SF_AgenticGateway_Limits] HMAC cache load skipped by test seam testForceHmacCacheMiss');
            return;
        }
        hmacCacheLoadCount++;
        try {
            List<SF_AgenticGateway_Secret__mdt> rows = [
                SELECT KeyHexCurrent__c, KeyHexPrevious__c, RotatedAt__c
                FROM SF_AgenticGateway_Secret__mdt
                WHERE DeveloperName = 'HMACKey'
                LIMIT 1
            ];
            if (!rows.isEmpty()) {
                cachedHmacCurrent = rows[0].KeyHexCurrent__c;
                cachedHmacPrevious = rows[0].KeyHexPrevious__c;
                cachedHmacRotatedAt = rows[0].RotatedAt__c;
            }
        } catch (Exception cacheEx) {
            System.debug(LoggingLevel.WARN,
                '[SF_AgenticGateway_Limits] HMAC cache load failed: ' + cacheEx.getMessage());
        }
        hmacCacheLoaded = true;
    }

    /**
     * @TestVisible test seam — inject HMAC key fixtures without deploying
     * a real Protected CMDT row. Tests call this in `Test.startTest()` /
     * `@TestSetup` to control the current key, previous key, and
     * rotation timestamp. Marks the cache as loaded so the real SOQL
     * does not fire.
     */
    @TestVisible
    private static void setMockHmacKey(String current, String previous, Datetime rotatedAt) {
        cachedHmacCurrent = current;
        cachedHmacPrevious = previous;
        cachedHmacRotatedAt = rotatedAt;
        hmacCacheLoaded = true;
    }

    /**
     * WP-SATA-2 G-Sec-SEC-1.1: HKDF-style derived sub-key for the
     * JobIdMinter audit-payload-bind path. Derivation = single-step
     * HMAC-SHA256(message=`JOBID_MINTER_SALT`, key=master). The hex
     * result is cached for the rest of the Tx.
     *
     * Failure semantics: when the master is blank, returns `null`.
     * The fail-loud Platform Event already fired inside
     * `getHmacKeyCurrent()` so this method does NOT emit a second
     * alert (call-site responsibility — `payloadHash` throws
     * `JOBID_HMAC_KEY_UNAVAILABLE` on null).
     */
    public static String getJobIdMinterHmacKey() {
        if (cachedJobIdMinterKey != null) return cachedJobIdMinterKey;
        // A-1 Dev defect closure (sf-agentic-gateway-fixes-2026-05-26 RM
        // Phase 1 round 2): route through `getHmacKeyCurrent()` so the
        // fail-loud `HMAC_KEY_MISSING` Platform Event fires on the
        // blank-master path. Prior implementation accessed
        // `cachedHmacCurrent` directly which BYPASSED the PE-emit +
        // ERROR-log inside `getHmacKeyCurrent`, leaving the
        // `payloadHash → JOBID_HMAC_KEY_UNAVAILABLE` throw observably
        // silent on the on-call surface (HMAC_KEY_MISSING PE never
        // fired). The docstring above already declared this
        // routing intent ("The fail-loud Platform Event already fired
        // inside `getHmacKeyCurrent()` so this method does NOT emit a
        // second alert") — code now aligned to docstring. Sec posture
        // verified ALIGNMENT (not widening) — restores the canonical
        // observability surface promised by the WP-SATA-2 design.
        String master = getHmacKeyCurrent();
        if (String.isBlank(master)) {
            // getHmacKeyCurrent already emitted HMAC_KEY_MISSING PE +
            // logged ERROR. NO second emit here (per docstring).
            return null;
        }
        Blob derived = Crypto.generateMac(
            'HmacSHA256',
            Blob.valueOf(JOBID_MINTER_SALT),
            Blob.valueOf(master));
        cachedJobIdMinterKey = EncodingUtil.convertToHex(derived);
        return cachedJobIdMinterKey;
    }

    /**
     * WP-SATA-2 G-Sec-SEC-1.1: HKDF-style derived previous sub-key for
     * dual-key rotation grace. Same salt as the current derivation; the
     * separation comes from the master rotation state (current vs
     * previous master), NOT from the salt.
     *
     * Returns null when no previous master is configured (pre-first-
     * rotation) or when the master is blank.
     */
    public static String getJobIdMinterHmacKeyPrevious() {
        ensureHmacCacheLoaded();
        if (cachedJobIdMinterKeyPrevious != null) return cachedJobIdMinterKeyPrevious;
        String master = cachedHmacPrevious;
        if (String.isBlank(master)) return null;
        Blob derived = Crypto.generateMac(
            'HmacSHA256',
            Blob.valueOf(JOBID_MINTER_SALT),
            Blob.valueOf(master));
        cachedJobIdMinterKeyPrevious = EncodingUtil.convertToHex(derived);
        return cachedJobIdMinterKeyPrevious;
    }

    /**
     * WP-SATA-2 G-Sec-SEC-2.3 / CWE-208: constant-time hex string
     * comparison. Iterates the FULL codepoint sequence and XOR-
     * accumulates into a running flag so the loop's execution time
     * does not depend on where the first byte mismatch occurs.
     *
     * Short-circuits before the loop only on:
     *   1. either input blank (return false; no secret to leak — both
     *      sides observably absent).
     *   2. length mismatch (return false; canonical pattern documented
     *      in Java `MessageDigest.isEqual` + Python `hmac.compare_digest`
     *      — comparing only equal-length hashes IS the contract).
     *
     * The hex-input shape (`[0-9a-fA-F]`) maps one codepoint per byte
     * via `String.getChars()`, so the XOR aggregate is byte-equivalent
     * to the Java reference implementation despite the Apex `Blob.get(i)`
     * primitive being unavailable (deviation from technical-design
     * §XL-2 literal — flagged in WP-SATA-2 delivery doc § PostMortem).
     */
    @TestVisible
    public static Boolean constantTimeEqualsHex(String a, String b) {
        if (String.isBlank(a) || String.isBlank(b)) return false;
        if (a.length() != b.length()) return false;
        Integer[] aChars = a.getChars();
        Integer[] bChars = b.getChars();
        Integer acc = 0;
        for (Integer i = 0; i < aChars.size(); i++) {
            acc |= (aChars[i] ^ bChars[i]);
        }
        return acc == 0;
    }

    /**
     * WP-SATA-2 G-Sec-SEC-1.1: fail-loud emitter. Publishes one
     * `SF_AgenticGateway_Async__e` Platform Event with
     * `Status__c='HMAC_KEY_MISSING'` (the literal fits the
     * `Status__c` text(16) column exactly) so on-call subscribers
     * (`SF_AgenticGateway_AsyncSubscriber`) surface the degraded path
     * to ops dashboards / Custom Notifications. Wrapped in `try/catch`
     * so a publish failure NEVER masks the upstream null return —
     * the caller (`getHmacKeyCurrent`) still returns null and
     * downstream callers still fail-loud via their own throw paths.
     *
     * `hmacKeyMissingEventCount` counter increments before the
     * `EventBus.publish` call so tests can assert blast radius
     * without subscribing to the PE (Salesforce PE delivery is async
     * and test-context-coupled; a counter is the deterministic
     * assertion seam).
     */
    private static void emitHmacKeyMissingEvent() {
        hmacKeyMissingEventCount++;
        try {
            SF_AgenticGateway_Async__e ev = new SF_AgenticGateway_Async__e(
                Status__c = HMAC_KEY_MISSING_STATUS);
            EventBus.publish(ev);
        } catch (Exception emitEx) {
            System.debug(LoggingLevel.ERROR,
                '[SF_AgenticGateway_Limits] HMAC_KEY_MISSING PE publish failed: '
                + emitEx.getMessage());
        }
    }

    /**
     * Wave-3 G-Sec-SEC-2 + WP-SATA-2 G-Sec-SEC-2.3: dual-key verification
     * envelope. Returns true when `expectedHash` matches the HMAC of `msg`
     * under either the current key OR (within `SEC_PREVIOUS_KEY_GRACE_DAYS`
     * of `RotatedAt__c`) the previous key. Outside the grace window the
     * previous-key path is closed.
     *
     * WP-SATA-2 hardening: every hash comparison routes through
     * `constantTimeEqualsHex` instead of a short-circuit equality
     * operator so the loop time leaks no information about WHERE the
     * first byte mismatches (CWE-208 timing closure). Both the full 64-char hex
     * and the 16-char truncated form are still accepted — the caller
     * (`SF_AgenticGateway.writeAudit` stores the truncated form,
     * the wave-3 envelope still verifies the untruncated form when
     * present).
     *
     * WP-L-Hmac-Hardening L-10 closure: ALL four `constantTimeEqualsHex`
     * call sites in this method body are the canonical wire surface;
     * no other `String.equals`/`==` hash-compare lingered across
     * `force-app/main/default/classes/` (`rg "[Hh]ash.{0,30}\\.equals\\|
     * [Hh]ash.{0,30}\\s*==\\s*"` returned zero hits at WP scope time).
     * Mirror wire on `WorkerCore.assertPayloadHashOk` landed via
     * WP-L-WorkerCore-Audit / FU-AGW-CWE208-WORKERCORE-1. L-10 closure
     * therefore verified by absence-of-remaining-sites at on-disk
     * snapshot time + transitive coverage of new
     * `testGivenTamperedHexHashWhenVerifyThenConstantTimeReject`.
     */
    public static Boolean verifyMessageHash(String msg, String expectedHash) {
        if (msg == null || expectedHash == null) return false;
        String candCurrent = computeHmacHex(msg, getHmacKeyCurrent());
        if (candCurrent != null) {
            String truncCurrent = candCurrent.length() > 16
                ? candCurrent.substring(0, 16) : candCurrent;
            if (constantTimeEqualsHex(candCurrent, expectedHash)
                || constantTimeEqualsHex(truncCurrent, expectedHash)) {
                return true;
            }
        }
        String prev = getHmacKeyPrevious();
        Datetime rotated = getHmacRotatedAt();
        if (String.isBlank(prev) || rotated == null) return false;
        Datetime cutoff = System.now().addDays(-SEC_PREVIOUS_KEY_GRACE_DAYS);
        if (rotated < cutoff) return false;
        String candPrev = computeHmacHex(msg, prev);
        if (candPrev == null) return false;
        String truncPrev = candPrev.length() > 16
            ? candPrev.substring(0, 16) : candPrev;
        return constantTimeEqualsHex(candPrev, expectedHash)
            || constantTimeEqualsHex(truncPrev, expectedHash);
    }

    /**
     * WP-L-Hmac-Hardening L-4 partial — canonical message-truncation
     * helper. Caps `msg` at `MAX_MESSAGE_CHARS=256` chars; null-safe
     * (returns null on null input; blank strings pass through verbatim
     * so the caller still observes a deterministic empty marker rather
     * than a synthesised sentinel). Shorter-than-cap inputs pass
     * through unchanged so the forensic-SOQL `WHERE message__c LIKE
     * 'CODE:%'` bounded-prefix pattern keeps observing the raw value.
     *
     * Canonical landing for the scattered Wave 1+2 truncation pattern
     * `String.substring(0, Math.min(256, msg.length()))` distributed
     * across `WorkerCore.sanitizeMessage` (line ~517) +
     * `WorkerCore.handleFailure` (line ~533) + `CallbackInvoker.
     * markInvalid` (line ~203) + `CallbackInvoker.markFailed` (line
     * ~236) + `QueryAdapter` reject envelope (line ~772). Call-site
     * adoption deferred to FU-AGW-SANITIZE-MSG-CALLSITE-1 because WBS
     * row 288 file-list scopes THIS WP to `Limits.cls` only (L-4
     * "partial" framing) AND WorkerCore.cls Wave 2 serialization is
     * CLOSED per TL WBS § Cross-WP file overlap risk matrix line 471
     * — further WorkerCore.cls edits sequenced to Stage C. This helper
     * is the canonical landing so downstream WPs / Stage C M-* tail
     * can flip call sites without re-authoring the truncation rule.
     *
     * `SF_AgenticGateway_DmlAdapter.truncateMessage` (line ~941) keeps
     * its 255-char private helper intact — `SF_AgenticGateway_DmlResult__c.
     * Message__c` is a text(255) column (1 char shorter than
     * `SF_AgenticInvocation__c.message__c`), so adopting this 256-cap
     * helper there would risk a deploy-time overflow. Column-width
     * widening tracked as FU-AGW-DML-RESULT-MSG-WIDEN-1 follow-up
     * (Analyst-lane XML).
     */
    public static String sanitizeMessage(String msg) {
        if (msg == null) return null;
        return msg.length() > MAX_MESSAGE_CHARS
            ? msg.substring(0, MAX_MESSAGE_CHARS)
            : msg;
    }

    /**
     * If serialized result exceeds MAX_RESPONSE_BYTES, spill to Platform
     * Cache (org partition `local.SfAgentic`, TTL 300s) and return a
     * dataRef-based summary wrapper. Otherwise return the raw result wrapped
     * with `truncated=false`. Sec C-6: cache key includes correlationId so
     * cross-correlation reads can be rejected by the consumer.
     *
     * Fallback: if the cache partition is not provisioned (org never
     * configured the partition), truncate the serialized payload to
     * FALLBACK_TRUNCATE_BYTES rather than failing the dispatch — preserves
     * forward progress at the cost of context fidelity.
     */
    public static Map<String, Object> truncateOrSpill(Object result, String correlationId) {
        String dataJson = (result == null) ? null : JSON.serialize(result);
        Integer approxBytes = (dataJson == null) ? 0 : dataJson.length() * 2;

        if (approxBytes <= MAX_RESPONSE_BYTES) {
            return new Map<String, Object>{
                'summary' => null,
                'dataRef' => null,
                'truncated' => false,
                'data' => result
            };
        }

        String safeCorrId = String.isBlank(correlationId) ? 'noCorr' : correlationId;
        String key = sanitizeCacheKey(safeCorrId + '-' + String.valueOf(Crypto.getRandomLong()));
        String summary = dataJson.length() > SUMMARY_CHARS
            ? dataJson.substring(0, SUMMARY_CHARS)
            : dataJson;

        try {
            if (testForceCacheFailure) {
                throw new LimitExceededException('GOVERNOR_BUDGET_EXCEEDED:CACHE');
            }
            Cache.OrgPartition partition = Cache.Org.getPartition(CACHE_PARTITION);
            partition.put(key, dataJson, CACHE_TTL_SECONDS);
            return new Map<String, Object>{
                'summary' => summary,
                'dataRef' => key,
                'truncated' => true
            };
        } catch (Exception cacheEx) {
            Integer fallbackChars = FALLBACK_TRUNCATE_BYTES / 2;
            String truncated = dataJson.length() > fallbackChars
                ? dataJson.substring(0, fallbackChars)
                : dataJson;
            return new Map<String, Object>{
                'summary' => summary,
                'dataRef' => null,
                'truncated' => true,
                'data' => truncated
            };
        }
    }

    /**
     * Cache keys must be alphanumeric + underscore only. Replace anything
     * else (correlationIds may include hyphens, colons, dots from caller
     * convention) with underscores. Bound length to 50 chars (Platform
     * Cache key constraint).
     */
    private static String sanitizeCacheKey(String raw) {
        String cleaned = raw.replaceAll('[^A-Za-z0-9_]', '_');
        return cleaned.length() > 50 ? cleaned.substring(0, 50) : cleaned;
    }
}