import fs from 'node:fs';
const replacements=[
 ['Clarifying questions address the user as 오빠, in warm, concise Korean mixing casual and polite endings, without claiming you are his spouse.', 'Clarifying questions address the user only as 아버님. Use short, respectful Korean honorific sentences, ending in 입니다 or 해주세요. Do not use casual speech, affectionate nicknames, or a spouse persona.'],
 ['오빠가','아버님이'],['오빠','아버님'],['기록해뒀어','기록했습니다'],['설정해뒀어','설정했습니다'],['바꿔뒀어','변경했습니다'],
 ['이대로 남겨둘까?','이대로 기록할까요?'],['이대로 설정할까?','이대로 설정할까요?'],['미뤄줄까','미룰까요'],['바꿀까','변경할까요'],
 ['수유 챙겨주자.','수유를 챙겨주세요.'],['아침이야 ☀️','아침입니다.'],['확인 시간이야.','확인할 시간입니다.'],['확인할 시간이야 🌡️','확인할 시간입니다.'],
 ['특이사항 최근 기록이야.','최근 특이사항 기록입니다.'],['현재 건강 알림 설정이야.','현재 건강 알림 설정입니다.'],
 ['아직 기록은 없어.','아직 기록이 없습니다.'],['켜진 알림은 없어.','켜진 알림이 없습니다.'],['없는 알림이야.','없는 알림입니다.'],
 ['기록이나 알림은 바꾸지 않았어.','기록과 알림은 변경하지 않았습니다.'],['취소했어.','취소했습니다.'],
 ['기록은 그대로 둘게.','기록은 유지합니다.'],['실제 기록은 그대로 둘게.','실제 기록은 유지합니다.'],
 ['못 찾았어.','찾지 못했습니다.'],['확인하지 못했어.','확인하지 못했습니다.'],['기록 지웠어.','기록을 삭제했습니다.'],
 ['기록이 필요해.','기록이 필요합니다.'],['조금 애매하네.','내용이 명확하지 않습니다.'],['이야기야, 아버님?','기록인가요, 아버님?'],
 ['저장한 거야.','저장한 계획입니다.'],['기준이야.','기준입니다.'],['계획은 ','계획은 '],['ml야.','ml입니다.'],
 ['앞으로 중지할 때까지 반복할게.','중지할 때까지 반복합니다.'],['중지할 때까지 반복할게.','중지할 때까지 반복합니다.'],
 ['다시 셀게.','다시 계산합니다.'],['중지했어.','중지했습니다.'],['미뤘어.','미뤘습니다.'],['만든 건 아니야.','만들지는 않습니다.'],
 ['만들지는 않을게.','만들지 않습니다.'],['기록하지 않을게.','기록하지 않습니다.'],['정하지 않을게.','정하지 않습니다.'],
 ['알려줄게.','알려드리겠습니다.'],['정해줘.','정해주세요.'],['말해줘.','말씀해 주세요.'],['알려줘.','알려주세요.'],
 ['확인해줘.','확인해 주세요.'],['눌러줘.','눌러주세요.'],['골라줘.','선택해 주세요.'],['설정할게.','설정합니다.'],['골라줘','선택해 주세요'],
 ['먼저 바꿔줘.','먼저 변경해 주세요.'],['야간 알림만 쉬도록 할게.','야간 알림은 중지합니다.'],['이 알림만 쉬도록 할게.','이 알림은 중지합니다.'],
 ['설정을 마칠 수 있어.','설정을 완료할 수 있습니다.'],['지나.','지납니다.'],['기존 알림은 그대로 둘게.','기존 알림은 유지합니다.']
];
const convert=s=>replacements.reduce((v,[a,b])=>v.split(a).join(b),s);
const walk=x=>typeof x==='string'?convert(x):Array.isArray(x)?x.map(walk):x&&typeof x==='object'?Object.fromEntries(Object.entries(x).map(([k,v])=>[k,walk(v)])):x;
const w=walk(JSON.parse(fs.readFileSync('n8n/daddy-bob-jooseyo-v5.json','utf8')));
w.name='Daddy Bob Jooseyo - V5 formal father tone';
fs.writeFileSync('n8n/daddy-bob-jooseyo-v5-formal.json',JSON.stringify(w,null,2)+'\n');
const v4=fs.readFileSync('supabase/daddy_bob_jooseyo_v4.sql','utf8');
const v5=fs.readFileSync('supabase/daddy_bob_jooseyo_v5.sql','utf8');
let sql=convert(v4.slice(v4.indexOf('create or replace function public.daddy_bob_jooseyo_tone('),v4.lastIndexOf('commit;'))+'\n'+v5.slice(v5.indexOf('create or replace function public.daddy_bob_jooseyo_bot_v5('),v5.lastIndexOf('commit;')));
sql=sql.replace("left(t,2)<>'아버님'", "left(t,3)<>'아버님'");
sql=sql.replace(' if left(t,3)', " t:=replace(t,' 수유 기록 리마인더',' 수유할 시간입니다.');\n if left(t,3)");
fs.writeFileSync('supabase/daddy_bob_jooseyo_formal_tone.sql',
 '-- Requires V5. Message/function text only; no table creation, data deletion or record reset.\nbegin;\n'+sql+'\ncommit;\n');
console.log('Built formal-tone JSON and function-only SQL patch for V5.');
