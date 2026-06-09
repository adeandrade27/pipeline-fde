/**
 * SF_AgenticGateway — single Invocable touchpoint for all Agentforce agents.
 *
 * Receives a Request with a handlerClass name (must clear the CMDT-backed
 * allow-list `SF_AgenticGateway_Allow__mdt`) and a JSON payload, then
 * routes the call to one of seven sync dispatch surfaces OR the new
 * `status:` read-side surface, OR the async submit pipeline based on
 * the CMDT `AsyncMode__c` selector:
 *
 *   <bare> | apex:<name>  → ISF_AgenticHandler reflection (existing path)
 *   flow:<api-name>       → SF_AgenticGateway_FlowAdapter (autolaunched)
 *   ip:<vip-name>         → SF_AgenticGateway_VipAdapter (Solar trampoline)
 *   dr:<dr-name>          → SF_AgenticGateway_VipAdapter (Solar trampoline)
 *   agent:<agentApiName>  → SF_AgenticGateway_AgentAdapter (Agentforce)
 *   dml:<bundle>          → SF_AgenticGateway_DmlAdapter (multi-SObject DML)
 *   query:<bundle>        → SF_AgenticGateway_QueryAdapter (multi-query SOQL bundle)
 *   status:<jobId>        → SF_AgenticGateway_StatusAdapter (USER_MODE pull)
 *
 * CMDT `AsyncMode__c` ∈ {Sync, Async, PayloadOptIn} controls whether the
 * 6 sync prefixes route inline (today's path, preserved byte-for-byte) or
 * detour through `SF_AgenticGateway_AsyncDispatcher.submit` for a
 * Queueable/Future worker. PayloadOptIn honours per-call `"async":true`
 * with Sync winning when AsyncMode=Sync (G-Sec-ASYNC-1).
 *
 * Request/Response field set is byte-for-byte preserved (P1 in PO Story);
 * the bot UI wiring depends on it.
 *
 * Defense-in-depth (see SA+TA design §6 + Sec threat model §3 + agent
 * dispatch design docs/sf-agentic-gateway-agent-dispatch-2026-05-12.md §3
 * + async selector design docs/sf-agentic-gateway-async-selector-2026-05-14.md §6):
 *   - G-Sec-1: prefix parser whitelist {apex|flow|ip|dr|agent|dml|query|status}
 *   - G-Sec-2: CMDT row Active=true AND DispatchType matches prefix
 *   - G-Sec-3: Apex path Type.forName + instanceof ISF_AgenticHandler
 *   - G-Sec-4: Flow path ProcessType=AutoLaunchedFlow
 *   - G-Sec-5: VIP path target name flows verbatim from CMDT
 *   - G-Sec-7: stack traces NEVER propagated; only TypeName + getMessage()
 *   - G-Sec-9: payload byte cap pre-checked before any JSON parse
 *   - G-Sec-AGENT-1..4: see SF_AgenticGateway_AgentAdapter docblock
 *   - G-Sec-DML-1..14: see SF_AgenticGateway_DmlAdapter docblock
 *   - G-Sec-QUERY-1..14: see SF_AgenticGateway_QueryAdapter docblock
 *   - G-Sec-ASYNC-1: AsyncMode default Sync; PayloadOptIn caller flag honoured only when CMDT says so
 *   - G-Sec-ASYNC-2: status: never bypasses authorization; USER_MODE SOQL inside StatusAdapter
 *   - G-Sec-ASYNC-3: jobId server-minted; caller-supplied jobIds rejected
 *   - G-Sec-ASYNC-4: worker runs under enqueueing user; no impersonation
 *   - G-Sec-ASYNC-5: per-user concurrent cap enforced pre-enqueue
 *   - G-Sec-ASYNC-6: result TTL double-gated (Platform Cache TTL ≤ audit ceiling)
 *   - G-Sec-ASYNC-7: worker exceptions sanitised; ≤256 char message; MessageHash
 *   - G-Sec-ASYNC-8: PayloadHash HMAC re-verified at worker entry
 *   - G-Sec-ASYNC-9: status: NEVER echoes original payload
 *   - G-Sec-ASYNC-10: per-Tx async submit counter (MAX_ASYNC_SUBMITS_PER_TX=10)
 *   - G-Sec-ASYNC-11: worker CPU + callout pre-check on entry
 *   - G-Sec-ASYNC-12: dml: + agent: re-run their gates inside the worker
 *   - G-Sec-L-15: correlationId sanitization regex [a-zA-Z0-9-]{1,64} —
 *       non-blank values failing the regex are rejected with deterministic
 *       `CORRELATION_ID_INVALID:<32-char-prefix>` BEFORE prefix parse +
 *       AllowList lookup (CWE-359 linkability + LINDDUN § L.1; WP-L-Sanitization L-15).
 *   - G-Sec-L-23: isAsyncRequested fail-CLOSED on JSON parse failure —
 *       System.JSONException is no longer swallowed; throws
 *       `PAYLOAD_PARSE_ERROR:<64-char-msg>` so the audit row captures
 *       success=false with deterministic code shape (CWE-754 silent-error
 *       removal; WP-L-Sanitization L-23).
 *   - C-5: audit MessageHash is HMAC-SHA256 truncated; raw never stored
 */
