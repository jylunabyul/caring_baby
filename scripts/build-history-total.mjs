import fs from 'node:fs';
const file='supabase/daddy_bob_jooseyo_v8.sql';let sql=fs.readFileSync(file,'utf8');
const marker=" if uid is not null then insert into public.daddy_bob_jooseyo_updates";
const patch=` -- Today totals use every actual feeding in the Korean calendar day, not the last-ten history list.
 if p_action='history' then
  select array_agg(c.id) into ids from public.daddy_bob_jooseyo_children c
   where c.telegram_chat_id=p_chat_id and (c.name=p_args->>'name' or
    (nullif(p_args->>'name','') is null and (select count(*) from public.daddy_bob_jooseyo_children where telegram_chat_id=p_chat_id)=1));
  if cardinality(ids)=1 and r->>'reply' is not null then
   start_at:=((now() at time zone 'Asia/Seoul')::date)::timestamp at time zone 'Asia/Seoul';
   finish_at:=start_at+interval '24 hours';
   select coalesce(sum(amount_ml),0),count(*) into amount,feeds from public.daddy_bob_jooseyo_feedings
    where child_id=any(ids) and fed_at>=start_at and fed_at<finish_at;
   label:='오늘 총 수유량: '||amount||'ml / 1,000ml · '||feeds||'회 (한국 시간)'||E'\\n'||
    case when amount<1000 then '설정 기준까지 남은 양: '||(1000-amount)||'ml'
     when amount=1000 then '설정 기준 1,000ml에 도달했습니다.'
     else '설정 기준보다 '||(amount-1000)||'ml 초과했습니다.' end;
   r:=r||jsonb_build_object('today_total_ml',amount,'today_feed_count',feeds,'daily_reference_ml',1000,
    'reply',label||E'\\n\\n'||(r->>'reply'));
  end if;
 end if;
`;
if(!sql.includes('today_total_ml'))sql=sql.replace(marker,patch+marker);
fs.writeFileSync(file,sql);
fs.writeFileSync('supabase/daddy_bob_jooseyo_history_total.sql',sql.replace('-- Apply AFTER V7. Adds a read-only clinical timeline RPC; existing records are preserved.','-- Apply after V8. Replaces V8 RPC only; existing records are preserved.')+"\nnotify pgrst, 'reload schema';\n");
