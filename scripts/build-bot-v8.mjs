import fs from 'node:fs';
const w=JSON.parse(fs.readFileSync('n8n/daddy-bob-jooseyo-v7.json','utf8'));
w.name='Daddy Bob Jooseyo - V8 daily timeline';
const get=name=>w.nodes.find(n=>n.name===name);
for(const n of w.nodes)if(n.type==='n8n-nodes-base.httpRequest'&&n.parameters.url?.endsWith('/daddy_bob_jooseyo_bot_v7'))n.parameters.url=n.parameters.url.replace(/_v7$/,'_v8');
const request=get('Build Gemini request');
request.parameters.jsCode=request.parameters.jsCode.replace('const system=',"fields.action.enum.push('daily_timeline');\nfields.report_date={type:['string','null']};\nconst system=");
const instruction=`\nDaily timeline: action=daily_timeline for 오늘 하루 기록 보여줘, 어늘 하루 기록 보여줘 (오늘 typo), 오늘 전체 기록, 오늘 하루 정리, or a specified day's full activity timeline. report_date is YYYY-MM-DD from Korean context.now_kst (not UTC), handle 어제 and explicit dates. name=null means all registered children; only a stated child name filters. A read-only timeline request never creates a clinical event. Do not use history for a request spanning feeding + health + sleep. Never generate a timeline from limited prompt context; the server queries all stored actual records for that Korean day. Future reminders are not actual administrations and must not be included as completed events.
`;
request.parameters.jsCode=request.parameters.jsCode.replace('text:system +','text:system + '+JSON.stringify(instruction)+' +');
const validator=get('Validate Gemini intent');
const marker='const validateV7=function($json,$){';
const branch=`
const parsed=$json.choices?.[0];
if(parsed?.finish_reason==='stop'){
 let value;try{value=JSON.parse(parsed.message.content);}catch{}
 if(value?.action==='daily_timeline'){
  const b=$('Build Gemini request').item.json;const n=b.normalized,c=b.context;
  const date=value.report_date??c.now_kst?.slice(0,10);
  const args={update_id:n.args.update_id,report_date:date};
  if(value.name!=null){if(!(c.children||[]).some(ch=>ch.name===value.name))return [{json:{chat_id:n.chat_id,action:'clarify',args:{update_id:n.args.update_id,question:'아버님, 조회할 아이 이름을 확인해 주세요.'}}}];args.name=value.name;}
  if(typeof date!=='string'||!/^\\d{4}-\\d{2}-\\d{2}$/.test(date)||!Number.isFinite(Date.parse(date+'T00:00:00Z'))||new Date(date+'T00:00:00Z').toISOString().slice(0,10)!==date)return [{json:{chat_id:n.chat_id,action:'clarify',args:{update_id:n.args.update_id,question:'아버님, 조회할 날짜를 YYYY-MM-DD로 알려주세요.'}}}];
  return [{json:{chat_id:n.chat_id,action:'daily_timeline',args}}];
 }
}
`;
validator.parameters.jsCode=validator.parameters.jsCode.replace(marker,marker+'\n'+branch);
const quick=get('Resolve short replies');
const insertionAt=quick.parameters.jsCode.lastIndexOf('return [{json:');
quick.parameters.jsCode=quick.parameters.jsCode.slice(0,insertionAt)+`if(!action && /^(오늘|어늘|금일)(?:하루)?(?:전체)?(?:기록|타임라인)(?:을|좀)?(?:보여줘|보여주세요|알려줘|정리해줘)$/.test(text.replace(/\\s/g,''))){action='daily_timeline';args.report_date=(n.received_at_kst||c.now_kst).slice(0,10);}
if(!action && (m=text.match(/^\\/timeline(?:\\s+(\\d{4}-\\d{2}-\\d{2}))?$/i))){action='daily_timeline';args.report_date=m[1]||(n.received_at_kst||c.now_kst).slice(0,10);}
return [{json:`+quick.parameters.jsCode.slice(insertionAt+'return [{json:'.length);
get('Format response').parameters.jsCode=fs.readFileSync('scripts/bot-timeline-pages.js','utf8');
fs.writeFileSync('n8n/daddy-bob-jooseyo-v8.json',JSON.stringify(w,null,2)+'\n');
console.log('Built V8: Korean-day actual event timeline, all-child/single-child scopes, complete Telegram pagination.');
