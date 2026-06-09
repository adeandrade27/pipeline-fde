public with sharing class FinDiagCaseHandler implements ISF_AgenticHandler {

    public String handle(String inputJson) {
        Map<String,Object> params = (Map<String,Object>) JSON.deserializeUntyped(inputJson);
        String caseId = (String) params.get('caseId');
        if (caseId == null) {
            throw new HandlerException('caseId is required');
        }
        List<Case> cases = [
            SELECT Id, CaseNumber, Subject, Status, Description, Priority,
                   Account.Name, Account.Phone, CreatedDate
            FROM Case
            WHERE Id = :caseId
            LIMIT 1
        ];
        if (cases.isEmpty()) {
            throw new HandlerException('Case not found: ' + caseId);
        }
        return JSON.serialize(cases[0]);
    }

    public class HandlerException extends Exception {}
}
