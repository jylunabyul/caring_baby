import fs from 'node:fs';
const w=JSON.parse(fs.readFileSync('n8n/daddy-bob-jooseyo-v4.json','utf8'));
w.name='Daddy Bob Jooseyo - V5 personal care reminders';
for(const n of w.nodes)if(n.type==='n8n-nodes-base.httpRequest'&&n.parameters.url?.endsWith('/daddy_bob_jooseyo_bot_v4'))n.parameters.url=n.parameters.url.replace(/_v4$/,'_v5');
const normalize=w.nodes.find(n=>n.name==='Normalize update');
normalize.parameters.jsCode=normalize.parameters.jsCode.replace("if (data === 'cancel')",`if ((m=data.match(/^care_(night|day):([0-9a-f-]{36})$/i))) {
 action='care_choice';args={expected_token:m[2],overnight:m[1]==='night'};
} else if ((m=data.match(/^care_(stop|later):([0-9a-f-]{36})$/i))) {
 action=m[1]==='stop'?'care_cancel':'care_snooze';args={plan_id:m[2],...(m[1]==='later'?{minutes:30}:{})};
} else if (data === 'cancel')`);
const quick=w.nodes.find(n=>n.name==='Resolve short replies');
quick.parameters.jsCode=quick.parameters.jsCode.replace("if(yes.has(short)||no.has(short)){",`if(c.pending?.action==='care_setup' && /^(밤에도|밤에도알려줘|야간포함|낮에만|낮에만알려줘|야간제외)$/.test(short)){
 action='care_choice';args.expected_token=c.pending.token;args.overnight=/^(밤에도|야간포함)/.test(short);
}
if(!action && (yes.has(short)||no.has(short))){`).replace('}else if(c.pending && text.length<=6','}else if(!action && c.pending && text.length<=6');
quick.parameters.jsCode=quick.parameters.jsCode.replace('return [{json:',`if(!action && /^\\/care$/i.test(text))action='care_list';
if(!action && (m=text.match(/^\\/carestop\\s+([0-9a-f-]{36})$/i))){action='care_cancel';args.plan_id=m[1];}
if(!action && (m=text.match(/^\\/caresnooze\\s+([0-9a-f-]{36})\\s+(\\d{1,4})$/i))){action='care_snooze';args.plan_id=m[1];args.minutes=Number(m[2]);}
return [{json:`);
const request=w.nodes.find(n=>n.name==='Build Gemini request');
const fields=`
fields.action.enum.push('care_setup','care_cancel','care_snooze','care_list');
for(const key of ['care_kind','plan_id','anchor_id','end_at'])fields[key]={type:['string','null']};
for(const key of ['interval_minutes','reminder_count','minutes'])fields[key]={type:['integer','null']};
for(const key of ['record_new','overnight'])fields[key]={type:['boolean','null']};
`;
request.parameters.jsCode=request.parameters.jsCode.replace('const system=',fields+'\nconst system=');
request.parameters.jsCode=request.parameters.jsCode.replace('recent:context.recent,pending,now_kst:', 'recent:context.recent,health_recent:context.health_recent||[],care_plans:context.care_plans||[],pending,now_kst:');
const instruction=`\nUser-defined repeated care reminders (separate from feeding):
care_setup: user explicitly asks repeated temperature or medication reminders, with care_kind=temperature|medicine, name, interval_minutes (convert ONLY the explicitly stated hours to minutes), record_new boolean.
If user reports an ACTUAL first measurement/administration AND asks for repetition in the same sentence, record_new=true and include observed temperature or exact actual medicine,dose,dose_unit,time. Do not invent a measurement, medicine, dose or interval. If only configuring reminders from an already logged observation/administration, record_new=false; choose an anchor_id only from health_recent matching the child/kind/medicine, otherwise leave it null and SQL resolves the latest actual matching event. For medicine a real medicine name is required; do not invent a drug from vague '약'. For temperature the schedule alone does not create a fictitious reading.
All care_setup proposals are explicitly confirmed. overnight must be null unless user explicitly says to include or exclude nighttime; the bot offers two buttons before activating. end_at is a timezone-explicit ISO endpoint only if the user specifies it. reminder_count is the requested number of future NOTIFICATION deliveries (not doses). If neither end_at nor reminder_count is stated, leave both null and confirmation will explicitly say repeats until stopped. Do not choose a clinical course length. The interval is the user's plan, never a dose or clinical recommendation. A question about recommended drug dose or frequency is clarify, not a plan.
If the current pending care_setup is being refined, retain its exact recorded facts, original time and interval; update only the user's stated changes. Do not record an extra initial event when changing a pending plan.
care_list: list active care reminder settings. care_cancel/care_snooze: use plan_id only from care_plans and a child/medicine unambiguously identified by user. Ask which when more than one matches. snooze minutes must be explicitly specified. Cancellation stops reminders, not health records; snoozing notification is not changing a prescribed medication regimen.
`;
request.parameters.jsCode=request.parameters.jsCode.replace('text:system +', 'text:system + '+JSON.stringify(instruction)+' +');
const validation=w.nodes.find(n=>n.name==='Validate Gemini intent');
const careValidate=`
if(['care_setup','care_cancel','care_snooze','care_list'].includes(v.action)){
 if(v.action==='care_list')return [{json:{...base,action:'care_list',args:a}}];
 if(v.action==='care_cancel'||v.action==='care_snooze'){
  const plan=(c.care_plans||[]).find(p=>p.id===v.plan_id && p.active);
  if(!plan || (v.name!=null&&v.name!==plan.name))return clarify('오빠, 어느 투약·체온 알림을 바꿀까? 아이 이름과 약 이름을 알려줘.');
  a.plan_id=plan.id;
  if(v.action==='care_snooze'){
   if(!num('minutes',1,1440,true))return clarify('몇 분 미뤄줄까, 오빠?');a.minutes=v.minutes;
  }
 }else{
  if(!name||!['temperature','medicine'].includes(v.care_kind)||typeof v.record_new!=='boolean')return clarify('오빠, 어느 아이의 체온 또는 투약 알림인지 알려줘.');
  if(!num('interval_minutes',15,10080,true))return clarify('오빠, 몇 시간 또는 몇 분 간격으로 확인할지 직접 정해서 알려줘.');
  a.name=name.name;a.care_kind=v.care_kind;a.record_new=v.record_new;a.interval_minutes=v.interval_minutes;
  if(v.overnight!=null && typeof v.overnight!=='boolean')return clarify('밤에도 알릴지는 설정 버튼에서 골라줘.');
  a.overnight=v.overnight??null;
  if(v.care_kind==='medicine'){
   if(!string(v.medicine))return clarify('기준이 될 약 이름을 알려줘, 오빠.');a.medicine=v.medicine;
  }
  if(v.record_new){
   if(v.care_kind==='temperature'){
    if(!num('temperature',30,45))return clarify('오빠, 처음 실제로 잰 체온을 알려줘.');a.temperature=v.temperature;
   }else{
    if(!num('dose',0.001,100000)||!['ml','mg','g','방울','정','포'].includes(v.dose_unit))return clarify('실제 투여량과 단위를 알려줘. 용량은 내가 정하지 않을게.');a.dose=v.dose;a.dose_unit=v.dose_unit;
   }
   if(v.time!=null){
    if(typeof v.time!=='string'||!/^\\d{4}-\\d{2}-\\d{2}T\\d{2}:\\d{2}:\\d{2}(?:Z|[+-]\\d{2}:\\d{2})$/.test(v.time)||!Number.isFinite(Date.parse(v.time))||Date.parse(v.time)>Date.parse(c.now_kst))return clarify('첫 실제 기록 시각을 다시 알려줘.');a.time=v.time;
   }
  }else if(v.anchor_id!=null){
   const h=(c.health_recent||[]).find(h=>h.id===v.anchor_id && h.name===name.name && h.kind===v.care_kind && (v.care_kind==='temperature'||h.medicine===v.medicine));
   if(!h)return clarify('오빠, 기준이 될 실제 기록을 다시 확인해줘.');a.anchor_id=h.id;
  }
  if(v.end_at!=null){
   if(typeof v.end_at!=='string'||!/^\\d{4}-\\d{2}-\\d{2}T\\d{2}:\\d{2}:\\d{2}(?:Z|[+-]\\d{2}:\\d{2})$/.test(v.end_at)||!Number.isFinite(Date.parse(v.end_at))||Date.parse(v.end_at)<=Date.parse(c.now_kst))return clarify('언제까지 알릴지 미래의 종료 시각을 알려줘.');a.end_at=v.end_at;
  }
  if(v.reminder_count!=null){if(!num('reminder_count',1,1000,true))return clarify('알림 횟수를 정수로 알려줘.');a.reminder_count=v.reminder_count;}
 }
 return [{json:{...base,action:v.action,args:a}}];
}
`;
validation.parameters.jsCode=validation.parameters.jsCode.replace("if (['health','healthhistory','morning']",careValidate+"\nif (['health','healthhistory','morning']");
const careHttp={method:'POST',url:'https://tvymznlclqilemgeczdd.supabase.co/rest/v1/rpc/daddy_bob_jooseyo_bot_v5',authentication:'predefinedCredentialType',nodeCredentialType:'supabaseApi',sendBody:true,contentType:'json',specifyBody:'json',jsonBody:JSON.stringify({p_chat_id:'9114513581',p_action:'care_due',p_args:{}}),options:{timeout:20000}};
w.nodes.push({id:'care-minute',name:'Care reminders every minute',type:'n8n-nodes-base.scheduleTrigger',typeVersion:1.2,position:[0,1000],parameters:{rule:{interval:[{field:'minutes',minutesInterval:1}]}}});
w.nodes.push({id:'care-due',name:'Get care reminders',type:'n8n-nodes-base.httpRequest',typeVersion:4.2,position:[250,1000],parameters:careHttp});
w.connections['Care reminders every minute']={main:[[{node:'Get care reminders',type:'main',index:0}]]};
w.connections['Get care reminders']={main:[[{node:'Prepare reminders',type:'main',index:0}]]};
const mark=w.nodes.find(n=>n.name==='Mark delivered');mark.parameters.jsonBody=mark.parameters.jsonBody.replace("delivery_day:$('Loop reminders').item.json.delivery_day", "delivery_day:$('Loop reminders').item.json.delivery_day,plan_id:$('Loop reminders').item.json.plan_id,claim_token:$('Loop reminders').item.json.claim_token,occurrence_due:$('Loop reminders').item.json.occurrence_due");
w.active=false;
fs.writeFileSync('n8n/daddy-bob-jooseyo-v5.json',JSON.stringify(w,null,2)+'\n');
console.log('Built V5: first actual care record + confirmed interval/night/ending plan; independent one-minute care scheduler.');
