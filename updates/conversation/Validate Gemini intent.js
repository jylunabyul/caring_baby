// Strict boundary between model output and mutation RPC. Model output never supplies tokens/identity/confirmed.
const built = $('Build Gemini request').item.json;
const {normalized:n,context:c} = built;
const base = {chat_id:n.chat_id,callback_id:'',args:{update_id:n.args.update_id}};
const clarify = question => [{json:{...base,action:'clarify',args:{...base.args,question}}}];
const ask = '내용을 정확히 확인하지 못했어요. 아이 이름·먹은 양·조유량을 다시 알려주시거나 /help를 입력해 주세요.';
// Explicit commands have already been parsed without model inference. Keep them usable
// even if GPT is uncertain/unavailable; SQL still validates scope and requires confirmation.
if (n.action === 'help' && /^\/(help|start)(?:@\w+)?$/i.test(n.raw_text.trim())) {
 return [{json:{...base,action:'help'}}];
}
if (n.action === 'feed' && /^\/feed\s/i.test(n.raw_text)) {
 const {name,amount,prepared}=n.args;
 if ((c.children || []).some(child=>child.name===name)
   && Number.isInteger(amount) && amount>=1 && amount<=1000
   && Number.isInteger(prepared) && prepared>=amount && prepared<=2000) {
  return [{json:{...base,action:'feed',args:{...base.args,name,amount,prepared}}}];
 }
 return clarify('등록된 아이 이름과 먹은 양·조유량을 확인해 주세요. /children에서 이름을 볼 수 있습니다.');
}

if ($json.provider_error) {
 return clarify($json.provider_error);
}

let v;
try {
 const choice=$json.choices?.[0];
 if (choice?.finish_reason!=='stop' || choice.message?.refusal) return clarify(ask);
 v=JSON.parse(choice.message.content);
} catch { return clarify('Gemini 연결 또는 응답을 확인하지 못했어요. 잠시 후 다시 입력해 주세요. 아직 처리하지 않았습니다.'); }

// Conversation replies are sent directly to Telegram. They never enter the mutation RPC.
if(v && v.action==='chat'){
 if(typeof v.confidence!=='number'||v.confidence<0.5||v.confidence>1||typeof v.answer!=='string'||!v.answer.trim()||v.answer.length>1800)return clarify(ask);
 let answer=v.answer.trim();
 if(/(?:저장|기록|삭제|설정|예약|수정)(?:을|를)?\s*(?:했|해뒀|완료|되었|됐)/.test(answer))return clarify('아버님, 실제 기록이나 설정의 확인이 필요합니다. 원하시는 조회 내용을 말씀해 주세요.');
 if(!answer.startsWith('아버님'))answer='아버님, '+answer;
 return [{json:{...base,action:'chat',reply:answer,buttons:[]}}];
}

if (!v || typeof v!=='object' || typeof v.confidence!=='number' || v.confidence<0.85 || v.confidence>1) return clarify(ask);
if (v.action==='clarify') return clarify(typeof v.question==='string' && v.question.trim() ? v.question.slice(0,1000) : ask);
const a={...base.args};
const num=(key,min,max,integer=false)=>typeof v[key]==='number' && Number.isFinite(v[key]) && v[key]>=min && v[key]<=max && (!integer || Number.isInteger(v[key]));
const name=(c.children || []).find(x=>x.name===v.name);
const string=(x,max=80)=>typeof x==='string' && x.trim().length>0 && x.length<=max;
const date=x=>typeof x==='string' && /^\d{4}-\d{2}-\d{2}$/.test(x) && !Number.isNaN(Date.parse(x+'T00:00:00Z')) && new Date(x+'T00:00:00Z').toISOString().slice(0,10)===x;
const clock=x=>typeof x==='string' && /^(?:[01]\d|2[0-3]):[0-5]\d$/.test(x);


