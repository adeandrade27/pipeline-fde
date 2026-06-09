SF_AgenticGateway.Request req = new SF_AgenticGateway.Request();
req.handlerClass = 'flow:Buscar_Dados_Assets';
req.payloadJson  = '{\"IDdaconta\":\"001000000000001\",\"orderReference\":\"ORD-001\"}';
req.correlationId = 'smokeh05Assets';
List<SF_AgenticGateway.Request> reqs = new List<SF_AgenticGateway.Request>{ req };
List<SF_AgenticGateway.Response> resps = SF_AgenticGateway.invoke(reqs);
SF_AgenticGateway.Response r = resps[0];
System.debug('RESULT::' + JSON.serialize(r));
