SF_AgenticGateway.Request req = new SF_AgenticGateway.Request();
req.handlerClass = 'flow:Buscar_casos_do_cliente_ou_contrato';
req.payloadJson  = '{\"contractReference\":\"CONT-001\"}';
req.correlationId = 'smokeh09CaseHistory';
List<SF_AgenticGateway.Request> reqs = new List<SF_AgenticGateway.Request>{ req };
List<SF_AgenticGateway.Response> resps = SF_AgenticGateway.invoke(reqs);
SF_AgenticGateway.Response r = resps[0];
System.debug('RESULT::' + JSON.serialize(r));
