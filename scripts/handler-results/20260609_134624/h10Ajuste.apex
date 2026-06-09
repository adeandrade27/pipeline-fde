SF_AgenticGateway.Request req = new SF_AgenticGateway.Request();
req.handlerClass = 'flow:Buscar_Ajuste_de_Pagamento';
req.payloadJson  = '{\"accountReference\":\"001000000000001\",\"caseReference\":\"500Hn00001sbGrYIAU\"}';
req.correlationId = 'smokeh10Ajuste';
List<SF_AgenticGateway.Request> reqs = new List<SF_AgenticGateway.Request>{ req };
List<SF_AgenticGateway.Response> resps = SF_AgenticGateway.invoke(reqs);
SF_AgenticGateway.Response r = resps[0];
System.debug('RESULT::' + JSON.serialize(r));
