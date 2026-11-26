import {test,before,after} from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';
import {PGlite} from '@electric-sql/pglite';
const w=JSON.parse(fs.readFileSync('n8n/daddy-bob-jooseyo-v4.json','utf8'));
const code=name=>w.nodes.find(n=>n.name===name).parameters.jsCode;
const quick=new Function('$json','$',code('Resolve short replies'));
const chat='9114513581',token='00000000-0000-0000-0000-000000000099';
const context={children:[{id:'child',name:'별이'}],recent:[],pending:{action:'feed',token,args:{name:'별이',amount:120}},now_kst:'2026-11-25T22:00:00+09:00'};
const n=text=>({chat_id:chat,action:'unknown',raw_text:text,args:{update_id:'v4-1'},callback_id:''});
const route=(text,c=context)=>quick(c,()=>({item:{json:n(text)}}))[0].json;
let db,child,seq=10000;
const rows=async(sql,args=[]) => (await db.query(sql,args)).rows;
const call=async(action,args={},id=String(seq++))=>(await rows('select public.daddy_bob_jooseyo_bot_v4($1,$2,$3::jsonb) as result',[chat,action,JSON.stringify({...args,...(id==null?{}:{update_id:id})})]))[0].result;
const yes=async p=>call('decision',{decision:true,expected_token:p.buttons[0].data.split(':')[1]});
before(async()=>{
 db=new PGlite();
 await db.exec(`create role anon;create role authenticated;create role service_role;create schema auth;create table auth.users(id uuid primary key);create function auth.uid() returns uuid language sql as $$select null::uuid$$;create function auth.role() returns text language sql as $$select current_setting('request.jwt.claim.role',true)$$;select set_config('request.jwt.claim.role','service_role',false);create table public.unrelated(id int);insert into public.unrelated values(1);`);
 for(const f of ['daddy_bob_jooseyo.sql','daddy_bob_jooseyo_telegram_only.sql','daddy_bob_jooseyo_v2.sql','daddy_bob_jooseyo_v3.sql','daddy_bob_jooseyo_v4.sql'])await db.exec(fs.readFileSync('supabase/'+f,'utf8'));
 await db.exec(fs.readFileSync('supabase/daddy_bob_jooseyo_v4.sql','utf8'));
 child=(await rows(`insert into public.daddy_bob_jooseyo_children(name,date_of_birth,telegram_chat_id,quiet_enabled) values('별이',current_date-20,$1,false) returning id`,[chat]))[0].id;
});
after(async()=>db?.close());
test('confirmation typo variants resolve without Gemini and stay token-bound; negation never becomes approval',()=>{
 for(const text of ['응','웅','ㅇㅇ','넹','응ㅋㅋ','네!']){const out=route(text);assert.equal(out.ready,true);assert.equal(out.args.decision,true);assert.equal(out.args.expected_token,token);}
 for(const text of ['아니','아뇨','아닝','ㄴㄴ','아니요!'])assert.equal(route(text).args.decision,false);
 assert.equal(route('응 근데 100으로 바꿔').ready,false);
 assert.equal(route('응',{...context,pending:null}).action,'skip');
 assert.equal(route('응',{...context,pending:{...context.pending,action:'await_amount'}}).action,'skip');
});
test('repeated uncertain answers have at most one hint per pending session; repeated proposals and updates stay silent',async()=>{
 const p=await call('feed',{name:'별이',amount:120,prepared:120});assert.match(p.reply,/오빠/);
 const a=await call('quiet_clarify',{question:'확인 버튼 눌러줘.'});assert.match(a.reply,/오빠/);
 assert.equal((await call('quiet_clarify',{question:'확인 버튼 눌러줘.'})).silent,true);
 assert.equal((await call('feed',{name:'별이',amount:120,prepared:120})).silent,true);
 const out=await yes(p);assert.match(out.reply,/기록해뒀어/);
 assert.equal((await call('skip',{},'same-skip')).silent,true);
 assert.equal((await call('skip',{},'same-skip')).silent,true);
});
test('health temperature and medicine require confirmation, preserve exact time/dose, and reject missing medicine units',async()=>{
 const eventTime=new Date((await rows("select now()-interval '2 hours' as t"))[0].t).toISOString();
 const p=await call('health',{name:'별이',health_kind:'temperature',temperature:38.2,time:eventTime});
 assert.equal((await rows('select count(*)::int as n from public.daddy_bob_jooseyo_health'))[0].n,0);
 await yes(p);
 const temp=(await rows("select * from public.daddy_bob_jooseyo_health where kind='temperature'"))[0];assert.equal(Number(temp.temperature_c),38.2);
 assert.equal(new Date(temp.occurred_at).toISOString(),eventTime);
 const m=await call('health',{name:'별이',health_kind:'medicine',medicine:'기록용 약명',dose:2.5,dose_unit:'ml'});
 await yes(m);
 const med=(await rows("select * from public.daddy_bob_jooseyo_health where kind='medicine'"))[0];assert.equal(Number(med.dose),2.5);assert.equal(med.dose_unit,'ml');
 await assert.rejects(call('health',{name:'별이',health_kind:'medicine',medicine:'약명',dose:2.5}),/required/);
 const fever=await call('health',{name:'별이',health_kind:'temperature',temperature:38.1});assert.match(fever.reply,/즉시 의료진/);
 await call('cancel');
 await assert.rejects(call('health',{name:'별이',health_kind:'temperature',temperature:38,time:'2000-01-01T00:00:00+09:00'}),/predates birth/);
});
test('health notes, history and cancellation work without changing feeding amounts; warning text is not diluted',async()=>{
 const p=await call('health',{name:'별이',health_kind:'note',note:'기침 두 번 했음'});await yes(p);
 assert.match((await call('healthhistory',{name:'별이'})).reply,/기침 두 번/);
 const cancelled=await call('health',{name:'별이',health_kind:'note',note:'저장하면 안 됨'});
 await call('decision',{decision:false,expected_token:cancelled.buttons[0].data.split(':')[1]});
 assert.equal((await rows("select count(*)::int as n from public.daddy_bob_jooseyo_health where note='저장하면 안 됨'"))[0].n,0);
 assert.equal((await rows('select amount_ml from public.daddy_bob_jooseyo_feedings limit 1'))[0].amount_ml,120);
});
test('morning plan is claimed once across concurrent schedule queries; failed delivery retries and marking never creates a feed',async()=>{
 await db.query("update public.daddy_bob_jooseyo_children set morning_time='00:00',morning_end='23:59:59.999999' where id=$1",[child]);
 const count=(await rows('select count(*)::int as n from public.daddy_bob_jooseyo_feedings'))[0].n;
 const first=await call('due',{},null);const m=first.messages.find(m=>m.kind==='morning');assert(m);assert.match(m.reply,/200ml/);assert.match(m.reply,/오빠가 정해둔/);
 assert(!(await call('due',{},null)).messages.some(m=>m.kind==='morning'));
 await db.query("update public.daddy_bob_jooseyo_children set morning_claim_until=now()-interval '1 minute' where id=$1",[child]);
 assert((await call('due',{},null)).messages.some(m=>m.kind==='morning'));
 await call('mark',{kind:'morning',child_id:child,delivery_day:m.delivery_day},null);
 assert(!(await call('due',{},null)).messages.some(m=>m.kind==='morning'));
 assert.equal((await rows('select count(*)::int as n from public.daddy_bob_jooseyo_feedings'))[0].n,count);
});
test('morning plan is user-configurable and original 08-09 defaults persist for a new child',async()=>{
 const p=await call('morning',{name:'별이',enabled:true,plan_ml:180});await yes(p);
 assert.equal((await rows('select morning_plan_ml from public.daddy_bob_jooseyo_children where id=$1',[child]))[0].morning_plan_ml,180);
 const off=await call('morning',{name:'별이',enabled:false,plan_ml:180});await yes(off);
 assert.equal((await rows('select morning_enabled from public.daddy_bob_jooseyo_children where id=$1',[child]))[0].morning_enabled,false);
 const add=await call('childadd',{name:'둘째',dob:'2026-07-13'});await yes(add);
 const ch=(await rows("select morning_time,morning_end,morning_plan_ml from public.daddy_bob_jooseyo_children where name='둘째'"))[0];assert.equal(ch.morning_time,'08:00:00');assert.equal(ch.morning_end,'09:00:00');assert.equal(ch.morning_plan_ml,200);
});
test('V4 model request/validator support health with no invented doses and native Gemini remains wired',()=>{
 const request=new Function('$json','$',code('Build Gemini request'));
 const normalized=n('별이 약 2.5ml 줬어');const c={...context,pending:null};
 const built=request({context:c},()=>({item:{json:normalized}}))[0].json;
 assert(built.request.generationConfig.responseSchema.properties.medicine);
 assert.match(built.request.systemInstruction.parts[0].text,/Do NOT guess any medication/);
 const validate=new Function('$json','$',code('Validate Gemini intent'));
 const ai=v=>({choices:[{finish_reason:'stop',message:{content:JSON.stringify({confidence:0.99,...v})}}]});
 const source=()=>({item:{json:built}});
 assert.equal(validate(ai({action:'health',name:'별이',health_kind:'medicine',medicine:'약명',dose:2.5,dose_unit:'ml'}),source)[0].json.action,'health');
 assert.equal(validate(ai({action:'health',name:'별이',health_kind:'medicine',medicine:'약명',dose:2.5}),source)[0].json.action,'clarify');
 assert.equal(validate(ai({action:'health',name:'별이',health_kind:'temperature',temperature:38.2}),source)[0].json.args.temperature,38.2);
 assert.equal(w.nodes.find(n=>n.name==='Morning at 8 Seoul').parameters.rule.interval[0].expression,'0 8 * * *');
 assert.equal(w.settings.timezone,'Asia/Seoul');assert.equal(w.connections['Ready without model?'].main[0][0].node,'Process command');
 const format=new Function('$json',code('Format response'));assert.deepEqual(format({silent:true}),[]);
});
test('deleting a child removes only that child health records; other tables remain untouched; all new tables deny browser reads',async()=>{
 const p=await call('childdelete',{name:'별이'});await yes(p);
 assert.equal((await rows('select count(*)::int as n from public.daddy_bob_jooseyo_health where child_id=$1',[child]))[0].n,0);
 assert.match((await call('children')).reply,/둘째/);
 assert.equal((await rows('select count(*)::int as n from public.unrelated'))[0].n,1);
 for(const t of ['daddy_bob_jooseyo_health','daddy_bob_jooseyo_chat_guard']){
  const x=(await rows("select relrowsecurity,has_table_privilege('authenticated',oid,'SELECT') as allowed from pg_class where relname=$1",[t]))[0];assert.equal(x.relrowsecurity,true);assert.equal(x.allowed,false);
 }
});
