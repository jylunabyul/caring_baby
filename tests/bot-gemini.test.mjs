import {test} from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';
const workflow=JSON.parse(fs.readFileSync('n8n/daddy-bob-jooseyo-gemini.json'));
const node=name=>workflow.nodes.find(n=>n.name===name);
const decode=new Function('$json',node('Decode Gemini response').parameters.jsCode);
const request=new Function('$json','$',node('Build Gemini request').parameters.jsCode);
const validate=new Function('$json','$',node('Validate Gemini intent').parameters.jsCode);
const normalized={chat_id:'9114513581',action:'unknown',args:{update_id:'9'},raw_text:'별이 120 먹었어',callback_id:''};
const context={children:[{name:'별이',id:'child'}],recent:[],pending:null,now_kst:'2026-11-25T21:00:00+09:00'};
const built=request(context,()=>({item:{json:normalized}}))[0].json;
const source=()=>({item:{json:built}});
test('Gemini request converts schema to nullable Gemini types and excludes confirmation tokens/credentials',()=>{
 assert.equal(built.request.generationConfig.responseMimeType,'application/json');
 assert.equal(built.request.generationConfig.responseSchema.type,'OBJECT');
 assert.equal(built.request.generationConfig.responseSchema.properties.decision.type,'BOOLEAN');
 assert.equal(built.request.generationConfig.responseSchema.properties.decision.nullable,true);
 assert.equal(built.request.generationConfig.thinkingConfig.thinkingBudget,0);
 assert(!('model' in built.request));assert(!('response_format' in built.request));
 assert.equal(node('Gemini intent and yes-no').parameters.genericAuthType,'httpHeaderAuth');
 assert(!workflow.nodes.some(n=>n.parameters.url?.includes('api.openai.com')));
 assert(workflow.nodes.every(n=>!n.credentials));assert.equal(workflow.active,false);
});
test('Gemini candidate maps a natural feeding to confirmation-aware RPC arguments',()=>{
 const ai={action:'feed',confidence:0.99,name:'별이',amount:120,prepared:120};
 const out=decode({candidates:[{finishReason:'STOP',content:{parts:[{thought:true,text:'internal'},{text:JSON.stringify(ai)}]}}]})[0].json;
 const mapped=validate(out,source)[0].json;
 assert.equal(mapped.action,'feed');assert.deepEqual(mapped.args,{update_id:'9',name:'별이',amount:120,prepared:120});
 assert(!('confirmed' in mapped.args));
});
test('Gemini quota/auth/model errors produce explicit service messages rather than misunderstood-input replies',()=>{
 for(const [error,expected] of [[{code:429,message:'RESOURCE_EXHAUSTED'},/한도/],[{code:403,message:'PERMISSION_DENIED'},/접근 권한/],[{code:404,message:'NOT_FOUND'},/모델/],[{message:'403 - Forbidden - perhaps check your credentials?'},/접근 권한/]]){
  const out=decode({error})[0].json;
  const result=validate(out,source)[0].json;
  assert.equal(result.action,'clarify');assert.match(result.args.question,expected);
 }
});
test('Gemini blocked, truncated, empty and malformed results never mutate records',()=>{
 for(const data of [{promptFeedback:{blockReason:'SAFETY'}},{candidates:[{finishReason:'MAX_TOKENS'}]},{candidates:[{finishReason:'STOP',content:{parts:[]}}]},{candidates:[{finishReason:'STOP',content:{parts:[{text:'invalid json'}]}}]}]){
  assert.equal(validate(decode(data)[0].json,source)[0].json.action,'clarify');
 }
});
