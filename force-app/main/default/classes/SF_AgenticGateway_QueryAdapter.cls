/**
 * SF_AgenticGateway_QueryAdapter — eighth dispatch surface (`query:<bundle>`)
 * for the gateway. Turns a JSON contract `{queries:[{sobject, fields[],
 * where, orderBy, limit, offset}]}` into one or more SOQL queries executed
 * under USER_MODE against CMDT-allow-listed SObjects + fields, and returns
 * structured records through the same byte-stable Response envelope as
 * `dml:`.
 *
 * Locked design: docs/sf-agentic-gateway-query-adapter-2026-05-20.md
 * Sec threat model: docs/sf-agentic-gateway-query-adapter-2026-05-20-sec-threat-model.md
 * Plan: .cursor/plans/sf-agentic-gateway-query-adapter_d725fe83.plan.md
 *
 * Contract:
 *   Payload: {"allowPartial":bool, "queries":[
 *     {"alias":"acct", "sobject":"Account",
 *      "fields":["Id","Name","Owner.Email"],
 *      "where":{"and":[{"field":"Industry","op":"eq","value":"Banking"}]},
 *      "orderBy":[{"field":"CreatedDate","direction":"desc","nullsLast":true}],
 *      "limit":25, "offset":0}
 *   ]}
 *   Response: {"queries":[{"alias","sobject","records","totalSize","done",
 *     "nextOffset","error?"}], "errors?":[]}
 *
 * Sec gates (§6 of locked design):
 *   G-Sec-QUERY-1: CMDT row Active=true + DispatchType=Query (gateway-level)
 *   G-Sec-QUERY-2: CMDT Sobjects__c allow-list (preValidate)
 *   G-Sec-QUERY-3: CMDT AllowedFieldsBySobject__c per-SObject fields (preValidate + buildSoql + buildWhere + buildOrderBy)
 *   G-Sec-QUERY-4: USER_MODE on every Database.queryWithBinds (runQueries)
 *   G-Sec-QUERY-5: stack traces never propagated (catch → code:message)
 *   G-Sec-QUERY-6: MAX_QUERIES_PER_CALL=5 (Limits.assertQueriesOk)
 *   G-Sec-QUERY-7: Schema.getGlobalDescribe().get(sobject)!=null + fields.getMap().containsKey(field) (preValidate + validateFieldPath)
 *   G-Sec-QUERY-8: MAX_QUERY_ROWS_PER_CALL=200 (Limits.assertQueryRowsOk + per-query clamp)
 *   G-Sec-QUERY-9: per-query errors normalised to code:message (runQueries catch + shapeError)
 *   G-Sec-QUERY-10: MAX_QUERY_DISPATCHES_PER_TX=5 (Limits.assertQueryDispatchCountOk)
 *   G-Sec-QUERY-11: WHERE + ORDER BY fields cross-checked against AllowedFieldsBySobject__c (buildWhere + buildOrderBy)
 *   G-Sec-QUERY-12: bind-variable-only — identifiers via Schema, values via Map<String,Object> bindMap consumed by Database.queryWithBinds; zero String.format, zero raw value concat (buildSoql + buildWhere)
 *   G-Sec-QUERY-13: parent-field traversal depth ≤ MAX_QUERY_DEPTH=3 (validateFieldPath)
 *   G-Sec-QUERY-14: hardcoded operator accept-list {eq,ne,in,nin,like,lt,le,gt,ge,isNull,notNull,and,or,not} (buildWhere switch)
 *
 * `with sharing` is non-negotiable. USER_MODE on every queryWithBinds is the
 * platform-level FLS + sharing + CRUD enforcement; the CMDT allow-list is
 * the second wall on top of that.
 */
