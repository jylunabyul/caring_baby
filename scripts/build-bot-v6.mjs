import fs from 'node:fs';
const w=JSON.parse(fs.readFileSync('n8n/daddy-bob-jooseyo-v5-conversation.json','utf8'));
w.name='Daddy Bob Jooseyo - V6 multi-request assistant';
const get=name=>w.nodes.find(n=>n.name===name);
for(const node of w.nodes)if(node.type==='n8n-nodes-base.httpRequest'&&node.parameters.url?.endsWith('/daddy_bob_jooseyo_bot_v5'))node.parameters.url=node.parameters.url.replace(/_v5$/,'_v6');
const normalize=get('Normalize update');normalize.parameters.jsCode=normalize.parameters.jsCode.replace("if ((m=data.match(/^care_",`if ((m=data.match(/^fixed_(stop|later):([0-9a-f-]{36})$/i))) {
 action=m[1]==='stop'?'medicine_cancel':'medicine_snooze';args={schedule_id:m[2],...(m[1]==='later'?{minutes:30}:{})};
} else if ((m=data.match(/^care_`);
const req=get('Build Gemini request');
const fields=`
fields.action.enum.push('batch','medicine_schedule','medicine_cancel','medicine_snooze');
for(const key of ['scheduled_at','schedule_id'])fields[key]={type:['string','null']};
fields.repeat_daily={type:['boolean','null']};
const batchActions=['feed','edit','delete','health','care_setup','medicine_schedule','growth','stock','sleep','morning','childadd','reset','childdelete','care_cancel','care_snooze','medicine_cancel','medicine_snooze','children','history','status','healthhistory','care_list'];
const nested=Object.fromEntries(Object.entries(fields).map(([name,field])=>{
 const types=Array.isArray(field.type)?field.type:[field.type];
 const prop={type:types.find(t=>t!=='null').toUpperCase()};if(types.includes('null'))prop.nullable=true;if(field.enum)prop.enum=field.enum;return [name,prop];
}));
nested.action={type:'STRING',enum:batchActions};
fields.operations={type:['array','null'],items:{type:'OBJECT',properties:nested}};
`;
req.parameters.jsCode=req.parameters.jsCode.replace('const system=',fields+'\nconst system=');
req.parameters.jsCode=req.parameters.jsCode.replace('if(field.enum)value.enum=field.enum;','if(field.enum)value.enum=field.enum;\n if(field.items)value.items=field.items;');
req.parameters.jsCode=req.parameters.jsCode.replace('care_plans:context.care_plans||[],pending,now_kst:', 'care_plans:context.care_plans||[],fixed_schedules:context.fixed_schedules||[],pending,now_kst:');
req.parameters.jsCode=req.parameters.jsCode.replace("if (pending?.args) { delete pending.args.confirmed; delete pending.args.update_id; }", "if (pending?.args) { delete pending.args.confirmed; delete pending.args.update_id; }\nif(pending && ['batch','batch_draft'].includes(context.pending.action)){pending.operations=context.pending.operations;pending.question=context.pending.question;}");
const rules=`\nMULTI-REQUEST MESSAGES:
When a user message contains multiple records, changes, or reminder requests, use action=batch and operations containing every requested item (max 12). Each item is a FLAT intent object with its action and fields, not a string. Do not collapse a compound message into only one intent. Each action must follow the same per-action rules. Include confidence per item, plus question only for its missing/ambiguous facts. Preserve all explicit numbers/time units: 1시간마다 = interval_minutes 60. Never ask for an interval that was already supplied.
One actual reading plus its repeat request is a care_setup with record_new=true, not also a duplicate health event. A FUTURE instruction to give medicine is medicine_schedule, NOT a past health administration and NOT care_setup with a fake initial administration. For multiple clock times use one medicine_schedule per exact time. medicine_schedule fields: name,medicine,dose,dose_unit,scheduled_at (future ISO +09:00),repeat_daily(boolean),end_at(optional). repeat_daily=true only when explicitly daily/repeating; otherwise false. A time range such as 12~1시 or 5~6시 is ambiguous: leave scheduled_at null and ask which exact time; do NOT silently pick the start/end/midpoint. A generic class such as 감기약 without an established specific medicine label needs its actual medicine name clarified. Do not assume administration safety from the stated amount. Unknown nighttime preference for a care_setup must be asked; batch requires overnight boolean.
Return partially extracted operations EVEN IF some items are incomplete. Put only necessary questions in question, mention the facts already understood in answer without claiming saved. The server stores a draft, not partial clinical records. context.pending.action=batch_draft contains prior operations/question; merge follow-up answers into the complete operation list, retain original measurement time/amount and all other requests, and do not invent missing facts.
medicine_cancel and medicine_snooze need schedule_id from fixed_schedules. Do not confuse fixed_schedules with interval care_plans; existing care_cancel/care_snooze uses plan_id. All medication/frequency values are user instructions, not model recommendations. Ambiguous intent remains a targeted question, not a guessed clinical update.
Example: 별이 오늘부터 1시간마다 체온 확인. 현재 10:30 36.9도. 감기약 점심12~1,저녁5~6,22시에10ml.
Extract care_setup temperature=36.9 interval_minutes=60 time=today10:30 record_new=true and three medicine_schedule items dose=10 dose_unit=ml. Ask for exact medicine, two time ranges, and nighttime inclusion. Do NOT answer by asking how many hours: 60 minutes is explicit. No partial saves before complete confirmation.
`;
req.parameters.jsCode=req.parameters.jsCode.replace('text:system +','text:system + '+JSON.stringify(rules)+' +');
const original=get('Validate Gemini intent').parameters.jsCode;
const batchSource=fs.readFileSync('scripts/bot-v6-batch-validate.js','utf8');
get('Validate Gemini intent').parameters.jsCode='const validateOne = function($json,$){\n'+original+'\n};\n'+batchSource;
const gemini=get('Google Gemini - Message a model');gemini.parameters.options.maxOutputTokens=6144;
const quick=get('Resolve short replies');
quick.parameters.jsCode=quick.parameters.jsCode.replace("if(!Array.isArray(c.children)||!Array.isArray(c.recent))throw new Error('V4 context is unavailable; check V4 SQL');", "if(!Array.isArray(c.children)||!Array.isArray(c.recent))return [{json:{...n,ready:true,action:'chat',reply:'아버님, 설정 데이터를 불러오지 못했습니다. 아직 기록을 변경하지 않았습니다. Supabase 연결과 V6 SQL 적용 상태를 확인해 주세요.',buttons:[]}}];");
get('Get chat context').onError='continueRegularOutput';
w.connections['Ready without model?'].main[0]=[{node:'Is conversation?',type:'main',index:0}];
const fmt=get('Format response');fmt.parameters.jsCode=`if ($json.reply && typeof $json.reply==='string')return [{json:{...$json,silent:false}}];
return [{json:{chat_id:'9114513581',reply:'아버님, 서버 응답을 확인하지 못해 저장 여부가 불확실합니다. 복구됐다고 단정할 수 없습니다. /history, /health 또는 /care로 확인한 뒤 다시 말씀해 주세요.',buttons:[]}}];`;
for(const name of ['Build Gemini request','Validate Gemini intent','Decode Gemini response']){
 const node=get(name);node.onError='continueErrorOutput';
 w.connections[name].main[1]=[{node:'Format response',type:'main',index:0}];
}
const mark=get('Mark delivered');mark.parameters.jsonBody=mark.parameters.jsonBody.replace("occurrence_due:$('Loop reminders').item.json.occurrence_due", "occurrence_due:$('Loop reminders').item.json.occurrence_due,schedule_id:$('Loop reminders').item.json.schedule_id");
// Allow only the owner's private chat AND sender. Denial exits before any context/model/DB node.
w.nodes.push({id:'access-check',name:'Check private owner',type:'n8n-nodes-base.code',typeVersion:2,position:[-450,0],parameters:{jsCode:`const update=$json;const cb=update.callback_query;const msg=cb?.message||update.message;const sender=cb?.from||msg?.from;
if(!msg?.chat?.id)return [];
const allowed=msg.chat.type==='private'&&String(msg.chat.id)==='9114513581'&&String(sender?.id)==='9114513581';
return [{json:{...update,owner_allowed:allowed,denied_chat_id:String(msg.chat.id)}}];`}});
w.nodes.push({id:'owner-if',name:'Owner allowed?',type:'n8n-nodes-base.if',typeVersion:2.2,position:[-220,0],parameters:{conditions:{options:{typeValidation:'strict',version:2},conditions:[{id:'owner',leftValue:'={{ $json.owner_allowed }}',rightValue:true,operator:{type:'boolean',operation:'equals'}}],combinator:'and'}}});
w.nodes.push({id:'access-denied',name:'Reply access denied',type:'n8n-nodes-base.telegram',typeVersion:1.2,position:[0,-250],parameters:{resource:'message',operation:'sendMessage',chatId:'={{ $json.denied_chat_id }}',text:'죄송합니다. 허용되지 않았습니다.',additionalFields:{appendAttribution:false}}});
w.connections['Telegram updates']={main:[[{node:'Check private owner',type:'main',index:0}]]};
w.connections['Check private owner']={main:[[{node:'Owner allowed?',type:'main',index:0}]]};
w.connections['Owner allowed?']={main:[[{node:'Normalize update',type:'main',index:0}],[{node:'Reply access denied',type:'main',index:0}]]};
w.active=false;
fs.writeFileSync('n8n/daddy-bob-jooseyo-v6.json',JSON.stringify(w,null,2)+'\n');
console.log('Built V6 multi-intent workflow with transactional batch confirmation and explicit user feedback.');
