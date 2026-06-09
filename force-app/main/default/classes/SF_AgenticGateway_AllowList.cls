/**
 * SF_AgenticGateway_AllowList — CMDT-backed allow-list cache for the
 * gateway. Replaces the legacy hardcoded `ALLOWED_HANDLERS` Set as the
 * runtime authoritative source while the Set itself stays in
 * SF_AgenticGateway as compile-time documentation + backward-compat seam
 * for the existing v9 test class.
 *
 * Cache is built lazily on first lookup per transaction (CMDT records are
 * effectively static; one query per Tx is the right granularity). Tests
 * inject fixtures via `setMockAllowList`.
 *
 * Sec G-Sec-2: every dispatch is gated on `Active__c=true` AND
 * `DispatchType__c` matching the parsed prefix (case-insensitive).
 *
 * DML adapter extension (docs/sf-agentic-gateway-dml-adapter-2026-05-14.md
 * §4): three new CMDT fields drive per-bundle multi-SObject DML gating:
 *   - `Sobjects__c` (CSV) — allow-listed SObject API names per bundle
 *   - `AllowedOpsBySobject__c` (JSON map) — per-SObject ops allowed
 *   - `AllowOwnerOverride__c` (Boolean) — gate on `OwnerId` smuggling
 * The parsed JSON map for `AllowedOpsBySobject__c` is cached per-Tx to
 * avoid re-parse on each per-record check inside the adapter loop.
 *
 * Async selector extension (docs/sf-agentic-gateway-async-selector-2026-05-14.md
 * §4.1): five new CMDT fields drive the sync/async selector + worker config:
 *   - `AsyncMode__c` — picklist {Sync, Async, PayloadOptIn} (G-Sec-ASYNC-1)
 *   - `AsyncRuntime__c` — picklist {Queueable, Future, BatchApex}
 *   - `AsyncResultTtlSeconds__c` — Number (default 86400)
 *   - `AsyncMaxConcurrent__c` — Number (default 5; G-Sec-ASYNC-5)
 *   - `AsyncCallbackHandler__c` — Text (dormant; FU-AGW-ASYNC-2)
 * Plus the `status:` prefix special-case in `isAuthorized` (no CMDT row
 * required — per-row visibility enforced by USER_MODE SOQL in
 * SF_AgenticGateway_StatusAdapter; G-Sec-ASYNC-2).
 *
 * Query adapter extension (docs/sf-agentic-gateway-query-adapter-2026-05-20.md
 * §3.2): three new CMDT fields drive per-bundle multi-query SOQL gating:
 *   - `AllowedFieldsBySobject__c` (JSON map) — per-SObject field allow-list
 *     (G-Sec-QUERY-3 + G-Sec-QUERY-11); empty → deny (positive-list)
 *   - `MaxQueryRows__c` (Number) — per-query LIMIT cap intersected with
 *     `Limits.MAX_QUERY_ROWS_PER_CALL=200` (G-Sec-QUERY-8)
 *   - `MaxQueriesPerCall__c` (Number) — bundle size cap intersected with
 *     `Limits.MAX_QUERIES_PER_CALL=5` (G-Sec-QUERY-6)
 * The parsed JSON map for `AllowedFieldsBySobject__c` is cached per-Tx
 * via FIELDS_CACHE (mirrors OPS_CACHE) so a multi-query bundle pays the
 * parse cost once.
 *
 * Wave-3 extension (docs/sf-agentic-gateway-wave-3-2026-05-20-technical-design.md
 * §4 / §6): four new CMDT fields drive async observability + retry + per-
 * record audit gating:
 *   - `AsyncPublishEnabled__c` (Boolean) — per-bundle kill switch for the
 *     operational Platform Event emit on Completed / Failed / Retried
 *     terminal transitions (G-Sec-ASYNC-13). Defaults false.
 *   - `AsyncMaxRetries__c` (Number) — per-bundle retry ceiling intersected
 *     with `Limits.MAX_RETRIES_HARD_CAP=5` (G-Sec-ASYNC-15). Defaults 0.
 *   - `AsyncBatchChunkSize__c` (Number) — BatchApex chunk size intersected
 *     with the platform 2000 ceiling (G-Sec-ASYNC-15 / FU-AGW-ASYNC-3).
 *     Defaults 200.
 *   - `AuditPerRecord__c` (Boolean) — DML adapter per-record audit child
 *     insert toggle (DML-AUDIT-1 / G-Sec-DML-15). Defaults false.
 */
