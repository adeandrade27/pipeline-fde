SF_AgenticGateway.Request req = new SF_AgenticGateway.Request();
req.handlerClass = 'flow:Buscar_informacoes_da_Conta';
req.payloadJson  = '{\"caseBillingAccount\":\"001000000000001\",\"caseConsumerAccount\":\"001000000000002\"}';
req.correlationId = 'smokeh06Account';
List<SF_AgenticGateway.Request> reqs = new List<SF_AgenticGateway.Request>{ req };
List<SF_AgenticGateway.Response> resps = SF_AgenticGateway.invoke(reqs);
SF_AgenticGateway.Response r = resps[0];
System.debug('RESULT::' + JSON.serialize(r));
