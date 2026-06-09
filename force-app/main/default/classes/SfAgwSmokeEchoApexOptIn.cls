/**
 * SfAgwSmokeEchoApexOptIn — payload-opt-in async wrapper for SfAgwSmokeEchoApex
 * (scope sf-agentic-gateway-smoke-template-2026-05-29 WP-1 round-1 fix).
 *
 * See SfAgwSmokeEchoApexQueueable for round-1 design rationale (Target__c
 * uniqueness drives one-class-per-row). Sec C-1 + C-2 preserved transitively.
 */
public with sharing class SfAgwSmokeEchoApexOptIn implements ISF_AgenticHandler {
    public Object handle(String payloadJson) {
        return new SfAgwSmokeEchoApex().handle(payloadJson);
    }
}