public with sharing class SF_AgenticGateway {

    public class SF_AgenticGatewayException extends Exception {}

    public class Request {
        @InvocableVariable(required=true label='Handler Class Name'
            description='Dispatch target. Bare value or prefixed: apex:|flow:|ip:|dr:|agent:|dml:|query:. Must be allow-listed in SF_AgenticGateway_Allow__mdt.')
        public String handlerClass;

        @InvocableVariable(required=true label='Payload JSON'
            description='JSON-encoded payload string. Format depends on handlerClass contract. Optional batch[] array supported when CMDT MaxBatchSize > 1.')
        public String payloadJson;

        @InvocableVariable(label='Correlation ID'
            description='Optional opaque correlation identifier; echoed back in response and persisted to SF_AgenticInvocation__c.')
        public String correlationId;
    }

    public class Response {
        @InvocableVariable(label='Success'
            description='True only if the handler/adapter executed and returned without exception.')
        public Boolean success;

        @InvocableVariable(label='Data JSON'
            description='JSON-encoded dispatch result. Null if success=false. Oversize results spilled to Platform Cache; see truncated/dataRef wrapper.')
        public String dataJson;

        @InvocableVariable(label='Message'
            description='Error type + message when success=false. Stack traces are intentionally omitted.')
        public String message;

        @InvocableVariable(label='Correlation ID'
            description='Echo of the request correlation ID (or null if not provided).')
        public String correlationId;
    }

    /**
     * Legacy hardcoded allow-list — RUNTIME source-of-truth has moved to
     * `SF_AgenticGateway_Allow__mdt` via SF_AgenticGateway_AllowList. This
     * Set remains as compile-time documentation of the v9 + post-rewire
     * baseline AND as the dependency anchor for the existing test class
     * `SF_AgenticGatewayTest.testAllowListBehaviorEachListedHandlerAccepted`
     * which asserts size matches and contains each entry.
     *
     * 2026-05-10 — agente-diagnostico-financeiro source-rewire (PM Gate 2
     * Revision 2 §R2.1–R2.5; joint locked design §6 component map): set
     * shrunk from 13 → 8 entries. 5 new adapters take over the 10 dropped
     * compressed-bot stubs; 3 surviving stubs (Q6=keep_all per PM Gate 2
     * Revision 1) retained byte-identical.
     *
     * 2026-05-11 — sf-financial-diagnose-poc-scope-2026-05-11 sole-handler
     * re-architecture (joint locked design §2.5 + §3.1): adds
     * `SF_FinancialDiagnosePocScope` as the 9th entry — the sole handler
     * dispatched by the new `SF_FinancialDiagnosePocScope_v2` planner
     * bundle bound to `SF_FinancialDiagnosticCompressed` BotVersion v2.
     * The 8 pre-existing entries remain in the Set as compile-time
     * documentation; runtime activation is gated by the CMDT
     * `Active__c` toggle (the 13 legacy `SF_FinDiag*` CMDT rows are
     * flipped to `Active__c=false` by the Analyst WP-B deliverable).
     * The 9 names here MUST stay in sync with the active Apex-dispatch
     * CMDT records under
     * force-app/main/default/customMetadata/SF_AgenticGateway_Allow.*.
     *
     * 2026-05-12 — sf-agentic-gateway-agent-dispatch-2026-05-12 (joint
     * locked design): adds the fifth dispatch surface `agent:` for
     * Agentforce agent invocation via `Invocable.Action` /
     * `generateAiAgentResponse`. Agent targets are CMDT-only (no entry
     * in this compile-time Set): the runtime AllowList gates them by
     * `DispatchType__c='Agent'` + `Active__c=true`. This Set continues
     * to document only the Apex-dispatch baseline.
     */
    @TestVisible
    private static final Set<String> ALLOWED_HANDLERS = new Set<String>{
        // 5 new adapters (joint locked design 2026-05-08 §5)
        'InvoiceFromAccountAdapter',
        'InvoiceDetailsAdapter',
        'Customer360Aggregator',
        'InteractionHistoryAggregator',
        'CaseUpdateSharingAdapter',
        // 3 surviving stubs (Q6=keep_all)
        'SF_FinDiagCaseRouteHandler',
        'SF_FinDiagOnScreenCtxHandler',
        'SF_FinDiagPriceLookupHandler',
        // sf-financial-diagnose-poc-scope-2026-05-11 sole-handler addition
        'SF_FinancialDiagnosePocScope',
        // findiag-billing-actions-wiring-2026-05-28: new handler routed at
        // apex:SF_FinDiagInvoiceDetailsHandler — decoupled from the legacy
        // AgentInvoiceDetailsAction chain (Path B SAFER user choice). Parity
        // test SF_AgenticGatewayTest.testAllowListBehaviorEachListedHandlerAccepted
        // exercises this entry alongside the prior 9.
        'SF_FinDiagInvoiceDetailsHandler',
        // findiag-historical-handler-2026-05-29: new handler routed at
        // apex:SF_FinDiagHistoricalInvoicesHandler — decoupled from the
        // legacy AgentInvoicesAction invocable (Path B SAFER continuation).
        // Replaces the ip:SolarFIN_getResidentialInvoices route which is
        // flipped to Active=false in the same scope (CMDT deactivation,
        // Analyst WP-2). Set size bumps 10 → 11; parity test
        // testAllowListBehaviorEachListedHandlerAccepted iterates the new
        // entry alongside the prior 10 per L-1.
        'SF_FinDiagHistoricalInvoicesHandler',
        // sf-agentic-gateway-smoke-template-2026-05-29 WP-1: smoke fixture
        // handlers for production-readiness validation (SA+TA joint
        // technical-design §1.1–§1.3). All `public with sharing` per Sec C-2.
        // Round-1 fix (rm-validate-r1-bug §3 F-3..5): Target__c is schema-
        // unique on SF_AgenticGateway_Allow__mdt, so the original B-3
        // pragmatic-exit "share Target__c across async variants" was invalid
        // — three wrapper classes (Queueable / Future / OptIn) now delegate
        // to the canonical SfAgwSmokeEchoApex, each with its own distinct
        // CMDT row + Target__c value. CMDT rows (11 total) ship Active=true
        // for QA + soak, flipped to Active=false at PM Gate 4 closeout per
        // Sec C-3. Set size 11 → 17; parity test extended to iterate the new
        // 6 smoke entries.
        'SfAgwSmokeEchoApex',
        'SfAgwSmokeEchoApexQueueable',
        'SfAgwSmokeEchoApexFuture',
        'SfAgwSmokeEchoApexOptIn',
        'SfAgwSmokeBatchHandler',
        'SfAgwSmokeCallback'
    };

    private static final String PREFIX_APEX = 'apex';
    private static final String PREFIX_FLOW = 'flow';
    private static final String PREFIX_IP = 'ip';
    private static final String PREFIX_DR = 'dr';
    private static final String PREFIX_AGENT = 'agent';
    private static final String PREFIX_DML = 'dml';
    private static final String PREFIX_QUERY = 'query';
    private static final String PREFIX_STATUS = 'status';
    private static final Set<String> KNOWN_PREFIXES = new Set<String>{
        PREFIX_APEX, PREFIX_FLOW, PREFIX_IP, PREFIX_DR,
        PREFIX_AGENT, PREFIX_DML, PREFIX_QUERY, PREFIX_STATUS
    };

    private static final String ASYNC_MODE_SYNC = 'Sync';
    private static final String ASYNC_MODE_ASYNC = 'Async';
    private static final String ASYNC_MODE_PAYLOAD_OPTIN = 'PayloadOptIn';

    /**
     * WP-L-Sanitization L-15 (audit finding L-15 / CWE-359) — correlationId
     * sanitization regex. Allow-list charset `[a-zA-Z0-9-]` bounded to
     * 1..64 chars; rejects email, JWT, path, whitespace, and other
     * linkability-enabling shapes per Sec threat model LINDDUN § L.1.
     *
     * `Pattern.compile` cached in a static field per Apex regex perf
     * best-practice — `invoke` accepts `List<Request>` and a bulk
     * Invocable batch would otherwise re-compile this regex per Request.
     * Pattern instances in Apex are immutable + thread-safe within a
     * transaction so static reuse is canonical (see SA+TA technical
     * design § L-15 + Sec card § Card · WP-L-Sanitization).
     *
     * `CORRELATION_ID_TRUNCATE_CHARS=32` bounds the log surface of the
     * rejection audit message: caller-supplied bytes are echoed back
     * truncated so a 4KB email-shaped value does NOT bloat the audit
     * row or downstream observability sink.
     *
     * `PAYLOAD_PARSE_ERROR_MSG_CHARS=64` bounds the `getMessage()` echo
     * inside the L-23 throw (avoid mirroring an attacker-controlled
     * giant malformed-JSON tail back into the audit row).
     */
    private static final Pattern CORRELATION_ID_PATTERN =
        Pattern.compile('[a-zA-Z0-9\\-]{1,64}');
    private static final Integer CORRELATION_ID_TRUNCATE_CHARS = 32;
    private static final Integer PAYLOAD_PARSE_ERROR_MSG_CHARS = 64;

    /**
     * WP-L-Dispatcher-Drift Phase 1 (audit finding L-5): polymorphic
     * adapter registry replacing the wave-3 prefix `if/else` chain
     * inside `dispatchSync`. Each entry is a singleton instance of
     * the matching `IAgenticAdapter` implementer; the same registry
     * key vocabulary as `KNOWN_PREFIXES` minus `status` (status
     * dispatches at `invokeOne` lines 202-213 BEFORE reaching
     * dispatchSync, so the registry only carries the 7 sync-routable
     * prefixes).
     *
     * `ip` and `dr` both point to `SF_AgenticGateway_VipAdapter` — the
     * adapter's `dispatch` body reads `args.get('prefix')` to
     * disambiguate between `invokeIp` and `invokeDr` static
     * delegations.
     *
     * `apex` points to the inner `ApexHandlerAdapter` private class
     * below — wraps the existing `dispatchApex` private reflection
     * path (`Type.forName` + `ISF_AgenticHandler.handle`) verbatim so
     * the wave-3 G-Sec-3 reflection gate stays in-line.
     *
     * Sec G-Sec gates preserved at the boundary BEFORE the registry
     * lookup: `assertNotInCallbackScope` (line 299, wave-3
     * G-Sec-ASYNC-14) + WP-SATA-3 G-Sec-DML-17 runtime AllowList
     * re-check (lines 314-318) both fire BEFORE the polymorphic
     * dispatch — the registry is the SECOND line; AllowList re-check
     * is the FIRST line.
     */
    private static final Map<String, IAgenticAdapter> ADAPTER_REGISTRY =
        new Map<String, IAgenticAdapter>{
            PREFIX_APEX  => new ApexHandlerAdapter(),
            PREFIX_FLOW  => new SF_AgenticGateway_FlowAdapter(),
            PREFIX_IP    => new SF_AgenticGateway_VipAdapter(),
            PREFIX_DR    => new SF_AgenticGateway_VipAdapter(),
            PREFIX_AGENT => new SF_AgenticGateway_AgentAdapter(),
            PREFIX_DML   => new SF_AgenticGateway_DmlAdapter(),
            PREFIX_QUERY => new SF_AgenticGateway_QueryAdapter()
        };

    @InvocableMethod(
        label='SF Agentic Gateway'
        description='Single safe touchpoint for all Agentforce agents. Routes requests to allow-listed handlers via reflection.'
        category='Agentforce')
    public static List<Response> invoke(List<Request> requests) {
        List<Response> responses = new List<Response>();
        if (requests == null) return responses;
        for (Request req : requests) {
            responses.add(invokeOne(req));
        }
        return responses;
    }

    private static Response invokeOne(Request req) {
        Response resp = new Response();
        if (req == null) {
            resp.success = false;
            resp.message = 'SF_AgenticGatewayException: Request is null';
            return resp;
        }
        resp.correlationId = req.correlationId;

        Long cpuAtStart = Limits.getCpuTime();
        String prefix = null;
        String target = null;
        Integer batchSize = 1;
        Boolean truncated = false;
        Boolean asyncOrStatusBranch = false;

        // BUG-2026-06-01 (sf-agentic-gateway-savepoint-callout-fix): savepoint
        // is now acquired LAZILY, only for the `dml` prefix, immediately before
        // dispatchSync. `Database.setSavepoint()` counts as DML for callout
        // ordering, so holding one across a callout dispatch (ip/dr/agent/flow,
        // or an apex: handler wrapping an IP/HTTP callout) makes the callout
        // throw "uncommitted work pending" — OmniStudio swallows it to
        // {success:false,error:""}. DmlAdapter self-manages its own inner
        // savepoint; query/status are read-only; so the gateway-boundary
        // savepoint is needed only as belt-and-suspenders for the dml: contract.
        Savepoint sp = null;
        try {
            SF_AgenticGateway_Limits.assertDispatchCountOk();
            SF_AgenticGateway_Limits.assertPayloadSizeOk(req.payloadJson);

            // G-Sec-L-15 (WP-L-Sanitization; CWE-359; LINDDUN § L.1):
            // correlationId sanitization. Blank/null is ACCEPTED — the
            // writeAudit sentinel `'noCorr-' + Crypto.getRandomLong()`
            // (line 510) backfills a server-minted opaque value so audit
            // rows still join correctly. Non-blank caller-supplied values
            // MUST clear `[a-zA-Z0-9-]{1,64}`; otherwise reject with
            // deterministic `CORRELATION_ID_INVALID:<32-char-prefix>` so
            // the standard catch + writeAudit pipeline captures
            // `success=false` + the truncated echo (no email/JWT/path tail
            // leaks downstream). Gate fires BEFORE `parsePrefix` so
            // sanitization is observed at the earliest possible boundary
            // — prefix parse failure on a poison correlationId would
            // otherwise burn the audit signal in the wrong order.
            if (!String.isBlank(req.correlationId)
                && !CORRELATION_ID_PATTERN.matcher(req.correlationId).matches()) {
                Integer endIdx = Math.min(
                    CORRELATION_ID_TRUNCATE_CHARS,
                    req.correlationId.length());
                String truncatedCorrId = req.correlationId.substring(0, endIdx);
                throw new SF_AgenticGatewayException(
                    'CORRELATION_ID_INVALID:' + truncatedCorrId);
            }

            ParsedTarget parsed = parsePrefix(req.handlerClass);
            prefix = parsed.prefix;
            target = parsed.target;
            batchSize = countBatch(req.payloadJson);

            // G-Sec-ASYNC-2: status: prefix is read-side, no CMDT row
            // required; per-row visibility enforced by USER_MODE SOQL
            // inside the StatusAdapter. AllowList.isAuthorized special-
            // cases status to always return true.
            if (PREFIX_STATUS.equals(prefix)) {
                if (!SF_AgenticGateway_AllowList.isAuthorized(target, prefix)) {
                    throw new SF_AgenticGatewayException(
                        'Status not authorised: ' + req.handlerClass);
                }
                Map<String, Object> statusWrapped =
                    SF_AgenticGateway_StatusAdapter.invoke(
                        target, req.payloadJson, req.correlationId);
                truncated = (Boolean) statusWrapped.get('truncated');
                resp.success = true;
                resp.dataJson = JSON.serialize(statusWrapped);
                asyncOrStatusBranch = true;
            } else {
                if (!SF_AgenticGateway_AllowList.isAuthorized(target, prefix)) {
                    throw new SF_AgenticGatewayException(
                        'Handler not in allow-list: ' + req.handlerClass);
                }

                Integer maxBatch = SF_AgenticGateway_AllowList.maxBatch(target);

                SF_AgenticGateway_Limits.assertCpuOk();
                SF_AgenticGateway_Limits.assertHeapOk();

                // G-Sec-ASYNC-1: AsyncMode selector. Sync wins by default
                // and when AsyncMode=Sync regardless of payload flag.
                String asyncMode = SF_AgenticGateway_AllowList.asyncMode(target);
                Boolean asyncResolved = false;
                if (ASYNC_MODE_ASYNC.equalsIgnoreCase(asyncMode)) {
                    asyncResolved = true;
                } else if (ASYNC_MODE_PAYLOAD_OPTIN.equalsIgnoreCase(asyncMode)) {
                    asyncResolved = isAsyncRequested(req.payloadJson);
                }

                if (asyncResolved) {
                    // AsyncDispatcher.submit owns its own SF_AgenticInvocation__c
                    // row; we skip the sync writeAudit to avoid duplicates.
                    Map<String, Object> asyncWrapped =
                        SF_AgenticGateway_AsyncDispatcher.submit(
                            prefix, target, req.payloadJson, req.correlationId);
                    truncated = (Boolean) asyncWrapped.get('truncated');
                    resp.success = true;
                    resp.dataJson = JSON.serialize(asyncWrapped);
                    asyncOrStatusBranch = true;
                } else {
                    // BUG-2026-06-01: acquire the rollback savepoint ONLY for
                    // the multi-SObject DML dispatch — never before a callout
                    // dispatch (see invokeOne savepoint docblock above).
                    if (PREFIX_DML.equals(prefix)) {
                        sp = Database.setSavepoint();
                    }
                    Object rawResult = dispatchSync(
                        prefix, target, req.payloadJson, req.correlationId, maxBatch);
                    Map<String, Object> wrapped =
                        SF_AgenticGateway_Limits.truncateOrSpill(rawResult, req.correlationId);
                    truncated = (Boolean) wrapped.get('truncated');
                    resp.success = true;
                    resp.dataJson = JSON.serialize(wrapped);
                }
            }
        } catch (SF_AgenticGateway_Limits.LimitExceededException limEx) {
            if (sp != null) Database.rollback(sp);
            resp.success = false;
            resp.message = limEx.getTypeName() + ': ' + limEx.getMessage();
        } catch (Exception e) {
            if (sp != null) Database.rollback(sp);
            resp.success = false;
            resp.message = e.getTypeName() + ': ' + e.getMessage();
            System.debug(LoggingLevel.WARN,
                '[SF_AgenticGateway] reject handlerClass=' + req.handlerClass
                + ' correlationId=' + req.correlationId
                + ' error=' + resp.message);
        }

        // Async + status: branches manage their own audit (or read-only
        // surface that doesn't need one); skip the sync writeAudit to
        // avoid duplicate rows.
        if (!asyncOrStatusBranch) {
            writeAudit(req, prefix, target, batchSize, cpuAtStart, truncated, resp);
        }
        return resp;
    }

    /**
     * Public sync-path helper extracted from `invokeOne` so the async
     * workers (`SF_AgenticGateway_QueueableWorker` /
     * `SF_AgenticGateway_FutureWorker` via `SF_AgenticGateway_WorkerCore`)
     * can re-use the SAME 7-way switch verbatim. Re-runs the per-prefix
     * gates that already live inside the adapters (G-Sec-DML-1..14 in
     * `SF_AgenticGateway_DmlAdapter`; G-Sec-AGENT-1..4 in
     * `SF_AgenticGateway_AgentAdapter`; G-Sec-QUERY-1..14 in
     * `SF_AgenticGateway_QueryAdapter`) — so async dispatch inherits the
     * full sync gate matrix (G-Sec-ASYNC-12).
     *
     * Pre-conditions enforced by caller: prefix ∈ {apex|flow|ip|dr|agent|dml|query};
     * CMDT row already authorised; payload size already asserted.
     */
    public static Object dispatchSync(
        String prefix,
        String target,
        String payloadJson,
        String correlationId,
        Integer maxBatch
    ) {
        SF_AgenticGateway_Limits.assertNotInCallbackScope();

        // WP-SATA-3 Phase 1 — defense-in-depth runtime AllowList re-check
        // (G-Sec-DML-17 NEW). Closes CWE-862 in-namespace bypass: any
        // in-namespace Apex caller (test seam, future handler, callback
        // landing AFTER `exitCallbackScope`) reaches the 7-way adapter
        // switch bypassing the entry-time `invokeOne` AllowList gate. The
        // legitimate runtime caller `SF_AgenticGateway_WorkerCore.runWorker`
        // (line 208) flows through this re-check successfully because the
        // CMDT row was already verified active at submit boundary; the
        // re-check also catches the operator-soft-kill case where
        // `Active__c` flipped to false between submit and worker run
        // (PO AC-P0-3 Scenario 3b). Phase 2 (`@TestVisible private static`
        // narrow + WorkerCore trampoline) DEFERRED to wave-4 per
        // `specs/wave-4-followup-dispatchsync-private.md`.
        //
        // WP-L-Dispatcher-Drift Phase 1 update — `mapPrefixToCmdtPicklist`
        // private helper moved to `SF_AgenticGateway_PrefixMapper.
        // toCmdtPicklist(prefix)` static helper (audit finding L-1).
        // Gate code (lines 314-318) preserved verbatim semantically;
        // only the helper call site updated.
        String cmdtType = SF_AgenticGateway_PrefixMapper.toCmdtPicklist(prefix);
        if (!SF_AgenticGateway_AllowList.isAuthorized(target, cmdtType)) {
            throw new SF_AgenticGatewayException(
                'DISPATCH_SYNC_BYPASS_BLOCKED:' + prefix + ':' + target);
        }

        // WP-L-Dispatcher-Drift Phase 1 (audit findings L-5 + L-6):
        // polymorphic adapter dispatch via `Map<String, IAgenticAdapter>
        // ADAPTER_REGISTRY` lookup replacing the wave-3 prefix `if/else`
        // chain. Per-adapter `dispatch` instance method unpacks the
        // canonical args Map + delegates to the existing static
        // `invoke(...)` signature verbatim (backwards-compat facade).
        // Unknown-prefix branch preserves wave-3 `UNKNOWN_PREFIX:<prefix>`
        // throw contract — defense-in-depth backstop because
        // `parsePrefix` already rejects unknown prefixes at line 379
        // BEFORE reaching dispatchSync.
        IAgenticAdapter adapter = ADAPTER_REGISTRY.get(prefix);
        if (adapter == null) {
            throw new SF_AgenticGatewayException('UNKNOWN_PREFIX: ' + prefix);
        }
        return adapter.dispatch(target, new Map<String, Object>{
            'prefix' => prefix,
            'payloadJson' => payloadJson,
            'correlationId' => correlationId,
            'maxBatch' => maxBatch
        });
    }

    /**
     * Inner adapter wrapping the existing private `dispatchApex`
     * reflection path so the `apex` prefix slots into the
     * `ADAPTER_REGISTRY` uniform shape (per WP-L-Dispatcher-Drift
     * Phase 1). Wave-3 G-Sec-3 reflection gate
     * (`Type.forName` + `instanceof ISF_AgenticHandler`) preserved
     * verbatim — `dispatch` just unpacks the args Map and forwards.
     *
     * No new AllowList propagation here — the `apex` prefix is gated
     * by the wave-3 `SF_AgenticGateway.invokeOne` AllowList entry
     * gate (line 215) AND the WP-SATA-3 `dispatchSync` runtime
     * AllowList re-check (line 315) — adding a third gate would be
     * dead code (the second one already fires before the registry
     * lookup).
     */
    private class ApexHandlerAdapter implements IAgenticAdapter {
        public Object dispatch(String target, Map<String, Object> args) {
            String payloadJson = (String) args.get('payloadJson');
            return dispatchApex(target, payloadJson);
        }
    }

    /**
     * G-Sec-ASYNC-1: per-call `"async": true` flag detection for
     * AsyncMode=PayloadOptIn rows.
     *
     * G-Sec-L-23 (WP-L-Sanitization L-23 / CWE-754 silent error):
     * fail-CLOSED on JSON parse failure. Wave-3 swallowed the
     * `System.JSONException` and fell through to `return false` (silent
     * "sync default"), masking caller-side payload malformation AND
     * denying any audit/observability signal — the audit row would
     * record `success=true` for a sync dispatch that was supposed to be
     * async. New direction: catch `System.JSONException` specifically
     * and throw a deterministic `SF_AgenticGatewayException` with shape
     * `PAYLOAD_PARSE_ERROR:<64-char-getMessage()-prefix>` so the
     * outer `invokeOne` catch + `writeAudit` pipeline captures
     * `success=false` + the deterministic code shape for forensics.
     * Blank/null payload preserves the existing `return false` fast
     * path (parsing not attempted).
     */
    @TestVisible
    private static Boolean isAsyncRequested(String payloadJson) {
        if (String.isBlank(payloadJson)) return false;
        try {
            Object parsed = JSON.deserializeUntyped(payloadJson);
            if (parsed instanceof Map<String, Object>) {
                Object flag = ((Map<String, Object>) parsed).get('async');
                if (flag instanceof Boolean) return (Boolean) flag;
            }
        } catch (System.JSONException jsonEx) {
            String rawMsg = jsonEx.getMessage() == null
                ? 'null'
                : jsonEx.getMessage();
            Integer endIdx = Math.min(
                PAYLOAD_PARSE_ERROR_MSG_CHARS, rawMsg.length());
            throw new SF_AgenticGatewayException(
                'PAYLOAD_PARSE_ERROR:' + rawMsg.substring(0, endIdx));
        }
        return false;
    }

    /** Existing v9 reflection path: Type.forName → instanceof ISF_AgenticHandler → handle(). */
    private static Object dispatchApex(String target, String payloadJson) {
        Type t = Type.forName(target);
        if (t == null) {
            throw new SF_AgenticGatewayException(
                'Handler class not found: ' + target);
        }
        Object instance = t.newInstance();
        if (!(instance instanceof ISF_AgenticHandler)) {
            throw new SF_AgenticGatewayException(
                'Handler does not implement ISF_AgenticHandler: ' + target);
        }
        ISF_AgenticHandler handler = (ISF_AgenticHandler) instance;
        return handler.handle(payloadJson);
    }

    private class ParsedTarget {
        String prefix;
        String target;
    }

    private static ParsedTarget parsePrefix(String handlerClass) {
        ParsedTarget out = new ParsedTarget();
        if (String.isBlank(handlerClass)) {
            out.prefix = PREFIX_APEX;
            out.target = '';
            return out;
        }
        Integer colonAt = handlerClass.indexOf(':');
        if (colonAt < 0) {
            out.prefix = PREFIX_APEX;
            out.target = handlerClass;
            return out;
        }
        String rawPrefix = handlerClass.substring(0, colonAt).toLowerCase();
        String rest = handlerClass.substring(colonAt + 1);
        if (!KNOWN_PREFIXES.contains(rawPrefix)) {
            throw new SF_AgenticGatewayException(
                'UNKNOWN_PREFIX: ' + rawPrefix);
        }
        out.prefix = rawPrefix;
        out.target = rest;
        return out;
    }

    /**
     * Best-effort batch size detection from the payload JSON. Used for
     * audit logging only; the adapters re-parse their own payload and
     * enforce CMDT MaxBatchSize independently.
     */
    private static Integer countBatch(String payloadJson) {
        if (String.isBlank(payloadJson)) return 1;
        try {
            Object parsed = JSON.deserializeUntyped(payloadJson);
            if (parsed instanceof Map<String, Object>) {
                Object batch = ((Map<String, Object>) parsed).get('batch');
                if (batch instanceof List<Object>) {
                    return Math.max(1, ((List<Object>) batch).size());
                }
            }
        } catch (Exception ignore) {
        }
        return 1;
    }

    /**
     * Fire-and-forget audit row insert. NEVER fails the dispatch — all
     * exceptions swallowed to a debug log. Sec C-5: only the HMAC hash of
     * the message is persisted, never the raw text.
     */
    private static void writeAudit(
        Request req,
        String prefix,
        String target,
        Integer batchSize,
        Long cpuAtStart,
        Boolean truncated,
        Response resp
    ) {
        try {
            SF_AgenticInvocation__c row = new SF_AgenticInvocation__c();
            row.handlerClass__c = req.handlerClass == null ? '' : req.handlerClass;
            row.correlationId__c = String.isBlank(req.correlationId)
                ? 'noCorr-' + String.valueOf(Crypto.getRandomLong())
                : req.correlationId;
            row.timestamp__c = System.now();
            row.success__c = resp.success == true;
            row.DispatchType__c = SF_AgenticGateway_PrefixMapper.toCmdtPicklist(prefix);
            row.Target__c = target == null ? row.handlerClass__c : target;
            row.BatchSize__c = batchSize;
            row.CpuMsUsed__c = Limits.getCpuTime() - cpuAtStart;
            row.HeapBytesPeak__c = Limits.getHeapSize();
            row.Truncated__c = truncated == true;
            row.MessageHash__c = SF_AgenticGateway_Limits.hashMessage(resp.message);
            Database.insert(row, false);
        } catch (Exception auditEx) {
            System.debug(LoggingLevel.WARN,
                '[SF_AgenticGateway] audit insert failed: ' + auditEx.getMessage());
        }
    }

    // mapPrefixToCmdtPicklist (private static, pre-WP-L-Dispatcher-Drift)
    // moved to `SF_AgenticGateway_PrefixMapper.toCmdtPicklist(prefix)`
    // — see audit finding L-1 (prefix mapper consolidation) +
    // `docs/sf-agentic-gateway-fixes-2026-05-26-wp-l-dispatcher-drift-delivery.md`
    // hot-file regression check.
}