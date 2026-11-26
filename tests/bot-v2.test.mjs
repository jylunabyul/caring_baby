import {test,before,after} from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';
import {PGlite} from '@electric-sql/pglite';
const parse=new Function('$json',fs.readFileSync('scripts/bot-v2-parse.js','utf8'));
const chat='9114513581';
const incoming=(text,id=1,owner=chat)=>({update_id:id,message:{text,chat:{id:Number(owner),type:'private'},from:{id:Number(owner)}}});
let db,seq=100;
const scalar=async(sql,params=[]) => (await db.query(sql,params)).rows[0];
const call=async(action,args={},id=String(seq++))=>(await scalar('select public.daddy_bob_jooseyo_bot($1,$2,$3::jsonb) as result',[chat,action,JSON.stringify({...args,...(id==null?{}:{update_id:id})})])).result;
const confirm=async r=>call('confirm',{token:r.buttons[0].data.split(':')[1]});
let child;
before(async()=>{
 db=new PGlite();
 await db.exec(`create role anon; create role authenticated; create role service_role; create schema auth; create table auth.users(id uuid primary key); create function auth.uid() returns uuid language sql as $$select null::uuid$$; create function auth.role() returns text language sql as $$select current_setting('request.jwt.claim.role',true)$$; select set_config('request.jwt.claim.role','service_role',false); create table public.existing_app(id int primary key, note text); insert into public.existing_app values(1,'keep me');`);
 for(const f of ['daddy_bob_jooseyo.sql','daddy_bob_jooseyo_telegram_only.sql']) await db.exec(fs.readFileSync('supabase/'+f,'utf8'));
 child=(await scalar(`insert into public.daddy_bob_jooseyo_children(name,date_of_birth,telegram_chat_id) values('별이',current_date-100,$1) returning id`,[chat])).id;
 await db.query('insert into public.daddy_bob_jooseyo_feedings(child_id,amount_ml) values($1,120)',[child]);
 const migration=fs.readFileSync('supabase/daddy_bob_jooseyo_v2.sql','utf8');
 await db.exec(migration);
 await db.exec(migration); // migration is repeatable without destroying rows
});
after(async()=>db?.close());