if(['care_setup','care_cancel','care_snooze','care_list'].includes(v.action)){
 if(v.action==='care_list')return [{json:{...base,action:'care_list',args:a}}];
 if(v.action==='care_cancel'||v.action==='care_snooze'){
  const plan=(c.care_plans||[]).find(p=>p.id===v.plan_id && p.active);
  if(!plan || (v.name!=null&&v.name!==plan.name))return clarify('아버님, 어느 투약·체온 알림을 변경할까요? 아이 이름과 약 이름을 알려주세요.');
  a.plan_id=plan.id;
  if(v.action==='care_snooze'){
   if(!num('minutes',1,1440,true))return clarify('몇 분 미룰까요, 아버님?');a.minutes=v.minutes;
  }
 }else{
  if(!name||!['temperature','medicine'].includes(v.care_kind)||typeof v.record_new!=='boolean')return clarify('아버님, 어느 아이의 체온 또는 투약 알림인지 알려주세요.');
  if(!num('interval_minutes',15,10080,true))return clarify('아버님, 몇 시간 또는 몇 분 간격으로 확인할지 직접 정해서 알려주세요.');
  a.name=name.name;a.care_kind=v.care_kind;a.record_new=v.record_new;a.interval_minutes=v.interval_minutes;
  if(v.overnight!=null && typeof v.overnight!=='boolean')return clarify('밤에도 알릴지는 설정 버튼에서 선택해 주세요.');
  a.overnight=v.overnight??null;
  if(v.care_kind==='medicine'){
   if(!string(v.medicine))return clarify('기준이 될 약 이름을 알려줘, 아버님.');a.medicine=v.medicine;
  }
  if(v.record_new){
   if(v.care_kind==='temperature'){
    if(!num('temperature',30,45))return clarify('아버님, 처음 실제로 잰 체온을 알려주세요.');a.temperature=v.temperature;
   }else{
    if(!num('dose',0.001,100000)||!['ml','mg','g','방울','정','포'].includes(v.dose_unit))return clarify('실제 투여량과 단위를 알려주세요. 용량은 내가 정하지 않습니다.');a.dose=v.dose;a.dose_unit=v.dose_unit;
   }
   if(v.time!=null){
    if(typeof v.time!=='string'||!/^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}(?:Z|[+-]\d{2}:\d{2})$/.test(v.time)||!Number.isFinite(Date.parse(v.time))||Date.parse(v.time)>Date.parse(c.now_kst))return clarify('첫 실제 기록 시각을 다시 알려주세요.');a.time=v.time;
   }
  }else if(v.anchor_id!=null){
   const h=(c.health_recent||[]).find(h=>h.id===v.anchor_id && h.name===name.name && h.kind===v.care_kind && (v.care_kind==='temperature'||h.medicine===v.medicine));
   if(!h)return clarify('아버님, 기준이 될 실제 기록을 다시 확인해 주세요.');a.anchor_id=h.id;
  }
  if(v.end_at!=null){
   if(typeof v.end_at!=='string'||!/^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}(?:Z|[+-]\d{2}:\d{2})$/.test(v.end_at)||!Number.isFinite(Date.parse(v.end_at))||Date.parse(v.end_at)<=Date.parse(c.now_kst))return clarify('언제까지 알릴지 미래의 종료 시각을 알려주세요.');a.end_at=v.end_at;
  }
  if(v.reminder_count!=null){if(!num('reminder_count',1,1000,true))return clarify('알림 횟수를 정수로 알려주세요.');a.reminder_count=v.reminder_count;}
 }
 return [{json:{...base,action:v.action,args:a}}];
}

if (['health','healthhistory','morning'].includes(v.action)) {
 if(!name)return clarify('어느 아이 기록인가요, 아버님? 이름을 같이 알려주세요.');
 a.name=name.name;
 if(v.action==='health'){
  if(!['temperature','medicine','note'].includes(v.health_kind))return clarify('체온인지 투약인지, 어떤 특이사항인지 알려주세요.');
  a.health_kind=v.health_kind;
  if(v.health_kind==='temperature'){
   if(!num('temperature',30,45))return clarify('아버님, 실제로 잰 체온을 도 단위로 알려주세요.');
   a.temperature=v.temperature;
  }else if(v.health_kind==='medicine'){
   if(!string(v.medicine) || !num('dose',0.001,100000) || !['ml','mg','g','방울','정','포'].includes(v.dose_unit))return clarify('약 이름, 실제 투여량과 단위를 알려주세요. 용량은 내가 정하지 않습니다.');
   a.medicine=v.medicine;a.dose=v.dose;a.dose_unit=v.dose_unit;
  }else{
   if(!string(v.note,1500))return clarify('아버님, 남겨둘 특이사항을 말씀해 주세요.');a.note=v.note;
  }
  if(v.time!=null){
   if(typeof v.time!=='string'||!/^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}(?:Z|[+-]\d{2}:\d{2})$/.test(v.time)||!Number.isFinite(Date.parse(v.time))||Date.parse(v.time)>Date.parse(c.now_kst))return clarify('아버님, 실제로 있었던 시각을 다시 알려주세요. 미래 시각으로는 기록하지 않습니다.');
   a.time=v.time;
  }
 }else if(v.action==='morning'){
  if(typeof v.enabled!=='boolean'||!num('plan_ml',1,1000,true))return clarify('아버님, 아침 알림을 켤지와 아버님이 정한 수유 계획량을 알려주세요.');
  a.enabled=v.enabled;a.plan_ml=v.plan_ml;
 }
 return [{json:{...base,action:v.action,args:a}}];
}

