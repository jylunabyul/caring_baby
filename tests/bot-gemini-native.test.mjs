import {test} from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';
const w=JSON.parse(fs.readFileSync('n8n/daddy-bob-jooseyo-gemini-native.json','utf8'));
test('native Google Gemini uses message operation, native credentials and raw JSON output without HTTP authentication settings',()=>{
 const n=w.nodes.find(n=>n.type==='@n8n/n8n-nodes-langchain.googleGemini');
 assert(n);assert.equal(n.typeVersion,1);assert.equal(n.parameters.resource,'text');assert.equal(n.parameters.operation,'message');
 assert.equal(n.parameters.modelId.value,'models/gemini-2.5-flash');assert.equal(n.parameters.jsonOutput,true);assert.equal(n.parameters.simplify,false);
 assert(!('authentication' in n.parameters));assert(!('url' in n.parameters));assert(!n.credentials);
 assert.equal(w.connections['Build Gemini request'].main[0][0].node,n.name);
 assert.equal(w.connections[n.name].main[0][0].node,'Decode Gemini response');
 assert.equal(w.active,false);
});
test('native model prompt includes output fields and scoped user context; raw candidate reaches existing validator',()=>{
 const request=new Function('$json','$',w.nodes.find(n=>n.name==='Build Gemini request').parameters.jsCode);
 const normalized={chat_id:'9114513581',action:'unknown',raw_text:'별이 120 먹었어',args:{update_id:'native-1'},callback_id:''};
 const context={children:[{id:'child',name:'별이'}],recent:[],pending:null,now_kst:'2026-11-25T22:00:00+09:00'};
 const built=request(context,()=>({item:{json:normalized}}))[0].json;
 assert.equal(JSON.parse(built.request.contents[0].parts[0].text).text,'별이 120 먹었어');
 assert(built.request.generationConfig.responseSchema.required.includes('confidence'));
 const decode=new Function('$json',w.nodes.find(n=>n.name==='Decode Gemini response').parameters.jsCode);
 const validate=new Function('$json','$',w.nodes.find(n=>n.name==='Validate Gemini intent').parameters.jsCode);
 const output=decode({candidates:[{finishReason:'STOP',content:{role:'model',parts:[{text:JSON.stringify({action:'feed',confidence:0.99,name:'별이',amount:120,prepared:120})}]}}]})[0].json;
 const result=validate(output,()=>({item:{json:built}}))[0].json;
 assert.equal(result.action,'feed');assert.equal(result.args.amount,120);assert(!('confirmed' in result.args));
});
