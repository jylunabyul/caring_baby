const built=$('Build Gemini request').item.json;
const n=built.normalized,c=built.context;
let v;
try{const x=$json.choices?.[0];if(x?.finish_reason!=='stop')return validateOne($json,$);v=JSON.parse(x.message.content);}catch{return validateOne($json,$);}
const supported=['stop_health_alerts','rest_start','rest_end','rest_record','rest_history'];
if(!supported.includes(v?.action))return validateOne($json,$);
const base={chat_id:n.chat_id,callback_id:'',args:{update_id:n.args.update_id}};
const ask=question=>[{json:{...base,action:'clarify',args:{...base.args,question}}}];
if(typeof v.confidence!=='number'||v.confidence<0.85||v.confidence>1)return ask(v.question||'아버님, 중지할 알림이나 수면 기록 내용을 확인해 주세요.');
const children=c.children||[];
let child=children.find(ch=>ch.name===v.name);
if(!child && v.name==null && children.length===1)child=children[0];
const args={...base.args};
const instant=t=>typeof t==='string'&&/^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}(?:Z|[+-]\d{2}:\d{2})$/.test(t)&&Number.isFinite(Date.parse(t));
if(v.action==='stop_health_alerts'){
 if(v.all_children===true){
  if(!/(모든|전체|전부).*(아이|아기|애들)|(아이|아기|애들).*(모두|전체|전부)/.test(n.raw_text))return ask('아버님, 어느 아이의 투약·체온 알림을 중지할까요?');
  args.all_children=true;
 }else{
  if(!child)return ask('아버님, 어느 아이의 알림을 중지할까요?');args.name=child.name;args.all_children=false;
 }
 if(!Array.isArray(v.stop_kinds)||!v.stop_kinds.length||v.stop_kinds.some(k=>!['temperature','medicine'].includes(k)))return ask('아버님, 투약과 체온 중 어떤 알림을 중지할까요?');
 args.stop_kinds=[...new Set(v.stop_kinds)];
 if(typeof v.medicine==='string'&&v.medicine.trim()&&!['약','투약','감기약'].includes(v.medicine.trim()))args.medicine=v.medicine.trim();
}else{
 if(!child)return ask('아버님, 어느 아이의 낮잠·수면 기록인가요?');args.name=child.name;
 if(v.action!=='rest_history'){
  if(v.action!=='rest_end'&&!['nap','night'].includes(v.rest_kind))return ask('아버님, 낮잠인가요, 밤잠인가요?');
  if(v.rest_kind!=null)args.rest_kind=v.rest_kind;
  if(v.action==='rest_record'){
   if(!instant(v.started_at)||!instant(v.ended_at)||Date.parse(v.ended_at)<=Date.parse(v.started_at)||Date.parse(v.ended_at)>Date.parse(c.now_kst))return ask('아버님, 한국 시간으로 잠든 시각과 깬 시각을 알려주세요. 실제 수면 기록에 미래 시각은 넣지 않습니다.');
   args.started_at=v.started_at;args.ended_at=v.ended_at;
  }else{
   const time=v.time??n.received_at_kst??c.now_kst;
   if(!instant(time)||Date.parse(time)>Date.parse(c.now_kst))return ask('아버님, 실제 잠들거나 깬 시각을 다시 알려주세요.');args.time=time;
  }
  if(v.note!=null){if(typeof v.note!=='string'||v.note.length>1500)return ask('아버님, 수면 메모를 짧게 알려주세요.');args.note=v.note;}
 }
}
return [{json:{...base,action:v.action,args}}];
