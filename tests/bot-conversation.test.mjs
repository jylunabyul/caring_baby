import {test} from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';
const w=JSON.parse(fs.readFileSync('n8n/daddy-bob-jooseyo-v5-conversation.json','utf8'));
const code=name=>w.nodes.find(n=>n.name===name).parameters.jsCode;
const normalized={chat_id:'9114513581',action:'unknown',raw_text:'고맙다',args:{update_id:'thanks'},callback_id:''};
const context={children:[{id:'child',name:'별이'}],recent:[],health_recent:[],care_plans:[],pending:{action:'feed',token:'token',args:{name:'별이',amount:120}},now_kst:'2026-11-26T10:29:00+09:00'};
const build=new Function('$json','$',code('Build Gemini request'));
const built=build({context},()=>({item:{json:normalized}}))[0].json;
const validate=new Function('$json','$',code('Validate Gemini intent'));
const map=v=>validate({choices:[{finish_reason:'stop',message:{content:JSON.stringify(v)}}]},()=>({item:{json:built}}))[0].json;
test('thanks is a direct conversation reply and never routed through the mutation RPC',()=>{
 const out=map({action:'chat',confidence:0.99,answer:'필요하시면 말씀해 주세요.'});
 assert.equal(out.action,'chat');assert.equal(out.reply,'아버님, 필요하시면 말씀해 주세요.');assert.deepEqual(out.buttons,[]);
 assert.equal(w.connections['Validate Gemini intent'].main[0][0].node,'Is conversation?');
 assert.equal(w.connections['Is conversation?'].main[0][0].node,'Send reply');
 assert.equal(w.connections['Is conversation?'].main[1][0].node,'Process command');
 assert.equal(built.request.generationConfig.responseSchema.properties.answer.type,'STRING');
});
test('short thanks/questions reach Gemini even with a pending approval; actual yes remains token-bound',()=>{
 const quick=new Function('$json','$',code('Resolve short replies'));
 for(const text of ['고맙다','감사','안녕','왜 그래?']){
  const out=quick(context,()=>({item:{json:{...normalized,raw_text:text}}}))[0].json;
  assert.equal(out.ready,false);
 }
 const yes=quick(context,()=>({item:{json:{...normalized,raw_text:'응'}}}))[0].json;
 assert.equal(yes.action,'decision');assert.equal(yes.args.expected_token,'token');
});
test('conversation cannot claim a completed operation; malformed chat stays clarification',()=>{
 for(const answer of ['저장했습니다.','기록 완료했습니다.','삭제했습니다.'])assert.equal(map({action:'chat',confidence:1,answer}).action,'clarify');
 assert.equal(map({action:'chat',confidence:0.99,answer:null}).action,'clarify');
 assert.equal(map({action:'clarify',confidence:0.99,question:'얼마나 먹였나요?'}).action,'clarify');
 assert.match(built.request.systemInstruction.parts[0].text,/thank-you does not approve/);
});
