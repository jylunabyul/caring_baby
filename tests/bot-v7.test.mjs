import {test,before,after} from 'node:test';import assert from 'node:assert/strict';import fs from 'node:fs';import {PGlite} from '@electric-sql/pglite';
let db,child,other,seq=40000;const chat='9114513581';
const q=async(sql,args=[]) => (await db.query(sql,args)).rows;
const call=async(action,args={},id=String(seq++))=>(await q('select public.daddy_bob_jooseyo_bot_v7($1,$2,$3::jsonb) as r',[chat,action,JSON.stringify({...args,...(id==null?{}:{update_id:id})})]))[0].r;
const approve=async()=>{const p=(await q('select state from public.daddy_bob_jooseyo_sessions where chat_id=$1',[chat]))[0].state;return call('decision',{decision:true,expected_token:p.token});};
const clock=async minutes=>new Date((await q('select now()+make_interval(mins=>$1) as t',[minutes]))[0].t).toISOString();
before(async()=>{
 db=new PGlite();await db.exec(`create role anon;create role authenticated;create role service_role;create schema auth;create table auth.users(id uuid primary key);create function auth.uid() returns uuid language sql as $$select null::uuid$$;create function auth.role() returns text language sql as $$select current_setting('request.jwt.claim.role',true)$$;select set_config('request.jwt.claim.role','service_role',false);create table public.unrelated_app(id int);insert into public.unrelated_app values(1);`);
 for(const f of ['daddy_bob_jooseyo.sql','daddy_bob_jooseyo_telegram_only.sql','daddy_bob_jooseyo_v2.sql','daddy_bob_jooseyo_v3.sql','daddy_bob_jooseyo_v5_upgrade.sql','daddy_bob_jooseyo_v6.sql','daddy_bob_jooseyo_v7.sql'])await db.exec(fs.readFileSync('supabase/'+f,'utf8'));
 await db.exec(fs.readFileSync('supabase/daddy_bob_jooseyo_v7.sql','utf8'));
 child=(await q(`insert into public.daddy_bob_jooseyo_children(name,date_of_birth,telegram_chat_id) values('별이',current_date-100,$1) returning id`,[chat]))[0].id;
 other=(await q(`insert into public.daddy_bob_jooseyo_children(name,date_of_birth,telegram_chat_id) values('둘째',current_date-100,$1) returning id`,[chat]))[0].id;
 await q("insert into public.daddy_bob_jooseyo_health(child_id,kind,temperature_c) values($1,'temperature',36.9)",[child]);
 for(const [cid,kind,medicine]of[[child,'temperature',''],[child,'medicine','약A'],[child,'medicine','약B'],[other,'temperature','']]){
  await q("insert into public.daddy_bob_jooseyo_care_plans(child_id,kind,medicine,dose,dose_unit,interval_minutes,anchor_at,next_due_at,overnight) values($1,$2,$3,2.5,'ml',60,now(),now()+interval '1 hour',true)",[cid,kind,medicine]);
 }
 for(const medicine of ['약A','약B'])await q("insert into public.daddy_bob_jooseyo_med_slots(child_id,medicine,dose,dose_unit,slot_key,next_due_at) values($1,$2,2.5,'ml','slot',now()+interval '2 hours')",[child,medicine]);
});
after(async()=>db?.close());
test('stop temperature only leaves medicine and all clinical records intact; stop a specific drug covers both reminder systems',async()=>{
 const before=(await q('select * from public.daddy_bob_jooseyo_health')).map(x=>JSON.stringify(x));
 assert.equal((await call('stop_health_alerts',{name:'별이',stop_kinds:['temperature']})).stopped,1);
 assert.equal((await q("select count(*)::int as n from public.daddy_bob_jooseyo_care_plans where child_id=$1 and kind='medicine' and active",[child]))[0].n,2);
 assert.equal((await call('stop_health_alerts',{name:'별이',stop_kinds:['medicine'],medicine:'약A'})).stopped,2);
 assert.equal((await q("select count(*)::int as n from public.daddy_bob_jooseyo_care_plans where child_id=$1 and medicine='약B' and active",[child]))[0].n,1);
 assert.deepEqual((await q('select * from public.daddy_bob_jooseyo_health')).map(x=>JSON.stringify(x)),before);
});
test('stop both affects only selected child, invalidates staged reactivation and leaves feeding/morning plans intact',async()=>{
 const morning=(await q('select morning_enabled from public.daddy_bob_jooseyo_children where id=$1',[child]))[0].morning_enabled;
 await call('batch',{operations:[{action:'medicine_schedule',args:{name:'별이',medicine:'약B',dose:2.5,dose_unit:'ml',scheduled_at:await clock(60),repeat_daily:false}}]});
 const p=(await q('select state from public.daddy_bob_jooseyo_sessions where chat_id=$1',[chat]))[0].state;
 const r=await call('stop_health_alerts',{name:'별이',stop_kinds:['medicine','temperature']});assert.equal(r.stopped,2);assert.match(r.reply,/기존 기록은 유지/);
 assert.equal((await q('select count(*)::int as n from public.daddy_bob_jooseyo_care_plans where child_id=$1 and active',[other]))[0].n,1);
 assert.equal((await q('select morning_enabled from public.daddy_bob_jooseyo_children where id=$1',[child]))[0].morning_enabled,morning);
 assert.equal((await q('select count(*)::int as n from public.daddy_bob_jooseyo_sessions where chat_id=$1',[chat]))[0].n,0);
 await call('decision',{decision:true,expected_token:p.token});assert.equal((await q('select count(*)::int as n from public.daddy_bob_jooseyo_med_slots where child_id=$1 and active',[child]))[0].n,0);
});
test('historical nap is confirmed once and stores start/end UTC+KST with computed duration',async()=>{
 const day=(await q("select (current_date-1)::text as d"))[0].d;
 const p=await call('rest_record',{name:'별이',rest_kind:'nap',started_at:day+'T13:00:00+09:00',ended_at:day+'T14:00:00+09:00'});
 assert.match(p.reply,/기록할까요/);assert.equal((await q('select count(*)::int as n from public.daddy_bob_jooseyo_rests'))[0].n,0);
 assert.equal((await approve()).ok,true);
 const row=(await q("select kind,duration_minutes,to_char(started_at_utc,'HH24:MI') as utc,to_char(started_at_kst,'HH24:MI') as kst from public.daddy_bob_jooseyo_rests"))[0];
 assert.equal(row.kind,'nap');assert.equal(Number(row.duration_minutes),60);assert.equal(row.utc,'04:00');assert.equal(row.kst,'13:00');
 const older=(await q("select (current_date-2)::text as d"))[0].d;
 await call('rest_record',{name:'별이',rest_kind:'night',started_at:older+'T22:00:00+09:00',ended_at:day+'T07:00:00+09:00'});await approve();
 const night=(await q("select duration_minutes,to_char(ended_at_kst,'HH24:MI') as kst from public.daddy_bob_jooseyo_rests where kind='night'"))[0];assert.equal(Number(night.duration_minutes),540);assert.equal(night.kst,'07:00');
});
test('open sleep start and wake-up form one session, overlaps/future intervals do not overwrite it',async()=>{
 const started=await clock(-60),ended=await clock(-10);
 await call('rest_start',{name:'별이',rest_kind:'night',time:started});await approve();
 assert.equal((await q('select count(*)::int as n from public.daddy_bob_jooseyo_rests where ended_at is null'))[0].n,1);
 const duplicate=await call('rest_start',{name:'별이',rest_kind:'nap',time:await clock(-30)});assert.equal(duplicate.ok,false);
 await call('rest_end',{name:'별이',time:ended});await approve();
 assert.equal((await q('select count(*)::int as n from public.daddy_bob_jooseyo_rests where ended_at is null'))[0].n,0);
 const overlap=await call('rest_record',{name:'별이',rest_kind:'nap',started_at:await clock(-50),ended_at:await clock(-40)});assert.equal(overlap.ok,false);
 const future=await call('rest_start',{name:'別',rest_kind:'night',time:await clock(60)});assert.equal(future.ok,false);
 const history=await call('rest_history',{name:'별이'});assert.match(history.reply,/낮잠/);assert.match(history.reply,/밤잠/);assert.match(history.reply,/한국 시간/);
});
test('new sleep operations participate in existing atomic batch rollback',async()=>{
 const day=(await q("select (current_date-2)::text as d"))[0].d;
 const before=(await q('select count(*)::int as n from public.daddy_bob_jooseyo_rests'))[0].n;
 await call('batch',{operations:[{action:'rest_record',args:{name:'별이',rest_kind:'nap',started_at:day+'T13:00:00+09:00',ended_at:day+'T14:00:00+09:00'}},{action:'health',args:{name:'별이',health_kind:'temperature',temperature:100}}]});
 const failed=await approve();assert.equal(failed.rolled_back,true);assert.equal((await q('select count(*)::int as n from public.daddy_bob_jooseyo_rests'))[0].n,before);
 await call('batch',{operations:[{action:'rest_record',args:{name:'별이',rest_kind:'nap',started_at:day+'T13:00:00+09:00',ended_at:day+'T14:00:00+09:00'}},{action:'rest_history',args:{name:'별이'}}]});
 const ok=await approve();assert.equal(ok.ok,true);assert.match(ok.reply,/최근 수면 기록/);
});
test('rest tables enforce RLS/owner scope and cascade only with the explicitly deleted child',async()=>{
 const x=(await q("select relrowsecurity,has_table_privilege('authenticated',oid,'SELECT') as allowed from pg_class where relname='daddy_bob_jooseyo_rests'"))[0];assert.equal(x.relrowsecurity,true);assert.equal(x.allowed,false);
 await assert.rejects(db.query("select public.daddy_bob_jooseyo_bot_v7('42','rest_history','{}')"),/Not authorized/);
 await call('childdelete',{name:'별이'});await approve();assert.equal((await q('select count(*)::int as n from public.daddy_bob_jooseyo_rests where child_id=$1',[child]))[0].n,0);
 assert.equal((await q('select count(*)::int as n from public.daddy_bob_jooseyo_children where id=$1',[other]))[0].n,1);
 assert.equal((await q('select count(*)::int as n from public.unrelated_app'))[0].n,1);
});
const w=JSON.parse(fs.readFileSync('n8n/daddy-bob-jooseyo-v7.json','utf8'));
const get=name=>w.nodes.find(n=>n.name===name);
test('model maps stop/logging phrase to reminders only; one-child inference and multi-child ambiguity are guarded',()=>{
 const normalize={chat_id:chat,action:'unknown',raw_text:'약이랑 체온은 그만 기록해도 돼',args:{update_id:'new'},callback_id:''};
 const context={children:[{id:'1',name:'별이'}],recent:[],health_recent:[],care_plans:[],fixed_schedules:[],rest_recent:[],pending:null,now_kst:'2026-11-26T15:00:00+09:00'};
 const build=new Function('$json','$',get('Build Gemini request').parameters.jsCode);
 const validate=new Function('$json','$',get('Validate Gemini intent').parameters.jsCode);
 const map=(value,c=context)=>{
  const built=build({context:c},()=>({item:{json:normalize}}))[0].json;
  return validate({choices:[{finish_reason:'stop',message:{content:JSON.stringify({confidence:0.99,...value})}}]},()=>({item:{json:built}}))[0].json;
 };
 const op={action:'stop_health_alerts',stop_kinds:['medicine','temperature'],all_children:false};
 assert.equal(map(op).args.name,'별이');assert.equal(map(op).action,'stop_health_alerts');
 assert.equal(map(op,{...context,children:[...context.children,{id:'2',name:'둘째'}]}).action,'clarify');
 assert.equal(map({...op,all_children:true}).action,'clarify');
 const rest=map({action:'rest_record',name:'별이',rest_kind:'nap',started_at:'2026-11-25T13:00:00+09:00',ended_at:'2026-11-25T14:00:00+09:00'});assert.equal(rest.action,'rest_record');
 const batch=map({action:'batch',operations:[{action:'rest_record',name:'별이',rest_kind:'nap',started_at:'2026-11-25T13:00:00+09:00',ended_at:'2026-11-25T14:00:00+09:00',confidence:0.99}]});assert.equal(batch.action,'batch');assert.equal(batch.args.operations[0].action,'rest_record');
 const built=build({context},()=>({item:{json:normalize}}))[0].json;assert.match(built.request.systemInstruction.parts[0].text,/NOT deletion/);assert(JSON.parse(built.request.contents[0].parts[0].text).context.rest_recent);
});
