public class CustomiseTokenData implements ind_docgen_api.OpenInterface{
public Boolean invokeMethod(String methodName, Map<String,Object> inputMap, Map<String, Object> outMap) {
if (methodName == null || String.isEmpty(methodName)) {
return false;
}

switch on methodName {
when 'transformTokenData' {
return handleTransform(inputMap, outMap);
}
when else {
System.debug('Unknown method: ' + methodName);
return false;
}
}
}

private Boolean handleTransform(Map<String, Object> inMap, Map<String, Object> outMap){
String tokenData = (String) inMap.get('TokenData');
if (inMap == null || inMap.get('TokenData') == null) {
return false;
}
Map<String, Object> m = (Map<String, Object>) JSON.deserializeUntyped(tokenData);
Map<String,List<Object>> parentToChild = new Map<String,List<Object>>();

List<Object> products =(List<Object>) m.get('products');
List<Object> updatedProducts =new List<Object>();
for(Object product: products){
Map<String,Object> prodMap = (Map<String,Object>)product;
String id = (String)prodMap.get('Id');

String parentId = (String)prodMap.get('ParentId');
if(parentId!=null){
List<Object> children = (List<Object>)parentToChild.get(parentId);
if(children == null){
children = new List<Object>();
}
children.add(product);
parentToChild.put(parentId,children);
} else{
updatedProducts.add(product);
}
}
for(Object product:updatedProducts){
fetchChildren(product, parentToChild);
}

m.put('products', updatedProducts);


String finalString = JSON.serialize(m);
outMap.put('TokenData',finalString);
return true;
}


Object fetchChildren(Object product,Map<String,Object> parentToChild){
Map<String,Object> productMap = (Map<String,Object>)product;
String id = (String)productMap.get('Id');
Boolean keyExist = parentToChild.containsKey(id);
if(keyExist){
List<Object> children = (List<Object>)parentToChild.get(id);
List<Object> Existingchildren = (List<Object>)productMap.get('child');
if(Existingchildren == null){
Existingchildren = new List<Object>();
}
for(Object child:children){
Object updatedMap = fetchChildren(child, parentToChild);
Existingchildren.add(updatedMap);
}
productMap.put('child',Existingchildren);
}
return productMap;
}

}