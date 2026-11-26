import {test} from 'node:test';import assert from 'node:assert/strict';import fs from 'node:fs';import {PGlite} from '@electric-sql/pglite';
const source=fs.readFileSync('scripts/bot-korean-time.js','utf8');const normalize=new Function('$json','$',source);
const make=(intent,raw='어제 오후 1시에 200미리 먹였어')=>{
 const x={choices:[{finish_reason:'stop',message:{content:JSON.stringify(intent)}}]};
 return JSON.parse(normalize(x,()=>({item:{json:{normalized:{raw_text:raw}}}}))[0].json.choices[0].message.content);
};
test('Korean local afternoon time is attached to +09 exactly once, already-KST inputs do not shift',()=>{
 for(const time of ['2026-11-26T13:00:00','2026-11-26T13:00','2026-11-26T13:00:00+09:00'])assert.equal(make({action:'feed',time}).time,'2026-11-26T13:00:00+09:00');
 assert.equal(make({action:'feed',time:'2026-11-26T01:00:00'},'오늘 오전 1시에 먹였어').time,'2026-11-26T01:00:00+09:00');
});
test('unqualified one oclock, wrong offset, and invalid calendar dates never silently change the instant',()=>{
 assert.equal(make({action:'feed',time:'2026-11-26T13:00:00'},'한시에 200미리 먹였어').action,'clarify');
 assert.equal(make({action:'feed',time:'2026-11-26T04:00:00Z'}).action,'clarify');
 assert.equal(make({action:'health',time:'2026-02-30T13:00:00'}).action,'clarify');
});
test('batch record/schedule/end times normalize independently and care intervals are not mistaken for hours of day',()=>{
 const v=make({action:'batch',operations:[{action:'health',time:'2026-11-26T10:30:00'},{action:'medicine_schedule',scheduled_at:'2026-11-26T22:00:00',end_at:'2026-11-28T22:00:00'}]},'현재 10시30분 36.9도, 한시간마다 확인. 밤 10시 약 알림');
 assert.equal(v.operations[0].time,'2026-11-26T10:30:00+09:00');assert.equal(v.operations[1].scheduled_at,'2026-11-26T22:00:00+09:00');
 assert.equal(v.operations[1].end_at,'2026-11-28T22:00:00+09:00');
});
test('provider errors pass through without inventing event times',()=>{assert.deepEqual(normalize({provider_error:'quota'},()=>{}),[{json:{provider_error:'quota'}}]);});
test('Telegram receive date anchors Korean today, and model context presents UTC event instants in KST',()=>{
 const w=JSON.parse(fs.readFileSync('n8n/daddy-bob-jooseyo-v6-kst.json','utf8'));
 const parse=new Function('$json',w.nodes.find(n=>n.name==='Normalize update').parameters.jsCode);
 const date=Date.parse('2026-11-26T13:05:00+09:00')/1000;
 const n=parse({update_id:1,message:{date,text:'오후 1시에 200 먹었어',from:{id:9114513581},chat:{id:9114513581,type:'private'}}})[0].json;
 assert.equal(n.received_at_kst,'2026-11-26T13:05:00.000+09:00');
 const build=new Function('$json','$',w.nodes.find(n=>n.name==='Build Gemini request').parameters.jsCode);
 const context={children:[],recent:[],health_recent:[{occurred_at:'2026-11-26T04:00:00Z'}],care_plans:[],fixed_schedules:[],pending:null,now_kst:'2026-11-26T13:06:00+09:00'};
 const built=build({context},()=>({item:{json:n}}))[0].json;const prompt=JSON.parse(built.request.contents[0].parts[0].text);
 assert.equal(prompt.context.now_kst,n.received_at_kst);assert.equal(prompt.context.health_recent[0].occurred_at,'2026-11-26T13:00:00.000+09:00');
 assert.equal(w.connections['Decode Gemini response'].main[0][0].node,'Normalize Korean input times');
});
test('single Korean 13:00 feeding stores UTC 04:00 and KST 13:00, displays Korean, preserving original records',async()=>{
 const db=new PGlite();try{
 await db.exec(`create role anon;create role authenticated;create role service_role;create schema auth;create table auth.users(id uuid primary key);create function auth.uid() returns uuid language sql as $$select null::uuid$$;create function auth.role() returns text language sql as $$select current_setting('request.jwt.claim.role',true)$$;select set_config('request.jwt.claim.role','service_role',false);`);
 for(const f of ['daddy_bob_jooseyo.sql','daddy_bob_jooseyo_telegram_only.sql','daddy_bob_jooseyo_v2.sql','daddy_bob_jooseyo_v3.sql','daddy_bob_jooseyo_v5_upgrade.sql','daddy_bob_jooseyo_formal_tone.sql','daddy_bob_jooseyo_v6.sql'])await db.exec(fs.readFileSync('supabase/'+f,'utf8'));
 await db.exec(`insert into public.daddy_bob_jooseyo_children(name,date_of_birth,telegram_chat_id) values('별이',current_date-100,'9114513581');`);
 const patch=fs.readFileSync('supabase/daddy_bob_jooseyo_korean_io.sql','utf8');await db.exec(patch);await db.exec(patch);
 const day=(await db.query("select (current_date-1)::text as day")).rows[0].day;
 const call=async(action,args)=>(await db.query("select public.daddy_bob_jooseyo_bot_v6('9114513581',$1,$2::jsonb) as r",[action,JSON.stringify(args)])).rows[0].r;
 const pending=await call('feed',{name:'별이',amount:200,prepared:200,time:day+'T13:00:00+09:00',update_id:'kst-proposal'});
 assert.match(pending.reply,/오후 1:00 \(한국 시간\)/);assert(!pending.reply.includes('T13:00'));
 const token=(await db.query('select state from public.daddy_bob_jooseyo_sessions')).rows[0].state.token;
 await call('decision',{decision:true,expected_token:token,update_id:'kst-save'});
 const row=(await db.query("select amount_ml,to_char(fed_at_utc,'HH24:MI') as utc,to_char(fed_at_kst,'HH24:MI') as kst from public.daddy_bob_jooseyo_feedings")).rows[0];
 assert.deepEqual(row,{amount_ml:200,utc:'04:00',kst:'13:00'});
 await db.exec(patch);assert.equal((await db.query('select count(*)::int as n from public.daddy_bob_jooseyo_feedings')).rows[0].n,1);
 }finally{await db.close();}
});
