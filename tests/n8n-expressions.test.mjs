import {test} from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';
import {Tournament} from '@n8n/tournament';
const engine=new Tournament(error=>{throw error;});
const row={chat_id:'9114513581',callback_id:'callback',action:'help',args:{update_id:'123'},reply:'<확인 & 안내>',buttons:[{text:'확인',data:'confirm:token'}],child_id:'child-id',kind:'feeding',request:{model:'gpt-4.1-mini',messages:[],contents:[{parts:[{text:'user input'}]}],systemInstruction:{parts:[{text:'system instructions'}]},generationConfig:{responseSchema:{type:'OBJECT',properties:{},required:[]}}}};
const context={$json:row,JSON,Date,String,Array,$:()=>({item:{json:row}})};
const run=expr=>engine.execute(expr.slice(1),context);
const walk=(value,path,visit)=>{
 if(typeof value==='string'){if(value.startsWith('={{'))visit(value,path);return;}
 if(value && typeof value==='object')for(const [k,v] of Object.entries(value))walk(v,path+'.'+k,visit);
};
test('n8n parser reproduces adjacent closing-braces failure and accepts repaired JSON body',()=>{
 assert.throws(()=>run("={{ JSON.stringify({p_chat_id:$json.chat_id,p_action:'context',p_args:{}}) }}"),/Unexpected|syntax/i);
 const fixed="={{ JSON.stringify({p_chat_id:$json.chat_id,p_action:'context',p_args:{ } }) }}";
 assert.deepEqual(JSON.parse(run(fixed)),{p_chat_id:row.chat_id,p_action:'context',p_args:{}});
});
for(const version of ['v2','v3','gemini','gemini-native','v4','v5','v5-formal','v5-conversation','v6','v6-kst','v7','v8','v9','v10'])test(`${version} every generated n8n expression parses and evaluates with the n8n engine`,()=>{
 const workflow=JSON.parse(fs.readFileSync(`n8n/daddy-bob-jooseyo-${version}.json`));
 let count=0;
 for(const node of workflow.nodes)walk(node.parameters,node.name,(expression,path)=>{
  try{run(expression);count++;}catch(e){throw new Error(path+': '+e.message);}
 });
 assert(count>=10);
 const get=name=>workflow.nodes.find(n=>n.name===name);
 const rows=run(get('Send reply').parameters.inlineKeyboard.rows);
 assert.equal(rows[0].row.buttons[0].additionalFields.callback_data,'confirm:token');
 assert.equal(run(get('Send reply').parameters.text),'&lt;확인 &amp; 안내&gt;');
 const mark=JSON.parse(run(get('Mark delivered').parameters.jsonBody));
 assert.equal(mark.p_args.child_id,'child-id');assert.equal(mark.p_args.kind,'feeding');
 if(version!=='v2'){
  const body=JSON.parse(run(get('Get chat context').parameters.jsonBody));
  assert.equal(body.p_action,'context');assert.deepEqual(body.p_args,{});
 }
});
