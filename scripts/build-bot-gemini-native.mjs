import fs from 'node:fs';
const w=JSON.parse(fs.readFileSync('n8n/daddy-bob-jooseyo-gemini.json','utf8'));
w.name='Daddy Bob Jooseyo - Google Gemini native node';
const oldName='Gemini intent and yes-no';
const name='Google Gemini - Message a model';
const node=w.nodes.find(n=>n.name===oldName);
node.name=name;
node.type='@n8n/n8n-nodes-langchain.googleGemini';
node.typeVersion=1;
node.parameters={
 resource:'text',operation:'message',
 modelId:{__rl:true,mode:'id',value:'models/gemini-2.5-flash'},
 messages:{values:[{role:'user',content:'={{ $json.request.contents[0].parts[0].text }}'}]},
 simplify:false,jsonOutput:true,
 options:{
  systemMessage:"={{ $json.request.systemInstruction.parts[0].text + '\\nReturn exactly one JSON object matching these fields and types. Set all unused fields to null. confidence must be a number from 0 to 1, not a percentage. No Markdown or extra prose. Output schema: ' + JSON.stringify($json.request.generationConfig.responseSchema) }}",
  temperature:0,maxOutputTokens:2048,thinkingBudget:0
 }
};
node.notes='n8n 기본 Google Gemini → Text → Message a Model. Google Gemini(PaLM) API 자격 증명에서 API 키를 연결하세요. Simplify Output=false, Output Content as JSON=true를 유지합니다. 모델은 계정에서 사용 가능한 것으로 선택하세요.';
for(const [source,outputs] of Object.entries(w.connections)){
 for(const group of outputs.main||[])for(const edge of group)if(edge.node===oldName)edge.node=name;
 if(source===oldName){w.connections[name]=outputs;delete w.connections[source];}
}
fs.writeFileSync('n8n/daddy-bob-jooseyo-gemini-native.json',JSON.stringify(w,null,2)+'\n');
console.log('Generated native Google Gemini Message a Model workflow (googlePalmApi credentials).');
