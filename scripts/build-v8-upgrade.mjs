import fs from 'node:fs';
const files=['daddy_bob_jooseyo_formal_tone.sql','daddy_bob_jooseyo_v6.sql','daddy_bob_jooseyo_korean_io.sql','daddy_bob_jooseyo_v7.sql','daddy_bob_jooseyo_v8.sql'];
const guard=`-- V5 -> V8 additive upgrade for V10 n8n. Preserves existing records.
begin;
do $$ begin
 if to_regprocedure('public.daddy_bob_jooseyo_bot_v5(text,text,jsonb)') is null then
  raise exception 'V5 SQL is required before this upgrade';
 end if;
end $$;\n`;
const body=files.map(f=>'-- Source: '+f+'\n'+fs.readFileSync('supabase/'+f,'utf8').replace(/^begin;\s*$/gm,'').replace(/^commit;\s*$/gm,'').replace(/^notify pgrst, 'reload schema';\s*$/gm,'').replace(/^select fed_at, fed_at_utc, fed_at_kst.*$/gm,'')).join('\n');
fs.writeFileSync('supabase/daddy_bob_jooseyo_v5_to_v8.sql',guard+body+"\nnotify pgrst, 'reload schema';\ncommit;\nselect to_regprocedure('public.daddy_bob_jooseyo_bot_v8(text,text,jsonb)') is not null as v8_ready;\n");
