// Translate the documented Gemini generateContent response into the shared intent validator input.
const data=$json.body && typeof $json.body==='object' ? $json.body : $json;
if (data.error) {
 const err=data.error;
 const message=typeof err==='string'?err:(err.description || err.message || '');
 const code=Number(err.code || err.httpCode || err.statusCode || $json.statusCode || 0);
 let provider_error='Gemini API 호출에 실패했어요. 잠시 후 다시 시도하거나 n8n의 Gemini 노드 오류를 확인해 주세요. 이번 요청은 처리하지 않았습니다.';
 if(code===429 || /RESOURCE_EXHAUSTED|quota|rate.?limit|usage.?limit|429/i.test(message)) provider_error='Gemini API 사용량 또는 요청 한도를 초과했어요. 한도·결제 상태를 확인한 뒤 다시 시도해 주세요. 이번 요청은 처리하지 않았습니다.';
 else if([401,403].includes(code) || /PERMISSION_DENIED|API_KEY_INVALID|credential|unauthorized|forbidden|401|403/i.test(message)) provider_error='Gemini API 키 또는 프로젝트 접근 권한을 확인해 주세요. n8n의 Header Auth 자격 증명이 필요합니다. 이번 요청은 처리하지 않았습니다.';
 else if(code===404 || /NOT_FOUND|model.*not.*found/i.test(message)) provider_error='설정한 Gemini 모델을 사용할 수 없어요. Gemini 노드의 모델 주소와 프로젝트 모델 접근을 확인해 주세요. 이번 요청은 처리하지 않았습니다.';
 return [{json:{provider_error}}];
}
if(data.promptFeedback?.blockReason)return [{json:{provider_error:'Gemini가 이 요청의 응답을 차단했어요. 다른 표현으로 다시 알려주세요. 기록은 변경하지 않았습니다.'}}];
const candidate=data.candidates?.[0];
if(candidate?.finishReason!=='STOP')return [{json:{provider_error:'Gemini 응답이 완성되지 않았어요. 다시 입력해 주세요. 기록은 변경하지 않았습니다.'}}];
const content=(candidate.content?.parts || []).filter(p=>!p.thought && typeof p.text==='string').map(p=>p.text).join('');
if(!content.trim())return [{json:{provider_error:'Gemini 응답 내용이 비어 있어요. 잠시 후 다시 시도해 주세요. 기록은 변경하지 않았습니다.'}}];
return [{json:{choices:[{finish_reason:'stop',message:{content}}]}}];
