/**
 * SF_AgenticGateway_FutureWorker — @future fire-and-forget worker for
 * the async dispatch surface (joint locked design
 * docs/sf-agentic-gateway-async-selector-2026-05-14.md §5.2).
 *
 * Same body shape as `SF_AgenticGateway_QueueableWorker.execute` but:
 *   - no Queueable chaining (cannot enqueue from inside @future);
 *   - no AsyncApexJobId returned by Salesforce platform;
 *   - `callout=true` for adapter callouts (agent / IP / DR);
 *   - run user = the user who enqueued the @future.
 *
 * Both workers funnel through `SF_AgenticGateway_WorkerCore.runWorker`
 * so the audit + cache + dispatch pipeline stays single-sourced (Sec
 * G-Sec-ASYNC-7/-8/-11/-12 all re-checked there).
 *
 * `without sharing` because @future methods must be static; the worker
 * sharing context is preserved by the gateway's runtime user (Sec
 * G-Sec-ASYNC-4 — no `System.runAs`). The downstream USER_MODE SOQL in
 * `WorkerCore` re-asserts the sharing boundary on the audit-row read.
 */
public without sharing class SF_AgenticGateway_FutureWorker {

    @future(callout=true)
    public static void execute(
        String jobId,
        String prefix,
        String target,
        String payloadJson,
        String correlationId,
        String expectedHash
    ) {
        SF_AgenticGateway_WorkerCore.runWorker(
            jobId, prefix, target, payloadJson, correlationId, expectedHash);
    }
}