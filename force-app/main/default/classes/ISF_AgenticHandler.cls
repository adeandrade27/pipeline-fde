/**
 * Contract for all Agentforce handlers invoked through SF_AgenticGateway.
 *
 * Each handler is registered in SF_AgenticGateway.ALLOWED_HANDLERS and
 * accepts a JSON-encoded payload, returning a JSON-serializable Object that
 * the gateway forwards back to the agent. Implementations must be self-contained
 * (no cross-bot Apex dependencies) and enforce WITH USER_MODE on every SOQL/DML.
 */
public interface ISF_AgenticHandler {
    Object handle(String payloadJson);
}