import fs from 'node:fs';
const w=JSON.parse(fs.readFileSync('n8n/daddy-bob-jooseyo-v8.json','utf8'));
w.name='Daddy Bob Jooseyo - V9 daily 9pm report';
w.settings.timezone='Asia/Seoul';
const clone=(name,id,newName,position)=>{const n=structuredClone(w.nodes.find(n=>n.name===name));Object.assign(n,{id,name:newName,position});return n;};
const schedule=clone('Morning at 8 Seoul','daily-report-21','Daily report at 21 Seoul',[0,1100]);
schedule.parameters.rule.interval=[{field:'cronExpression',expression:'0 21 * * *'}];
const request={id:'daily-report-date',name:'Prepare daily report',type:'n8n-nodes-base.code',typeVersion:2,position:[240,1100],parameters:{jsCode:`// Schedule trigger timestamps may use UTC; select the report date in Korea.
const stamp=new Date($json.timestamp);
if(!Number.isFinite(stamp.getTime()))throw new Error('정기 리포트 실행 시각을 확인할 수 없습니다.');
const parts=new Intl.DateTimeFormat('en-US',{timeZone:'Asia/Seoul',year:'numeric',month:'2-digit',day:'2-digit'}).formatToParts(stamp);
const get=type=>parts.find(p=>p.type===type).value;
const date=get('year')+'-'+get('month')+'-'+get('day');
return [{json:{chat_id:'9114513581',action:'daily_timeline',args:{report_date:date}}}];`}};
const fetch=clone('Process command','daily-report-fetch','Get daily report',[480,1100]);
const format=clone('Format response','daily-report-format','Format daily report',[720,1100]);
format.parameters.jsCode=`if(typeof $json.reply==='string')$json.reply='오후 9시 정기 리포트 · 발송 시점까지 입력된 기록\\n'+$json.reply;\n`+format.parameters.jsCode;
const send=clone('Send reply','daily-report-send','Send daily report',[960,1100]);
// No buttons or user-input branches are involved in scheduled reports.
send.parameters.replyMarkup='none';delete send.parameters.inlineKeyboard;
w.nodes.push(schedule,request,fetch,format,send);
for(const [from,to]of [[schedule,request],[request,fetch],[fetch,format],[format,send]])w.connections[from.name]={main:[[{node:to.name,type:'main',index:0}]]};
fs.writeFileSync('n8n/daddy-bob-jooseyo-v9.json',JSON.stringify(w,null,2)+'\n');
console.log('Built V9: daily 21:00 Asia/Seoul full timeline report to owner. No additional SQL.');
