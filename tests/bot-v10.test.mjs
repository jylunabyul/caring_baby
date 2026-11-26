import {test} from 'node:test';import assert from 'node:assert/strict';import fs from 'node:fs';
const w=JSON.parse(fs.readFileSync('n8n/daddy-bob-jooseyo-v10.json','utf8'));const code=name=>w.nodes.find(n=>n.name===name).parameters.jsCode;
const n={chat_id:'9114513581',action:'unknown',raw_text:'별이 대변 봤어',args:{update_id:'event-1'},received_at_kst:'2026-11-26T16:00:00+09:00'};
const context={children:[{id:'child',name:'별이'}],recent:[],pending:null,now_kst:n.received_at_kst};
const built=new Function('$json','$',code('Build Gemini request'))({context},()=>({item:{json:n}}))[0].json;
const validate=value=>new Function('$json','$',code('Validate Gemini intent'))({choices:[{finish_reason:'stop',message:{content:JSON.stringify(value)}}]},()=>({item:{json:built}}))[0].json;
test('native Gemini prompt includes special event routing and prevents fabricated visit details',()=>{
 const prompt=JSON.stringify(built.request);assert.match(prompt,/Special event recording/);assert.match(prompt,/대변/);assert.match(prompt,/병원진료/);assert.match(prompt,/Do not invent/);
 assert.ok(w.nodes.some(n=>n.type==='@n8n/n8n-nodes-langchain.googleGemini'));
 assert.ok(w.nodes.some(n=>n.name==='Daily report at 21 Seoul'));
});
test('bowel event and historical hospital visit map to confirmation-aware health notes in KST',()=>{
 const poop=validate({action:'health',confidence:0.99,name:'별이',health_kind:'note',note:'[대변] 대변을 봄',time:null});assert.equal(poop.action,'health');assert.equal(poop.args.note,'[대변] 대변을 봄');assert.equal(poop.args.confirmed,undefined);
 const clinic=validate({action:'health',confidence:0.99,name:'별이',health_kind:'note',note:'[병원진료] 감기 진료를 받음',time:'2026-11-26T13:00:00+09:00'});assert.equal(clinic.args.time,'2026-11-26T13:00:00+09:00');
});
test('multiple events stay separate in a single confirmation batch',()=>{
 const result=validate({action:'batch',confidence:0.99,operations:[{action:'health',confidence:0.99,name:'별이',health_kind:'note',note:'[대변] 대변을 봄'},{action:'health',confidence:0.99,name:'별이',health_kind:'note',note:'[병원진료] 감기 진료를 받음'}]});
 assert.equal(result.action,'batch');assert.equal(result.args.operations.length,2);assert.equal(result.args.operations[1].args.note,'[병원진료] 감기 진료를 받음');
});
test('explicit event command maps without model and retains access to daily timeline',()=>{
 const run=text=>new Function('$json','$',code('Resolve short replies'))(context,()=>({item:{json:{...n,raw_text:text}}}))[0].json;
 assert.equal(run('/event 별이 대변을 봄').args.note,'[이벤트] 대변을 봄');assert.equal(run('오늘 하루 기록 보여줘').action,'daily_timeline');
});