if (['help','children','cancel'].includes(v.action)) { /* no model-supplied arguments */ }
else if (v.action==='decision') {
 const pending=c.pending;
 // Approval/cancellation is bound to the exact context token and checked AGAIN transactionally in SQL.
 const yes=/^(응|네|넵|예|어|맞아|맞아요|좋아|좋아요|확인|확인해|확인해줘|저장해|저장해줘|진행해|진행해줘|삭제해|삭제해줘|그래|그래요|ok|okay|yes)[.!。\s]*$/i;
 const no=/^(아니|아니요|아냐|아니야|취소|취소해|취소해줘|안돼|안 돼|하지마|하지 마|no)[.!。\s]*$/i;
 if (!pending?.token || pending.action==='await_amount' || typeof v.decision!=='boolean'
   || !(v.decision ? yes : no).test(n.raw_text.trim())) return clarify('확인 요청에 동의하면 “응”, 취소하려면 “아니”라고 답해 주세요. 변경할 내용이 있다면 새로 알려주세요.');
 a.decision=v.decision;a.expected_token=pending.token;
} else if (v.action==='childadd') {
 if (!string(v.name) || !date(v.dob)) return clarify('새 아이의 이름과 생년월일(YYYY-MM-DD)을 알려주세요.');
 a.name=v.name.trim();a.dob=v.dob;
} else {
 if (['edit','delete'].includes(v.action)) {
  const row=(c.recent || []).find(r=>r.id===v.feed_id);
  if (!row) return clarify('수정·삭제할 기록을 찾지 못했어요. /history 아이이름으로 기록 ID를 확인해 주세요.');
  if (v.name!=null && row.name!==v.name) return clarify('아이 이름과 기록이 일치하지 않아요. 어느 기록인지 다시 알려주세요.');
  a.feed_id=row.id;
 } else if (v.action==='amount') {
  if (c.pending?.action!=='await_amount') return clarify('어느 아이에게 먹인 양인가요? 아이 이름도 알려주세요.');
 } else {
  if (!name) return clarify('어느 아이의 기록인가요? /children에서 이름을 확인해 주세요.');
  a.name=name.name;
 }
 switch(v.action) {
  case 'feed': case 'amount': case 'edit':
   if (!num('amount',1,1000,true) || !num('prepared',v.amount,2000,true)) return clarify('실제 먹은 양(1~1000ml)과 준비한 조유량을 확인해 주세요. 조유량은 먹은 양 이상이어야 합니다.');
   a.amount=v.amount;a.prepared=v.prepared;
   if (v.time!=null) {
    if (v.action==='amount' || typeof v.time!=='string' || !/^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}(?:Z|[+-]\d{2}:\d{2})$/.test(v.time) || !Number.isFinite(Date.parse(v.time)) || Date.parse(v.time)>Date.parse(c.now_kst)) return clarify('기록 시각을 시간대가 포함된 과거 시각으로 알려주세요.');
    a.time=v.time;
   }
   break;
  case 'growth':
   if (!num('weight',0.3,80) || !num('height',20,150)) return clarify('체중(kg)과 키(cm)를 함께 알려주세요.');
   a.weight=v.weight;a.height=v.height;break;
  case 'stock':
   if (!string(v.product) || !num('grams',1,10000) || !num('scoop_g',0.1,100) || !num('scoop_ml',1,1000) || !num('tins',0,100) || !num('lead',0,60,true) || !num('buffer',0,60,true)) return clarify('제품명·한 통 가루g·한 스푼g·스푼당 조유ml·남은 통수·배송일·여유일을 알려주세요. 비율은 제품 라벨을 확인해 주세요.');
   for(const key of ['product','grams','scoop_g','scoop_ml','tins','lead','buffer']) a[key]=v[key];
   break;
  case 'sleep':
   if (typeof v.enabled!=='boolean' || (v.enabled && (!clock(v.start)||!clock(v.end)||v.start===v.end))) return clarify('알림을 쉴 시작·종료 시간을 알려주세요. 예: 별이 밤 10시부터 아침 8시까지 알림 쉬어줘.');
   a.enabled=v.enabled;if(v.enabled){a.start=v.start;a.end=v.end;}break;
  case 'history':case 'status':case 'reset':case 'childdelete':case 'delete':case 'fed':case 'later':break;
  default:return clarify(ask);
 }
}
return [{json:{...base,action:v.action,args:a}}];

