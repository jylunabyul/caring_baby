import {test,before,after} from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';
import {PGlite} from '@electric-sql/pglite';
const chat='9114513581';let db,child,seq=30000;
const q=async(sql,args=[]) => (await db.query(sql,args)).rows;
const call=async(action,args={},id=String(seq++))=>(await q('select public.daddy_bob_jooseyo_bot_v6($1,$2,$3::jsonb) as r',[chat,action,JSON.stringify({...args,...(id==null?{}:{update_id:id})})]))[0].r;
const approve=async()=>{const p=(await q('select state from public.daddy_bob_jooseyo_sessions where chat_id=$1',[chat]))[0].state;return call('decision',{decision:true,expected_token:p.token});};
const future=async minutes=>new Date((await q('select now()+make_interval(mins=>$1) as t',[minutes]))[0].t).toISOString();
let at;
before(async()=>{
 db=new PGlite();await db.exec(`create role anon;create role authenticated;create role service_role;create schema auth;create table auth.users(id uuid primary key);create function auth.uid() returns uuid language sql as $$select null::uuid$$;create function auth.role() returns text language sql as $$select current_setting('request.jwt.claim.role',true)$$;select set_config('request.jwt.claim.role','service_role',false);create table public.other_app(id int);insert into public.other_app values(1);`);
 for(const file of ['daddy_bob_jooseyo.sql','daddy_bob_jooseyo_telegram_only.sql','daddy_bob_jooseyo_v2.sql','daddy_bob_jooseyo_v3.sql','daddy_bob_jooseyo_v5_upgrade.sql','daddy_bob_jooseyo_formal_tone.sql','daddy_bob_jooseyo_v6.sql'])await db.exec(fs.readFileSync('supabase/'+file,'utf8'));
 await db.exec(fs.readFileSync('supabase/daddy_bob_jooseyo_v6.sql','utf8'));
 child=(await q(`insert into public.daddy_bob_jooseyo_children(name,date_of_birth,telegram_chat_id) values('별이',current_date-100,$1) returning id`,[chat]))[0].id;
 at=await future(60);
});
after(async()=>db?.close());
const med=(time,dose=10)=>({action:'medicine_schedule',args:{name:'별이',medicine:'기록용약A',dose,dose_unit:'ml',scheduled_at:time,repeat_daily:false}});
test('one confirmation commits actual temperature, hourly plan and three future medication reminders without fake administrations',async()=>{
 const operations=[{action:'care_setup',args:{name:'별이',care_kind:'temperature',temperature:36.9,record_new:true,interval_minutes:60,overnight:true}},med(at),med(await future(240)),med(await future(540))];
 const p=await call('batch',{operations});assert.match(p.reply,/4개/);
 assert.equal((await q('select count(*)::int as n from public.daddy_bob_jooseyo_health'))[0].n,0);
 const r=await approve();assert.equal(r.ok,true);assert.match(r.reply,/업데이트했습니다/);
 assert.equal((await q('select count(*)::int as n from public.daddy_bob_jooseyo_health'))[0].n,1);
 assert.equal((await q('select interval_minutes from public.daddy_bob_jooseyo_care_plans'))[0].interval_minutes,60);
 assert.equal((await q('select count(*)::int as n from public.daddy_bob_jooseyo_med_slots'))[0].n,3);
 assert.equal((await q("select count(*)::int as n from public.daddy_bob_jooseyo_health where kind='medicine'"))[0].n,0);
});
test('fixed schedule upsert changes same slot, preserves clinical records, duplicate confirmation never executes twice',async()=>{
 await call('batch',{operations:[med(at,9)]});const p=(await q('select state from public.daddy_bob_jooseyo_sessions where chat_id=$1',[chat]))[0].state;
 const args={decision:true,expected_token:p.token};const first=await call('decision',args,'confirm-v6');const second=await call('decision',args,'confirm-v6');
 assert.deepEqual(second,first);assert.equal((await q('select count(*)::int as n from public.daddy_bob_jooseyo_med_slots'))[0].n,3);
 assert.equal(Number((await q('select dose from public.daddy_bob_jooseyo_med_slots where next_due_at=$1',[at]))[0].dose),9);
});
test('failure of a later batch operation rolls back earlier actual records and leaves existing data unchanged',async()=>{
 const before=(await q('select count(*)::int as n from public.daddy_bob_jooseyo_health'))[0].n;
 await call('batch',{operations:[{action:'health',args:{name:'별이',health_kind:'note',note:'must roll back'}}, {...med(await future(300)),args:{...med(at).args,scheduled_at:await future(300),dose_unit:'invalid'}}]});
 const r=await approve();assert.equal(r.ok,false);assert.equal(r.rolled_back,true);assert.equal(r.failed_operation,2);assert.match(r.reply,/모두 되돌렸습니다/);
 assert.equal((await q('select count(*)::int as n from public.daddy_bob_jooseyo_health'))[0].n,before);
 assert.equal((await q('select count(*)::int as n from public.daddy_bob_jooseyo_med_slots'))[0].n,3);
});
test('incomplete mixed message persists only a draft, freezes observation time, and approval cannot execute it',async()=>{
 const draft=[{action:'care_setup',name:'별이',care_kind:'temperature',temperature:36.9,record_new:true,interval_minutes:60,time:null},{action:'medicine_schedule',name:'별이',medicine:'감기약',dose:10,dose_unit:'ml',scheduled_at:null,repeat_daily:false}];
 const before=(await q('select count(*)::int as n from public.daddy_bob_jooseyo_health'))[0].n;
 const r=await call('batch_draft',{draft_operations:draft,question:'실제 약명과 12~1시 중 정확한 시각을 알려주세요.'});assert.match(r.reply,/아직 기록은 변경하지/);
 const ctx=await call('context',{},null);assert.equal(ctx.pending.action,'batch_draft');assert.equal(ctx.pending.operations[0].interval_minutes,60);assert(ctx.pending.operations[0].time);
 const yes=await approve();assert.match(yes.reply,/먼저 확인/);
 assert.equal((await q('select count(*)::int as n from public.daddy_bob_jooseyo_health'))[0].n,before);
 await call('cancel');
});
test('every owner request has feedback, including no-op, repeated update, invalid mutation and clarification',async()=>{
 assert.match((await call('skip')).reply,/추가 변경/);
 const one=await call('skip',{},'same-owner-request');const two=await call('skip',{},'same-owner-request');assert(one.reply&&two.reply);
 const invalid=await call('health',{name:'별이',health_kind:'temperature',temperature:100});assert.equal(invalid.rolled_back,true);assert(invalid.reply);
 await call('clarify',{question:'필수 항목 확인'});assert((await call('clarify',{question:'필수 항목 확인'})).reply);
 assert.equal((await call('care_due',{},null)).messages.length,0);
});
test('clinical fever warnings survive batch previews, success replies and incomplete drafts',async()=>{
 const p=await call('batch',{operations:[{action:'health',args:{name:'별이',health_kind:'temperature',temperature:40.1}}]});
 assert.match(p.reply,/즉시 의료진/);const r=await approve();assert.equal(r.ok,true);assert.match(r.reply,/즉시 의료진/);
 const draft=await call('batch_draft',{draft_operations:[{action:'health',name:'별이',health_kind:'temperature',temperature:40.2}],question:'다른 항목을 확인해 주세요.'});assert.match(draft.reply,/즉시 의료진/);await call('cancel');
});
test('fixed reminders are leased, marked only after send, never log a dose, and stop/snooze invalidate stale marks',async()=>{
 const slot=(await q('select * from public.daddy_bob_jooseyo_med_slots order by next_due_at limit 1'))[0];
 await q("update public.daddy_bob_jooseyo_med_slots set next_due_at=now()-interval '1 minute' where id=$1",[slot.id]);
 const msg=(await call('care_due',{},null)).messages.find(x=>x.schedule_id===slot.id);assert(msg);
 assert(!(await call('care_due',{},null)).messages.some(x=>x.schedule_id===slot.id));
 await call('medicine_snooze',{schedule_id:slot.id,minutes:30});const changed=(await q('select next_due_at from public.daddy_bob_jooseyo_med_slots where id=$1',[slot.id]))[0].next_due_at;
 await call('mark',msg,null);assert.equal(new Date((await q('select next_due_at from public.daddy_bob_jooseyo_med_slots where id=$1',[slot.id]))[0].next_due_at).getTime(),new Date(changed).getTime());
 await call('medicine_cancel',{schedule_id:slot.id});assert.equal((await q('select active from public.daddy_bob_jooseyo_med_slots where id=$1',[slot.id]))[0].active,false);
 assert.equal((await q("select count(*)::int as n from public.daddy_bob_jooseyo_health where kind='medicine'"))[0].n,0);
});
test('new fixed slots deny browser reads and retain unrelated app tables',async()=>{
 const p=(await q("select relrowsecurity,has_table_privilege('authenticated',oid,'SELECT') as can_read from pg_class where relname='daddy_bob_jooseyo_med_slots'"))[0];assert.equal(p.relrowsecurity,true);assert.equal(p.can_read,false);
 await assert.rejects(db.query("select public.daddy_bob_jooseyo_bot_v6('42','context','{}')"),/Not authorized/);
 assert.equal((await q('select count(*)::int as n from public.other_app'))[0].n,1);
});
const w=JSON.parse(fs.readFileSync('n8n/daddy-bob-jooseyo-v6.json','utf8'));
const code=name=>w.nodes.find(n=>n.name===name).parameters.jsCode;
test('only private owner chat AND sender can reach model/DB; everyone else receives exact denial',()=>{
 const check=new Function('$json',code('Check private owner'));
 const update=(cid,sender,type='private')=>({update_id:1,message:{text:'anything',chat:{id:cid,type},from:{id:sender}}});
 assert.equal(check(update(Number(chat),Number(chat)))[0].json.owner_allowed,true);
 for(const [cid,sender,type] of [[42,42,'private'],[Number(chat),42,'private'],[-42,Number(chat),'group']])assert.equal(check(update(cid,sender,type))[0].json.owner_allowed,false);
 assert.equal(w.nodes.find(n=>n.name==='Reply access denied').parameters.text,'죄송합니다. 허용되지 않았습니다.');
 assert.equal(w.connections['Owner allowed?'].main[1][0].node,'Reply access denied');
 assert.equal(w.connections['Owner allowed?'].main[0][0].node,'Normalize update');
});
test('multi-intent validation retains known interval, asks only missing facts and emits a typed batch after clarification',()=>{
 const n={chat_id:chat,action:'unknown',raw_text:'체온 36.9, 1시간마다. 감기약 10ml 점심12~1시, 저녁5~6시,22시',args:{update_id:'mixed'},callback_id:''};
 const ctx={children:[{id:'c',name:'별이'}],recent:[],health_recent:[],care_plans:[],fixed_schedules:[],pending:null,now_kst:'2026-11-26T10:30:00+09:00'};
 const build=new Function('$json','$',code('Build Gemini request'));
 const built=build({context:ctx},()=>({item:{json:n}}))[0].json;
 const validate=new Function('$json','$',code('Validate Gemini intent'));
 const map=v=>validate({choices:[{finish_reason:'stop',message:{content:JSON.stringify(v)}}]},()=>({item:{json:built}}))[0].json;
 const temp={action:'care_setup',confidence:0.99,name:'별이',care_kind:'temperature',temperature:36.9,record_new:true,interval_minutes:60,overnight:true,time:'2026-11-26T10:30:00+09:00'};
 const medication={action:'medicine_schedule',confidence:0.99,name:'별이',medicine:'감기약',dose:10,dose_unit:'ml',scheduled_at:null,repeat_daily:false,question:'점심 12~1시 중 정확히 몇 시인가요?'};
 const missing=map({action:'batch',confidence:0.99,operations:[temp,medication]});assert.equal(missing.action,'batch_draft');assert.equal(missing.args.draft_operations[0].interval_minutes,60);assert.match(missing.args.question,/60분/);assert.match(missing.args.question,/실제 약 이름/);assert.match(missing.args.question,/12~1/);assert(!missing.args.question.includes('몇 시간'));
 const complete=map({action:'batch',confidence:0.99,operations:[temp,{...medication,medicine:'약명A',scheduled_at:'2026-11-26T12:00:00+09:00'}]});assert.equal(complete.action,'batch');assert.equal(complete.args.operations.length,2);
 assert(!('confirmed' in complete.args.operations[0].args));
 const restored=build({context:{...ctx,pending:{action:'batch_draft',operations:[temp,medication],question:'약명?'}}},()=>({item:{json:n}}))[0].json;
 assert.equal(JSON.parse(restored.request.contents[0].parts[0].text).context.pending.operations.length,2);
});
test('context and code failures have a reply path, with honest unknown commit status for network errors',()=>{
 const quick=new Function('$json','$',code('Resolve short replies'));
 const n={chat_id:chat,raw_text:'기록해줘',args:{update_id:'error'},callback_id:''};
 const output=quick({error:'network failed'},()=>({item:{json:n}}))[0].json;assert.equal(output.action,'chat');assert(output.reply);
 const format=new Function('$json',code('Format response'));assert.match(format({error:'timeout'})[0].json.reply,/저장 여부가 불확실/);
 assert.equal(w.connections['Ready without model?'].main[0][0].node,'Is conversation?');
 for(const name of ['Build Gemini request','Decode Gemini response','Validate Gemini intent'])assert.equal(w.connections[name].main[1][0].node,'Format response');
});
