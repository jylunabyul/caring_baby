import fs from 'node:fs';
const w=JSON.parse(fs.readFileSync('n8n/daddy-bob-jooseyo-v6-kst.json','utf8'));
w.name='Daddy Bob Jooseyo - V7 sleep and care stop';
const get=name=>w.nodes.find(n=>n.name===name);
for(const n of w.nodes)if(n.type==='n8n-nodes-base.httpRequest'&&n.parameters.url?.endsWith('/daddy_bob_jooseyo_bot_v6'))n.parameters.url=n.parameters.url.replace(/_v6$/,'_v7');
const quick=get('Resolve short replies');
const insertionAt=quick.parameters.jsCode.lastIndexOf('return [{json:');
quick.parameters.jsCode=quick.parameters.jsCode.slice(0,insertionAt)+ "if(!action && (m=text.match(/^\\/rest\\s+(.+)$/i))){action='rest_history';args.name=m[1];}\nreturn [{json:"+quick.parameters.jsCode.slice(insertionAt+'return [{json:'.length);
const request=get('Build Gemini request');
const fields=`
const restActions=['stop_health_alerts','rest_start','rest_end','rest_record','rest_history'];
fields.action.enum.push(...restActions);
const restFields={rest_kind:{type:['string','null']},started_at:{type:['string','null']},ended_at:{type:['string','null']},all_children:{type:['boolean','null']},stop_kinds:{type:['array','null'],items:{type:'STRING',enum:['temperature','medicine']}}};
Object.assign(fields,restFields);
for(const [key,field] of Object.entries(restFields)){
 const types=field.type;const prop={type:types.find(t=>t!=='null').toUpperCase(),nullable:true};if(field.items)prop.items=field.items;
 fields.operations.items.properties[key]=prop;
}
fields.operations.items.properties.action.enum.push(...restActions);
`;
request.parameters.jsCode=request.parameters.jsCode.replace('const system=',fields+'\nconst system=');
request.parameters.jsCode=request.parameters.jsCode.replace('fixed_schedules:context.fixed_schedules||[],pending,now_kst:', 'fixed_schedules:context.fixed_schedules||[],rest_recent:context.rest_recent||[],pending,now_kst:');
request.parameters.jsCode=request.parameters.jsCode.replace('const pending =',"context.rest_recent=contextRows(context.rest_recent,['started_at','ended_at']);\nconst pending =");
const rules=`\nStop care alarms and sleep records:
'약이랑 체온은 그만 기록해도 돼', '약 체온 알림 그만', '이제 체온 확인 중지' mean stop_health_alerts, NOT deletion of past health data. stop_kinds=['medicine','temperature'] when both, otherwise only requested kind. This stops interval care plans AND fixed medication time slots. An explicit specific drug can set medicine; generic 약/투약 means all drugs for the selected child. If only one child exists infer that child; with multiple children ask whose unless the user explicitly says all children (all_children=true). Never treat '그만 기록' as childdelete/reset.
rest_start: actual falling asleep, name,rest_kind=nap|night,time(optional current receive time),note(optional). Use nap only when user says 낮잠, night when 밤잠/밤에 잠/야간 수면. If kind is unclear ask. rest_end: actual waking up, name,time; closes the single open sleep session, no need to guess nap/night. rest_record: completed historical interval; name,rest_kind,started_at,ended_at,note. Rest planned for the future is not an actual sleep record; clarify. Crossing midnight needs the correct Korean dates. Bare hour ambiguity follows the Korean time rules. rest_history lists sleep history/duration. Keep old action sleep for notification quiet-hours settings; it is NOT an actual sleep log.
All started_at/ended_at/time values are Korean civil YYYY-MM-DDTHH:mm:ss without Z/offset, normalized by trusted code. Sleeping does not automatically pause medication/temperature alerts or edit feeding quiet settings. The explicit stop action stops alerts only; manual health logging remains possible. Compound sleep and other requests use batch operations.
`;
request.parameters.jsCode=request.parameters.jsCode.replace('text:system +','text:system + '+JSON.stringify(rules)+' +');
const validator=get('Validate Gemini intent');
const marker='// Model extracts; trusted validators authorize.';
const index=validator.parameters.jsCode.indexOf(marker);if(index<0)throw new Error('Expected V6 batch source');
const single=validator.parameters.jsCode.slice(0,index);
let batch=validator.parameters.jsCode.slice(index).replaceAll('validateOne(', 'validateV7(');
batch=batch.replace("'healthhistory','care_list']);", "'healthhistory','care_list','stop_health_alerts','rest_start','rest_end','rest_record','rest_history']);");
validator.parameters.jsCode=single+'\nconst validateV7=function($json,$){\n'+fs.readFileSync('scripts/bot-v7-validate.js','utf8')+'\n};\n'+batch;
const normalize=get('Normalize Korean input times');normalize.parameters.jsCode=normalize.parameters.jsCode.replace("['time','scheduled_at','end_at']", "['time','scheduled_at','end_at','started_at','ended_at']");
const native=get('Google Gemini - Message a model');native.parameters.options.systemMessage=native.parameters.options.systemMessage.replaceAll('time,scheduled_at,end_at','time,scheduled_at,end_at,started_at,ended_at');
fs.writeFileSync('n8n/daddy-bob-jooseyo-v7.json',JSON.stringify(w,null,2)+'\n');
console.log('Built V7: explicitly stop care alerts, preserve logs, record naps/night sleep in Korean time.');
