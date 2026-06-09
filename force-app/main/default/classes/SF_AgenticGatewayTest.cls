@isTest
public with sharing class SF_AgenticGatewayTest {

    @isTest(seeAllData=true)
    static void testDispatchSuccess() {
        Case c = [SELECT Id, CaseNumber FROM Case LIMIT 1];

        SF_AgenticGateway.Request req = new SF_AgenticGateway.Request();
        req.target = 'Buscar_caso_de_atendimento';
        req.inputJson = '{"caseId":"' + c.Id + '"}';
        req.sessionId = 'test-session-001';

        Test.startTest();
        List<SF_AgenticGateway.Response> results = SF_AgenticGateway.dispatch(
            new List<SF_AgenticGateway.Request>{ req }
        );
        Test.stopTest();

        SF_AgenticGateway.Response res = results[0];
        System.assertEquals('Success', res.status, 'Expected Success status');
        System.assertNotEquals(null, res.dataJson, 'dataJson should not be null');
        System.assert(res.dataJson.contains(c.CaseNumber), 'dataJson should contain CaseNumber');

        List<SF_AgenticInvocation__c> logs = [
            SELECT Status__c, Target__c, SessionId__c
            FROM SF_AgenticInvocation__c
            WHERE Target__c = 'Buscar_caso_de_atendimento'
        ];
        System.assertEquals(1, logs.size(), 'Should have 1 invocation log');
        System.assertEquals('Success', logs[0].Status__c);
    }

    @isTest
    static void testDispatchTargetNotFound() {
        SF_AgenticGateway.Request req = new SF_AgenticGateway.Request();
        req.target = 'Target_Inexistente';
        req.inputJson = '{}';
        req.sessionId = 'test-session-002';

        Test.startTest();
        List<SF_AgenticGateway.Response> results = SF_AgenticGateway.dispatch(
            new List<SF_AgenticGateway.Request>{ req }
        );
        Test.stopTest();

        SF_AgenticGateway.Response res = results[0];
        System.assertEquals('Error', res.status, 'Expected Error status');
        System.assert(res.errorMessage.contains('not allowed'), 'Error should mention not allowed');

        List<SF_AgenticInvocation__c> logs = [
            SELECT Status__c
            FROM SF_AgenticInvocation__c
            WHERE Target__c = 'Target_Inexistente'
        ];
        System.assertEquals(1, logs.size(), 'Should have 1 invocation log');
        System.assertEquals('Error', logs[0].Status__c);
    }
}
