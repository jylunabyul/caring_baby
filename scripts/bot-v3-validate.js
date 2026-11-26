// Strict boundary between model output and mutation RPC. Model output never supplies tokens/identity/confirmed.
const built = $('Build GPT request').item.json;
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
let v;
try {
 const choice=$json.choices?.[0];
 if (choice?.finish_reason!=='stop' || choice.message?.refusal) return clarify(ask);
 v=JSON.parse(choice.message.content);
} catch { return clarify('GPT 연결 또는 응답을 확인하지 못했어요. 잠시 후 다시 입력해 주세요. 아직 처리하지 않았습니다.'); }
if (!v || typeof v!=='object' || typeof v.confidence!=='number' || v.confidence<0.85 || v.confidence>1) return clarify(ask);
if (v.action==='clarify') return clarify(typeof v.question==='string' && v.question.trim() ? v.question.slice(0,1000) : ask);
const a={...base.args};
const num=(key,min,max,integer=false)=>typeof v[key]==='number' && Number.isFinite(v[key]) && v[key]>=min && v[key]<=max && (!integer || Number.isInteger(v[key]));
const name=(c.children || []).find(x=>x.name===v.name);
const string=(x,max=80)=>typeof x==='string' && x.trim().length>0 && x.length<=max;
const date=x=>typeof x==='string' && /^\d{4}-\d{2}-\d{2}$/.test(x) && !Number.isNaN(Date.parse(x+'T00:00:00Z')) && new Date(x+'T00:00:00Z').toISOString().slice(0,10)===x;
const clock=x=>typeof x==='string' && /^(?:[01]\d|2[0-3]):[0-5]\d$/.test(x);
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
