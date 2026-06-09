SF_AgenticGateway.Request req = new SF_AgenticGateway.Request();
req.handlerClass = 'flow:Agentforce_Roteamento_Divergencia_Financeira';
req.payloadJson  = '{\"varCaseId\":\"500Hn00001sbGrYIAU\",\"varDescricaoAnalise\":\"cliente contesta cobrança indevida de R$150\"}';
req.correlationId = 'smokeh04FinRoute';
List<SF_AgenticGateway.Request> reqs = new List<SF_AgenticGateway.Request>{ req };
List<SF_AgenticGateway.Response> resps = SF_AgenticGateway.invoke(reqs);
SF_AgenticGateway.Response r = resps[0];
System.debug('RESULT::' + JSON.serialize(r));
