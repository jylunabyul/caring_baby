import fs from 'node:fs';
const w=JSON.parse(fs.readFileSync('n8n/daddy-bob-jooseyo-v9.json','utf8'));
w.name='Daddy Bob Jooseyo - V10 special event records';
const get=name=>w.nodes.find(n=>n.name===name);
const rules=`
Special event recording (use the existing health note storage, not a new action):
- Record actual bowel movements, hospital/clinic visits, vaccinations, vomiting, accidents and other notable childcare events as action=health, health_kind=note, note=the user's factual description prefixed with a short category such as [대변], [병원진료], [예방접종], [구토], [이벤트].
- "별이 대변 봤어" -> health note "[대변] 대변을 봄". "별이 병원에서 감기 진료 받았어" -> health note "[병원진료] 병원에서 감기 진료를 받음". Do not invent stool color, diagnosis, medication, dose, or examination results.
- Past event times such as 오늘 오후 1시, 어제 오전 10시 use Korean civil time exactly as for feeding. If not specified time=null (server confirmation time). A clinic appointment in the future is not a completed visit: ask for clarification rather than record it as actual attendance.
- Infer a child only if exactly one is registered; otherwise ask which child. Do not assign an event to an arbitrary child.
- A message with bowel movement + clinic visit + feeding contains distinct operations: use batch with one operation per actual event and preserve each stated timestamp. Use existing confirmation before saving. Planned medication is a schedule, never an actual dose.
- Event history uses healthhistory; a full day's events use daily_timeline so events appear alongside feeding, temperature and sleep in chronological order. Thank-you/chat statements are not events.
`;
const req=get('Build Gemini request');
req.parameters.jsCode=req.parameters.jsCode.replace('text:system +','text:system + '+JSON.stringify(rules)+' +');
const quick=get('Resolve short replies');const index=quick.parameters.jsCode.lastIndexOf('return [{json:');
quick.parameters.jsCode=quick.parameters.jsCode.slice(0,index)+`if(!action && (m=text.match(/^\\/event\\s+(\\S+)\\s+([\\s\\S]+)$/i))){action='health';Object.assign(args,{name:m[1],health_kind:'note',note:'[이벤트] '+m[2]});}
`+quick.parameters.jsCode.slice(index);
fs.writeFileSync('n8n/daddy-bob-jooseyo-v10.json',JSON.stringify(w,null,2)+'\n');
console.log('Built V10: special events as confirmed health notes, included in daily reports. No SQL changes.');
