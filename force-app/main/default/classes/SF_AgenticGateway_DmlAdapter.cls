/**
 * SF_AgenticGateway_DmlAdapter — sixth dispatch surface (`dml:<bundle>`) for
 * the gateway. Lets a single agent payload write multiple heterogeneous
 * SObjects atomically in one Tx with @ref:<alias> parent→child Id chaining.
 *
 * Locked design: docs/sf-agentic-gateway-dml-adapter-2026-05-14.md
 * Plan: ~/.cursor/plans/dml_adapter_multi_sobject_b9bceadf.plan.md
 *
 * Contract:
 *   Payload: {"allOrNone":bool, "groups":[
 *     {"sobject":"Account", "op":"upsert|insert|update|delete",
 *      "externalIdField":"...", "records":[{"clientRef":"acc-1", "Name":"..."}]}
 *   ]}
 *   Response: {"groups":[{"sobject":"...", "op":"...",
 *     "results":[{"success":bool, "id":"001...", "clientRef":"acc-1", "message":"..."}]}]}
 *
 * Sec gates (§5 of locked design):
 *   G-Sec-DML-1: CMDT row Active=true + DispatchType=Dml (gateway-level)
 *   G-Sec-DML-2: CMDT Sobjects__c allow-list (preValidate)
 *   G-Sec-DML-3: CMDT AllowedOpsBySobject__c per-SObject ops (preValidate)
 *   G-Sec-DML-4: USER_MODE on every Database.<op> (runDml)
 *   G-Sec-DML-5: stack traces never propagated (catch → code:message)
 *   G-Sec-DML-6: MAX_DML_GROUPS_PER_CALL=5 (Limits.assertDmlGroupsOk)
 *   G-Sec-DML-7: Schema.getGlobalDescribe().get(sobject)!=null (preValidate)
 *   G-Sec-DML-8: MAX_DML_RECORDS_PER_CALL=50 (Limits.assertDmlRecordsOk)
 *   G-Sec-DML-9: per-record errors normalized to code:message (runDml + shapeResults)
 *   G-Sec-DML-10: MAX_DML_DISPATCHES_PER_TX=5 (Limits.assertDmlDispatchCountOk)
 *   G-Sec-DML-11: @ref forward-only resolver, max 50 refs/call (scanRefsForwardOnly)
 *   G-Sec-DML-12: single Tx savepoint, allOrNone default true (invoke try/catch)
 *   G-Sec-DML-13: Id field on insert records rejected (preValidate)
 *   G-Sec-DML-14: OwnerId rejected unless CMDT AllowOwnerOverride__c=true (preValidate)
 *   G-Sec-DML-15: per-record audit child rows on SF_AgenticInvocation_Item__c
 *                 inserted USER_MODE before invoke returns when CMDT
 *                 AuditPerRecord__c=true; M-D parent Id sourced from caller's
 *                 correlationToAuditId map (NO post-hoc SOQL); on DML-rows
 *                 budget breach the parent audit row is flipped Truncated__c=true
 *                 and items insert is skipped (best-effort, never fails dispatch)
 *   G-Sec-DML-16: WP-SATA-4 positive-list DML field-write allow-list mirror of
 *                 QueryAdapter G-Sec-QUERY-3 (preValidate). Enabled per-bundle
 *                 by CMDT picklist `WritePolicy__c=FieldList`; gated against
 *                 per-Tx parsed `AllowedWriteFieldsBySobject__c` JSON map.
 *                 Default `WritePolicy__c=Permissive` (null backward-compat per
 *                 PO Premise P6) preserves byte-identical wave-3 behavior.
 *                 Per-record per-field iteration rejects
 *                 `DML_FIELD_NOT_AUTHORIZED:<sobject>:<field>`; empty / unset
 *                 allow-list under FieldList rejects
 *                 `DML_FIELDLIST_NOT_CONFIGURED:<sobject>` fail-closed.
 *                 Structural keys `clientRef` / `Id` / `OwnerId` exempt (already
 *                 enforced by G-Sec-DML-13/14 + existing contract). Closes
 *                 CWE-732 + CWE-345 + AI-1 (PRIMARY prompt-injection
 *                 field-write privilege escalation) + AI-2 (wildcard
 *                 exploitation via L-16 chain — accessor strips `*` and
 *                 parent-traversal tokens at cache load).
 *
 * `with sharing` is non-negotiable. USER_MODE ensures FLS + CRUD + row-level
 * sharing are enforced per record regardless of caller permissions.
 */