test('parser accepts owner only, handles buttons, multiple children, edit timestamps',()=>{
 assert.equal(parse(incoming('/feed 별이 120 150'))[0].json.args.prepared,150);
 assert.equal(parse(incoming('/feed 별이 120'))[0].json.args.prepared,120);
 assert.equal(parse(incoming('/feed 별이 120',1,'42')).length,0);
 const group=incoming('/children');group.message.chat.type='group';assert.equal(parse(group).length,0);
 const forged=incoming('/children');forged.message.from.id=42;assert.equal(parse(forged).length,0);
 const cb={update_id:8,callback_query:{id:'cb',from:{id:Number(chat)},message:{chat:{id:Number(chat),type:'private'}},data:'fed:00000000-0000-0000-0000-000000000001'}};
 assert.equal(parse(cb)[0].json.action,'fed');
 assert.equal(parse(incoming('/feed 첫째 별이 120 150'))[0].json.args.name,'첫째 별이');
 assert.equal(parse(incoming('/stock 별이 제품 700 5 40 2 3 2'))[0].json.action,'stock');
 assert.equal(parse(incoming('/edit 00000000-0000-0000-0000-000000000001 110 150 2026-01-01T19:23:00+09:00'))[0].json.args.time,'2026-01-01T19:23:00+09:00');
});
test('/help and /start expose all commands and fit in one Telegram message',async()=>{
 for(const command of ['/help','/start']){
  const normalized=parse(incoming(command,seq++))[0].json;
  assert.equal(normalized.action,'help');
  const response=await call(normalized.action,normalized.args);
  for(const name of ['/feed','/history','/edit','/delete','/children','/childadd','/growth','/status','/stock','/reset','/childdelete','/cancel','/help']) assert(response.reply.includes(name));
  assert(response.reply.includes('UUID는 /history'));
  assert(response.reply.includes('실제 제품 라벨'));
  assert(response.reply.length<4096);
 }
});
test('upgrade preserves existing records and unrelated objects; RLS permissions remain restricted',async()=>{
 assert.equal((await scalar('select amount_ml from public.daddy_bob_jooseyo_feedings limit 1')).amount_ml,120);
 assert.equal((await scalar('select note from public.existing_app')).note,'keep me');
 const rows=(await db.query(`select c.relname,c.relrowsecurity,has_table_privilege('authenticated',c.oid,'SELECT') as can_read from pg_class c join pg_namespace n on n.oid=c.relnamespace where n.nspname='public' and c.relkind='r' and starts_with(c.relname::text,'daddy_bob_jooseyo_')`)).rows;
 assert.equal(rows.length,6);
 for(const r of rows){assert.equal(r.relrowsecurity,true);assert.equal(r.can_read,false);}
});
test('RPC denies wrong identity and non-service calls',async()=>{
 await assert.rejects(db.query(`select public.daddy_bob_jooseyo_bot('42','children','{}')`),/Not authorized/);
 await db.exec("select set_config('request.jwt.claim.role','authenticated',false)");
 await assert.rejects(call('children'),/Not authorized/);
 await db.exec("select set_config('request.jwt.claim.role','service_role',false)");
});
test('confirmation required; duplicate updates and consumed buttons never insert twice',async()=>{
 const before=(await scalar('select count(*)::int as n from public.daddy_bob_jooseyo_feedings')).n;
 const pending=await call('feed',{name:'별이',amount:100,prepared:150},'feed-1');
 assert.equal((await scalar('select count(*)::int as n from public.daddy_bob_jooseyo_feedings')).n,before);
 assert.deepEqual(await call('feed',{name:'별이',amount:100,prepared:150},'feed-1'),pending);
 const token=pending.buttons[0].data.split(':')[1];
 const saved=await call('confirm',{token},'confirm-1');
 assert.match(saved.reply,/저장 완료/);
 assert.deepEqual(await call('confirm',{token},'confirm-1'),saved);
 assert.match((await call('confirm',{token})).reply,/만료/);
 assert.equal((await scalar('select count(*)::int as n from public.daddy_bob_jooseyo_feedings')).n,before+1);
});
test('expired, superseded and cancelled confirmation tokens do not mutate data',async()=>{
 const p=await call('feed',{name:'별이',amount:90});
 await db.exec("update public.daddy_bob_jooseyo_sessions set expires_at=now()-interval '1 minute'");
 assert.match((await confirm(p)).reply,/만료/);
 const p2=await call('feed',{name:'별이',amount:80});
 await call('cancel');assert.match((await confirm(p2)).reply,/만료/);
 const p3=await call('feed',{name:'별이',amount:70});await call('feed',{name:'별이',amount:60});
 assert.match((await confirm(p3)).reply,/만료/);
});
test('stock uses powder grams and label yield; prepared amount deducted, edits/deletions refunded',async()=>{
 const setup=await call('stock',{name:'별이',product:'테스트제품',grams:700,scoop_g:5,scoop_ml:40,tins:2,lead:3,buffer:2});
 await confirm(setup);
 const stock=async()=>(await scalar('select stock_ml_equivalent as n from public.daddy_bob_jooseyo_formula_inventory where child_id=$1',[child])).n;
 assert.equal(await stock(),11200);
 const saved=await confirm(await call('feed',{name:'별이',amount:100,prepared:150}));
 const id=saved.reply.split('기록 ID: ')[1];assert.equal(await stock(),11050);
 await confirm(await call('edit',{feed_id:id,amount:110,prepared:200,time:'2026-01-01T19:23:00+09:00'}));assert.equal(await stock(),11000);
 assert.equal((await scalar('select amount_ml from public.daddy_bob_jooseyo_feedings where id=$1',[id])).amount_ml,110);
 await confirm(await call('delete',{feed_id:id}));assert.equal(await stock(),11200);
 const cancelled=await call('stock',{name:'별이',product:'테스트제품',grams:700,scoop_g:5,scoop_ml:40,tins:1,lead:3,buffer:2});
 await call('cancel');assert.match((await confirm(cancelled)).reply,/만료/);assert.equal(await stock(),11200);
});
test('invalid consumption/negative stock inputs fail without mutation',async()=>{
 await assert.rejects(call('feed',{name:'별이',amount:150,prepared:100}),/Invalid/);
 const setup=await call('stock',{name:'별이',product:'bad',grams:-1,scoop_g:5,scoop_ml:40,tins:1,lead:3,buffer:2});
 await assert.rejects(confirm(setup),/Invalid stock/);
 const old=(await scalar('select stock_ml_equivalent as n from public.daddy_bob_jooseyo_formula_inventory where child_id=$1',[child])).n;
 await db.query('update public.daddy_bob_jooseyo_formula_inventory set stock_ml_equivalent=10 where child_id=$1',[child]);
 const shortage=await call('feed',{name:'별이',amount:100,prepared:150});
 await assert.rejects(confirm(shortage),/Insufficient tracked stock/);
 assert.equal((await scalar('select stock_ml_equivalent as n from public.daddy_bob_jooseyo_formula_inventory where child_id=$1',[child])).n,10);
 await db.query('update public.daddy_bob_jooseyo_formula_inventory set stock_ml_equivalent=$1 where child_id=$2',[old,child]);
 const pending=await call('feed',{name:'별이',amount:1000,prepared:2000});
 const confirmed=await confirm(pending);assert.match(confirmed.reply,/저장 완료/);
});
test('growth/status and multiple children; reset preserves profile and growth',async()=>{
 await call('childadd',{name:'둘째',dob:'2026-01-01'});
 assert.match((await call('children')).reply,/별이.*둘째/);
 await call('growth',{name:'별이',weight:6.5,height:62});
 assert.match((await call('status',{name:'별이'})).reply,/62/);
 assert.match((await call('status',{name:'별이'})).reply,/975~1300/);
 await confirm(await call('reset',{name:'별이'}));
 assert.equal((await scalar('select count(*)::int as n from public.daddy_bob_jooseyo_feedings where child_id=$1',[child])).n,0);
 assert.equal((await scalar('select count(*)::int as n from public.daddy_bob_jooseyo_growth where child_id=$1',[child])).n,1);
 assert.match((await call('children')).reply,/별이/);
});
test('reminders include buttons, snooze does not fabricate a feed, mark throttles; stock alert is independent',async()=>{
 await confirm(await call('feed',{name:'별이',amount:120,prepared:150}));
 await db.query("update public.daddy_bob_jooseyo_feedings set fed_at=now()-interval '4 hours' where child_id=$1",[child]);
 let due=(await call('due',{},null)).messages;
 assert(due.some(m=>m.kind==='feeding'&&m.buttons[0].data==='fed:'+child));
 await call('mark',{kind:'feeding',child_id:child},null);
 assert(!(await call('due',{},null)).messages.some(m=>m.kind==='feeding'));
 const count=(await scalar('select count(*)::int as n from public.daddy_bob_jooseyo_feedings')).n;
 await call('later',{child_id:child});
 assert.equal((await scalar('select count(*)::int as n from public.daddy_bob_jooseyo_feedings')).n,count);
 await call('fed',{child_id:child});
 const prompt=await call('amount',{amount:80,prepared:100});assert.match(prompt.reply,/80ml/);
 await confirm(prompt);
 await db.query('update public.daddy_bob_jooseyo_formula_inventory set stock_ml_equivalent=100 where child_id=$1',[child]);
 due=(await call('due',{},null)).messages;
 assert(due.some(m=>m.kind==='stock'));
 await call('mark',{kind:'stock',child_id:child},null);
 assert(!(await call('due',{},null)).messages.some(m=>m.kind==='stock'));
});
test('full child deletion cascades only its own data; confirmation required',async()=>{
 const p=await call('childdelete',{name:'별이'});
 assert.equal((await scalar('select count(*)::int as n from public.daddy_bob_jooseyo_children where id=$1',[child])).n,1);
 await confirm(p);
 for(const t of ['feedings','growth','formula_inventory'])assert.equal((await scalar(`select count(*)::int as n from public.daddy_bob_jooseyo_${t} where child_id=$1`,[child])).n,0);
 assert.match((await call('children')).reply,/둘째/);
 assert.equal((await scalar("select count(*)::int as n from public.daddy_bob_jooseyo_updates where response::text like '%별이%'")).n,0);
 assert.equal((await scalar('select note from public.existing_app')).note,'keep me');
});
test('workflow has safe schedule, credentials only, callback ACK and mark-after-send; keyboard expressions render',()=>{
 const w=JSON.parse(fs.readFileSync('n8n/daddy-bob-jooseyo-v2.json'));
 assert.equal(w.active,false);assert.equal(w.settings.timezone,'Asia/Seoul');
 assert.equal(w.nodes.find(n=>n.name==='Normalize update').parameters.jsCode,fs.readFileSync('scripts/bot-v2-parse.js','utf8'));
 assert(!JSON.stringify(w).includes('$env'));
 assert(!JSON.stringify(w).includes('service_role'));
 assert.equal(w.connections['Send reminder'].main[0][0].node,'Mark delivered');
 assert.equal(w.connections['Loop reminders'].main[1][0].node,'Send reminder');
 const n=w.nodes.find(n=>n.name==='Send reply');
 const render=(expr,json)=>new Function('$json','return ('+expr.slice(3,-2)+');')(json);
 const sample={chat_id:chat,reply:'<제품 & 테스트>',buttons:[{text:'확인',data:'confirm:'+child}]};
 assert.equal(render(n.parameters.text,sample),'&lt;제품 &amp; 테스트&gt;');
 assert.equal(render(n.parameters.inlineKeyboard.rows,sample)[0].row.buttons[0].additionalFields.callback_data,'confirm:'+child);
 assert.deepEqual(render(n.parameters.inlineKeyboard.rows,{buttons:[]}),[]);
});
