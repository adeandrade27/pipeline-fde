/**
 * ISF_AgenticBatchHandler — wave-3 FU-AGW-ASYNC-3.
 *
 * Reflective batch-handler contract resolved by
 * SF_AgenticGateway_BatchWorker at start() via Type.forName(target).
 * The wave-3 convention is: the bundle Target__c is the fully qualified
 * Apex class name that implements this interface; AsyncDispatcher
 * validates the existence + interface match at submit time.
 *
 * HARD RULES:
 *   - Every SOQL+DML executed inside scope() and executeChunk() MUST
 *     use `WITH USER_MODE` (SOQL) or `AccessLevel.USER_MODE` (DML).
 *     The worker runs `without sharing` so the FLS/CRUD/sharing
 *     enforcement lives inside the handler implementation
 *     (G-Sec-DML-7 / G-Sec-ASYNC-15).
 *   - Stateful fields on the BatchWorker side are typed to primitives
 *     only (Integer counters). Handlers may hold no cross-chunk state;
 *     each executeChunk invocation is independent.
 *   - Chunk size is intersected at submit time: min(CMDT
 *     AsyncBatchChunkSize__c default 200, platform max 2000).
 *
 * Failure semantics: exceptions thrown by executeChunk are caught by
 * BatchWorker, the chunk's Savepoint is rolled back, the
 * Database.Stateful failedChunks counter increments, and finish()
 * flips the audit row to Failed when failedChunks &gt; 0.
 */
public interface ISF_AgenticBatchHandler {

    /**
     * Returns the QueryLocator that drives the batch chunking. The
     * `input` map carries the deserialized payload JSON the caller
     * supplied at SF_AgenticGateway.invoke time. SOQL MUST use
     * WITH USER_MODE.
     */
    Database.QueryLocator scope(Map<String, Object> input);

    /**
     * Invoked once per chunk by BatchWorker.execute. Every SOQL+DML
     * inside this method MUST use USER_MODE. Exceptions are caught by
     * BatchWorker → savepoint rollback → failedChunks++.
     */
    void executeChunk(List<SObject> chunk, Map<String, Object> input);
}