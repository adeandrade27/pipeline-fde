/**
 * SF_AgenticGateway_QueueableWorker — Queueable worker that runs the
 * sync 6-way dispatch logic inside a fresh Tx + writes the result to
 * Platform Cache (joint locked design
 * docs/sf-agentic-gateway-async-selector-2026-05-14.md §5.1).
 *
 * Pipeline:
 *   execute(qc)
 *     → load audit row by jobId WITH USER_MODE                   // Sec G-Sec-ASYNC-2
 *     → verify PayloadHash__c matches payloadJson snapshot       // Sec G-Sec-ASYNC-8
 *     → re-validate CMDT Active__c (catches mid-flight deactivation)
 *     → assertWorkerGovernorPrecheck()                            // Sec G-Sec-ASYNC-11
 *     → audit.AsyncStatus = Running; audit.StartedAt = now()
 *     → result = SF_AgenticGateway.dispatchSync(prefix, target, payload, corr, max)
 *                                                                 // re-runs G-Sec-DML / G-Sec-AGENT (G-Sec-ASYNC-12)
 *     → wrapped = SF_AgenticGateway_Limits.truncateOrSpill(...)
 *     → write to local.SfAgentic cache key=ResultRef__c
 *     → audit.AsyncStatus = Completed; audit.CompletedAt = now()
 *   ↳ catch Exception → audit.AsyncStatus = Failed; MessageHash; no stack
 *
 * `Database.AllowsCallouts` lets the worker call out to agents / IPs.
 * `with sharing` so the worker honours the enqueueing user's permissions
 * (Sec G-Sec-ASYNC-4 — no impersonation).
 */
public with sharing class SF_AgenticGateway_QueueableWorker
    implements Queueable, Database.AllowsCallouts {

    public class WorkerException extends Exception {}

    @TestVisible private final String jobId;
    @TestVisible private final String prefix;
    @TestVisible private final String target;
    @TestVisible private final String payloadJson;
    @TestVisible private final String correlationId;
    @TestVisible private final String expectedHash;

    public SF_AgenticGateway_QueueableWorker(
        String jobId,
        String prefix,
        String target,
        String payloadJson,
        String correlationId,
        String expectedHash
    ) {
        this.jobId = jobId;
        this.prefix = prefix;
        this.target = target;
        this.payloadJson = payloadJson;
        this.correlationId = correlationId;
        this.expectedHash = expectedHash;
    }

    public void execute(QueueableContext qc) {
        SF_AgenticGateway_WorkerCore.runWorker(
            jobId, prefix, target, payloadJson, correlationId, expectedHash);
    }
}