SF_AgenticGateway.Request req = new SF_AgenticGateway.Request();
req.handlerClass = 'flow:Buscar_casos_do_cliente_ou_contrato';
req.payloadJson  = '{\"caseId\":\"500Hn00001sbGrYIAU\"}';
req.correlationId = 'smoke-09_CaseHistory';
List<SF_AgenticGateway.Request> reqs = new List<SF_AgenticGateway.Request>{ req };
List<SF_AgenticGateway.Response> resps = SF_AgenticGateway.invoke(reqs);
SF_AgenticGateway.Response r = resps[0];
System.debug('RESULT::' + JSON.serialize(r));
