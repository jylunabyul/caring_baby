import fs from 'node:fs';
const w=JSON.parse(fs.readFileSync('n8n/daddy-bob-jooseyo-gemini-native.json','utf8'));
w.name='Daddy Bob Jooseyo - V4 daily care';
for(const n of w.nodes)if(n.type==='n8n-nodes-base.httpRequest' && n.parameters.url?.endsWith('/daddy_bob_jooseyo_bot'))n.parameters.url+='_v4';
const request=w.nodes.find(n=>n.name==='Build Gemini request');
const extraFields=`
fields.action.enum.push('health','healthhistory','morning');
for(const field of ['health_kind','medicine','dose_unit','note'])fields[field]={type:['string','null']};
for(const field of ['temperature','dose','plan_ml'])fields[field]={type:['number','null']};
`;
request.parameters.jsCode=request.parameters.jsCode.replace('const system=',extraFields+'\nconst system=');
const rules=`\nAdditional personal-bot actions:
health: record an observed event, NOT medical advice. name plus health_kind=temperature|medicine|note.
For temperature use temperature in Celsius. For medicine require exact medicine name, actual dose and dose_unit (ml,mg,g,방울,정,포). Do NOT guess any medication or dose from age/weight. If the user asks how much medicine to give, do not record administration; clarify that clinician/package instructions are needed. note records other observations in the user's own words (e.g. coughing, rash, spit-up), without inventing diagnosis. Missing fever measurement can be a note, not an invented temperature. time is explicit ISO with +09:00 only when the user specifies a time; otherwise null. healthhistory lists health notes for a child.
morning: enable/disable the user's morning notification plan; fields name,enabled,plan_ml. Default user-configured plan=200ml between 08:00 and 09:00 Seoul; this is a reminder, not medical advice.
If the user replies after a confirmation with a correction, extract a new proposed action; never confirm the old incorrect amount. Clear short yes/no are handled locally. Do not make the user repeat a recognized yes/no.
Clarifying questions address the user as 오빠, in warm, concise Korean mixing casual and polite endings, without claiming you are his spouse. Example: 오빠, 약 이름이랑 실제 먹인 양을 알려줘. Never flirt or joke about symptoms. Preserve clear clinical warnings and factual units.
`;
request.parameters.jsCode=request.parameters.jsCode.replace('text:system}', 'text:system + '+JSON.stringify(rules)+'}');
const validation=w.nodes.find(n=>n.name==='Validate Gemini intent');
const healthValidate=`
if (['health','healthhistory','morning'].includes(v.action)) {
 if(!name)return clarify('어느 아이 이야기야, 오빠? 이름을 같이 알려줘.');
 a.name=name.name;
 if(v.action==='health'){
  if(!['temperature','medicine','note'].includes(v.health_kind))return clarify('체온인지 투약인지, 어떤 특이사항인지 알려줘.');
  a.health_kind=v.health_kind;
  if(v.health_kind==='temperature'){
   if(!num('temperature',30,45))return clarify('오빠, 실제로 잰 체온을 도 단위로 알려줘.');
   a.temperature=v.temperature;
  }else if(v.health_kind==='medicine'){
   if(!string(v.medicine) || !num('dose',0.001,100000) || !['ml','mg','g','방울','정','포'].includes(v.dose_unit))return clarify('약 이름, 실제 투여량과 단위를 알려줘. 용량은 내가 정하지 않을게.');
   a.medicine=v.medicine;a.dose=v.dose;a.dose_unit=v.dose_unit;
  }else{
   if(!string(v.note,1500))return clarify('오빠, 남겨둘 특이사항을 말해줘.');a.note=v.note;
  }
  if(v.time!=null){
   if(typeof v.time!=='string'||!/^\\d{4}-\\d{2}-\\d{2}T\\d{2}:\\d{2}:\\d{2}(?:Z|[+-]\\d{2}:\\d{2})$/.test(v.time)||!Number.isFinite(Date.parse(v.time))||Date.parse(v.time)>Date.parse(c.now_kst))return clarify('오빠, 실제로 있었던 시각을 다시 알려줘. 미래 시각으로는 기록하지 않을게.');
   a.time=v.time;
  }
 }else if(v.action==='morning'){
  if(typeof v.enabled!=='boolean'||!num('plan_ml',1,1000,true))return clarify('오빠, 아침 알림을 켤지와 오빠가 정한 수유 계획량을 알려줘.');
  a.enabled=v.enabled;a.plan_ml=v.plan_ml;
 }
 return [{json:{...base,action:v.action,args:a}}];
}
`;
validation.parameters.jsCode=validation.parameters.jsCode.replace("if (['help','children','cancel']",healthValidate+"\nif (['help','children','cancel']");
w.nodes.push({id:'quick-reply',name:'Resolve short replies',type:'n8n-nodes-base.code',typeVersion:2,position:[800,300],parameters:{jsCode:fs.readFileSync('scripts/bot-v4-quick.js','utf8')}});
w.nodes.push({id:'quick-if',name:'Ready without model?',type:'n8n-nodes-base.if',typeVersion:2.2,position:[1000,300],parameters:{conditions:{options:{typeValidation:'strict',version:2},conditions:[{id:'ready',leftValue:'={{ $json.ready }}',rightValue:true,operator:{type:'boolean',operation:'equals'}}],combinator:'and'}}});
w.connections['Get chat context']={main:[[{node:'Resolve short replies',type:'main',index:0}]]};
w.connections['Resolve short replies']={main:[[{node:'Ready without model?',type:'main',index:0}]]};
w.connections['Ready without model?']={main:[[{node:'Process command',type:'main',index:0}],[{node:'Build Gemini request',type:'main',index:0}]]};
// Build Gemini request now receives the routed envelope, not bare context.
request.parameters.jsCode=request.parameters.jsCode.replace('const context = $json;', 'const context = $json.context;');
w.nodes.find(n=>n.name==='Format response').parameters.jsCode="if ($json.silent) return [];\n"+w.nodes.find(n=>n.name==='Format response').parameters.jsCode;
const mark=w.nodes.find(n=>n.name==='Mark delivered');
mark.parameters.jsonBody=mark.parameters.jsonBody.replace("kind:$('Loop reminders').item.json.kind", "kind:$('Loop reminders').item.json.kind,delivery_day:$('Loop reminders').item.json.delivery_day");
w.nodes.push({id:'morning-8am',name:'Morning at 8 Seoul',type:'n8n-nodes-base.scheduleTrigger',typeVersion:1.2,position:[0,700],parameters:{rule:{interval:[{field:'cronExpression',expression:'0 8 * * *'}]}}});
w.connections['Morning at 8 Seoul']={main:[[{node:'Get reminders',type:'main',index:0}]]};
const format=w.nodes.find(n=>n.name==='Format response');format.parameters.jsCode=format.parameters.jsCode.replace('처리하지 못했어요. 기록은 저장되지 않았을 수 있습니다. /history 아이이름으로 먼저 확인하고, 재고 입력·명령 형식 및 n8n 실행 오류를 확인해 주세요.','오빠, 처리 결과를 확인하지 못했어. 다시 입력하기 전에 /history 아이이름으로 저장됐는지 한 번만 확인해줘.');
w.nodes.find(n=>n.name==='Send reminder').notes='08:00 전용 실행 + 15분 간격 재시도. SQL에서 오전 발송을 10분간 예약하고 성공 시 날짜를 기록합니다. 외부 전송/DB 실패 시 중복 가능성은 완전히 없앨 수 없습니다.';
w.active=false;
fs.writeFileSync('n8n/daddy-bob-jooseyo-v4.json',JSON.stringify(w,null,2)+'\n');
console.log('Built V4 native Gemini bot: local typo replies, quiet clarifications, morning plan, health records.');
