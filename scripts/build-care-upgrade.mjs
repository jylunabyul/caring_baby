import fs from 'node:fs';
const read=file=>fs.readFileSync('supabase/'+file,'utf8');
const v4=read('daddy_bob_jooseyo_v4.sql');
const v5=read('daddy_bob_jooseyo_v5.sql');
const body=text=>text.slice(text.indexOf('begin;')+6,text.lastIndexOf('commit;'));
const check=v5.slice(v5.lastIndexOf('commit;')+7);
fs.writeFileSync('supabase/daddy_bob_jooseyo_v5_upgrade.sql',
 '-- Apply to an existing V3 or V4 installation. V4 + V5 in ONE transaction; existing data is preserved.\nbegin;\n'+body(v4)+'\n'+body(v5)+'\ncommit;\n'+check);
console.log('Built atomic V3/V4 → V5 upgrade SQL.');