public with sharing class SF_AgenticGateway_AllowList {

    @TestVisible
    private static Map<String, SF_AgenticGateway_Allow__mdt> CACHE = null;

    /**
     * Per-Tx parsed-JSON cache for `AllowedOpsBySobject__c`. Keyed by
     * Target__c, valued by {sobject → set-of-ops} map. Built lazily on
     * first `allowedOpsFor` call; cleared by tests via `clearOpsCache`.
     */
    private static Map<String, Map<String, Set<String>>> OPS_CACHE = null;

    /**
     * Per-Tx parsed-JSON cache for `AllowedFieldsBySobject__c`. Keyed
     * by Target__c, valued by {sobject → set-of-field-tokens} map. Each
     * field token is the verbatim caller-allow-listed identifier (e.g.
     * `Id`, `Name`, `Owner.Email`). Built lazily on first
     * `allowedFieldsFor` call; reset alongside CACHE by setMockAllowList.
     */
    private static Map<String, Map<String, Set<String>>> FIELDS_CACHE = null;

    /**
     * WP-SATA-4 (G-Sec-DML-16): per-Tx parsed-JSON cache for the
     * write-side mirror `AllowedWriteFieldsBySobject__c`. Keyed by
     * Target__c, valued by {sobject → set-of-write-field-tokens} map.
     * Mirrors `FIELDS_CACHE` (query read-side) verbatim except for
     * write-only token semantics — DML does NOT support parent-traversal
     * field writes, so tokens containing `.` are stripped at cache load;
     * literal `*` wildcard tokens and empty-string tokens are also
     * stripped (defense-in-depth per Sec card § S.4 SECONDARY tamper row
     * + paired with WP-L-Sanitization L-16 Allow__mdt
     * `<visibility>Protected</visibility>` flip). Built lazily on first
     * `allowedWriteFieldsFor` call; reset alongside CACHE by
     * `setMockAllowList`. Malformed JSON falls through to an empty map
     * for that target (Sec defense — never throw out of an allow-list
     * read; `DmlAdapter.preValidate` translates empty map into
     * `DML_FIELDLIST_NOT_CONFIGURED:<sobject>` fail-closed per Sec card
     * § S.4 TERTIARY row).
     */
    private static Map<String, Map<String, Set<String>>> WRITE_FIELDS_CACHE = null;

    /** Returns CMDT row by exact `Target__c` value, or null if not allow-listed. */
    public static SF_AgenticGateway_Allow__mdt lookup(String target) {
        if (String.isBlank(target)) return null;
        ensureLoaded();
        return CACHE.get(target);
    }

    /**
     * True iff CMDT row exists, is Active, and its DispatchType matches the
     * parsed prefix (case-insensitive: CMDT picklist values are
     * Apex/Flow/IP/DR/Agent/Dml/Query; parsed prefix is lowercase apex/flow/ip/dr/agent/dml/query).
     *
     * G-Sec-ASYNC-2: the `status:` prefix is special-cased — it never
     * requires a CMDT row because per-row visibility on
     * `SF_AgenticInvocation__c` is enforced via USER_MODE SOQL inside
     * `SF_AgenticGateway_StatusAdapter`. Defence-in-depth: the picklist
     * value `Status` is added to the CMDT field for audit-row symmetry
     * but not consulted at runtime.
     */
    public static Boolean isAuthorized(String target, String dispatchType) {
        if (String.isBlank(target) || String.isBlank(dispatchType)) return false;
        if ('status'.equalsIgnoreCase(dispatchType)) return true;
        SF_AgenticGateway_Allow__mdt row = lookup(target);
        if (row == null) return false;
        if (row.Active__c != true) return false;
        String cmdtType = row.DispatchType__c == null ? '' : row.DispatchType__c;
        return cmdtType.equalsIgnoreCase(dispatchType);
    }

    /**
     * WP-L-Dispatcher-Drift Phase 1 (audit findings L-5 + L-6): hard
     * gate consumed by the Agent / Flow / Vip / Status `IAgenticAdapter`
     * dispatch entry points (per Sec card § Card · WP-L-Dispatcher-
     * Drift assertion (a) — "confirm `AllowList.assertBundleActive`
     * propagates to Agent/Flow/Vip adapter entry"). Wraps the
     * pre-existing `isAuthorized(target, dispatchType)` Boolean
     * accessor with a deterministic `<adapterCode>_ALLOWLIST_BYPASS_BLOCKED:<target>`
     * throw on reject — matching the sibling
     * `DISPATCH_SYNC_BYPASS_BLOCKED:<prefix>:<target>` pattern density
     * shipped by WP-SATA-3 (G-Sec-DML-17 entry-time re-check).
     *
     * Defense-in-depth contract — this is the SECOND line for
     * Agent/Flow/Vip; the FIRST line is the entry-time
     * `SF_AgenticGateway.invokeOne` AllowList gate at line 215 +
     * WP-SATA-3 `SF_AgenticGateway.dispatchSync` runtime re-check at
     * line 315. Both lines stay in place verbatim; this third gate
     * catches any future in-namespace caller (test seam, async
     * callback landing AFTER `exitCallbackScope`, partner-package
     * dispatcher) that reaches the adapter `dispatch` instance method
     * bypassing both wave-3 + WP-SATA-3 entry points.
     *
     * Status-prefix special case (G-Sec-ASYNC-2 wave-3 preserved):
     * `isAuthorized(target, 'status')` returns true by design (per-row
     * visibility enforced via USER_MODE SOQL in
     * `SF_AgenticGateway_StatusAdapter.loadAuditUserMode`); calling
     * this helper from StatusAdapter is a shape no-op + the
     * USER_MODE SOQL is the actual gate.
     *
     * Pure-function failure shape — throw the canonical gateway
     * exception with the deterministic error-code:target payload;
     * caller's existing `try/catch` envelope in
     * `SF_AgenticGateway.invokeOne` lines 255-267 routes the throw
     * through `writeAudit` for forensic audit row persistence (per
     * wave-3 baseline; no new audit pipeline introduced this WP).
     *
     * @param target Target__c value to authorize.
     * @param dispatchType canonical CMDT picklist token from
     *        `SF_AgenticGateway_PrefixMapper.toCmdtPicklist(prefix)`
     *        (`Apex`/`Flow`/`IP`/`DR`/`Agent`/`Dml`/`Query`/`Status`).
     * @param adapterCode short-form uppercase adapter identifier used
     *        in the error message prefix (`AGENT`/`FLOW`/`IP`/`DR`/
     *        `DML`/`QUERY`/`STATUS`). Convention: matches the
     *        adapter's natural domain prefix in deterministic error
     *        codes already shipped (`AGENT_NOT_FOUND_OR_INVALID`,
     *        `FLOW_NOT_FOUND_OR_INVALID`, `VIP_TARGET_BLANK`,
     *        `DML_*`, `QUERY_*`).
     * @throws SF_AgenticGateway.SF_AgenticGatewayException with
     *         message `<adapterCode>_ALLOWLIST_BYPASS_BLOCKED:<target>`
     *         on reject.
     */
    public static void assertBundleActive(
        String target,
        String dispatchType,
        String adapterCode
    ) {
        if (isAuthorized(target, dispatchType)) return;
        String safeCode = String.isBlank(adapterCode) ? 'ADAPTER' : adapterCode;
        String safeTarget = target == null ? '' : target;
        throw new SF_AgenticGateway.SF_AgenticGatewayException(
            safeCode + '_ALLOWLIST_BYPASS_BLOCKED:' + safeTarget);
    }

    /** CMDT MaxBatchSize__c, defaulting to 1 when null/missing. */
    public static Integer maxBatch(String target) {
        SF_AgenticGateway_Allow__mdt row = lookup(target);
        if (row == null || row.MaxBatchSize__c == null) return 1;
        return Integer.valueOf(row.MaxBatchSize__c);
    }

    /**
     * Sec G-Sec-DML-2: CMDT `Sobjects__c` CSV → Set of allow-listed
     * SObject API names for this DML bundle. Empty/null CMDT field
     * returns an empty Set (positive-list semantics: nothing allowed by
     * default). Never returns null.
     */
    public static Set<String> allowedSobjects(String target) {
        Set<String> out = new Set<String>();
        SF_AgenticGateway_Allow__mdt row = lookup(target);
        if (row == null) return out;
        String csv = row.Sobjects__c;
        if (String.isBlank(csv)) return out;
        for (String token : csv.split(',')) {
            String trimmed = token == null ? '' : token.trim();
            if (String.isNotBlank(trimmed)) {
                out.add(trimmed);
            }
        }
        return out;
    }

    /**
     * Sec G-Sec-DML-3: CMDT `AllowedOpsBySobject__c` JSON map →
     * per-SObject Set of allowed ops (lowercased downstream by adapter).
     * Parsed once per Tx, cached. Returns an empty Set when the bundle
     * target/sobject is not present in the map; never returns null.
     */
    public static Set<String> allowedOpsFor(String target, String sobjectName) {
        if (String.isBlank(target) || String.isBlank(sobjectName)) {
            return new Set<String>();
        }
        ensureOpsCacheLoaded(target);
        Map<String, Set<String>> opsBySobject = OPS_CACHE.get(target);
        if (opsBySobject == null) return new Set<String>();
        Set<String> ops = opsBySobject.get(sobjectName);
        return ops == null ? new Set<String>() : ops;
    }

    /**
     * Sec G-Sec-DML-14: CMDT `AllowOwnerOverride__c` flag. When false
     * (default), records carrying `OwnerId` are rejected as
     * DML_OWNERID_FORBIDDEN. Null CMDT field defaults to false.
     */
    public static Boolean allowOwnerOverride(String target) {
        SF_AgenticGateway_Allow__mdt row = lookup(target);
        if (row == null) return false;
        return row.AllowOwnerOverride__c == true;
    }

    /**
     * Async-selector helpers (Sec G-Sec-ASYNC-1..6 + §4.1 of the joint
     * locked design). Each helper defaults to the "Sync / safe" value
     * when the CMDT row is missing OR the field is null, preserving
     * today's byte-identical sync behaviour on any row not yet
     * configured for async.
     */
    public static String asyncMode(String target) {
        SF_AgenticGateway_Allow__mdt row = lookup(target);
        if (row == null) return 'Sync';
        String v = row.AsyncMode__c;
        return String.isBlank(v) ? 'Sync' : v;
    }

    public static String asyncRuntime(String target) {
        SF_AgenticGateway_Allow__mdt row = lookup(target);
        if (row == null) return 'Queueable';
        String v = row.AsyncRuntime__c;
        return String.isBlank(v) ? 'Queueable' : v;
    }

    public static Integer asyncResultTtlSeconds(String target) {
        SF_AgenticGateway_Allow__mdt row = lookup(target);
        if (row == null || row.AsyncResultTtlSeconds__c == null) return 86400;
        return Integer.valueOf(row.AsyncResultTtlSeconds__c);
    }

    public static Integer asyncMaxConcurrent(String target) {
        SF_AgenticGateway_Allow__mdt row = lookup(target);
        if (row == null || row.AsyncMaxConcurrent__c == null) return 5;
        return Integer.valueOf(row.AsyncMaxConcurrent__c);
    }

    public static String asyncCallbackHandler(String target) {
        SF_AgenticGateway_Allow__mdt row = lookup(target);
        if (row == null) return null;
        return row.AsyncCallbackHandler__c;
    }

    /**
     * Wave-3 ASYNC-3 (G-Sec-ASYNC-15 / FU-AGW-ASYNC-3): CMDT
     * `AsyncBatchChunkSize__c` per-bundle BatchApex chunk size.
     * Returns 200 when null/missing. AsyncDispatcher intersects this
     * with the platform 2000 ceiling via `Math.min(..., 2000)`.
     */
    public static Integer asyncBatchChunkSize(String target) {
        SF_AgenticGateway_Allow__mdt row = lookup(target);
        if (row == null || row.AsyncBatchChunkSize__c == null) return 200;
        return Integer.valueOf(row.AsyncBatchChunkSize__c);
    }

    /**
     * Wave-3 ASYNC-4 (G-Sec-ASYNC-15): CMDT `AsyncMaxRetries__c` per-
     * bundle retry ceiling. Returns 0 when null/missing (retries disabled
     * by default). WorkerCore intersects this with
     * `Limits.MAX_RETRIES_HARD_CAP=5` via `effectiveMaxRetries`.
     */
    public static Integer asyncMaxRetries(String target) {
        SF_AgenticGateway_Allow__mdt row = lookup(target);
        if (row == null || row.AsyncMaxRetries__c == null) return 0;
        return Integer.valueOf(row.AsyncMaxRetries__c);
    }

    /**
     * Wave-3 ASYNC-1 (G-Sec-ASYNC-13): CMDT `AsyncPublishEnabled__c`
     * per-bundle kill switch for the operational Platform Event emit
     * on Completed / Failed / Retried terminal transitions. Defaults
     * false so any unmigrated bundle stays silent until an operator
     * explicitly opts in.
     */
    public static Boolean asyncPublishEnabled(String target) {
        SF_AgenticGateway_Allow__mdt row = lookup(target);
        if (row == null || row.AsyncPublishEnabled__c == null) return false;
        return row.AsyncPublishEnabled__c == true;
    }

    /**
     * Wave-3 DML-AUDIT-1 (G-Sec-DML-15): CMDT `AuditPerRecord__c` per-
     * bundle toggle for the DML adapter per-record audit child insert.
     * Defaults false so existing DML bundles stay byte-identical until
     * an operator opts in.
     */
    public static Boolean auditPerRecord(String target) {
        SF_AgenticGateway_Allow__mdt row = lookup(target);
        if (row == null || row.AuditPerRecord__c == null) return false;
        return row.AuditPerRecord__c == true;
    }

    /**
     * Sec G-Sec-QUERY-3 + G-Sec-QUERY-11: CMDT `AllowedFieldsBySobject__c`
     * JSON map → per-SObject Set of allow-listed field tokens (verbatim
     * caller-allow-listed identifiers including parent-traversal paths
     * like `Owner.Email`). Parsed once per Tx, cached via FIELDS_CACHE.
     * Returns an empty Set when the bundle target/sobject is not present
     * in the map; never returns null (positive-list semantics: empty =
     * deny).
     */
    public static Set<String> allowedFieldsFor(String target, String sobjectName) {
        if (String.isBlank(target) || String.isBlank(sobjectName)) {
            return new Set<String>();
        }
        ensureFieldsCacheLoaded(target);
        Map<String, Set<String>> fieldsBySobject = FIELDS_CACHE.get(target);
        if (fieldsBySobject == null) return new Set<String>();
        Set<String> fields = fieldsBySobject.get(sobjectName);
        return fields == null ? new Set<String>() : fields;
    }

    /**
     * Sec G-Sec-QUERY-8: CMDT `MaxQueryRows__c` per-bundle LIMIT cap.
     * Returns 200 when null/missing (mirrors `Limits.MAX_QUERY_ROWS_PER_CALL`).
     * Adapter additionally intersects with the Limits hard cap so any
     * admin-misconfigured CMDT row stays bounded.
     */
    public static Integer maxQueryRows(String target) {
        SF_AgenticGateway_Allow__mdt row = lookup(target);
        if (row == null || row.MaxQueryRows__c == null) return 200;
        return Integer.valueOf(row.MaxQueryRows__c);
    }

    /**
     * Sec G-Sec-QUERY-6: CMDT `MaxQueriesPerCall__c` per-bundle bundle
     * size cap. Returns 5 when null/missing (mirrors
     * `Limits.MAX_QUERIES_PER_CALL`). Adapter additionally intersects
     * with the Limits hard cap.
     */
    public static Integer maxQueriesPerCall(String target) {
        SF_AgenticGateway_Allow__mdt row = lookup(target);
        if (row == null || row.MaxQueriesPerCall__c == null) return 5;
        return Integer.valueOf(row.MaxQueriesPerCall__c);
    }

    /**
     * WP-SATA-4 G-Sec-DML-16: CMDT `WritePolicy__c` picklist accessor
     * (closes CWE-732 + CWE-345 + AI-1 PRIMARY + AI-2 — mirror of the
     * read-side QueryAdapter G-Sec-QUERY-3 positive-list pattern).
     * Returns the canonical token `Permissive` when the CMDT row is
     * missing, the picklist is null/blank, or the bundle has never been
     * opted-in to `FieldList` mode. Backward-compat per PO Premise P6:
     * existing wave-3 bundles whose `WritePolicy__c` is null get the
     * Permissive default at runtime → byte-identical existing behavior;
     * per-row opt-in to `FieldList` is tracked as follow-on
     * `FU-AGW-DML-FIELDLIST-ADOPT-1` (post-Gate-4 Analyst+Sec task per
     * tech-design § XL-4 § Migration).
     *
     * Canonical return values: `Permissive` (default, any FLS-permitted
     * field accepted by `DmlAdapter.preValidate`) | `FieldList`
     * (positive-list allow-list enforcement against the per-Tx parsed
     * `AllowedWriteFieldsBySobject__c` JSON map).
     */
    public static String writePolicy(String target) {
        SF_AgenticGateway_Allow__mdt row = lookup(target);
        if (row == null) return 'Permissive';
        String v = row.WritePolicy__c;
        return String.isBlank(v) ? 'Permissive' : v;
    }

    /**
     * WP-SATA-4 G-Sec-DML-16: CMDT `AllowedWriteFieldsBySobject__c` JSON
     * map → per-SObject Set of allow-listed write-field tokens. Parent-
     * traversal tokens (`Owner.Email` — anything containing `.`) and
     * literal `*` wildcard tokens are stripped at cache load (DML does
     * not support parent-traversal field writes; wildcard rejection per
     * Sec card § S.4 SECONDARY tamper row paired with WP-L-Sanitization
     * L-16 Allow__mdt `<visibility>Protected</visibility>` flip). Empty
     * tokens are also stripped (defensive). Parsed once per Tx via
     * `ensureWriteFieldsCacheLoaded`; cached in `WRITE_FIELDS_CACHE`.
     * Returns an empty Set when the bundle target/sobject is not present
     * in the map; never returns null (positive-list semantics: empty =
     * deny — `DmlAdapter.preValidate` translates empty Set into
     * `DML_FIELDLIST_NOT_CONFIGURED:<sobject>` when `WritePolicy__c =
     * FieldList`).
     */
    public static Set<String> allowedWriteFieldsFor(String target, String sobjectName) {
        if (String.isBlank(target) || String.isBlank(sobjectName)) {
            return new Set<String>();
        }
        ensureWriteFieldsCacheLoaded(target);
        Map<String, Set<String>> fieldsBySobject = WRITE_FIELDS_CACHE.get(target);
        if (fieldsBySobject == null) return new Set<String>();
        Set<String> fields = fieldsBySobject.get(sobjectName);
        return fields == null ? new Set<String>() : fields;
    }

    /**
     * @TestVisible test seam — inject fixtures keyed by Target__c without
     * requiring deployed CMDT records. Pass null to clear (forces re-load
     * on next lookup, useful when test wants live CMDT behavior).
     */
    @TestVisible
    private static void setMockAllowList(Map<String, SF_AgenticGateway_Allow__mdt> fixture) {
        CACHE = fixture;
        OPS_CACHE = null;
        FIELDS_CACHE = null;
        WRITE_FIELDS_CACHE = null;
    }

    /**
     * @TestVisible test seam — drop the per-Tx parsed `AllowedOpsBySobject__c`
     * cache so the next `allowedOpsFor` call re-parses from CMDT. Used by
     * tests that swap CMDT fixtures mid-Tx.
     */
    @TestVisible
    private static void clearOpsCache() {
        OPS_CACHE = null;
    }

    private static void ensureLoaded() {
        if (CACHE != null) return;
        Map<String, SF_AgenticGateway_Allow__mdt> built =
            new Map<String, SF_AgenticGateway_Allow__mdt>();
        for (SF_AgenticGateway_Allow__mdt row : [
            SELECT DeveloperName, Target__c, DispatchType__c, Active__c, MaxBatchSize__c,
                   Sobjects__c, AllowedOpsBySobject__c, AllowOwnerOverride__c,
                   AllowedFieldsBySobject__c, MaxQueryRows__c, MaxQueriesPerCall__c,
                   AllowedWriteFieldsBySobject__c, WritePolicy__c,
                   AsyncMode__c, AsyncRuntime__c, AsyncResultTtlSeconds__c,
                   AsyncMaxConcurrent__c, AsyncCallbackHandler__c,
                   AsyncPublishEnabled__c, AsyncMaxRetries__c,
                   AsyncBatchChunkSize__c, AuditPerRecord__c
            FROM SF_AgenticGateway_Allow__mdt
            WHERE Active__c = true
        ]) {
            if (row.Target__c != null) {
                built.put(row.Target__c, row);
            }
        }
        CACHE = built;
    }

    /**
     * Lazy build of per-Tx parsed `AllowedOpsBySobject__c` cache. Called
     * from `allowedOpsFor`. Each target's JSON is parsed at most once per
     * Tx; subsequent calls hit the cache. Malformed JSON yields an empty
     * map for that target (Sec defense: never throw out of an allow-list
     * read; preValidate in the adapter handles the empty-Set reject).
     */
    private static void ensureOpsCacheLoaded(String target) {
        if (OPS_CACHE == null) {
            OPS_CACHE = new Map<String, Map<String, Set<String>>>();
        }
        if (OPS_CACHE.containsKey(target)) return;
        Map<String, Set<String>> parsed = new Map<String, Set<String>>();
        SF_AgenticGateway_Allow__mdt row = lookup(target);
        if (row == null || String.isBlank(row.AllowedOpsBySobject__c)) {
            OPS_CACHE.put(target, parsed);
            return;
        }
        try {
            Object raw = JSON.deserializeUntyped(row.AllowedOpsBySobject__c);
            if (raw instanceof Map<String, Object>) {
                Map<String, Object> jsonMap = (Map<String, Object>) raw;
                for (String sobjectName : jsonMap.keySet()) {
                    Object opsRaw = jsonMap.get(sobjectName);
                    Set<String> ops = new Set<String>();
                    if (opsRaw instanceof List<Object>) {
                        for (Object o : (List<Object>) opsRaw) {
                            if (o != null) {
                                ops.add(String.valueOf(o));
                            }
                        }
                    }
                    parsed.put(sobjectName, ops);
                }
            }
        } catch (Exception ignore) {
            // Malformed JSON → empty allow-list for this target; adapter rejects per-call.
        }
        OPS_CACHE.put(target, parsed);
    }

    /**
     * Lazy build of per-Tx parsed `AllowedFieldsBySobject__c` cache.
     * Called from `allowedFieldsFor`. Mirrors `ensureOpsCacheLoaded`
     * verbatim — each target's JSON is parsed at most once per Tx;
     * malformed JSON yields an empty map for that target (Sec defense:
     * never throw out of an allow-list read; QueryAdapter's preValidate
     * handles the empty-Set reject via G-Sec-QUERY-3).
     */
    private static void ensureFieldsCacheLoaded(String target) {
        if (FIELDS_CACHE == null) {
            FIELDS_CACHE = new Map<String, Map<String, Set<String>>>();
        }
        if (FIELDS_CACHE.containsKey(target)) return;
        Map<String, Set<String>> parsed = new Map<String, Set<String>>();
        SF_AgenticGateway_Allow__mdt row = lookup(target);
        if (row == null || String.isBlank(row.AllowedFieldsBySobject__c)) {
            FIELDS_CACHE.put(target, parsed);
            return;
        }
        try {
            Object raw = JSON.deserializeUntyped(row.AllowedFieldsBySobject__c);
            if (raw instanceof Map<String, Object>) {
                Map<String, Object> jsonMap = (Map<String, Object>) raw;
                for (String sobjectName : jsonMap.keySet()) {
                    Object fieldsRaw = jsonMap.get(sobjectName);
                    Set<String> fields = new Set<String>();
                    if (fieldsRaw instanceof List<Object>) {
                        for (Object o : (List<Object>) fieldsRaw) {
                            if (o != null) {
                                fields.add(String.valueOf(o));
                            }
                        }
                    }
                    parsed.put(sobjectName, fields);
                }
            }
        } catch (Exception ignore) {
            // Malformed JSON → empty allow-list for this target; adapter rejects per-call.
        }
        FIELDS_CACHE.put(target, parsed);
    }

    /**
     * WP-SATA-4 G-Sec-DML-16: lazy build of per-Tx parsed
     * `AllowedWriteFieldsBySobject__c` cache. Called from
     * `allowedWriteFieldsFor`. Mirrors `ensureFieldsCacheLoaded` (read
     * side) with three write-only token strips at parse time:
     *
     *   (a) parent-traversal tokens (`Owner.Email` — any token whose
     *       String contains a `.`) are dropped — DML does not support
     *       parent-traversal field writes (Sec card § S.4 SECONDARY
     *       tamper row + tech-design § XL-4 lines 440-442 inline
     *       comment "DML does not support parent-traversal field
     *       writes").
     *   (b) literal `*` wildcard tokens are dropped — wildcard
     *       expansion is rejected at the accessor regardless of CMDT
     *       content (Sec card § S.4 SECONDARY tamper row + AI-2 row —
     *       defense-in-depth paired with WP-L-Sanitization L-16
     *       `<visibility>Protected</visibility>` flip on the parent
     *       CMDT type which closes the upstream Customize-Application
     *       admin seed path).
     *   (c) empty / blank tokens are dropped — defensive against
     *       operator typos.
     *
     * Each target's JSON is parsed at most once per Tx; malformed JSON
     * yields an empty map for that target (Sec defense: never throw out
     * of an allow-list read; `DmlAdapter.preValidate` translates empty
     * map into `DML_FIELDLIST_NOT_CONFIGURED:<sobject>` fail-closed per
     * Sec card § S.4 TERTIARY row line 200 mirror of QueryAdapter
     * G-Sec-QUERY-3 swallow-pattern at line 482).
     */
    private static void ensureWriteFieldsCacheLoaded(String target) {
        if (WRITE_FIELDS_CACHE == null) {
            WRITE_FIELDS_CACHE = new Map<String, Map<String, Set<String>>>();
        }
        if (WRITE_FIELDS_CACHE.containsKey(target)) return;
        Map<String, Set<String>> parsed = new Map<String, Set<String>>();
        SF_AgenticGateway_Allow__mdt row = lookup(target);
        if (row == null || String.isBlank(row.AllowedWriteFieldsBySobject__c)) {
            WRITE_FIELDS_CACHE.put(target, parsed);
            return;
        }
        try {
            Object raw = JSON.deserializeUntyped(row.AllowedWriteFieldsBySobject__c);
            if (raw instanceof Map<String, Object>) {
                Map<String, Object> jsonMap = (Map<String, Object>) raw;
                for (String sobjectName : jsonMap.keySet()) {
                    Object fieldsRaw = jsonMap.get(sobjectName);
                    Set<String> fields = new Set<String>();
                    if (fieldsRaw instanceof List<Object>) {
                        for (Object o : (List<Object>) fieldsRaw) {
                            if (o == null) continue;
                            String tok = String.valueOf(o);
                            if (String.isBlank(tok)) continue;
                            if (tok == '*') continue;
                            if (tok.contains('.')) continue;
                            fields.add(tok);
                        }
                    }
                    parsed.put(sobjectName, fields);
                }
            }
        } catch (Exception ignore) {
            // Malformed JSON → empty allow-list for this target; adapter rejects per-call
            // (DML_FIELDLIST_NOT_CONFIGURED:<sobject> from preValidate) — fail-closed.
        }
        WRITE_FIELDS_CACHE.put(target, parsed);
    }
}