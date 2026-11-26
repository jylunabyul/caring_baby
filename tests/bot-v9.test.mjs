import {test} from 'node:test';import assert from 'node:assert/strict';import fs from 'node:fs';
const w=JSON.parse(fs.readFileSync('n8n/daddy-bob-jooseyo-v9.json','utf8'));const get=name=>w.nodes.find(n=>n.name===name);
test('daily report runs at 21 Seoul independently of feeding quiet hours',()=>{
 assert.equal(w.settings.timezone,'Asia/Seoul');assert.deepEqual(get('Daily report at 21 Seoul').parameters.rule.interval,[{field:'cronExpression',expression:'0 21 * * *'}]);
 const path=['Daily report at 21 Seoul','Prepare daily report','Get daily report','Format daily report','Send daily report'];
 for(let i=0;i<path.length-1;i++)assert.equal(w.connections[path[i]].main[0][0].node,path[i+1]);
 assert.match(get('Get daily report').parameters.url,/_v8$/);assert.equal(get('Send daily report').parameters.replyMarkup,'none');
});
test('scheduled UTC timestamps choose Korean calendar date and fixed owner scope without stale cached results',()=>{
 const run=new Function('$json',get('Prepare daily report').parameters.jsCode);
 const r=run({timestamp:'2026-11-26T15:05:00Z'})[0].json;
 assert.equal(r.chat_id,'9114513581');assert.equal(r.action,'daily_timeline');assert.deepEqual(r.args,{report_date:'2026-11-27'});
 assert.equal(run({timestamp:'2026-11-26T12:00:00Z'})[0].json.args.report_date,'2026-11-26');
 assert.throws(()=>run({timestamp:'invalid'}),/실행 시각/);
});
test('scheduled report includes all pages and sends a response even for an empty day',()=>{
 const run=new Function('$json',get('Format daily report').parameters.jsCode);
 const empty=run({chat_id:'9114513581',reply:'기록이 없습니다.',timeline_lines:[]});assert.equal(empty.length,1);assert.match(empty[0].json.reply,/오후 9시 정기 리포트/);
 const pages=run({chat_id:'9114513581',reply:'하루 기록',timeline_lines:Array.from({length:200},(_,i)=>`${i} 수유 기록 ${'a'.repeat(50)}`)});
 assert.ok(pages.length>1);assert.ok(pages.every(p=>p.json.chat_id==='9114513581'&&p.json.reply.length<4096));assert.match(pages.at(-1).json.reply,/199 수유 기록/);
});
