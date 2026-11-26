import fs from 'node:fs';
const w=JSON.parse(fs.readFileSync('n8n/daddy-bob-jooseyo-v2.json','utf8'));
w.name='Daddy Bob Jooseyo - V3 GPT and quiet hours';
const parser=fs.readFileSync('scripts/bot-v2-parse.js','utf8')
 .replace("else if (/^\\/children$/i.test(text)) action = 'children';",`else if (/^\\/children$/i.test(text)) action = 'children';
else if ((m = text.match(/^\\/sleep\\s+(.+?)\\s+(\\d{2}:\\d{2})\\s+(\\d{2}:\\d{2})$/i))) {
 action='sleep';args={name:m[1],enabled:true,start:m[2],end:m[3]};
} else if ((m = text.match(/^\\/sleep\\s+(.+?)\\s+off$/i))) {
 action='sleep';args={name:m[1],enabled:false};
}`)
 .replace("action,args,callback_id:cb?.id || ''", "action,args,raw_text:text,callback_id:cb?.id || ''");
w.nodes.find(n=>n.name==='Normalize update').parameters.jsCode=parser;
const rpc='https://tvymznlclqilemgeczdd.supabase.co/rest/v1/rpc/daddy_bob_jooseyo_bot';
const append=(id,name,type,version,parameters,pos,extra={})=>w.nodes.push({id,name,type:'n8n-nodes-base.'+type,typeVersion:version,position:pos,parameters,...extra});
append('context','Get chat context','httpRequest',4.2,{method:'POST',url:rpc,authentication:'predefinedCredentialType',nodeCredentialType:'supabaseApi',sendBody:true,contentType:'json',specifyBody:'json',jsonBody:"={{ JSON.stringify({p_chat_id:$json.chat_id,p_action:'context',p_args:{ } }) }}",options:{timeout:20000}},[650,160]);
append('gpt-request','Build GPT request','code',2,{jsCode:fs.readFileSync('scripts/bot-v3-request.js','utf8')},[870,160]);
append('gpt','GPT intent and yes-no','httpRequest',4.2,{method:'POST',url:'https://api.openai.com/v1/chat/completions',authentication:'predefinedCredentialType',nodeCredentialType:'openAiApi',sendBody:true,contentType:'json',specifyBody:'json',jsonBody:'={{ JSON.stringify($json.request) }}',options:{timeout:45000}},[1090,160],{onError:'continueRegularOutput'});
append('validate','Validate GPT intent','code',2,{jsCode:fs.readFileSync('scripts/bot-v3-validate.js','utf8')},[1310,160]);
w.connections['Is callback?'].main[1]=[{node:'Get chat context',type:'main',index:0}];
for(const [a,b] of [['Get chat context','Build GPT request'],['Build GPT request','GPT intent and yes-no'],['GPT intent and yes-no','Validate GPT intent'],['Validate GPT intent','Process command']]) w.connections[a]={main:[[{node:b,type:'main',index:0}]]};
for(const n of w.nodes){if(['Process command','Format response','Send reply'].includes(n.name))n.position[0]+=700;if(n.name==='Normalize update')n.notes='허용된 개인 계정만 통과합니다. 텍스트는 GPT로 해석하고 버튼 콜백은 정확한 토큰으로 직접 처리합니다.';}
fs.writeFileSync('n8n/daddy-bob-jooseyo-v3.json',JSON.stringify(w,null,2)+'\n');
console.log('Built inactive V3 workflow: scoped context → GPT structured intent → validator → confirmation-aware RPC.');
