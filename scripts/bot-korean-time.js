// Model civil times are Korean local times. Append +09:00 exactly once; never rely on server timezone.
if($json.provider_error)return [{json:$json}];
const built=$('Build Gemini request').item.json;
const raw=built.normalized.raw_text||'';
let intent;
try{const choice=$json.choices?.[0];if(choice?.finish_reason!=='stop')return [{json:$json}];intent=JSON.parse(choice.message.content);}catch{return [{json:$json}];}
const bareHour=/(?:한|두|세|네|다섯|여섯|일곱|여덟|아홉|열|열한|열두|0?[1-9]|1[0-2])\s*시(?!간)/.test(raw);
const clearPeriod=/오전|오후|아침|점심|저녁|밤|새벽|낮|현재|지금|방금|(?:1[3-9]|2[0-3])\s*시|\d{4}-\d{2}-\d{2}T/.test(raw);
const localToKst=value=>{
 if(typeof value!=='string')throw new Error('Time is not text');
 const m=value.match(/^(\d{4}-\d{2}-\d{2})T(\d{2}:\d{2})(?::(\d{2}))?(?:\+09:00)?$/);
 if(!m)throw new Error('Expected Korean local time, not UTC');
 const civil=m[1]+'T'+m[2]+':'+(m[3]||'00');
 const epoch=Date.parse(civil+'+09:00');
 if(!Number.isFinite(epoch)||new Date(epoch+9*3600000).toISOString().slice(0,19)!==civil)throw new Error('Invalid calendar date');
 return civil+'+09:00';
};
const question='아버님, 기록 시각을 한국 시간으로 확인해 주세요. “한 시”는 오전 1시인가요, 오후 1시인가요?';
const normalize=op=>{
 const target=op?.args && typeof op.args==='object'?op.args:op;
 if(!target||typeof target!=='object')return;
 for(const key of ['time','scheduled_at','end_at']){
  if(target[key]==null)continue;
  if(bareHour&&!clearPeriod)throw new Error('AM/PM is ambiguous');
  target[key]=localToKst(target[key]);
 }
};
if(intent?.action==='batch'&&Array.isArray(intent.operations)){
 for(const op of intent.operations){try{normalize(op);}catch{op.confidence=0;op.question=question;}}
}else{
 try{normalize(intent);}catch(error){intent={action:'clarify',confidence:1,question:error.message==='AM/PM is ambiguous'?question:'아버님, 기록 시각을 한국 시간으로 확인해 주세요. 예: 11월 26일 오후 1시.'};}
}
return [{json:{...$json,choices:[{...$json.choices[0],message:{...$json.choices[0].message,content:JSON.stringify(intent)}}]}}];
