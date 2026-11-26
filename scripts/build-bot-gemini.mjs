import fs from 'node:fs';
const w=JSON.parse(fs.readFileSync('n8n/daddy-bob-jooseyo-v3.json','utf8'));
w.name='Daddy Bob Jooseyo - Gemini personal assistant';
const request=fs.readFileSync('scripts/bot-v3-request.js','utf8');
const prefix=request.slice(0,request.indexOf('return [{json:{normalized,context,request:'));
const geminiRequest=prefix+`
// Gemini responseSchema uses nullable rather than JSON Schema union types.
const properties=Object.fromEntries(Object.entries(fields).map(([name,field])=>{
 const types=Array.isArray(field.type)?field.type:[field.type];
 const value={type:types.find(t=>t!=='null').toUpperCase()};
 if(types.includes('null'))value.nullable=true;
 if(field.enum)value.enum=field.enum;
 return [name,value];
}));
return [{json:{normalized,context,request:{
 systemInstruction:{parts:[{text:system}]},
 contents:[{role:'user',parts:[{text:JSON.stringify({text:normalized.raw_text,context:{children:context.children,recent:context.recent,pending,now_kst:context.now_kst}})}]}],
 generationConfig:{temperature:0,maxOutputTokens:2048,thinkingConfig:{thinkingBudget:0},responseMimeType:'application/json',
 responseSchema:{type:'OBJECT',properties,required:Object.keys(properties)}}
}}}];
`;
const decode=fs.readFileSync('scripts/bot-gemini-decode.js','utf8');
const validation=fs.readFileSync('scripts/bot-v3-validate.js','utf8')
 .replaceAll('Build GPT request','Build Gemini request')
 .replaceAll('GPT 연결 또는 응답','Gemini 연결 또는 응답');
for(const n of w.nodes){
 if(n.name==='Build GPT request'){n.name='Build Gemini request';n.parameters.jsCode=geminiRequest;}
 if(n.name==='GPT intent and yes-no'){
  n.name='Gemini intent and yes-no';
  n.parameters.url='https://generativelanguage.googleapis.com/v1beta/models/gemini-2.5-flash:generateContent';
  n.parameters.authentication='genericCredentialType';
  delete n.parameters.nodeCredentialType;
  n.parameters.genericAuthType='httpHeaderAuth';
  n.notes='Header Auth 자격 증명: Name=x-goog-api-key, Value=본인의 Gemini API 키. 키는 URL/본문에 입력하지 않습니다.';
 }
 if(n.name==='Validate GPT intent'){n.name='Validate Gemini intent';n.parameters.jsCode=validation;}
}
const rename=name=>({'Build GPT request':'Build Gemini request','GPT intent and yes-no':'Gemini intent and yes-no','Validate GPT intent':'Validate Gemini intent'}[name]||name);
const connections={};
for(const [name,outputs] of Object.entries(w.connections)){
 for(const group of outputs.main||[])for(const edge of group)edge.node=rename(edge.node);
 connections[rename(name)]=outputs;
}
w.connections=connections;
w.nodes.push({id:'decode-gemini',name:'Decode Gemini response',type:'n8n-nodes-base.code',typeVersion:2,position:[1420,300],parameters:{jsCode:decode}});
w.connections['Gemini intent and yes-no']={main:[[{node:'Decode Gemini response',type:'main',index:0}]]};
w.connections['Decode Gemini response']={main:[[{node:'Validate Gemini intent',type:'main',index:0}]]};
// API errors go directly to a user-visible provider message; do not pass them as model misunderstanding.
const errorGate=`
if ($json.provider_error) {
 return clarify($json.provider_error);
}
`;
const validator=w.nodes.find(n=>n.name==='Validate Gemini intent');
validator.parameters.jsCode=validator.parameters.jsCode.replace('let v;',errorGate+'\nlet v;');
w.active=false;
fs.writeFileSync('n8n/daddy-bob-jooseyo-gemini.json',JSON.stringify(w,null,2)+'\n');
console.log('Generated Gemini import: key-free Header Auth, same SQL/confirmation/quiet-hours workflow.');
