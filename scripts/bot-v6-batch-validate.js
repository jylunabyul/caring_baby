// Model extracts; trusted validators authorize. No user/model token or confirmation flag is accepted.
const built=$('Build Gemini request').item.json;
const n=built.normalized,c=built.context;
const base={chat_id:n.chat_id,callback_id:'',args:{update_id:n.args.update_id}};
const ask=q=>[{json:{...base,action:'clarify',args:{...base.args,question:q}}}];
let v;
try{const item=$json.choices?.[0];if(item?.finish_reason!=='stop')return validateOne($json,$);v=JSON.parse(item.message.content);}catch{return validateOne($json,$);}
if(!['batch','medicine_schedule','medicine_cancel','medicine_snooze'].includes(v?.action))return validateOne($json,$);
const input=v.action==='batch'?v.operations:[v];
if(!Array.isArray(input)||input.length<1||input.length>12)return ask('아버님, 요청을 1~12개 항목으로 나누어 다시 말씀해 주세요.');
const allowed=new Set(['feed','edit','delete','health','care_setup','medicine_schedule','growth','stock','sleep','morning','childadd','reset','childdelete','care_cancel','care_snooze','medicine_cancel','medicine_snooze','children','history','status','healthhistory','care_list']);
const out=[],questions=[],draft=[];
const instant=x=>typeof x==='string'&&/^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}(?:Z|[+-]\d{2}:\d{2})$/.test(x)&&Number.isFinite(Date.parse(x));
for(const [index,raw] of input.entries()){
 const item=raw&&typeof raw==='object'&&!Array.isArray(raw)?{...(raw.args&&typeof raw.args==='object'?raw.args:{}),...raw}:{};
 delete item.args;
 // Only bounded primitive fields go into an untrusted draft. They never execute until revalidated.
 const clean=Object.fromEntries(Object.entries(item).filter(([k,val])=>!['confirmed','token','expected_token','chat_id','update_id'].includes(k)&&k.length<50&&(val==null||typeof val==='boolean'||typeof val==='number'&&Number.isFinite(val)||typeof val==='string'&&val.length<=1600)));
 draft.push(clean);
 const fail=q=>{if(!questions.some(line=>line.slice(line.indexOf(':')+2)===q))questions.push(`${index+1}번: ${q}`);};
 if(!allowed.has(item.action)){fail('처리할 기록 또는 일정 종류를 확인해 주세요.');continue;}
 const confidence=item.confidence??v.confidence;
 if(typeof confidence!=='number'||confidence<0.85||confidence>1){fail(item.question||'인식한 내용을 다시 확인해 주세요.');continue;}
 if(item.action==='medicine_schedule'){
  let valid=true;
  if(!(c.children||[]).some(ch=>ch.name===item.name)){fail('아이 이름을 알려주세요.');continue;}
  if(typeof item.medicine!=='string'||!item.medicine.trim()||['감기약','해열제','약'].includes(item.medicine.trim())){fail('실제 약 이름을 알려주세요.');valid=false;}
  if(typeof item.dose!=='number'||!Number.isFinite(item.dose)||item.dose<=0||!['ml','mg','g','방울','정','포'].includes(item.dose_unit)){fail('아버님께서 정한 투여량과 단위를 알려주세요.');valid=false;}
  if(!instant(item.scheduled_at)||Date.parse(item.scheduled_at)<=Date.parse(c.now_kst)){fail(item.question||'범위가 아닌 정확한 미래 투약 예정 시각을 알려주세요.');valid=false;}
  if(typeof item.repeat_daily!=='boolean'){fail('1회 일정인지 매일 반복인지 확인해 주세요.');valid=false;}
  if(item.end_at!=null&&(!instant(item.end_at)||Date.parse(item.end_at)<Date.parse(item.scheduled_at))){fail('종료 시각을 확인해 주세요.');valid=false;}
  if(!valid)continue;
  const args={name:item.name,medicine:item.medicine.trim(),dose:item.dose,dose_unit:item.dose_unit,scheduled_at:item.scheduled_at,repeat_daily:item.repeat_daily};
  if(item.end_at!=null)args.end_at=item.end_at;
  out.push({action:item.action,args});continue;
 }
 if(['medicine_cancel','medicine_snooze'].includes(item.action)){
  const found=(c.fixed_schedules||[]).find(s=>s.id===item.schedule_id&&(item.name==null||item.name===s.name));
  if(!found){fail('어느 약의 고정 시간 알림인지 확인해 주세요.');continue;}
  const args={schedule_id:found.id};
  if(item.action==='medicine_snooze'){
   if(!Number.isInteger(item.minutes)||item.minutes<1||item.minutes>1440){fail('미룰 시간을 분 단위로 알려주세요.');continue;}args.minutes=item.minutes;
  }
  out.push({action:item.action,args});continue;
 }
 if(item.action==='care_setup'&&typeof item.overnight!=='boolean'){fail('체온·투약 반복 알림을 밤에도 보낼지 알려주세요.');continue;}
 const candidate={...item,confidence};
 const fake={choices:[{finish_reason:'stop',message:{content:JSON.stringify(candidate)}}]};
 const one=validateOne(fake,()=>({item:{json:{...built,normalized:{...n,action:'unknown'}}}}))[0]?.json;
 if(!one||one.action==='clarify'){fail(item.question||one?.args?.question||'필수 입력을 확인해 주세요.');continue;}
 const args={...one.args};delete args.update_id;
 out.push({action:one.action,args});
}
const summary=draft.map((d,i)=>`${i+1}. ${d.name||'아이'} · ${d.action==='care_setup'&&d.care_kind==='temperature'?'체온 '+(d.temperature??'측정값 확인')+'℃ / '+(d.interval_minutes??'간격 확인')+'분 간격':d.action==='medicine_schedule'?(d.medicine||'약명 확인')+' '+(d.dose??'용량 확인')+(d.dose_unit||'')+' / '+(d.scheduled_at||'시각 확인 필요'):d.action}`).join('\n');
if(questions.length)return [{json:{...base,action:'batch_draft',args:{...base.args,draft_operations:draft,question:(summary+'\n\n확인할 내용:\n'+questions.join('\n')).slice(0,1400)}}}];
return [{json:{...base,action:'batch',args:{...base.args,operations:out}}}];