public with sharing class SF_AgenticGateway_DmlAdapter implements IAgenticAdapter {

    public class DmlAdapterException extends Exception {}

    /**
     * WP-L-Dispatcher-Drift Phase 1 (audit finding L-5): polymorphic
     * dispatch entry. Per Sec card § Card · WP-L-Dispatcher-Drift
     * assertion (a) — DML already has AllowList propagation via the
     * wave-3 `SF_AgenticGateway.invokeOne` line 215 entry-time gate
     * (G-Sec-DML-1) AND the WP-SATA-3 `dispatchSync` line 315 runtime
     * AllowList re-check (G-Sec-DML-17). Adding a third gate here
     * would be dead code (third identical verdict per Tx CACHE
     * lookup). `dispatch` delegates to the existing 3-arg static
     * `invoke(...)` signature verbatim; callers needing the wave-3
     * 4-arg overload (CMDT `AuditPerRecord__c=true` per-record audit
     * child insert via `correlationToAuditId` map) continue to call
     * the static method directly — this dispatch path covers the
     * 3-arg sync route only.
     *
     * Wave-3 per-bundle G-Sec-DML-2 (Sobjects__c allow-list) +
     * G-Sec-DML-3 (AllowedOpsBySobject__c per-SObject ops) +
     * G-Sec-DML-4 (USER_MODE) + G-Sec-DML-13 (Id on insert) +
     * G-Sec-DML-14 (OwnerId override) + G-Sec-DML-15 (per-record
     * audit) gates all stay inside the static `invoke` body verbatim
     * — this dispatch wrapper is the L-5 interface introduction
     * ONLY.
     */
    public Object dispatch(String target, Map<String, Object> args) {
        String payloadJson = (String) args.get('payloadJson');
        String correlationId = (String) args.get('correlationId');
        return invoke(target, payloadJson, correlationId);
    }

    @TestVisible private static final Integer MAX_REFS_PER_CALL = 50;

    /**
     * Sec G-Sec-DML-11: alias regex compiled once. Forward-only resolver
     * accepts aliases matching [A-Za-z0-9_-]{1,64}. Anything else raises
     * DML_REF_UNRESOLVED (caller smuggled a non-alias under the @ref: token).
     */
    private static final Pattern REF_PATTERN =
        Pattern.compile('^@ref:([A-Za-z0-9_\\-]{1,64})$');

    private static final String REF_PREFIX = '@ref:';

    /**
     * @TestVisible test seam — when non-null, runDml short-circuits the real
     * Database.<op> call and returns canned per-record results. Outer list
     * indexes groups in invocation order (one inner list per group call);
     * inner list indexes records inside that group; each entry is a Map
     * shaped as {success:Boolean, id:String?, message:String?}.
     * Tests reset to null between scenarios.
     */
    @TestVisible
    private static List<List<Object>> testForcedSaveResults = null;

    /**
     * @TestVisible test seam — when true, preValidate skips the
     * Schema.getGlobalDescribe().get(sobject) existence check (G-Sec-DML-7).
     * Used by tests that inject canned save results via testForcedSaveResults
     * and want to exercise allow-list / ref-resolver paths against synthetic
     * SObject names without requiring them to be deployed.
     */
    @TestVisible
    private static Boolean testSkipSchemaCheck = false;

    /**
     * @TestVisible test seam — when non-null, the @ref resolver throws
     * DmlAdapterException('DML_REF_UNRESOLVED:<value>') on the first @ref
     * token encountered regardless of aliasIdMap contents. Exercises the
     * runtime-resolver throw path without crafting a payload that bypasses
     * preValidate's forward-only check.
     */
    @TestVisible
    private static String testForceRefUnresolved = null;

    /**
     * Per-invocation counter for the testForcedSaveResults seam. Tracks
     * which group call we're on so the seam returns the right canned list.
     * Resets at the start of every invoke() so each test invocation gets a
     * fresh sequence regardless of prior calls in the same Tx.
     */
    @TestVisible
    private static Integer testCallIdx = 0;

    /**
     * @TestVisible test seam — when true, the DML-AUDIT-1 (G-Sec-DML-15)
     * pre-DML budget guard short-circuits to LimitExceededException
     * regardless of real `Limits.getDmlRows()`. Drives the
     * `audit.Truncated__c=true` skip-items path deterministically.
     */
    @TestVisible
    private static Boolean testForceAuditItemsRowsBreach = false;

    /**
     * Wave-3 DML-AUDIT-1 (G-Sec-DML-15): per-Tx flag set to true when items
     * insert was skipped due to DML-rows budget breach. Read by the
     * gateway's finalizeAudit so the parent audit row's `Truncated__c=true`
     * signal (already flipped via `markAuditTruncated`) survives the post-
     * dispatch UPDATE. Reset to false at the top of every `invoke()` so the
     * flag is scoped per dispatch within a multi-Request InvocableMethod
     * call (which may iterate several Request entries in the same Tx).
     * `public` so SF_AgenticGateway.finalizeAudit can read it without a
     * helper method round-trip; never written from outside this class.
     */
    public static Boolean lastItemsTruncated = false;

    /**
     * Invoke the multi-SObject DML adapter. Single Tx semantics: a savepoint
     * wraps every group; allOrNone=true (default) rolls back on any per-record
     * failure that surfaces as DmlException; allOrNone=false preserves native
     * partial-success semantics (rows that succeeded persist, rows that failed
     * surface success=false per-record).
     *
     * @param target        CMDT Target__c (bundle name) — e.g. "CaseEscalationBundle"
     * @param payloadJson   JSON {allOrNone, groups:[{sobject, op, externalIdField?, records:[{clientRef?, ...fields}]}]}
     * @param correlationId Gateway correlationId (echoed; no record values logged)
     * @return Map shaped as {groups:[{sobject, op, results:[{success, id?, clientRef?, message?}]}]}.
     *         On DmlException with allOrNone=true: same shape plus an `error` key
     *         carrying the normalized DML message; savepoint is rolled back.
     */
    public static Map<String, Object> invoke(
        String target,
        String payloadJson,
        String correlationId
    ) {
        return invoke(target, payloadJson, correlationId, null);
    }

    /**
     * Wave-3 overload: same contract as the 3-arg `invoke` plus an optional
     * `correlationToAuditId` map. When CMDT AuditPerRecord__c=true and the
     * map carries an entry for `correlationId`, per-record audit children
     * (`SF_AgenticInvocation_Item__c`) are inserted USER_MODE before the
     * outGroups response is returned (G-Sec-DML-15). Map null OR missing
     * entry is the safe no-op (existing behaviour preserved).
     */
    public static Map<String, Object> invoke(
        String target,
        String payloadJson,
        String correlationId,
        Map<String, Id> correlationToAuditId
    ) {
        testCallIdx = 0;
        lastItemsTruncated = false;
        SF_AgenticGateway_Limits.assertDmlDispatchCountOk();
        SF_AgenticGateway_Limits.assertCpuOk();
        SF_AgenticGateway_Limits.assertHeapOk();
        SF_AgenticGateway_Limits.assertPayloadSizeOk(payloadJson);

        if (String.isBlank(target)) {
            throw new DmlAdapterException('DML_BUNDLE_NOT_FOUND_OR_INVALID:blank-name');
        }

        Map<String, Object> parsed = parsePayload(payloadJson);
        Boolean allOrNone = parsed.containsKey('allOrNone') && parsed.get('allOrNone') != null
            ? (Boolean) parsed.get('allOrNone')
            : true;

        Object rawGroupsObj = parsed.get('groups');
        if (!(rawGroupsObj instanceof List<Object>)) {
            throw new DmlAdapterException('DML_PAYLOAD_INVALID:groups-missing');
        }
        List<Object> rawGroups = (List<Object>) rawGroupsObj;
        SF_AgenticGateway_Limits.assertDmlGroupsOk(rawGroups.size());

        List<Map<String, Object>> groups = normalizeGroups(rawGroups);
        Integer totalRecords = sumRecords(groups);
        SF_AgenticGateway_Limits.assertDmlRecordsOk(totalRecords);

        preValidate(target, groups);

        Savepoint sp = Database.setSavepoint();
        Map<String, Id> aliasIdMap = new Map<String, Id>();
        List<Map<String, Object>> outGroups = new List<Map<String, Object>>();

        try {
            for (Map<String, Object> grp : groups) {
                SF_AgenticGateway_Limits.assertDmlRowsOk();
                List<Map<String, Object>> records = (List<Map<String, Object>>) grp.get('records');
                resolveRefs(records, aliasIdMap);
                String sobjectName = (String) grp.get('sobject');
                String op = ((String) grp.get('op')).toLowerCase();
                String externalIdField = (String) grp.get('externalIdField');
                List<Map<String, Object>> rowResults =
                    runDml(sobjectName, op, records, externalIdField, allOrNone, aliasIdMap);
                outGroups.add(new Map<String, Object>{
                    'sobject' => sobjectName,
                    'op' => op,
                    'results' => rowResults
                });
            }

            // Wave-3 DML-AUDIT-1 (G-Sec-DML-15): per-record audit child.
            // Audit Id sourced from caller's correlationToAuditId map (no SOQL).
            if (SF_AgenticGateway_AllowList.auditPerRecord(target)
                    && correlationToAuditId != null
                    && correlationToAuditId.containsKey(correlationId)) {
                Id auditId = correlationToAuditId.get(correlationId);
                if (auditId != null) {
                    insertAuditItems(outGroups, auditId);
                }
            }

            return new Map<String, Object>{ 'groups' => outGroups };
        } catch (DmlException dmlEx) {
            Database.rollback(sp);
            return new Map<String, Object>{
                'groups' => outGroups,
                'error' => 'DML_TRANSACTION_FAILED: ' + safeDmlMessage(dmlEx)
            };
        } catch (DmlAdapterException known) {
            Database.rollback(sp);
            throw known;
        } catch (Exception other) {
            Database.rollback(sp);
            throw new DmlAdapterException(other.getTypeName() + ': ' + other.getMessage());
        }
    }

    /**
     * Untyped JSON parse + defensive shape check. Throws
     * DML_PAYLOAD_INVALID:<reason> on malformed input; never lets a
     * JSONException surface to the gateway.
     */
    @TestVisible
    private static Map<String, Object> parsePayload(String payloadJson) {
        if (String.isBlank(payloadJson)) {
            throw new DmlAdapterException('DML_PAYLOAD_INVALID:blank');
        }
        Object raw;
        try {
            raw = JSON.deserializeUntyped(payloadJson);
        } catch (Exception jex) {
            throw new DmlAdapterException('DML_PAYLOAD_INVALID:malformed-json');
        }
        if (!(raw instanceof Map<String, Object>)) {
            throw new DmlAdapterException('DML_PAYLOAD_INVALID:not-object');
        }
        return (Map<String, Object>) raw;
    }

    /**
     * Coerce the untyped `groups` List<Object> into List<Map<String,Object>>,
     * preserving order. Each group's `records` is similarly coerced from
     * List<Object> to List<Map<String,Object>>. Malformed entries raise
     * DML_PAYLOAD_INVALID with the offending group/record index.
     */
    private static List<Map<String, Object>> normalizeGroups(List<Object> rawGroups) {
        List<Map<String, Object>> out = new List<Map<String, Object>>();
        for (Integer gi = 0; gi < rawGroups.size(); gi++) {
            Object g = rawGroups[gi];
            if (!(g instanceof Map<String, Object>)) {
                throw new DmlAdapterException(
                    'DML_PAYLOAD_INVALID:group-' + gi + '-not-object');
            }
            Map<String, Object> grp = (Map<String, Object>) g;
            Object recsObj = grp.get('records');
            List<Map<String, Object>> recs = new List<Map<String, Object>>();
            if (recsObj instanceof List<Object>) {
                List<Object> rawRecs = (List<Object>) recsObj;
                for (Integer ri = 0; ri < rawRecs.size(); ri++) {
                    Object r = rawRecs[ri];
                    if (!(r instanceof Map<String, Object>)) {
                        throw new DmlAdapterException(
                            'DML_PAYLOAD_INVALID:group-' + gi + '-record-' + ri + '-not-object');
                    }
                    recs.add((Map<String, Object>) r);
                }
            }
            grp.put('records', recs);
            out.add(grp);
        }
        return out;
    }

    /** Total record count across all groups; null-safe. */
    private static Integer sumRecords(List<Map<String, Object>> groups) {
        Integer total = 0;
        if (groups == null) return 0;
        for (Map<String, Object> g : groups) {
            Object recs = g.get('records');
            if (recs instanceof List<Map<String, Object>>) {
                total += ((List<Map<String, Object>>) recs).size();
            }
        }
        return total;
    }

    /**
     * Sec gates G-Sec-DML-2/3/7/11/13/14: fail-fast structural + allow-list
     * + forward-only ref validation BEFORE any DML executes. Each group's
     * clientRef aliases are added to `declaredAliases` AFTER that group's
     * refs are checked, ensuring forward-only semantics by construction.
     *
     * Distinguishes two ref-error variants:
     *   - DML_REF_UNRESOLVED: alias declared nowhere (or fails regex)
     *   - DML_REF_FORWARD_ONLY: alias declared in a later group (cycle attempt)
     */
    private static void preValidate(String target, List<Map<String, Object>> groups) {
        Set<String> allowedSobjects = SF_AgenticGateway_AllowList.allowedSobjects(target);
        Boolean ownerOverride = SF_AgenticGateway_AllowList.allowOwnerOverride(target);

        // WP-SATA-4 G-Sec-DML-16: per-bundle write-policy lookup once per
        // preValidate call (target-scoped — no per-record CMDT re-read).
        // `Permissive` (default + null backward-compat per PO Premise P6)
        // preserves existing wave-3 behavior byte-identical; `FieldList`
        // enables positive-list per-field enforcement against the
        // per-Tx parsed `AllowedWriteFieldsBySobject__c` map.
        String writePolicy = SF_AgenticGateway_AllowList.writePolicy(target);
        Boolean fieldListMode = 'FieldList'.equals(writePolicy);

        // Pass 1: collect every declared alias across all groups (used to
        // distinguish "never declared" from "declared later").
        Set<String> allDeclaredAliases = new Set<String>();
        for (Map<String, Object> grp : groups) {
            List<Map<String, Object>> records = (List<Map<String, Object>>) grp.get('records');
            for (Map<String, Object> rec : records) {
                Object cr = rec.get('clientRef');
                if (cr instanceof String && String.isNotBlank((String) cr)) {
                    allDeclaredAliases.add((String) cr);
                }
            }
        }

        // Pass 2: per-group structural + ref forward-only check.
        Set<String> declaredBefore = new Set<String>();
        Set<String> seenRefs = new Set<String>();
        Map<String, Schema.SObjectType> globalDescribe =
            testSkipSchemaCheck ? null : Schema.getGlobalDescribe();

        for (Integer gi = 0; gi < groups.size(); gi++) {
            Map<String, Object> grp = groups[gi];
            String sobjectName = (String) grp.get('sobject');
            Object opObj = grp.get('op');
            if (String.isBlank(sobjectName)) {
                throw new DmlAdapterException(
                    'DML_PAYLOAD_INVALID:group-' + gi + '-missing-sobject');
            }
            if (opObj == null || String.isBlank(String.valueOf(opObj))) {
                throw new DmlAdapterException(
                    'DML_PAYLOAD_INVALID:group-' + gi + '-missing-op');
            }
            String op = String.valueOf(opObj).toLowerCase();

            // G-Sec-DML-2: SObject in CMDT allow-list
            if (!allowedSobjects.contains(sobjectName)) {
                throw new DmlAdapterException('DML_SOBJECT_NOT_AUTHORIZED:' + sobjectName);
            }

            // G-Sec-DML-3: op in CMDT per-SObject ops allow-list
            Set<String> allowedOps = SF_AgenticGateway_AllowList.allowedOpsFor(target, sobjectName);
            if (!containsIgnoreCase(allowedOps, op)) {
                throw new DmlAdapterException(
                    'DML_OP_NOT_AUTHORIZED:' + sobjectName + ':' + op);
            }

            // G-Sec-DML-7: schema existence
            if (globalDescribe != null && globalDescribe.get(sobjectName) == null) {
                throw new DmlAdapterException('DML_SCHEMA_UNKNOWN:' + sobjectName);
            }

            // WP-SATA-4 G-Sec-DML-16: per-bundle FieldList-mode positive-list
            // field-write allow-list. Look up the parsed Set ONCE per group
            // (sobjectName is constant inside this group); the per-Tx cache
            // `WRITE_FIELDS_CACHE` parses each target's JSON map at most
            // once across all records / groups (governor target M per Sec
            // card § S.4 governor row + tech-design § XL-4 § Governor
            // impact). Empty / null Set under `FieldList` short-circuits to
            // `DML_FIELDLIST_NOT_CONFIGURED:<sobject>` fail-closed per Sec
            // card § S.4 TERTIARY tamper row (mirrors the JSON-parse-
            // exception swallow path in `_AllowList.ensureWriteFieldsCacheLoaded`).
            Set<String> allowedWriteFields = null;
            if (fieldListMode) {
                // D-1 fix (RM Phase 1 re-validate): inline the call. Apex compiler
                // resolved `SF_AgenticGateway_AllowList` on its own line as a
                // standalone variable identifier (not a class reference) when the
                // `.method(...)` chain wrapped to the next line — same identifier
                // inline at L367 (writePolicy) + L409 (allowedOpsFor) compiles
                // cleanly. Multiline split removed to keep lexer happy.
                allowedWriteFields = SF_AgenticGateway_AllowList.allowedWriteFieldsFor(target, sobjectName);
                if (allowedWriteFields == null || allowedWriteFields.isEmpty()) {
                    throw new DmlAdapterException(
                        'DML_FIELDLIST_NOT_CONFIGURED:' + sobjectName);
                }
            }

            List<Map<String, Object>> records = (List<Map<String, Object>>) grp.get('records');
            Set<String> aliasesDeclaredHere = new Set<String>();

            for (Integer ri = 0; ri < records.size(); ri++) {
                Map<String, Object> rec = records[ri];

                // G-Sec-DML-13: Id on insert
                if (op == 'insert' && rec.containsKey('Id') && rec.get('Id') != null) {
                    throw new DmlAdapterException(
                        'DML_ID_FORBIDDEN_ON_INSERT:group-' + gi + '-record-' + ri);
                }

                // G-Sec-DML-14: OwnerId without override
                if (rec.containsKey('OwnerId') && rec.get('OwnerId') != null && !ownerOverride) {
                    throw new DmlAdapterException(
                        'DML_OWNERID_FORBIDDEN:group-' + gi + '-record-' + ri);
                }

                // WP-SATA-4 G-Sec-DML-16: per-record positive-list field-write
                // enforcement when policy=FieldList. Iterates the record's
                // field keys; rejects with deterministic
                // `DML_FIELD_NOT_AUTHORIZED:<sobject>:<field>` for any token
                // not present in the parsed allow-list. Structural keys
                // (`clientRef` per existing contract; `Id` + `OwnerId` already
                // enforced by G-Sec-DML-13 + G-Sec-DML-14 above) are exempt
                // per tech-design § XL-4 lines 477-481 inline comment "Exempt
                // the structural keys preValidate already enforces". Per-Tx
                // governor delta ~0.05ms per 100 records (Set.contains O(1)).
                if (fieldListMode) {
                    for (String fld : rec.keySet()) {
                        if (fld == 'clientRef' || fld == 'Id' || fld == 'OwnerId') continue;
                        if (!allowedWriteFields.contains(fld)) {
                            throw new DmlAdapterException(
                                'DML_FIELD_NOT_AUTHORIZED:' + sobjectName + ':' + fld);
                        }
                    }
                }

                Object cr = rec.get('clientRef');
                if (cr instanceof String && String.isNotBlank((String) cr)) {
                    aliasesDeclaredHere.add((String) cr);
                }

                // G-Sec-DML-11: scan every field value for @ref tokens
                for (String fld : rec.keySet()) {
                    Object v = rec.get(fld);
                    if (!(v instanceof String)) continue;
                    String s = (String) v;
                    if (!s.startsWith(REF_PREFIX)) continue;
                    Matcher m = REF_PATTERN.matcher(s);
                    if (!m.matches()) {
                        String bad = s.length() > REF_PREFIX.length()
                            ? s.substring(REF_PREFIX.length())
                            : '';
                        throw new DmlAdapterException('DML_REF_UNRESOLVED:' + bad);
                    }
                    String alias = m.group(1);
                    if (!allDeclaredAliases.contains(alias)) {
                        throw new DmlAdapterException('DML_REF_UNRESOLVED:' + alias);
                    }
                    if (!declaredBefore.contains(alias)) {
                        throw new DmlAdapterException('DML_REF_FORWARD_ONLY:' + alias);
                    }
                    seenRefs.add(alias);
                    if (seenRefs.size() > MAX_REFS_PER_CALL) {
                        throw new DmlAdapterException(
                            'DML_REF_LIMIT_EXCEEDED:max=' + MAX_REFS_PER_CALL);
                    }
                }
            }
            declaredBefore.addAll(aliasesDeclaredHere);
        }
    }

    private static Boolean containsIgnoreCase(Set<String> values, String target) {
        if (values == null || values.isEmpty() || target == null) return false;
        for (String v : values) {
            if (v != null && v.equalsIgnoreCase(target)) return true;
        }
        return false;
    }

    /**
     * Per-record @ref resolver: walks each record's field values, replacing
     * any `@ref:<alias>` token with the resolved Id from aliasIdMap. Throws
     * DML_REF_UNRESOLVED if the alias is missing at resolve time (preValidate
     * already caught structural cases; this is a runtime defense-in-depth).
     *
     * Honors testForceRefUnresolved seam: when non-null, throws on the first
     * @ref encountered regardless of aliasIdMap contents.
     */
    private static void resolveRefs(
        List<Map<String, Object>> records,
        Map<String, Id> aliasIdMap
    ) {
        for (Map<String, Object> rec : records) {
            for (String fld : new Set<String>(rec.keySet())) {
                Object v = rec.get(fld);
                if (!(v instanceof String)) continue;
                String s = (String) v;
                if (!s.startsWith(REF_PREFIX)) continue;
                if (testForceRefUnresolved != null) {
                    throw new DmlAdapterException(
                        'DML_REF_UNRESOLVED:' + testForceRefUnresolved);
                }
                Matcher m = REF_PATTERN.matcher(s);
                if (!m.matches()) {
                    throw new DmlAdapterException(
                        'DML_REF_UNRESOLVED:' + s.substring(REF_PREFIX.length()));
                }
                String alias = m.group(1);
                Id resolved = aliasIdMap.get(alias);
                if (resolved == null) {
                    throw new DmlAdapterException('DML_REF_UNRESOLVED:' + alias);
                }
                rec.put(fld, resolved);
            }
        }
    }

    /**
     * Execute the per-group DML under USER_MODE (G-Sec-DML-4). Returns a
     * per-record result list shaped as {success, id?, clientRef?, message?}.
     * Populates aliasIdMap[clientRef] = SaveResult.getId() on success so the
     * next group's @ref tokens resolve. allOrNone propagates verbatim to
     * the platform call so allOrNone=true throws DmlException on first
     * failure (caught upstream in invoke).
     *
     * testForcedSaveResults seam: when set, this method skips the real
     * Database.<op> call and returns the canned per-record results for the
     * current group call. Populates aliasIdMap from canned ids when
     * success=true.
     */
    private static List<Map<String, Object>> runDml(
        String sobjectName,
        String op,
        List<Map<String, Object>> records,
        String externalIdField,
        Boolean allOrNone,
        Map<String, Id> aliasIdMap
    ) {
        if (testForcedSaveResults != null) {
            List<Map<String, Object>> rowResults =
                applyCannedSaveResults(records, aliasIdMap);
            testCallIdx++;
            return rowResults;
        }

        if (op == 'delete') {
            return runDelete(records, allOrNone);
        }

        Schema.SObjectType sObjType = Schema.getGlobalDescribe().get(sobjectName);
        if (sObjType == null) {
            throw new DmlAdapterException('DML_SCHEMA_UNKNOWN:' + sobjectName);
        }

        List<SObject> sobjs = new List<SObject>();
        for (Map<String, Object> rec : records) {
            SObject s = sObjType.newSObject();
            for (String fld : rec.keySet()) {
                if (fld == 'clientRef') continue;
                s.put(fld, rec.get(fld));
            }
            sobjs.add(s);
        }

        if (op == 'insert') {
            Database.SaveResult[] srs =
                Database.insert(sobjs, allOrNone, AccessLevel.USER_MODE);
            return shapeSaveResults(records, srs, aliasIdMap);
        }
        if (op == 'update') {
            Database.SaveResult[] srs =
                Database.update(sobjs, allOrNone, AccessLevel.USER_MODE);
            return shapeSaveResults(records, srs, aliasIdMap);
        }
        if (op == 'upsert') {
            Schema.SObjectField extId = resolveExternalIdField(sObjType, externalIdField);
            Database.UpsertResult[] urs =
                Database.upsert(sobjs, extId, allOrNone, AccessLevel.USER_MODE);
            return shapeUpsertResults(records, urs, aliasIdMap);
        }
        throw new DmlAdapterException('DML_OP_NOT_AUTHORIZED:unknown-op:' + op);
    }

    /**
     * Delete path: build a List<Id> from each record's `id` field, then
     * Database.delete(ids, allOrNone, USER_MODE). Records missing `id` are
     * surfaced as per-record failures pre-DML (don't trip a whole atomic
     * call over one malformed row when allOrNone=false).
     */
    private static List<Map<String, Object>> runDelete(
        List<Map<String, Object>> records,
        Boolean allOrNone
    ) {
        List<Map<String, Object>> rowResults = new List<Map<String, Object>>();
        List<Id> ids = new List<Id>();
        List<Integer> idxMap = new List<Integer>();
        for (Integer i = 0; i < records.size(); i++) {
            Map<String, Object> rec = records[i];
            Object idVal = rec.get('id');
            if (idVal == null) idVal = rec.get('Id');
            if (idVal == null) {
                rowResults.add(new Map<String, Object>{
                    'success' => false,
                    'clientRef' => rec.get('clientRef'),
                    'message' => 'DML_DELETE_MISSING_ID:record-' + i
                });
                continue;
            }
            try {
                ids.add(Id.valueOf(String.valueOf(idVal)));
                idxMap.add(i);
            } catch (Exception bad) {
                rowResults.add(new Map<String, Object>{
                    'success' => false,
                    'clientRef' => rec.get('clientRef'),
                    'message' => 'DML_DELETE_INVALID_ID:record-' + i
                });
            }
        }
        if (ids.isEmpty()) {
            testCallIdx++;
            return rowResults;
        }
        Database.DeleteResult[] drs =
            Database.delete(ids, allOrNone, AccessLevel.USER_MODE);
        for (Integer i = 0; i < drs.size(); i++) {
            Database.DeleteResult dr = drs[i];
            Map<String, Object> rec = records[idxMap[i]];
            Map<String, Object> row = new Map<String, Object>{
                'success' => dr.isSuccess(),
                'clientRef' => rec.get('clientRef')
            };
            if (dr.isSuccess()) {
                row.put('id', dr.getId());
            } else {
                row.put('message', formatDmlErrors(dr.getErrors()));
            }
            rowResults.add(row);
        }
        testCallIdx++;
        return rowResults;
    }

    private static Schema.SObjectField resolveExternalIdField(
        Schema.SObjectType sObjType,
        String fieldName
    ) {
        if (String.isBlank(fieldName)) {
            throw new DmlAdapterException('DML_EXTERNAL_ID_FIELD_INVALID:blank');
        }
        Schema.SObjectField field = sObjType.getDescribe().fields.getMap().get(fieldName);
        if (field == null) {
            throw new DmlAdapterException('DML_EXTERNAL_ID_FIELD_INVALID:' + fieldName);
        }
        return field;
    }

    /**
     * Walk SaveResult[] alongside the source records, populating aliasIdMap
     * with successful clientRef → Id pairs so later groups can resolve
     * `@ref:<alias>` tokens. Errors normalized to `STATUS_CODE: message`
     * (G-Sec-DML-9); stack traces never propagated.
     */
    private static List<Map<String, Object>> shapeSaveResults(
        List<Map<String, Object>> records,
        Database.SaveResult[] srs,
        Map<String, Id> aliasIdMap
    ) {
        List<Map<String, Object>> rowResults = new List<Map<String, Object>>();
        for (Integer i = 0; i < srs.size(); i++) {
            Database.SaveResult sr = srs[i];
            Map<String, Object> rec = records[i];
            String clientRef = (String) rec.get('clientRef');
            Map<String, Object> row = new Map<String, Object>{
                'success' => sr.isSuccess(),
                'clientRef' => clientRef
            };
            if (sr.isSuccess()) {
                row.put('id', sr.getId());
                if (String.isNotBlank(clientRef) && sr.getId() != null) {
                    aliasIdMap.put(clientRef, sr.getId());
                }
            } else {
                row.put('message', formatDmlErrors(sr.getErrors()));
            }
            rowResults.add(row);
        }
        testCallIdx++;
        return rowResults;
    }

    private static List<Map<String, Object>> shapeUpsertResults(
        List<Map<String, Object>> records,
        Database.UpsertResult[] urs,
        Map<String, Id> aliasIdMap
    ) {
        List<Map<String, Object>> rowResults = new List<Map<String, Object>>();
        for (Integer i = 0; i < urs.size(); i++) {
            Database.UpsertResult ur = urs[i];
            Map<String, Object> rec = records[i];
            String clientRef = (String) rec.get('clientRef');
            Map<String, Object> row = new Map<String, Object>{
                'success' => ur.isSuccess(),
                'clientRef' => clientRef
            };
            if (ur.isSuccess()) {
                row.put('id', ur.getId());
                if (String.isNotBlank(clientRef) && ur.getId() != null) {
                    aliasIdMap.put(clientRef, ur.getId());
                }
            } else {
                row.put('message', formatDmlErrors(ur.getErrors()));
            }
            rowResults.add(row);
        }
        testCallIdx++;
        return rowResults;
    }

    /**
     * Test-seam canned-result projection. Walks the records list, picking
     * the i-th canned entry from testForcedSaveResults[testCallIdx]. Missing
     * canned entries fall back to a synthetic success=false row. Populates
     * aliasIdMap from canned ids on success=true so chained-ref tests work.
     */
    private static List<Map<String, Object>> applyCannedSaveResults(
        List<Map<String, Object>> records,
        Map<String, Id> aliasIdMap
    ) {
        List<Map<String, Object>> rowResults = new List<Map<String, Object>>();
        List<Object> canned = (testCallIdx < testForcedSaveResults.size())
            ? testForcedSaveResults[testCallIdx]
            : new List<Object>();
        for (Integer i = 0; i < records.size(); i++) {
            Map<String, Object> rec = records[i];
            String clientRef = (String) rec.get('clientRef');
            Map<String, Object> row = new Map<String, Object>{ 'clientRef' => clientRef };
            if (i < canned.size() && canned[i] instanceof Map<String, Object>) {
                Map<String, Object> c = (Map<String, Object>) canned[i];
                Boolean success = c.get('success') == true;
                row.put('success', success);
                Object idVal = c.get('id');
                if (success && idVal != null) {
                    String idStr = String.valueOf(idVal);
                    row.put('id', idStr);
                    if (String.isNotBlank(clientRef)) {
                        try {
                            aliasIdMap.put(clientRef, Id.valueOf(idStr));
                        } catch (Exception ignore) {
                            // canned id not a real SF Id — leave aliasIdMap untouched
                        }
                    }
                }
                Object msg = c.get('message');
                if (!success) {
                    row.put('message',
                        msg == null ? 'DML_FORCED_FAILURE:test-seam' : String.valueOf(msg));
                }
            } else {
                row.put('success', false);
                row.put('message', 'DML_NO_CANNED_RESULT:idx=' + i);
            }
            rowResults.add(row);
        }
        return rowResults;
    }

    /**
     * Normalize List<Database.Error> to `STATUS_CODE: message` joined by `|`.
     * Never propagates stack traces (G-Sec-DML-5/9).
     */
    @TestVisible
    private static String formatDmlErrors(List<Database.Error> errs) {
        if (errs == null || errs.isEmpty()) return 'DML_UNKNOWN_ERROR';
        List<String> parts = new List<String>();
        for (Database.Error e : errs) {
            parts.add(String.valueOf(e.getStatusCode()) + ': ' + e.getMessage());
        }
        return String.join(parts, ' | ');
    }

    /**
     * Extract DmlException's first-row message without leaking stack
     * trace or array-index quirks. Falls back to getMessage() when the
     * platform exception carries no row-scoped detail.
     */
    private static String safeDmlMessage(DmlException dmlEx) {
        try {
            Integer count = dmlEx.getNumDml();
            if (count > 0) {
                return String.valueOf(dmlEx.getDmlStatusCode(0))
                    + ': ' + dmlEx.getDmlMessage(0);
            }
        } catch (Exception ignore) {
            // platform variance — fall through
        }
        return dmlEx.getMessage();
    }

    /**
     * Wave-3 DML-AUDIT-1 (G-Sec-DML-15): per-record audit child insert.
     * Pre-DML budget guard (`assertDmlRowsOk`) intersects with the test
     * seam `testForceAuditItemsRowsBreach`. On budget breach, parent audit
     * row is flipped Truncated__c=true and items insert is skipped — never
     * fails the dispatch. Any other exception during build/insert is
     * swallowed to a debug log (best-effort observability tier).
     *
     * Audit Id is the M-D parent — caller MUST have committed the audit row
     * before invoking this helper (the gateway pre-inserts it OUTSIDE the
     * dispatch savepoint so it survives any rollback).
     */
    private static void insertAuditItems(
        List<Map<String, Object>> outGroups,
        Id auditId
    ) {
        try {
            if (testForceAuditItemsRowsBreach) {
                throw new SF_AgenticGateway_Limits.LimitExceededException(
                    'GOVERNOR_BUDGET_EXCEEDED:DML_ROWS');
            }
            SF_AgenticGateway_Limits.assertDmlRowsOk();
            List<SF_AgenticInvocation_Item__c> items = buildAuditItems(outGroups, auditId);
            if (!items.isEmpty()) {
                Database.insert(items, false, AccessLevel.USER_MODE);
            }
        } catch (SF_AgenticGateway_Limits.LimitExceededException budgetEx) {
            // Pre-DML guard tripped — mark Truncated__c=true on the audit row
            // AND set the per-Tx flag so the gateway's finalizeAudit
            // preserves the truncation signal on its post-dispatch UPDATE.
            lastItemsTruncated = true;
            markAuditTruncated(auditId);
        } catch (Exception itemEx) {
            // Best-effort items insert; never fail the dispatch.
            System.debug(LoggingLevel.WARN,
                '[DmlAdapter] items insert failed: ' + itemEx.getMessage());
        }
    }

    /**
     * Walk outGroups[*].results to build a flat List of items mirroring the
     * adapter's per-record result shape. Each item carries M-D parent =
     * auditId plus 8 forensic fields (SObjectName, Op, ClientRef, RecordId,
     * Success, Message, GroupIndex, RecordIndex). Message is truncated to
     * 256 chars (matches field length cap + G-Sec-DML-9 sanitisation).
     */
    @TestVisible
    private static List<SF_AgenticInvocation_Item__c> buildAuditItems(
        List<Map<String, Object>> outGroups,
        Id auditId
    ) {
        List<SF_AgenticInvocation_Item__c> items = new List<SF_AgenticInvocation_Item__c>();
        if (outGroups == null) return items;
        for (Integer gi = 0; gi < outGroups.size(); gi++) {
            Map<String, Object> grp = outGroups[gi];
            String sobjectName = (String) grp.get('sobject');
            String op = (String) grp.get('op');
            Object resultsObj = grp.get('results');
            if (!(resultsObj instanceof List<Object>)) continue;
            List<Object> rows = (List<Object>) resultsObj;
            for (Integer ri = 0; ri < rows.size(); ri++) {
                Object rowObj = rows[ri];
                if (!(rowObj instanceof Map<String, Object>)) continue;
                Map<String, Object> row = (Map<String, Object>) rowObj;
                SF_AgenticInvocation_Item__c item = new SF_AgenticInvocation_Item__c(
                    SF_AgenticInvocation__c = auditId,
                    SObjectName__c = sobjectName,
                    Op__c = op,
                    ClientRef__c = (String) row.get('clientRef'),
                    RecordId__c = row.get('id') == null ? null : String.valueOf(row.get('id')),
                    Success__c = row.get('success') == true,
                    Message__c = truncateMessage((String) row.get('message')),
                    GroupIndex__c = gi,
                    RecordIndex__c = ri
                );
                items.add(item);
            }
        }
        return items;
    }

    /**
     * Wave-3 DML-AUDIT-1 (G-Sec-DML-15): flip parent audit row's
     * `Truncated__c` to true when items insert was skipped due to DML-rows
     * budget. Best-effort — failure to flip never fails the dispatch.
     */
    private static void markAuditTruncated(Id auditId) {
        if (auditId == null) return;
        try {
            List<SF_AgenticInvocation__c> updates = new List<SF_AgenticInvocation__c>{
                new SF_AgenticInvocation__c(Id = auditId, Truncated__c = true)
            };
            Database.update(updates, false, AccessLevel.USER_MODE);
        } catch (Exception ignore) {
            // Best-effort flag flip; swallow.
        }
    }

    /** Truncate a message to the 255-char cap matching Message__c length. */
    private static String truncateMessage(String msg) {
        if (msg == null) return null;
        return msg.length() > 255 ? msg.substring(0, 255) : msg;
    }
}