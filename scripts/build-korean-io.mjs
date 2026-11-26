import fs from 'node:fs';
const w=JSON.parse(fs.readFileSync('n8n/daddy-bob-jooseyo-v6.json','utf8'));
w.name='Daddy Bob Jooseyo - V6 Korean time input and output';
const get=name=>w.nodes.find(n=>n.name===name);
const normalize=get('Normalize update');
normalize.parameters.jsCode=normalize.parameters.jsCode.replace('raw_text:text,callback_id:', "raw_text:text,received_at_kst:(!cb&&Number.isFinite(message.date)?new Date(message.date*1000+9*3600000).toISOString().replace('Z','+09:00'):null),callback_id:");
const request=get('Build Gemini request');
request.parameters.jsCode=request.parameters.jsCode.replace('const context = $json.context;', 'const context = {...$json.context,now_kst:normalized.received_at_kst || $json.context.now_kst};');
const instruction=`\nKOREAN TIME INPUT CONTRACT (overrides earlier ISO output directions):
All user-entered wall-clock times without an explicitly different zone mean Asia/Seoul, NEVER UTC. 오후 1시 means local 13:00; 오전 1시 means local 01:00. Bare 한 시/1시 without clear AM/PM/context must be clarified rather than guessed. Yesterday/today and relative times use the Telegram receive time in context.now_kst (Seoul calendar). Do not use the n8n server's date/timezone.
For the intent fields time,scheduled_at,end_at, output Korean CIVIL strings YYYY-MM-DDTHH:mm:ss, with NO Z, NO UTC conversion and NO offset; trusted code will append +09:00. Null when a time is truly unspecified. Already-local input must never be shifted by nine hours again. Default actual event '방금/지금' uses the receive time's Korean civil calendar, not a later confirmation time. Future reminder schedules remain distinct from actual past records. In conversation answers display Korean clock time with 오전/오후 or HH:mm, never raw UTC/ISO.
`;
request.parameters.jsCode=request.parameters.jsCode.replace('text:system +','text:system + '+JSON.stringify(instruction)+' +');
const native=get('Google Gemini - Message a model');
native.parameters.options.systemMessage=native.parameters.options.systemMessage.slice(0,-2)+' + '+JSON.stringify(instruction)+' }}';
// Context fed to the model also uses explicit Korean offsets for all known timestamp fields.
const convert=`
const asKst=value=>{if(typeof value!=='string'||!/^\\d{4}-\\d{2}-\\d{2}T/.test(value))return value;const n=Date.parse(value);return Number.isFinite(n)?new Date(n+9*3600000).toISOString().replace('Z','+09:00'):value;};
const contextRows=(rows,keys)=>(rows||[]).map(row=>({...row,...Object.fromEntries(keys.filter(k=>row[k]!=null).map(k=>[k,asKst(row[k])]))}));
context.recent=contextRows(context.recent,['fed_at']);context.health_recent=contextRows(context.health_recent,['occurred_at']);
context.care_plans=contextRows(context.care_plans,['anchor_at','next_due_at','end_at']);context.fixed_schedules=contextRows(context.fixed_schedules,['next_due_at','end_at']);
`;
request.parameters.jsCode=request.parameters.jsCode.replace('const pending =',convert+'\nconst pending =');
w.nodes.push({id:'korean-time-input',name:'Normalize Korean input times',type:'n8n-nodes-base.code',typeVersion:2,position:[1500,350],parameters:{jsCode:fs.readFileSync('scripts/bot-korean-time.js','utf8')},onError:'continueErrorOutput'});
w.connections['Decode Gemini response'].main[0]=[{node:'Normalize Korean input times',type:'main',index:0}];
w.connections['Normalize Korean input times']={main:[[{node:'Validate Gemini intent',type:'main',index:0}],[{node:'Format response',type:'main',index:0}]]};
fs.writeFileSync('n8n/daddy-bob-jooseyo-v6-kst.json',JSON.stringify(w,null,2)+'\n');
const v3=fs.readFileSync('supabase/daddy_bob_jooseyo_v3.sql','utf8');
let core=v3.slice(v3.indexOf('create or replace function public.daddy_bob_jooseyo_bot('),v3.lastIndexOf('commit;'));
core=core.replace("E'\\n기록 시각: '||(args->>'time')", "E'\\n기록 시각: '||public.daddy_bob_jooseyo_format_kst((args->>'time')::timestamptz)");
let sql=fs.readFileSync('supabase/daddy_bob_jooseyo_dual_timezone.sql','utf8');
const split=sql.lastIndexOf('commit;');
sql=sql.slice(0,split)+core+'\n'+sql.slice(split);
fs.writeFileSync('supabase/daddy_bob_jooseyo_korean_io.sql',sql);
console.log('Built Korean civil-time input normalization + dual-zone storage + single/batch Korean display.');
