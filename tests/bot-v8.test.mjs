import {test,before,after} from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';
import {PGlite} from '@electric-sql/pglite';
let db,child,other;const chat='9114513581';
const q=async(sql,args=[])=>(await db.query(sql,args)).rows;
const call=async(args={})=>(await q('select public.daddy_bob_jooseyo_bot_v8($1,\'daily_timeline\',$2::jsonb) r',[chat,JSON.stringify({report_date:'2026-11-26',...args})]))[0].r;
before(async()=>{
 db=new PGlite();await db.exec(`create role anon;create role authenticated;create role service_role;create schema auth;create table auth.users(id uuid primary key);create function auth.uid() returns uuid language sql as $$select null::uuid$$;create function auth.role() returns text language sql as $$select current_setting('request.jwt.claim.role',true)$$;select set_config('request.jwt.claim.role','service_role',false);`);
 for(const f of ['daddy_bob_jooseyo.sql','daddy_bob_jooseyo_telegram_only.sql','daddy_bob_jooseyo_v2.sql','daddy_bob_jooseyo_v3.sql','daddy_bob_jooseyo_v5_upgrade.sql','daddy_bob_jooseyo_v5_to_v8.sql'])await db.exec(fs.readFileSync('supabase/'+f,'utf8'));
 child=(await q("insert into public.daddy_bob_jooseyo_children(name,date_of_birth,telegram_chat_id) values('별이','2026-07-13',$1) returning id",[chat]))[0].id;
 other=(await q("insert into public.daddy_bob_jooseyo_children(name,date_of_birth,telegram_chat_id) values('둘째','2026-07-13',$1) returning id",[chat]))[0].id;
 for(const [day,time,amount] of [['25','23:59',1],['26','00:00',100],['26','09:00',200],['26','23:59',50],['27','00:00',1]])await q('insert into public.daddy_bob_jooseyo_feedings(child_id,amount_ml,prepared_ml,fed_at) values($1,$2,$2,$3)',[child,amount,`2026-11-${day}T${time}:00+09:00`]);
 await q("insert into public.daddy_bob_jooseyo_feedings(child_id,amount_ml,prepared_ml,fed_at) values($1,90,120,'2026-11-26T08:00:00+09:00')",[other]);
 await q("insert into public.daddy_bob_jooseyo_health(child_id,kind,temperature_c,occurred_at) values($1,'temperature',36.9,'2026-11-26T10:30:00+09:00')",[child]);
 await q("insert into public.daddy_bob_jooseyo_health(child_id,kind,medicine,dose,dose_unit,occurred_at) values($1,'medicine','처방약',2.5,'ml','2026-11-26T12:00:00+09:00')",[child]);
 await q("insert into public.daddy_bob_jooseyo_health(child_id,kind,note,occurred_at) values($1,'note','기분 좋음','2026-11-26T15:00:00+09:00')",[child]);
 await q("insert into public.daddy_bob_jooseyo_rests(child_id,kind,started_at,ended_at) values($1,'night','2026-11-25T22:00:00+09:00','2026-11-26T07:00:00+09:00'),($1,'nap','2026-11-26T13:00:00+09:00','2026-11-26T14:00:00+09:00')",[child]);
});
after(async()=>db?.close());
test('Korean midnight boundaries and all child chronological clinical timeline are complete',async()=>{
 const r=await call();assert.equal(r.ok,undefined);assert.equal(r.event_count,11);assert.match(r.reply,/총 440ml/);
 const clocks=r.timeline_lines.map(x=>x.slice(0,5));assert.deepEqual(clocks,[...clocks].sort());
 assert.match(r.timeline_lines.join('\n'),/전날부터 밤잠 이어짐/);assert.match(r.timeline_lines.join('\n'),/실제 투약 처방약/);assert.match(r.timeline_lines.join('\n'),/메모 · 기분 좋음/);assert.match(r.timeline_lines.join('\n'),/낮잠 기상/);
 assert.equal(r.timeline_lines.filter(x=>x.includes('수유')).length,4);
 const only=await call({name:'별이'});assert.match(only.reply,/총 350ml/);assert.ok(only.timeline_lines.every(x=>!x.includes('둘째')));
});
test('empty day, unknown name and invalid date return clear results without changing observations',async()=>{
 const before=(await q('select count(*)::int n from public.daddy_bob_jooseyo_feedings'))[0].n;
 assert.equal((await call({report_date:'2026-10-01'})).event_count,0);
 assert.match((await call({name:'없는아이'})).reply,/이름을 찾지/);
 assert.equal((await call({report_date:'2026-02-30'})).ok,false);
 assert.equal((await q('select count(*)::int n from public.daddy_bob_jooseyo_feedings'))[0].n,before);
});
test('timeline has no last-ten limit',async()=>{
 await q("insert into public.daddy_bob_jooseyo_feedings(child_id,amount_ml,fed_at) select $1,10,'2026-11-24T10:00:00+09:00'::timestamptz+g*interval '1 minute' from generate_series(1,150) g",[child]);
 assert.equal((await call({report_date:'2026-11-24'})).timeline_lines.length,150);
});
const w=JSON.parse(fs.readFileSync('n8n/daddy-bob-jooseyo-v8.json','utf8'));
const code=name=>w.nodes.find(n=>n.name===name).parameters.jsCode;
const context={children:[{name:'별이'}],recent:[],now_kst:'2026-11-26T00:30:00+09:00'};
const quick=(text,c=context)=>new Function('$json','$',code('Resolve short replies'))(c,()=>({item:{json:{raw_text:text,received_at_kst:context.now_kst,args:{update_id:'test'}}}}))[0].json;
test('quick query handles today typo, rest and normal model routing without unconditional error return',()=>{
 for(const text of ['오늘 하루 기록을 보여줘','어늘 하루 기록 보여줘','/timeline']){const r=quick(text);assert.equal(r.action,'daily_timeline');assert.equal(r.args.report_date,'2026-11-26');assert.equal(r.ready,true);}
 assert.equal(quick('/rest 별이').action,'rest_history');assert.equal(quick('고맙다').ready,false);
 assert.equal(quick('고맙다',{}).action,'chat');
});
test('Telegram pagination retains all records and respects UTF16 message limit with emoji',()=>{
 const lines=Array.from({length:80},(_,i)=>`${i}  ${'🍼'.repeat(900)}`);
 const pages=new Function('$json',code('Format response'))({chat_id:chat,reply:'아버님, 하루 기록입니다.',timeline_lines:lines});
 assert.ok(pages.length>1);for(const p of pages){assert.ok(p.json.reply.length<4096);assert.ok(p.json.reply.isWellFormed());}
 const content=pages.map(p=>p.json.reply.split('\n\n').slice(1).join('\n\n')).join('\n');
 for(const line of lines)assert.ok(content.includes(line));
});
test('special event is confirmed before saving and appears at actual Korean time in full-day report',async()=>{
 const rpc=async(action,args)=>(await q('select public.daddy_bob_jooseyo_bot_v8($1,$2,$3::jsonb) r',[chat,action,JSON.stringify(args)]))[0].r;
 const before=(await q('select count(*)::int n from public.daddy_bob_jooseyo_health'))[0].n;
 const preview=await rpc('health',{name:'별이',health_kind:'note',note:'[병원진료] 병원에서 감기 진료를 받음',time:'2026-11-23T13:00:00+09:00'});
 assert.match(preview.reply,/기록할까요|저장할까요|남겨둘까/);assert.equal((await q('select count(*)::int n from public.daddy_bob_jooseyo_health'))[0].n,before);
 const pending=(await q('select state from public.daddy_bob_jooseyo_sessions where chat_id=$1',[chat]))[0].state;
 await rpc('decision',{decision:true,expected_token:pending.token});
 const report=await call({report_date:'2026-11-23'});assert.equal(report.event_count,1);assert.match(report.timeline_lines[0],/^13:00.*\[병원진료\].*감기 진료/);
});
test('history header sums all Korean-day feeds rather than latest ten, includes personal threshold and keeps UUIDs',async()=>{
 const day=(await q("select (now() at time zone 'Asia/Seoul')::date::text d"))[0].d;
 await q("insert into public.daddy_bob_jooseyo_feedings(child_id,amount_ml,fed_at) select $1,80,($2||'T00:00:00+09:00')::timestamptz+g*interval '1 minute' from generate_series(1,12) g",[other,day]);
 const history=async()=>(await q("select public.daddy_bob_jooseyo_bot_v8($1,'history',$2::jsonb) r",[chat,JSON.stringify({name:'둘째'})]))[0].r;
 const expected=Number((await q("select sum(amount_ml) total from public.daddy_bob_jooseyo_feedings where child_id=$1 and (fed_at at time zone 'Asia/Seoul')::date=$2::date",[other,day]))[0].total);
 const r=await history();assert.equal(r.today_total_ml,expected);assert.ok(r.reply.startsWith('오늘 총 수유량: '+expected+'ml'));assert.match(r.reply,/[a-f0-9]{8}-[a-f0-9-]{27,}/);
 assert.match(r.reply,expected<1000?/남은 양/:/초과했습니다/);
 await q("insert into public.daddy_bob_jooseyo_feedings(child_id,amount_ml,fed_at) values($1,200,($2||'T01:00:00+09:00')::timestamptz)",[other,day]);
 assert.match((await history()).reply,/초과했습니다/);
});
