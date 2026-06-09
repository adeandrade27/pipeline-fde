SF_AgenticGateway.Request req = new SF_AgenticGateway.Request();
req.handlerClass = 'flow:Buscar_Customer_Interection_Topic_do_caso';
req.payloadJson  = '{\"caseReference\":\"500Hn00001sbGrYIAU\",\"customerInterectionReference\":\"INT-001\"}';
req.correlationId = 'smokeh12Topics';
List<SF_AgenticGateway.Request> reqs = new List<SF_AgenticGateway.Request>{ req };
List<SF_AgenticGateway.Response> resps = SF_AgenticGateway.invoke(reqs);
SF_AgenticGateway.Response r = resps[0];
System.debug('RESULT::' + JSON.serialize(r));
