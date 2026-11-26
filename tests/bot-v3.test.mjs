import {test,before,after} from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';
import {PGlite} from '@electric-sql/pglite';
const CHAT='9114513581',ID='00000000-0000-0000-0000-000000000001',TOKEN='00000000-0000-0000-0000-000000000099';
const validate=new Function('$json','$',fs.readFileSync('scripts/bot-v3-validate.js','utf8'));
const build=new Function('$json','$',fs.readFileSync('scripts/bot-v3-request.js','utf8'));
const context={children:[{id:ID,name:'별이'}],recent:[{id:ID,name:'별이',amount_ml:120,prepared_ml:150,fed_at:'2026-11-25T19:23:00+09:00'}],pending:null,now_kst:'2026-11-25T20:00:00+09:00'};
const norm=text=>({chat_id:CHAT,raw_text:text,args:{update_id:'123'},callback_id:''});
const response=v=>({choices:[{finish_reason:'stop',message:{content:JSON.stringify({confidence:0.99,...v})}}]});
const mapped=(v,text='별이 120 먹고 150 탔어',ctx=context)=>validate(response(v),()=>({item:{json:{normalized:norm(text),context:ctx}}}))[0].json;
let db,child,seq=2000;
const q=async(sql,args=[]) => (await db.query(sql,args)).rows;
const rpc=async(action,args={},update=String(seq++))=>(await q('select public.daddy_bob_jooseyo_bot($1,$2,$3::jsonb) as result',[CHAT,action,JSON.stringify({...args,...(update==null?{}:{update_id:update})})]))[0].result;
const approve=async p=>rpc('decision',{decision:true,expected_token:p.buttons[0].data.split(':')[1]});
before(async()=>{
 db=new PGlite();
 await db.exec(`create role anon; create role authenticated; create role service_role; create schema auth; create table auth.users(id uuid primary key); create function auth.uid() returns uuid language sql as $$select null::uuid$$; create function auth.role() returns text language sql as $$select current_setting('request.jwt.claim.role',true)$$; select set_config('request.jwt.claim.role','service_role',false);`);
 for(const file of ['daddy_bob_jooseyo.sql','daddy_bob_jooseyo_telegram_only.sql','daddy_bob_jooseyo_v2.sql'])await db.exec(fs.readFileSync('supabase/'+file,'utf8'));
 child=(await q(`insert into public.daddy_bob_jooseyo_children(name,date_of_birth,telegram_chat_id) values('별이',current_date-100,$1) returning id`,[CHAT]))[0].id;
 await db.query('insert into public.daddy_bob_jooseyo_feedings(child_id,amount_ml) values($1,120)',[child]);
 const sql=fs.readFileSync('supabase/daddy_bob_jooseyo_v3.sql','utf8');await db.exec(sql);await db.exec(sql);
});
after(async()=>db?.close());

