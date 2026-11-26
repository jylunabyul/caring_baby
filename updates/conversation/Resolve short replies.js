// Resolve explicit short replies locally, bound to a live token; do not ask an LLM twice.
const n=$('Normalize update').item.json;
const c=$json;
if(!Array.isArray(c.children)||!Array.isArray(c.recent))throw new Error('V4 context is unavailable; check V4 SQL');
const text=n.raw_text.trim();
const short=text.toLowerCase().replace(/[\s.!?。！？~ㅋㅎ]/g,'');
const yes=new Set(['응','응응','으응','웅','웅웅','ㅇㅇ','ㅇ','네','넵','넹','예','엉','맞아','맞아요','좋아','좋아요','그래','그래요','확인','확인해줘','저장해줘','ok','okay','yes']);
const no=new Set(['아니','아니요','아뇨','아냐','아니야','아닝','아녀','아니용','ㄴㄴ','노노','취소','취소해줘','no']);
let action,args={update_id:n.args.update_id};
if(c.pending?.action==='care_setup' && /^(밤에도|밤에도알려줘|야간포함|낮에만|낮에만알려줘|야간제외)$/.test(short)){
 action='care_choice';args.expected_token=c.pending.token;args.overnight=/^(밤에도|야간포함)/.test(short);
}
if(!action && (yes.has(short)||no.has(short))){
 if(c.pending?.token && c.pending.action!=='await_amount'){
  action='decision';args.decision=yes.has(short);args.expected_token=c.pending.token;
 }else if(c.pending?.action==='await_amount' && no.has(short)){action='cancel';}
 else action='skip';
}
let m;
if(!action && (m=text.match(/^\/health\s+(.+)$/i))){action='healthhistory';args.name=m[1];}
if(!action && (m=text.match(/^\/temp\s+(.+?)\s+(\d{2}(?:\.\d)?)$/i))){action='health';Object.assign(args,{name:m[1],health_kind:'temperature',temperature:Number(m[2])});}
if(!action && (m=text.match(/^\/medicine\s+(\S+)\s+(.+?)\s+(\d+(?:\.\d+)?)\s+(ml|mg|g|방울|정|포)$/i))){action='health';Object.assign(args,{name:m[1],health_kind:'medicine',medicine:m[2],dose:Number(m[3]),dose_unit:m[4].toLowerCase()});}
if(!action && (m=text.match(/^\/note\s+(\S+)\s+(.+)$/i))){action='health';Object.assign(args,{name:m[1],health_kind:'note',note:m[2]});}
if(!action && (m=text.match(/^\/morning\s+(.+?)\s+(\d{1,4}|off)$/i))){action='morning';Object.assign(args,{name:m[1],enabled:m[2].toLowerCase()!=='off',plan_ml:m[2].toLowerCase()==='off'?200:Number(m[2])});}
if(!action && /^\/care$/i.test(text))action='care_list';
if(!action && (m=text.match(/^\/carestop\s+([0-9a-f-]{36})$/i))){action='care_cancel';args.plan_id=m[1];}
if(!action && (m=text.match(/^\/caresnooze\s+([0-9a-f-]{36})\s+(\d{1,4})$/i))){action='care_snooze';args.plan_id=m[1];args.minutes=Number(m[2]);}
return [{json:{...n,context:c,ready:!!action,...(action?{action,args}:{})}}];

