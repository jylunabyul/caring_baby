import fs from 'node:fs';
const w=JSON.parse(fs.readFileSync('n8n/daddy-bob-jooseyo-v5-formal.json','utf8'));
w.name='Daddy Bob Jooseyo - V5 formal with conversation';
const get=name=>w.nodes.find(n=>n.name===name);
const request=get('Build Gemini request');
request.parameters.jsCode=request.parameters.jsCode.replace('const system=', "fields.action.enum.push('chat');\nfields.answer={type:['string','null']};\nconst system=");
const rules=`\nConversation routing:
Use action=chat and answer for greetings, thanks (고맙다/고마워/감사합니다), casual conversation and general questions that do not request a stored-data operation. For 고맙다 answer e.g. 아버님, 필요하시면 말씀해 주세요. Do not ask for child/feeding amounts just because the input is not a command. Answer in concise respectful Korean, address 아버님, no spouse persona or casual speech. No Markdown.
For incomplete/ambiguous record changes or pending approvals, use clarify or decision, NOT chat. A thank-you does not approve a pending change. Reading actual records should use history/status/healthhistory/care_list instead of inventing data. chat never writes/edits/deletes/schedules anything; never claim a successful operation or promise a reminder was configured. Do not diagnose or prescribe drug doses. General childcare questions may get brief general information; concerning symptoms require medical evaluation guidance. API/provider failures must stay errors, not guessed conversational responses.
`;
request.parameters.jsCode=request.parameters.jsCode.replace('text:system +','text:system + '+JSON.stringify(rules)+' +');
const validator=get('Validate Gemini intent');
const branch=`
// Conversation replies are sent directly to Telegram. They never enter the mutation RPC.
if(v && v.action==='chat'){
 if(typeof v.confidence!=='number'||v.confidence<0.5||v.confidence>1||typeof v.answer!=='string'||!v.answer.trim()||v.answer.length>1800)return clarify(ask);
 let answer=v.answer.trim();
 if(/(?:저장|기록|삭제|설정|예약|수정)(?:을|를)?\\s*(?:했|해뒀|완료|되었|됐)/.test(answer))return clarify('아버님, 실제 기록이나 설정의 확인이 필요합니다. 원하시는 조회 내용을 말씀해 주세요.');
 if(!answer.startsWith('아버님'))answer='아버님, '+answer;
 return [{json:{...base,action:'chat',reply:answer,buttons:[]}}];
}
`;
validator.parameters.jsCode=validator.parameters.jsCode.replace("if (!v || typeof v!=='object'",branch+"\nif (!v || typeof v!=='object'");
// Unknown short messages need intent interpretation too; do not reject thanks before Gemini.
const quick=get('Resolve short replies');
const start=quick.parameters.jsCode.indexOf('}else if(!action && c.pending && text.length<=6');
if(start<0)throw new Error('Unexpected quick reply source');
const end=quick.parameters.jsCode.indexOf('\nlet m;',start);
quick.parameters.jsCode=quick.parameters.jsCode.slice(0,start)+'}'+quick.parameters.jsCode.slice(end);
w.nodes.push({id:'conversation-if',name:'Is conversation?',type:'n8n-nodes-base.if',typeVersion:2.2,position:[1650,250],parameters:{conditions:{options:{typeValidation:'strict',version:2},conditions:[{id:'chat',leftValue:'={{ $json.action }}',rightValue:'chat',operator:{type:'string',operation:'equals'}}],combinator:'and'}}});
w.connections['Validate Gemini intent']={main:[[{node:'Is conversation?',type:'main',index:0}]]};
w.connections['Is conversation?']={main:[[{node:'Send reply',type:'main',index:0}],[{node:'Process command',type:'main',index:0}]]};
w.active=false;
fs.writeFileSync('n8n/daddy-bob-jooseyo-v5-conversation.json',JSON.stringify(w,null,2)+'\n');
fs.mkdirSync('updates/conversation',{recursive:true});
for(const name of ['Build Gemini request','Validate Gemini intent','Resolve short replies'])fs.writeFileSync('updates/conversation/'+name+'.js',get(name).parameters.jsCode+'\n');
console.log('Built conversation routing and three replacement node code files. No SQL changes.');
