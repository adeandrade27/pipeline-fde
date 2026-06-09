public class COM_ObjectNameFromIdInvocable {
  public class FlowInput{
    @InvocableVariable public Id recordId;
  }

  @InvocableMethod public static FlowOutput[] getObjectNameFromRecordId(List<FlowInput> params){ 
    FlowOutput[] results = new List<FlowOutput>();
    for (FlowInput param: params) {
       results.add(new FlowOutput(
           param.recordId.getSObjectType().getDescribe().getName()));
    }
    return results;
  }

  public class FlowOutput{
    @InvocableVariable public String objectname;
    public FlowOutput(String objName) {this.objectName = objName;}
  }
}