test('V3 schema preserves records, quiet hours default to 22:00-08:00, context scopes pending/records',async()=>{
 assert.equal((await q('select count(*)::int as n from public.daddy_bob_jooseyo_feedings'))[0].n,1);
 const row=(await q('select quiet_enabled,quiet_start,quiet_end from public.daddy_bob_jooseyo_children'))[0];
 assert.equal(row.quiet_enabled,true);assert.equal(row.quiet_start,'22:00:00');assert.equal(row.quiet_end,'08:00:00');
 const c=await rpc('context',{},null);assert.equal(c.children[0].name,'별이');assert.equal(c.recent[0].amount_ml,120);assert.equal(c.pending,null);
});
test('quiet hours include 22:00 and exclude 08:00, support daytime and midnight crossing',async()=>{
 for(const [start,end,clock,expected] of [['22:00','08:00','21:59:59',false],['22:00','08:00','22:00',true],['22:00','08:00','00:00',true],['22:00','08:00','07:59:59',true],['22:00','08:00','08:00',false],['12:00','14:00','13:00',true],['12:00','14:00','14:00',false],['08:00','08:00','09:00',false]]){
  assert.equal((await q('select public.daddy_bob_jooseyo_is_quiet($1::time,$2::time,$3::time) as quiet',[start,end,clock]))[0].quiet,expected);
 }
});
test('GPT request uses structured schema and minimal context, never exposes confirmation token',()=>{
 const pending={action:'feed',token:TOKEN,args:{name:'별이',amount:120,prepared:150,confirmed:true,update_id:'old'}};
 const result=build({...context,pending},()=>({item:{json:norm('응')}}))[0].json;
 assert.equal(result.request.model,'gpt-4.1-mini');assert.equal(result.request.store,false);
 assert.equal(result.request.response_format.json_schema.strict,true);
 assert(!JSON.stringify(result.request).includes(TOKEN));assert(!result.request.messages[1].content.includes('confirmed'));
 assert.equal(result.context.pending.token,TOKEN);
});
test('natural intent validator maps only known child and fields; no model identity/token/confirmation allowed',()=>{
 const out=mapped({action:'feed',name:'별이',amount:120,prepared:150,confirmed:true,token:'fake',chat_id:'42'});
 assert.equal(out.action,'feed');assert.deepEqual(out.args,{update_id:'123',name:'별이',amount:120,prepared:150});assert.equal(out.chat_id,CHAT);
 assert.equal(mapped({action:'feed',name:'다른아이',amount:120,prepared:150}).action,'clarify');
 assert.equal(mapped({action:'delete',feed_id:'not-in-context'}).action,'clarify');
 assert.equal(mapped({action:'delete',feed_id:ID,name:'다른아이'}).action,'clarify');
 assert.equal(mapped({action:'mark',name:'별이'}).action,'clarify');
 assert.equal(mapped({action:'feed',name:'별이',amount:120,prepared:100}).action,'clarify');
 assert.equal(mapped({action:'feed',name:'별이',amount:'120',prepared:150}).action,'clarify');
 assert.equal(mapped({action:'stock',name:'별이',product:'분유',grams:700}).action,'clarify');
 assert.equal(mapped({action:'sleep',name:'별이',enabled:true,start:'22:00',end:'08:00'}).action,'sleep');
 assert.equal(mapped({action:'sleep',name:'별이',enabled:true,start:'25:00',end:'08:00'}).action,'clarify');
});
test('yes/no requires real pending confirmation and exact boolean; uncertain/corrective replies never confirm',()=>{
 const c={...context,pending:{action:'feed',token:TOKEN,args:{name:'별이',amount:120}}};
 assert.equal(mapped({action:'decision',decision:true},'응',c).args.expected_token,TOKEN);
 assert.equal(mapped({action:'decision',decision:false},'아니',c).args.decision,false);
 for(const text of ['응 근데 100으로 바꿔','아마 맞을걸','응 아니']) assert.equal(mapped({action:'decision',decision:true},text,c).action,'clarify');
 assert.equal(mapped({action:'decision',decision:'true'},'응',c).action,'clarify');
 assert.equal(mapped({action:'decision',decision:true},'응').action,'clarify');
 assert.equal(mapped({action:'decision',decision:true},'응',{...c,pending:{...c.pending,action:'await_amount'}}).action,'clarify');
});
test('GPT refusal, truncated/malformed output, low confidence and API failure do not mutate',()=>{
 const source=()=>({item:{json:{normalized:norm('기록해줘'),context}}});
 for(const output of [{error:'401'},{choices:[{finish_reason:'length',message:{content:'{}'}}]},{choices:[{finish_reason:'stop',message:{refusal:'no'}}]},{choices:[{finish_reason:'stop',message:{content:'not json'}}]}])assert.equal(validate(output,source)[0].json.action,'clarify');
 assert.equal(mapped({action:'delete',feed_id:ID,confidence:0.5}).action,'clarify');
});
test('SQL boolean decision is token-bound, atomic and deduplicated; false cancels without deleting any feed',async()=>{
 const before=(await q('select count(*)::int as n from public.daddy_bob_jooseyo_feedings'))[0].n;
 const p=await rpc('feed',{name:'별이',amount:120,prepared:120});
 const token=p.buttons[0].data.split(':')[1];
 const bad=await rpc('decision',{decision:'true',expected_token:token});assert.match(bad.reply,/확인할 요청/);
 const wrong=await rpc('decision',{decision:true,expected_token:ID});assert.match(wrong.reply,/확인할 요청/);
 const saved=await rpc('decision',{decision:true,expected_token:token},'same-update');assert.match(saved.reply,/저장 완료/);
 assert.deepEqual(await rpc('decision',{decision:true,expected_token:token},'same-update'),saved);
 assert.equal((await q('select count(*)::int as n from public.daddy_bob_jooseyo_feedings'))[0].n,before+1);
 const p2=await rpc('delete',{feed_id:(await rpc('context',{},null)).recent[0].id});
 await rpc('decision',{decision:false,expected_token:p2.buttons[0].data.split(':')[1]});
 assert.equal((await q('select count(*)::int as n from public.daddy_bob_jooseyo_feedings'))[0].n,before+1);
 const stale=await rpc('feed',{name:'별이',amount:110});await rpc('feed',{name:'별이',amount:100});
 assert.match((await approve(stale)).reply,/확인할 요청/);
});
test('quiet setting, growth and child addition require confirmation, overnight manual recording still works',async()=>{
 const p=await rpc('sleep',{name:'별이',enabled:true,start:'21:00',end:'09:00'});
 assert.equal((await q('select quiet_start from public.daddy_bob_jooseyo_children where id=$1',[child]))[0].quiet_start,'22:00:00');
 await approve(p);assert.equal((await q('select quiet_start from public.daddy_bob_jooseyo_children where id=$1',[child]))[0].quiet_start,'21:00:00');
 const growth=await rpc('growth',{name:'별이',weight:6.5,height:62});
 assert.equal((await q('select count(*)::int as n from public.daddy_bob_jooseyo_growth'))[0].n,0);
 await approve(growth);assert.equal((await q('select count(*)::int as n from public.daddy_bob_jooseyo_growth'))[0].n,1);
 const add=await rpc('childadd',{name:'둘째',dob:'2026-07-13'});assert(!(await rpc('children')).reply.includes('둘째'));await approve(add);assert((await rpc('children')).reply.includes('둘째'));
 await db.query("update public.daddy_bob_jooseyo_children set quiet_start=((now() at time zone 'Asia/Seoul')-interval '1 hour')::time,quiet_end=((now() at time zone 'Asia/Seoul')+interval '1 hour')::time where id=$1",[child]);
 const fed=await approve(await rpc('feed',{name:'별이',amount:100,prepared:100}));assert.match(fed.reply,/保存|저장 완료/);
 await db.query("update public.daddy_bob_jooseyo_feedings set fed_at=now()-interval '4 hours' where child_id=$1",[child]);
 await db.query("insert into public.daddy_bob_jooseyo_formula_inventory(child_id,product_name,stock_ml_equivalent,package_yield_ml) values($1,'분유',100,5000)",[child]);
 assert.equal((await rpc('due',{},null)).messages.length,0);
 await approve(await rpc('sleep',{name:'별이',enabled:false}));
 const due=(await rpc('due',{},null)).messages;assert(due.some(x=>x.kind==='feeding'));assert(due.some(x=>x.kind==='stock'));
});
test('V3 generated workflow routes every text through GPT, keeps callbacks deterministic and uses existing credential types',()=>{
 const w=JSON.parse(fs.readFileSync('n8n/daddy-bob-jooseyo-v3.json','utf8'));
 assert.equal(w.active,false);assert.equal(w.connections['Is callback?'].main[1][0].node,'Get chat context');
 assert.equal(w.connections['GPT intent and yes-no'].main[0][0].node,'Validate GPT intent');
 assert.equal(w.nodes.find(n=>n.name==='GPT intent and yes-no').parameters.nodeCredentialType,'openAiApi');
 assert(!JSON.stringify(w).includes('$env'));
 const source=w.nodes.find(n=>n.name==='Normalize update').parameters.jsCode;
 const normalize=new Function('$json',source);
 assert.equal(normalize({update_id:9,message:{text:'별이 120 먹었어',from:{id:Number(CHAT)},chat:{id:Number(CHAT),type:'private'}}})[0].json.raw_text,'별이 120 먹었어');
 assert.equal(normalize({update_id:10,message:{text:'/sleep 별이 22:00 08:00',from:{id:Number(CHAT)},chat:{id:Number(CHAT),type:'private'}}})[0].json.action,'sleep');
});

test('explicit /help and /feed remain usable when GPT is uncertain or unavailable, without accepting model-confirmed writes',()=>{
 const source=n=>()=>({item:{json:{normalized:n,context}}});
 const help={...norm('/help'),action:'help'};
 assert.equal(validate({error:'API unavailable'},source(help))[0].json.action,'help');
 const feed={...norm('/feed 별이 120'),action:'feed',args:{update_id:'command-1',name:'별이',amount:120,prepared:120,confirmed:true}};
 const out=validate(response({action:'clarify',confidence:0.5}),source(feed))[0].json;
 assert.equal(out.action,'feed');assert.deepEqual(out.args,{update_id:'command-1',name:'별이',amount:120,prepared:120});
 assert.equal(validate({},source({...feed,args:{...feed.args,name:'다른아이'}}))[0].json.action,'clarify');
 assert.equal(validate({},source({...feed,args:{...feed.args,prepared:100}}))[0].json.action,'clarify');
 const natural={...norm('별이 먹었어'),action:'unknown'};
 assert.equal(validate({},source(natural))[0].json.action,'clarify');
});