public with sharing class SF_AgenticGateway_QueryAdapter implements IAgenticAdapter {

    public class QueryAdapterException extends Exception {}

    /**
     * WP-L-Dispatcher-Drift Phase 1 (audit finding L-5): polymorphic
     * dispatch entry. Per Sec card § Card · WP-L-Dispatcher-Drift
     * assertion (a) — Query already has AllowList propagation via
     * the wave-3 `SF_AgenticGateway.invokeOne` line 215 entry-time
     * gate (G-Sec-QUERY-1) AND the WP-SATA-3 `dispatchSync` line 315
     * runtime AllowList re-check (G-Sec-DML-17). Adding a third gate
     * here would be dead code (third identical verdict per Tx CACHE
     * lookup). `dispatch` delegates to the existing static
     * `invoke(...)` signature verbatim — backwards-compat facade.
     *
     * Wave-3 per-bundle G-Sec-QUERY-2 (Sobjects__c allow-list) +
     * G-Sec-QUERY-3 (AllowedFieldsBySobject__c per-SObject fields)
     * + G-Sec-QUERY-4 (USER_MODE) gates stay inside the static
     * `invoke` body verbatim — this dispatch wrapper is the L-5
     * interface introduction ONLY.
     */
    public Object dispatch(String target, Map<String, Object> args) {
        String payloadJson = (String) args.get('payloadJson');
        String correlationId = (String) args.get('correlationId');
        return invoke(target, payloadJson, correlationId);
    }

    /**
     * G-Sec-QUERY-13: parent-field traversal cap. Mirrors
     * `SF_AgenticGateway_Limits.MAX_QUERY_DEPTH` (kept local because the
     * Limits copy is `@TestVisible private` and not callable from this
     * class at runtime). Both copies MUST stay in sync.
     */
    @TestVisible
    private static final Integer MAX_QUERY_DEPTH = 3;

    /**
     * G-Sec-QUERY-14: hardcoded leaf-operator accept-list. Anything else
     * → QUERY_OP_FORBIDDEN before reaching the SOQL builder. Logical
     * groups (and/or/not) are handled by `buildWhere` recursion above the
     * leaf switch.
     */
    private static final Set<String> ALLOWED_LEAF_OPS = new Set<String>{
        'eq', 'ne', 'in', 'nin', 'like',
        'lt', 'le', 'gt', 'ge',
        'isnull', 'notnull'
    };

    /** Platform OFFSET cap — Salesforce hard-limits OFFSET to 2000. */
    private static final Integer PLATFORM_OFFSET_CAP = 2000;

    /** Max fields per query — bounds parsing cost and SELECT length. */
    private static final Integer MAX_FIELDS_PER_QUERY = 50;

    /** Max orderBy entries per query — keeps the ORDER BY tail bounded. */
    private static final Integer MAX_ORDER_BY_PER_QUERY = 5;

    /**
     * @TestVisible test seam — when non-null, runQueries short-circuits
     * the real Database.queryWithBinds call and returns the canned
     * `List<SObject>` indexed by testCallIdx. Tests reset to null between
     * scenarios. Used in conjunction with `testSkipSchemaCheck=true` to
     * inject synthetic Account/Case rows without crafting real records.
     */
    @TestVisible
    private static List<List<SObject>> testForcedRecords = null;

    /**
     * @TestVisible test seam — when true, preValidate skips the
     * Schema.getGlobalDescribe().get(sobject) existence check and
     * validateFieldPath skips the parent-traversal Schema walk
     * (G-Sec-QUERY-7). Depth check (G-Sec-QUERY-13) still fires.
     */
    @TestVisible
    private static Boolean testSkipSchemaCheck = false;

    /**
     * @TestVisible test seam — when non-null, runQueries throws
     * QueryAdapterException('QUERY_USER_MODE_DENIED:<value>') on the
     * first per-query attempt. Exercises G-Sec-QUERY-4 deny path without
     * crafting real org FLS denials.
     */
    @TestVisible
    private static String testForceUserModeDenied = null;

    /**
     * Per-invocation counter for the testForcedRecords + testCapturedCalls
     * seams. Resets at the start of every invoke() so each test invocation
     * gets a fresh sequence regardless of prior calls in the same Tx.
     */
    @TestVisible
    private static Integer testCallIdx = 0;

    /**
     * @TestVisible test seam — when non-null, every runQueries call
     * appends {soql, bindMap, accessLevel} to this list. Used by T-25
     * (USER_MODE evidence) + T-14 (bind-only proof) to assert
     * G-Sec-QUERY-4 + G-Sec-QUERY-12 invariants without inspecting
     * platform internals.
     */
    @TestVisible
    private static List<Map<String, Object>> testCapturedCalls = null;

    /**
     * Invoke the multi-query SOQL adapter. Each query is independent and
     * side-effect-free; per-query errors honour `allowPartial`:
     *  - allowPartial=false (default): first failing query short-circuits
     *    the bundle → caller sees Response.success=false. No records leak.
     *  - allowPartial=true: per-query error captured into
     *    data.queries[i].error; surviving queries return records.
     *
     * @param target        CMDT Target__c (bundle name) — e.g. "AccountLookupBundle"
     * @param payloadJson   JSON {allowPartial, queries:[{alias, sobject, fields, where, orderBy, limit, offset}]}
     * @param correlationId Gateway correlationId (echoed; no record values logged)
     * @return Map shaped as {queries:[{alias, sobject, records, totalSize, done, nextOffset, error?}]}
     */
    public static Map<String, Object> invoke(
        String target,
        String payloadJson,
        String correlationId
    ) {
        testCallIdx = 0;
        SF_AgenticGateway_Limits.assertQueryDispatchCountOk();
        SF_AgenticGateway_Limits.assertCpuOk();
        SF_AgenticGateway_Limits.assertHeapOk();
        SF_AgenticGateway_Limits.assertPayloadSizeOk(payloadJson);

        if (String.isBlank(target)) {
            throw new QueryAdapterException('QUERY_BUNDLE_NOT_FOUND_OR_INVALID:blank-name');
        }

        try {
            Map<String, Object> parsed = parsePayload(payloadJson);
            Boolean allowPartial = parsed.containsKey('allowPartial')
                && parsed.get('allowPartial') != null
                ? (Boolean) parsed.get('allowPartial')
                : false;

            Object rawQueriesObj = parsed.get('queries');
            if (!(rawQueriesObj instanceof List<Object>)) {
                throw new QueryAdapterException('QUERY_PAYLOAD_INVALID:queries-missing');
            }
            List<Object> rawQueries = (List<Object>) rawQueriesObj;
            if (rawQueries.isEmpty()) {
                throw new QueryAdapterException('QUERY_PAYLOAD_INVALID:queries-empty');
            }
            // G-Sec-QUERY-6: bundle size cap (global + per-bundle intersection)
            SF_AgenticGateway_Limits.assertQueriesOk(rawQueries.size());
            Integer bundleQueryCap = SF_AgenticGateway_AllowList.maxQueriesPerCall(target);
            if (rawQueries.size() > bundleQueryCap) {
                throw new SF_AgenticGateway_Limits.LimitExceededException(
                    'GOVERNOR_BUDGET_EXCEEDED:QUERY_QUERIES');
            }

            List<Map<String, Object>> queries = normalizeQueries(rawQueries);
            Set<String> allowedSobjects = SF_AgenticGateway_AllowList.allowedSobjects(target);
            Integer bundleRowsCap = SF_AgenticGateway_AllowList.maxQueryRows(target);

            preValidate(target, queries, allowedSobjects);

            List<Map<String, Object>> outQueries = new List<Map<String, Object>>();
            for (Integer qi = 0; qi < queries.size(); qi++) {
                Map<String, Object> q = queries[qi];
                String alias = (String) q.get('alias');
                String sobjectName = (String) q.get('sobject');
                Set<String> allowedFields =
                    SF_AgenticGateway_AllowList.allowedFieldsFor(target, sobjectName);
                try {
                    Integer offset = readOffset(q);
                    Integer effectiveLimit = computeEffectiveLimit(q, bundleRowsCap);
                    BindContext bc = new BindContext();
                    String soql = buildSoql(
                        sobjectName, q, allowedFields, bc, effectiveLimit, offset);
                    List<SObject> records = runQueries(soql, bc.binds);
                    outQueries.add(shapeResult(
                        alias, sobjectName, records, effectiveLimit, offset));
                } catch (QueryAdapterException qae) {
                    if (!allowPartial) {
                        throw qae;
                    }
                    outQueries.add(shapeError(alias, sobjectName, qae.getMessage()));
                } catch (QueryException qx) {
                    String normalized = normaliseQueryException(qx);
                    if (!allowPartial) {
                        throw new QueryAdapterException(normalized);
                    }
                    outQueries.add(shapeError(alias, sobjectName, normalized));
                } catch (Exception other) {
                    String normalized = other.getTypeName() + ': ' + other.getMessage();
                    if (!allowPartial) {
                        throw new QueryAdapterException(normalized);
                    }
                    outQueries.add(shapeError(alias, sobjectName, normalized));
                }
            }
            return new Map<String, Object>{ 'queries' => outQueries };
        } catch (QueryAdapterException known) {
            throw known;
        } catch (SF_AgenticGateway_Limits.LimitExceededException limEx) {
            throw limEx;
        } catch (QueryException qx) {
            throw new QueryAdapterException(normaliseQueryException(qx));
        } catch (Exception other) {
            throw new QueryAdapterException(
                other.getTypeName() + ': ' + other.getMessage());
        }
    }

    /**
     * Untyped JSON parse + defensive shape check. Throws
     * QUERY_PAYLOAD_INVALID:<reason> on malformed input; never lets a
     * JSONException surface to the gateway (G-Sec-QUERY-5).
     */
    @TestVisible
    private static Map<String, Object> parsePayload(String payloadJson) {
        if (String.isBlank(payloadJson)) {
            throw new QueryAdapterException('QUERY_PAYLOAD_INVALID:blank');
        }
        Object raw;
        try {
            raw = JSON.deserializeUntyped(payloadJson);
        } catch (Exception jex) {
            throw new QueryAdapterException('QUERY_PAYLOAD_INVALID:malformed-json');
        }
        if (!(raw instanceof Map<String, Object>)) {
            throw new QueryAdapterException('QUERY_PAYLOAD_INVALID:not-object');
        }
        return (Map<String, Object>) raw;
    }

    /**
     * Coerce the untyped `queries` List<Object> into List<Map<String,Object>>,
     * preserving order. Malformed entries raise QUERY_PAYLOAD_INVALID with
     * the offending query index.
     */
    private static List<Map<String, Object>> normalizeQueries(List<Object> rawQueries) {
        List<Map<String, Object>> out = new List<Map<String, Object>>();
        for (Integer qi = 0; qi < rawQueries.size(); qi++) {
            Object q = rawQueries[qi];
            if (!(q instanceof Map<String, Object>)) {
                throw new QueryAdapterException(
                    'QUERY_PAYLOAD_INVALID:query-' + qi + '-not-object');
            }
            out.add((Map<String, Object>) q);
        }
        return out;
    }

    /**
     * Sec gates G-Sec-QUERY-2/3/7: fail-fast structural + allow-list +
     * Schema-existence validation BEFORE any SOQL is emitted. WHERE +
     * ORDER BY field allow-list checks (G-Sec-QUERY-11) and depth checks
     * (G-Sec-QUERY-13) happen inside buildSoql / buildWhere /
     * buildOrderBy where the AST is walked.
     */
    private static void preValidate(
        String target,
        List<Map<String, Object>> queries,
        Set<String> allowedSobjects
    ) {
        Map<String, Schema.SObjectType> globalDescribe =
            testSkipSchemaCheck ? null : Schema.getGlobalDescribe();

        for (Integer qi = 0; qi < queries.size(); qi++) {
            Map<String, Object> q = queries[qi];
            Object aliasObj = q.get('alias');
            Object sobjectObj = q.get('sobject');
            Object fieldsObj = q.get('fields');

            if (!(aliasObj instanceof String) || String.isBlank((String) aliasObj)) {
                throw new QueryAdapterException(
                    'QUERY_PAYLOAD_INVALID:query-' + qi + '-missing-alias');
            }
            if (((String) aliasObj).length() > 64) {
                throw new QueryAdapterException(
                    'QUERY_PAYLOAD_INVALID:query-' + qi + '-alias-too-long');
            }
            if (!(sobjectObj instanceof String) || String.isBlank((String) sobjectObj)) {
                throw new QueryAdapterException(
                    'QUERY_PAYLOAD_INVALID:query-' + qi + '-missing-sobject');
            }
            if (!(fieldsObj instanceof List<Object>)) {
                throw new QueryAdapterException(
                    'QUERY_PAYLOAD_INVALID:query-' + qi + '-missing-fields');
            }

            String sobjectName = (String) sobjectObj;

            // G-Sec-QUERY-2: SObject in CMDT allow-list
            if (!containsIgnoreCaseStr(allowedSobjects, sobjectName)) {
                throw new QueryAdapterException(
                    'QUERY_SOBJECT_NOT_AUTHORIZED:' + sobjectName);
            }
            // G-Sec-QUERY-7: Schema existence (skipped under testSkipSchemaCheck)
            if (globalDescribe != null && globalDescribe.get(sobjectName) == null) {
                throw new QueryAdapterException('QUERY_SCHEMA_UNKNOWN:' + sobjectName);
            }
        }
    }

    /**
     * G-Sec-QUERY-12: identifiers cross-checked against Schema /
     * allow-list; values flow into bc.binds keyed by server-minted
     * `b0,b1,…` tokens. The SOQL string is built from validated
     * identifiers + literal operator tokens + `:bN` references — zero
     * String.format, zero raw value concat.
     */
    private static String buildSoql(
        String sobjectName,
        Map<String, Object> query,
        Set<String> allowedFields,
        BindContext bc,
        Integer effectiveLimit,
        Integer offset
    ) {
        List<Object> rawFields = (List<Object>) query.get('fields');
        if (rawFields.isEmpty()) {
            throw new QueryAdapterException('QUERY_PAYLOAD_INVALID:fields-empty');
        }
        if (rawFields.size() > MAX_FIELDS_PER_QUERY) {
            throw new QueryAdapterException(
                'QUERY_PAYLOAD_INVALID:fields-cap:' + MAX_FIELDS_PER_QUERY);
        }

        List<String> fields = new List<String>();
        for (Object fo : rawFields) {
            if (!(fo instanceof String) || String.isBlank((String) fo)) {
                throw new QueryAdapterException(
                    'QUERY_PAYLOAD_INVALID:field-not-string');
            }
            String fld = (String) fo;
            // G-Sec-QUERY-3: SELECT field in CMDT field allow-list
            if (!containsIgnoreCaseStr(allowedFields, fld)) {
                throw new QueryAdapterException(
                    'QUERY_FIELD_NOT_AUTHORIZED:' + sobjectName + '.' + fld);
            }
            // G-Sec-QUERY-7 + G-Sec-QUERY-13: schema + depth check
            validateFieldPath(fld, sobjectName);
            fields.add(fld);
        }

        String selectClause = 'SELECT ' + String.join(fields, ', ');
        String fromClause = ' FROM ' + sobjectName;

        String whereClause = '';
        if (query.containsKey('where') && query.get('where') != null) {
            whereClause = ' WHERE '
                + buildWhere(query.get('where'), sobjectName, allowedFields, bc);
        }

        String orderClause = '';
        Object orderByObj = query.get('orderBy');
        if (orderByObj instanceof List<Object>) {
            List<Object> rawOrder = (List<Object>) orderByObj;
            if (!rawOrder.isEmpty()) {
                orderClause = ' ORDER BY '
                    + buildOrderBy(rawOrder, sobjectName, allowedFields);
            }
        } else if (orderByObj != null) {
            throw new QueryAdapterException(
                'QUERY_PAYLOAD_INVALID:orderBy-not-list');
        }

        String limitClause = ' LIMIT ' + String.valueOf(effectiveLimit);
        String offsetClause = offset > 0
            ? ' OFFSET ' + String.valueOf(offset)
            : '';

        return selectClause + fromClause + whereClause + orderClause
            + limitClause + offsetClause;
    }

    /**
     * G-Sec-QUERY-14: hardcoded operator accept-list + AST recursion.
     * G-Sec-QUERY-11: every WHERE-leaf field cross-checked against
     * allowedFields. Logical groups (and/or/not) recurse above the leaf
     * switch; anything outside the table → QUERY_OP_FORBIDDEN at parse.
     */
    private static String buildWhere(
        Object rawNode,
        String sobjectName,
        Set<String> allowedFields,
        BindContext bc
    ) {
        if (!(rawNode instanceof Map<String, Object>)) {
            throw new QueryAdapterException(
                'QUERY_PAYLOAD_INVALID:where-not-object');
        }
        Map<String, Object> node = (Map<String, Object>) rawNode;

        if (node.containsKey('and')) {
            return buildLogical(node.get('and'), 'and', 'AND',
                sobjectName, allowedFields, bc);
        }
        if (node.containsKey('or')) {
            return buildLogical(node.get('or'), 'or', 'OR',
                sobjectName, allowedFields, bc);
        }
        if (node.containsKey('not')) {
            return '(NOT '
                + buildWhere(node.get('not'), sobjectName, allowedFields, bc)
                + ')';
        }

        Object fieldObj = node.get('field');
        Object opObj = node.get('op');
        if (!(fieldObj instanceof String) || String.isBlank((String) fieldObj)) {
            throw new QueryAdapterException(
                'QUERY_PAYLOAD_INVALID:where-leaf-missing-field');
        }
        if (!(opObj instanceof String) || String.isBlank((String) opObj)) {
            throw new QueryAdapterException(
                'QUERY_PAYLOAD_INVALID:where-leaf-missing-op');
        }
        String field = (String) fieldObj;
        String op = ((String) opObj).toLowerCase();

        if (!ALLOWED_LEAF_OPS.contains(op)) {
            throw new QueryAdapterException('QUERY_OP_FORBIDDEN:' + op);
        }
        if (!containsIgnoreCaseStr(allowedFields, field)) {
            throw new QueryAdapterException(
                'QUERY_FIELD_NOT_AUTHORIZED:' + sobjectName + '.' + field);
        }
        validateFieldPath(field, sobjectName);

        Object value = node.get('value');

        if (op == 'isnull')  return field + ' = null';
        if (op == 'notnull') return field + ' != null';

        if (op == 'in' || op == 'nin') {
            if (!(value instanceof List<Object>)) {
                throw new QueryAdapterException('QUERY_VALUE_NOT_LIST:' + op);
            }
            if (((List<Object>) value).isEmpty()) {
                throw new QueryAdapterException('QUERY_VALUE_LIST_EMPTY:' + op);
            }
            String tok = bc.nextToken();
            bc.binds.put(tok, value);
            return field + (op == 'in' ? ' IN :' : ' NOT IN :') + tok;
        }

        if (op == 'like') {
            if (!(value instanceof String)) {
                throw new QueryAdapterException('QUERY_VALUE_NOT_STRING:like');
            }
            String tok = bc.nextToken();
            bc.binds.put(tok, value);
            return field + ' LIKE :' + tok;
        }

        if (value == null) {
            throw new QueryAdapterException('QUERY_VALUE_MISSING:' + op);
        }
        String tok = bc.nextToken();
        bc.binds.put(tok, value);
        if (op == 'eq') return field + ' = :' + tok;
        if (op == 'ne') return field + ' != :' + tok;
        if (op == 'lt') return field + ' < :' + tok;
        if (op == 'le') return field + ' <= :' + tok;
        if (op == 'gt') return field + ' > :' + tok;
        if (op == 'ge') return field + ' >= :' + tok;
        throw new QueryAdapterException('QUERY_OP_FORBIDDEN:' + op);
    }

    private static String buildLogical(
        Object rawChildren,
        String logicalKey,
        String soqlKeyword,
        String sobjectName,
        Set<String> allowedFields,
        BindContext bc
    ) {
        if (!(rawChildren instanceof List<Object>)) {
            throw new QueryAdapterException(
                'QUERY_PAYLOAD_INVALID:' + logicalKey + '-not-list');
        }
        List<Object> children = (List<Object>) rawChildren;
        if (children.isEmpty()) {
            throw new QueryAdapterException('QUERY_LOGICAL_EMPTY:' + logicalKey);
        }
        List<String> parts = new List<String>();
        for (Object child : children) {
            parts.add(buildWhere(child, sobjectName, allowedFields, bc));
        }
        return '(' + String.join(parts, ' ' + soqlKeyword + ' ') + ')';
    }

    /**
     * G-Sec-QUERY-11: ORDER BY fields cross-checked against allowedFields
     * (defence beyond USER_MODE — keeps the AST honest before
     * queryWithBinds). Direction limited to {asc,desc}; nullsLast flag
     * → NULLS LAST suffix.
     */
    private static String buildOrderBy(
        List<Object> rawOrder,
        String sobjectName,
        Set<String> allowedFields
    ) {
        if (rawOrder.size() > MAX_ORDER_BY_PER_QUERY) {
            throw new QueryAdapterException(
                'QUERY_PAYLOAD_INVALID:orderBy-cap:' + MAX_ORDER_BY_PER_QUERY);
        }
        List<String> parts = new List<String>();
        for (Integer i = 0; i < rawOrder.size(); i++) {
            Object raw = rawOrder[i];
            if (!(raw instanceof Map<String, Object>)) {
                throw new QueryAdapterException(
                    'QUERY_PAYLOAD_INVALID:orderBy-' + i + '-not-object');
            }
            Map<String, Object> entry = (Map<String, Object>) raw;
            Object fieldObj = entry.get('field');
            if (!(fieldObj instanceof String) || String.isBlank((String) fieldObj)) {
                throw new QueryAdapterException(
                    'QUERY_PAYLOAD_INVALID:orderBy-' + i + '-missing-field');
            }
            String field = (String) fieldObj;
            if (!containsIgnoreCaseStr(allowedFields, field)) {
                throw new QueryAdapterException(
                    'QUERY_FIELD_NOT_AUTHORIZED:' + sobjectName + '.' + field);
            }
            validateFieldPath(field, sobjectName);

            String direction = 'ASC';
            Object dirObj = entry.get('direction');
            if (dirObj instanceof String && String.isNotBlank((String) dirObj)) {
                String dirLower = ((String) dirObj).toLowerCase();
                if (dirLower == 'asc')  direction = 'ASC';
                else if (dirLower == 'desc') direction = 'DESC';
                else throw new QueryAdapterException(
                    'QUERY_PAYLOAD_INVALID:orderBy-' + i + '-bad-direction:' + dirObj);
            }
            String nullsClause = '';
            Object nullsLastObj = entry.get('nullsLast');
            if (nullsLastObj instanceof Boolean) {
                nullsClause = ((Boolean) nullsLastObj) ? ' NULLS LAST' : ' NULLS FIRST';
            }
            parts.add(field + ' ' + direction + nullsClause);
        }
        return String.join(parts, ', ');
    }

    /**
     * G-Sec-QUERY-7 + G-Sec-QUERY-13: walks the dotted field path,
     * resolving each intermediate segment via relationshipName lookup +
     * getReferenceTo(); rejects unknown fields, polymorphic ambiguity,
     * and depth > MAX_QUERY_DEPTH. Bypasses Schema walk under
     * testSkipSchemaCheck (depth check still fires).
     */
    private static void validateFieldPath(String field, String sobjectName) {
        List<String> segments = field.split('\\.');
        Integer depth = segments.size() - 1;
        if (depth > MAX_QUERY_DEPTH) {
            throw new QueryAdapterException('QUERY_DEPTH_EXCEEDED:' + field);
        }
        if (testSkipSchemaCheck) return;

        Schema.SObjectType currentType =
            Schema.getGlobalDescribe().get(sobjectName);
        if (currentType == null) {
            throw new QueryAdapterException('QUERY_SCHEMA_UNKNOWN:' + sobjectName);
        }

        for (Integer i = 0; i < segments.size() - 1; i++) {
            String segment = segments[i];
            Map<String, Schema.SObjectField> fmap =
                currentType.getDescribe().fields.getMap();
            Schema.SObjectField parentField = null;
            for (Schema.SObjectField sf : fmap.values()) {
                String relName = sf.getDescribe().getRelationshipName();
                if (relName != null && relName.equalsIgnoreCase(segment)) {
                    parentField = sf;
                    break;
                }
            }
            if (parentField == null) {
                throw new QueryAdapterException(
                    'QUERY_FIELD_UNKNOWN:' + sobjectName + '.' + field);
            }
            List<Schema.SObjectType> refs = parentField.getDescribe().getReferenceTo();
            if (refs == null || refs.isEmpty()) {
                throw new QueryAdapterException(
                    'QUERY_FIELD_UNKNOWN:' + sobjectName + '.' + field);
            }
            if (refs.size() > 1) {
                throw new QueryAdapterException(
                    'QUERY_FIELD_POLYMORPHIC:' + sobjectName + '.' + field);
            }
            currentType = refs[0];
        }
        String lastSegment = segments[segments.size() - 1];
        Map<String, Schema.SObjectField> finalFields =
            currentType.getDescribe().fields.getMap();
        if (!finalFields.containsKey(lastSegment)) {
            throw new QueryAdapterException(
                'QUERY_FIELD_UNKNOWN:' + sobjectName + '.' + field);
        }
    }

    private static Integer readOffset(Map<String, Object> q) {
        Object offsetObj = q.get('offset');
        if (offsetObj == null) return 0;
        Integer offset;
        if (offsetObj instanceof Integer) {
            offset = (Integer) offsetObj;
        } else if (offsetObj instanceof Long) {
            offset = ((Long) offsetObj).intValue();
        } else if (offsetObj instanceof Decimal) {
            offset = ((Decimal) offsetObj).intValue();
        } else {
            throw new QueryAdapterException(
                'QUERY_PAYLOAD_INVALID:offset-not-integer');
        }
        if (offset < 0) {
            throw new QueryAdapterException(
                'QUERY_PAYLOAD_INVALID:offset-negative');
        }
        if (offset > PLATFORM_OFFSET_CAP) {
            throw new QueryAdapterException(
                'QUERY_OFFSET_EXCEEDED:' + PLATFORM_OFFSET_CAP);
        }
        return offset;
    }

    /**
     * G-Sec-QUERY-8: per-query limit clamping. Caller value intersected
     * with CMDT MaxQueryRows__c (returned by allow-list helper) and
     * additionally gated by Limits.assertQueryRowsOk for the global hard
     * cap (MAX_QUERY_ROWS_PER_CALL=200).
     */
    private static Integer computeEffectiveLimit(
        Map<String, Object> q,
        Integer bundleRowsCap
    ) {
        Integer requested = null;
        Object lObj = q.get('limit');
        if (lObj instanceof Integer) {
            requested = (Integer) lObj;
        } else if (lObj instanceof Long) {
            requested = ((Long) lObj).intValue();
        } else if (lObj instanceof Decimal) {
            requested = ((Decimal) lObj).intValue();
        } else if (lObj != null) {
            throw new QueryAdapterException(
                'QUERY_PAYLOAD_INVALID:limit-not-integer');
        }
        Integer effective = requested == null
            ? bundleRowsCap
            : Math.min(requested, bundleRowsCap);
        if (effective <= 0) {
            throw new QueryAdapterException(
                'QUERY_PAYLOAD_INVALID:limit-non-positive');
        }
        SF_AgenticGateway_Limits.assertQueryRowsOk(effective);
        return effective;
    }

    /**
     * G-Sec-QUERY-4: every read goes through queryWithBinds under
     * AccessLevel.USER_MODE. testForcedRecords + testForceUserModeDenied
     * + testCapturedCalls seams short-circuit the real call for unit
     * testing without touching org FLS or platform queries.
     */
    private static List<SObject> runQueries(String soql, Map<String, Object> bindMap) {
        if (testCapturedCalls != null) {
            testCapturedCalls.add(new Map<String, Object>{
                'soql' => soql,
                'bindMap' => bindMap,
                'accessLevel' => 'USER_MODE'
            });
        }
        if (testForceUserModeDenied != null) {
            testCallIdx++;
            throw new QueryAdapterException(
                'QUERY_USER_MODE_DENIED:' + testForceUserModeDenied);
        }
        if (testForcedRecords != null) {
            List<SObject> canned = testCallIdx < testForcedRecords.size()
                ? testForcedRecords[testCallIdx]
                : new List<SObject>();
            testCallIdx++;
            return canned == null ? new List<SObject>() : canned;
        }
        List<SObject> records =
            Database.queryWithBinds(soql, bindMap, AccessLevel.USER_MODE);
        testCallIdx++;
        return records;
    }

    /**
     * Wrap a per-query success result into the envelope shape from
     * locked design §4.2. `done` is true when records.size() <
     * effectiveLimit (no more rows on the platform side); otherwise
     * the caller paginates with offset += records.size().
     */
    private static Map<String, Object> shapeResult(
        String alias,
        String sobjectName,
        List<SObject> records,
        Integer effectiveLimit,
        Integer offset
    ) {
        Integer count = records == null ? 0 : records.size();
        Boolean done = count < effectiveLimit;
        Integer nextOffset = done ? null : (offset + count);
        return new Map<String, Object>{
            'alias' => alias,
            'sobject' => sobjectName,
            'records' => records == null ? new List<SObject>() : records,
            'totalSize' => count,
            'done' => done,
            'nextOffset' => nextOffset
        };
    }

    /**
     * G-Sec-QUERY-9: per-query error envelope when allowPartial=true.
     * `records` is an empty list (not null) to preserve client iteration;
     * `error` carries the normalised code:message ≤ 256 chars; no record
     * values, no stack trace.
     */
    private static Map<String, Object> shapeError(
        String alias,
        String sobjectName,
        String message
    ) {
        String msg = message == null ? '' : message;
        if (msg.length() > 256) msg = msg.substring(0, 256);
        return new Map<String, Object>{
            'alias' => alias,
            'sobject' => sobjectName,
            'records' => new List<SObject>(),
            'totalSize' => 0,
            'done' => true,
            'nextOffset' => null,
            'error' => msg
        };
    }

    private static String normaliseQueryException(QueryException qx) {
        String msg = qx.getMessage();
        if (msg == null) msg = '';
        String lower = msg.toLowerCase();
        if (lower.contains('user_mode')
            || lower.contains('insufficient')
            || lower.contains('flow')) {
            return 'QUERY_USER_MODE_DENIED:' + msg;
        }
        return 'QUERY_EXECUTION_FAILED:' + msg;
    }

    private static Boolean containsIgnoreCaseStr(Set<String> values, String target) {
        if (values == null || values.isEmpty() || target == null) return false;
        for (String v : values) {
            if (v != null && v.equalsIgnoreCase(target)) return true;
        }
        return false;
    }

    /**
     * G-Sec-QUERY-12 helper: server-minted bind tokens (`b0,b1,…`)
     * keyed off a private counter so caller can NEVER poison the bind
     * map keyspace. Map<String,Object> values accept scalars + List<Object>
     * for IN/NOT IN; Database.queryWithBinds handles the type coercion.
     */
    private class BindContext {
        Integer idx = 0;
        Map<String, Object> binds = new Map<String, Object>();
        String nextToken() {
            String tok = 'b' + idx;
            idx++;
            return tok;
        }
    }
}