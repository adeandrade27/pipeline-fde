SF_AgenticGateway.Request req = new SF_AgenticGateway.Request();
req.handlerClass = 'apex:SF_FinDiagInvoiceDetailsHandler';
req.payloadJson  = '{\"caseId\":\"500Hn00001sbGrYIAU\"}';
req.correlationId = 'smokeh03InvDetails';
List<SF_AgenticGateway.Request> reqs = new List<SF_AgenticGateway.Request>{ req };
List<SF_AgenticGateway.Response> resps = SF_AgenticGateway.invoke(reqs);
SF_AgenticGateway.Response r = resps[0];
System.debug('RESULT::' + JSON.serialize(r));
