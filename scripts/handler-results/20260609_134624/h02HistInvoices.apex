SF_AgenticGateway.Request req = new SF_AgenticGateway.Request();
req.handlerClass = 'apex:SF_FinDiagHistoricalInvoicesHandler';
req.payloadJson  = '{\"startDate\":\"2026-01-01\",\"endDate\":\"2026-06-01\",\"operatorCode\":\"CLARO\",\"contractNumber\":\"123456\"}';
req.correlationId = 'smokeh02HistInvoices';
List<SF_AgenticGateway.Request> reqs = new List<SF_AgenticGateway.Request>{ req };
List<SF_AgenticGateway.Response> resps = SF_AgenticGateway.invoke(reqs);
SF_AgenticGateway.Response r = resps[0];
System.debug('RESULT::' + JSON.serialize(r));
