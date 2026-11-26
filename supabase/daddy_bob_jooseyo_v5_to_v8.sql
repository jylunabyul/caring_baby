-- V5 -> V8 additive upgrade for V10 n8n. Preserves existing records.
begin;
do $$ begin
 if to_regprocedure('public.daddy_bob_jooseyo_bot_v5(text,text,jsonb)') is null then
  raise exception 'V5 SQL is required before this upgrade';
 end if;
end $$;
-- Source: daddy_bob_jooseyo_formal_tone.sql
-- Requires V5. Message/function text only; no table creation, data deletion or record reset.

create or replace function public.daddy_bob_jooseyo_tone(p_text text)
returns text language plpgsql immutable set search_path=pg_catalog as $$
declare t text:=p_text;
begin
 if t is null then return null; end if;
 t:=replace(t,'저장 완료','기록했습니다');
 t:=replace(t,'ml를 저장할까요?','ml, 이대로 기록할까요?');
 t:=replace(t,'확인해 주세요','확인해줘');
 t:=replace(t,'알려주세요','알려줘');
 t:=replace(t,'입력해 주세요','입력해줘');
 t:=replace(t,'취소했어요. 기록은 변경하지 않았습니다.','취소했습니다. 기록은 유지합니다.');
 t:=replace(t,'수유 기록을 수정했어요.','수유 기록 변경했습니다.');
 t:=replace(t,'수유 기록 삭제 완료.','수유 기록을 삭제했습니다.');
 t:=replace(t,'알림 시간 설정을 변경했어요.','알림 시간 변경했습니다.');
 t:=replace(t,' 수유 기록 리마인더',' 수유할 시간입니다.');
 if left(t,3)<>'아버님' then t:='아버님, '||t; end if;
 return t;
end;
$$;
revoke all on function public.daddy_bob_jooseyo_tone(text) from public,anon,authenticated;
grant execute on function public.daddy_bob_jooseyo_tone(text) to service_role;

-- p_at is internal to the delivery mark, supplied from n8n's local trusted state, not a model.
create or replace function public.daddy_bob_jooseyo_bot_v4(p_chat_id text,p_action text,p_args jsonb default '{}'::jsonb)
returns jsonb language plpgsql security definer set search_path=pg_catalog,public,auth
as $v4$
declare
 act text:=p_action; args jsonb:=p_args; uid text:=p_args->>'update_id';
 r jsonb; pending jsonb; msg jsonb; messages jsonb:='[]'; buttons jsonb:='[]';
 ch public.daddy_bob_jooseyo_children; h public.daddy_bob_jooseyo_health;
 rec record; t timestamptz:=now(); local_day date:=(now() at time zone 'Asia/Seoul')::date;
 local_clock time:=(now() at time zone 'Asia/Seoul')::time;
 reply text; token text; ok boolean:=false; hint_at timestamptz;
begin
 if auth.role() is distinct from 'service_role' or p_chat_id is distinct from '9114513581' then raise exception 'Not authorized'; end if;
 perform pg_advisory_xact_lock(9114513581::bigint);
 if uid is not null and exists(select 1 from public.daddy_bob_jooseyo_updates where update_id=uid) then
   return jsonb_build_object('chat_id',p_chat_id,'silent',true,'buttons','[]'::jsonb);
 end if;
 select s.state into pending from public.daddy_bob_jooseyo_sessions s where s.chat_id=p_chat_id and expires_at>now();

 if act='context' then
   r:=public.daddy_bob_jooseyo_bot(p_chat_id,'context','{}'::jsonb);
   return r||jsonb_build_object('health_recent',coalesce((select jsonb_agg(to_jsonb(x)) from (
    select hh.id,cc.name,hh.kind,hh.occurred_at,hh.temperature_c,hh.medicine,hh.dose,hh.dose_unit,hh.note
    from public.daddy_bob_jooseyo_health hh join public.daddy_bob_jooseyo_children cc on cc.id=hh.child_id
    where cc.telegram_chat_id=p_chat_id order by hh.occurred_at desc limit 10)x),'[]'::jsonb));
 elsif act='due' then
   -- Claim each morning delivery for ten minutes: concurrent 08:00/15-minute runs cannot both send it.
   for rec in
    update public.daddy_bob_jooseyo_children set morning_claim_until=now()+interval '10 minutes'
    where telegram_chat_id=p_chat_id and active and morning_enabled
     and local_clock>=morning_time and local_clock<morning_end
     and morning_sent_on is distinct from local_day
     and (morning_claim_until is null or morning_claim_until<=now())
    returning id,name,morning_plan_ml
   loop
    messages:=messages||jsonb_build_array(jsonb_build_object('chat_id',p_chat_id,'child_id',rec.id,
     'kind','morning','delivery_day',local_day,'buttons',jsonb_build_array(
       jsonb_build_object('text','먹였어','data','fed:'||rec.id),jsonb_build_object('text','아직이야','data','later:'||rec.id)),
     'reply','아버님, 아침입니다. '||rec.name||' 일어났으면 수유를 챙겨주세요.'||E'\n아버님이 정해둔 아침 수유 계획은 '||rec.morning_plan_ml||'ml입니다. 이미 먹였으면 또 먹이지 말고 실제 먹은 양만 알려주세요.'||E'\n아기 상태와 의료진 지침을 우선해 주세요.'));
   end loop;
   r:=public.daddy_bob_jooseyo_bot(p_chat_id,'due','{}'::jsonb);
   for msg in select value from jsonb_array_elements(r->'messages') loop
    -- Avoid two feeding prompts in the morning window; the morning plan has its own delivery marker.
    if msg->>'kind'='feeding' and exists(select 1 from public.daddy_bob_jooseyo_children
      where id=(msg->>'child_id')::uuid and morning_enabled and local_clock>=morning_time and local_clock<morning_end) then continue; end if;
    messages:=messages||jsonb_build_array(msg||jsonb_build_object('reply',public.daddy_bob_jooseyo_tone(msg->>'reply')));
   end loop;
   return jsonb_build_object('messages',messages);
 elsif act='mark' and args->>'kind'='morning' then
   -- A delayed response cannot mark tomorrow's morning plan as sent.
   if (args->>'delivery_day')::date=local_day then
    update public.daddy_bob_jooseyo_children set morning_sent_on=local_day,morning_claim_until=null
     where id=(args->>'child_id')::uuid and telegram_chat_id=p_chat_id;
   end if;
   return jsonb_build_object('ok',true);
 elsif act='skip' then
   r:=jsonb_build_object('chat_id',p_chat_id,'silent',true,'buttons','[]'::jsonb);
 elsif act in ('clarify','quiet_clarify') then
   select last_hint_at into hint_at from public.daddy_bob_jooseyo_chat_guard where chat_id=p_chat_id;
   if (pending is not null and coalesce((pending->>'hint_sent')::boolean,false)) or hint_at>now()-interval '2 minutes' then
    r:=jsonb_build_object('chat_id',p_chat_id,'silent',true,'buttons','[]'::jsonb);
   else
    insert into public.daddy_bob_jooseyo_chat_guard values(p_chat_id,now())
     on conflict(chat_id) do update set last_hint_at=excluded.last_hint_at;
    update public.daddy_bob_jooseyo_sessions set state=state||jsonb_build_object('hint_sent',true) where chat_id=p_chat_id and expires_at>now();
    r:=jsonb_build_object('chat_id',p_chat_id,'reply',public.daddy_bob_jooseyo_tone(coalesce(args->>'question','내용이 명확하지 않습니다. 확인 버튼을 눌러주거나 바꿀 내용만 알려주세요.')),'buttons','[]'::jsonb);
   end if;
 else
   -- New health/morning actions use the same one-time confirmation session as feeding.
   if act in ('confirm','decision') and pending->>'action' in ('health','morning') then
    token:=case when act='confirm' then args->>'token' else args->>'expected_token' end;
    if token is distinct from pending->>'token' or (act='decision' and jsonb_typeof(args->'decision') is distinct from 'boolean') then
     r:=jsonb_build_object('chat_id',p_chat_id,'silent',true,'buttons','[]'::jsonb);
    elsif act='decision' and not (args->>'decision')::boolean then
     delete from public.daddy_bob_jooseyo_sessions where chat_id=p_chat_id;
     r:=jsonb_build_object('chat_id',p_chat_id,'reply','아버님, 취소했습니다. 기록은 유지합니다.','buttons','[]'::jsonb);
    else act:=pending->>'action';args:=pending->'args';ok:=true;end if;
   end if;
   if r is null and act in ('health','healthhistory','morning') then
    select * into ch from public.daddy_bob_jooseyo_children where telegram_chat_id=p_chat_id and name=args->>'name' for update;
    if ch.id is null then
     r:=jsonb_build_object('chat_id',p_chat_id,'reply','아버님, 아이 이름을 찾지 못했습니다. /children에서 한 번 확인해 주세요.','buttons','[]'::jsonb);
    elsif act='healthhistory' then
     select string_agg(to_char(hh.occurred_at at time zone 'Asia/Seoul','MM-DD HH24:MI')||' · '||case hh.kind
       when 'temperature' then '체온 '||hh.temperature_c||'℃'
       when 'medicine' then hh.medicine||' '||hh.dose||hh.dose_unit
       else hh.note end,E'\n' order by hh.occurred_at desc) into reply
      from (select * from public.daddy_bob_jooseyo_health where child_id=ch.id order by occurred_at desc limit 10)hh;
     r:=jsonb_build_object('chat_id',p_chat_id,'reply','아버님, '||ch.name||E' 최근 특이사항 기록입니다.\n'||coalesce(reply,'아직 기록이 없습니다.'),'buttons','[]'::jsonb);
    else
     if act='health' then
      t:=coalesce((args->>'time')::timestamptz,now());
      if t>now() then raise exception 'Future health event is not allowed';end if;
      if (t at time zone 'Asia/Seoul')::date<ch.date_of_birth then raise exception 'Health event predates birth date';end if;
      if args->>'health_kind' not in ('temperature','medicine','note') or args->>'health_kind' is null then raise exception 'Invalid health kind';end if;
      if args->>'health_kind'='temperature' and ((args->>'temperature')::numeric not between 30 and 45 or args->>'temperature' is null) then raise exception 'Invalid temperature';end if;
      if args->>'health_kind'='medicine' and (nullif(trim(args->>'medicine'),'') is null or args->>'dose' is null or (args->>'dose')::numeric<=0 or args->>'dose_unit' is null or args->>'dose_unit' not in ('ml','mg','g','방울','정','포')) then raise exception 'Medicine name, actual dose and unit are required';end if;
      if args->>'health_kind'='note' and nullif(trim(args->>'note'),'') is null then raise exception 'Note is required';end if;
      reply:=case args->>'health_kind' when 'temperature' then '체온 '||(args->>'temperature')||'℃'
       when 'medicine' then '투약 '||(args->>'medicine')||' '||(args->>'dose')||(args->>'dose_unit')
       else args->>'note' end;
      if not ok then args:=args||jsonb_build_object('time',t);end if;
     else
      if jsonb_typeof(args->'enabled') is distinct from 'boolean' or (args->>'plan_ml')::integer not between 1 and 1000 or args->>'plan_ml' is null then raise exception 'Invalid morning plan';end if;
      reply:='아침 알림 '||case when (args->>'enabled')::boolean then '08:00~09:00, 아버님이 정한 계획 '||(args->>'plan_ml')||'ml' else '끄기' end;
     end if;
     if not ok then
      token:=gen_random_uuid()::text;
      insert into public.daddy_bob_jooseyo_sessions values(p_chat_id,jsonb_build_object('action',act,'args',args,'token',token),now()+interval '15 minutes')
       on conflict(chat_id) do update set state=excluded.state,expires_at=excluded.expires_at;
      buttons:=jsonb_build_array(jsonb_build_object('text','응, 맞아','data','confirm:'||token),jsonb_build_object('text','아니, 취소','data','cancel'));
      reply:='아버님, '||ch.name||' '||reply||case when act='health' then E'\n시각: '||to_char(t at time zone 'Asia/Seoul','MM-DD HH24:MI') else '' end||E'\n이대로 기록할까요?';
     else
      delete from public.daddy_bob_jooseyo_sessions where chat_id=p_chat_id;
      if act='health' then
       insert into public.daddy_bob_jooseyo_health(child_id,kind,occurred_at,temperature_c,medicine,dose,dose_unit,note)
        values(ch.id,args->>'health_kind',t,(args->>'temperature')::numeric,args->>'medicine',(args->>'dose')::numeric,args->>'dose_unit',args->>'note') returning * into h;
       reply:='아버님, '||ch.name||' '||reply||' 기록했습니다. ('||to_char(t at time zone 'Asia/Seoul','MM-DD HH24:MI')||')';
      else
       update public.daddy_bob_jooseyo_children set morning_enabled=(args->>'enabled')::boolean,morning_plan_ml=case when (args->>'enabled')::boolean then (args->>'plan_ml')::integer else morning_plan_ml end where id=ch.id;
       reply:='아버님, 아침 알림 설정했습니다. 먹은 양은 알림만으로 기록하지 않습니다.';
      end if;
     end if;
     if act='health' and args->>'health_kind'='temperature' then
      if (args->>'temperature')::numeric>=38 and (t at time zone 'Asia/Seoul')::date<(ch.date_of_birth+interval '3 months')::date then
       reply:=reply||E'\n생후 3개월 미만 아기가 38℃ 이상이면 즉시 의료진에게 연락해 주세요.';
      elsif (args->>'temperature')::numeric>=40 then reply:=reply||E'\n40℃ 이상으로 기록됐어요. 즉시 의료진에게 연락해 주세요.';
      end if;
     elsif act='health' and args->>'health_kind'='medicine' then
      reply:=reply||E'\n실제 투여한 양을 기록하는 기능이에요. 약 용량·투여 간격을 추천하거나 변경하지 않습니다.';
     end if;
     r:=jsonb_build_object('chat_id',p_chat_id,'reply',reply,'buttons',buttons);
    end if;
   end if;
   if r is null then
    -- Repeating the same proposed feeding should not produce a new confirmation prompt/token.
    if act='feed' and pending->>'action'='feed'
      and coalesce(args->>'prepared',args->>'amount')=coalesce(pending->'args'->>'prepared',pending->'args'->>'amount')
      and args->>'amount'=pending->'args'->>'amount'
      and (args->>'name'=pending->'args'->>'name' or exists(select 1 from public.daddy_bob_jooseyo_children
        where id=(pending->'args'->>'child_id')::uuid and name=args->>'name' and telegram_chat_id=p_chat_id))
      and args->>'time' is not distinct from pending->'args'->>'time' then
      r:=jsonb_build_object('chat_id',p_chat_id,'silent',true,'buttons','[]'::jsonb);
    else
     r:=public.daddy_bob_jooseyo_bot(p_chat_id,act,args);
     if r ? 'reply' then r:=r||jsonb_build_object('reply',public.daddy_bob_jooseyo_tone(r->>'reply'));end if;
     if act='help' then r:=r||jsonb_build_object('reply',r->>'reply'||E'\n\n[특이사항]\n별이 체온 38.2도야 / 별이 타이레놀 2.5ml 줬어 / 별이 오늘 기침했어\n별이 특이사항 보여줘\n/temp 별이 38.2\n/medicine 별이 약이름 2.5 ml\n/note 별이 기침했어\n/health 별이\n/morning 별이 200 — 아침 8~9시 계획 알림 설정\n응·웅·ㅇㅇ / 아니·아뇨·ㄴㄴ로 답해도 돼. 애매하면 확인 버튼을 눌러주세요.');end if;
    end if;
   end if;
 end if;
 if uid is not null then
  insert into public.daddy_bob_jooseyo_updates(update_id,response) values(uid,r)
   on conflict(update_id) do update set response=excluded.response;
 end if;
 return r;
end;
$v4$;
revoke all on function public.daddy_bob_jooseyo_bot_v4(text,text,jsonb) from public,anon,authenticated;
grant execute on function public.daddy_bob_jooseyo_bot_v4(text,text,jsonb) to service_role;

create or replace function public.daddy_bob_jooseyo_bot_v5(p_chat_id text,p_action text,p_args jsonb default '{}'::jsonb)
returns jsonb language plpgsql security definer set search_path=pg_catalog,public,auth
as $v5$
declare
 act text:=p_action;args jsonb:=p_args;uid text:=p_args->>'update_id';
 r jsonb;pending jsonb;messages jsonb:='[]';buttons jsonb:='[]';
 ch public.daddy_bob_jooseyo_children;h public.daddy_bob_jooseyo_health;
 plan public.daddy_bob_jooseyo_care_plans;rec record;
 reply text;token text;stamp timestamptz;finish timestamptz;first_due timestamptz;
 gap integer;left_count integer;night boolean;approved boolean:=false;is_new boolean;
 now_clock time:=(now() at time zone 'Asia/Seoul')::time;
begin
 if auth.role() is distinct from 'service_role' or p_chat_id is distinct from '9114513581' then raise exception 'Not authorized';end if;
 perform pg_advisory_xact_lock(9114513581::bigint);
 if uid is not null and exists(select 1 from public.daddy_bob_jooseyo_updates where update_id=uid) then
  return jsonb_build_object('chat_id',p_chat_id,'silent',true,'buttons','[]'::jsonb);
 end if;
 select s.state into pending from public.daddy_bob_jooseyo_sessions s where chat_id=p_chat_id and expires_at>now();
 if act='context' then
  r:=public.daddy_bob_jooseyo_bot_v4(p_chat_id,'context','{}'::jsonb);
  return r||jsonb_build_object('care_plans',coalesce((select jsonb_agg(to_jsonb(x)) from (
    select p.id,c.name,p.kind,p.medicine,p.dose,p.dose_unit,p.interval_minutes,p.anchor_at,p.next_due_at,
     p.overnight,p.end_at,p.remaining,p.active
    from public.daddy_bob_jooseyo_care_plans p join public.daddy_bob_jooseyo_children c on c.id=p.child_id
    where c.telegram_chat_id=p_chat_id and p.active order by p.next_due_at)x),'[]'::jsonb));
 elsif act='care_due' then
  update public.daddy_bob_jooseyo_care_plans set active=false,claim_token=null,claim_until=null
   where active and ((end_at is not null and end_at<now()) or remaining=0);
  for rec in
   update public.daddy_bob_jooseyo_care_plans p set claim_token=gen_random_uuid(),claim_until=now()+interval '2 minutes'
    from public.daddy_bob_jooseyo_children c
    where c.id=p.child_id and c.telegram_chat_id=p_chat_id and c.active and p.active
     and p.next_due_at<=now() and (p.end_at is null or p.end_at>=now())
     and (p.remaining is null or p.remaining>0)
     and (p.claim_until is null or p.claim_until<=now())
     and (p.overnight or not public.daddy_bob_jooseyo_is_quiet('22:00','08:00',now_clock))
   returning p.*,c.name
  loop
   reply:=case rec.kind
    when 'temperature' then '아버님, '||rec.name||' 체온 확인할 시간입니다.'||E'\n아버님이 정한 간격 '||rec.interval_minutes||'분 기준입니다. 실제로 잰 값을 알려주세요.'
    else '아버님, '||rec.name||' 투약 계획 확인할 시간입니다.'||E'\n등록한 계획: '||rec.medicine||' '||rec.dose||rec.dose_unit||' · 간격 '||rec.interval_minutes||'분'||E'\n마지막 실제 투여 시각과 의료진·약 안내를 확인해 주세요. 알림만으로 투약한 기록을 만들지 않습니다.' end;
   messages:=messages||jsonb_build_array(jsonb_build_object('chat_id',p_chat_id,'kind','care',
     'child_id',rec.child_id,'plan_id',rec.id,'claim_token',rec.claim_token,'occurrence_due',rec.next_due_at,
     'reply',reply,'buttons',jsonb_build_array(
      jsonb_build_object('text','30분 미뤄줘','data','care_later:'||rec.id),
      jsonb_build_object('text','이 알림 중지','data','care_stop:'||rec.id))));
  end loop;
  return jsonb_build_object('messages',messages);
 elsif act='mark' and args->>'kind'='care' then
  -- Compare-and-set: stop/snooze/new actual record invalidates an in-flight delivery marker.
  update public.daddy_bob_jooseyo_care_plans set
   next_due_at=next_due_at+make_interval(mins=>interval_minutes)*
    (floor(extract(epoch from(now()-next_due_at))/(interval_minutes*60))+1)::double precision,
   remaining=case when remaining is null then null else greatest(0,remaining-1) end,
   active=remaining is null or remaining>1,
   claim_token=null,claim_until=null,last_sent_at=now(),updated_at=now()
  where id=(args->>'plan_id')::uuid and claim_token=(args->>'claim_token')::uuid
   and next_due_at=(args->>'occurrence_due')::timestamptz and active;
  return jsonb_build_object('ok',true);
 end if;

 if act in ('confirm','decision','care_choice') and pending->>'action'='care_setup' then
  token:=case when act='confirm' then args->>'token' else args->>'expected_token' end;
  if token is distinct from pending->>'token' or
    (act='decision' and jsonb_typeof(args->'decision') is distinct from 'boolean') then
    r:=jsonb_build_object('chat_id',p_chat_id,'silent',true,'buttons','[]'::jsonb);
  elsif act='decision' and not(args->>'decision')::boolean then
    delete from public.daddy_bob_jooseyo_sessions where chat_id=p_chat_id;
    r:=jsonb_build_object('chat_id',p_chat_id,'reply','아버님, 취소했습니다. 기록과 알림은 변경하지 않았습니다.','buttons','[]'::jsonb);
  else
    if act='care_choice' then
     if jsonb_typeof(args->'overnight') is distinct from 'boolean' then raise exception 'Night choice is required';end if;
     night:=(args->>'overnight')::boolean;
    elsif jsonb_typeof(pending->'args'->'overnight')='boolean' then night:=(pending->'args'->>'overnight')::boolean;
    end if;
    if night is null then
     if coalesce((pending->>'night_hint_sent')::boolean,false) then
      r:=jsonb_build_object('chat_id',p_chat_id,'silent',true,'buttons','[]'::jsonb);
     else
      update public.daddy_bob_jooseyo_sessions set state=state||jsonb_build_object('night_hint_sent',true) where chat_id=p_chat_id;
      r:=jsonb_build_object('chat_id',p_chat_id,'reply','아버님, 밤에도 알릴지만 선택해 주세요. 아래 버튼으로 설정을 완료할 수 있습니다.',
       'buttons',jsonb_build_array(jsonb_build_object('text','밤에도 포함해서 설정','data','care_night:'||token),jsonb_build_object('text','낮에만 설정','data','care_day:'||token)));
     end if;
    else
     args:=pending->'args'||jsonb_build_object('overnight',night);act:='care_setup';approved:=true;
    end if;
  end if;
 end if;
 if r is null and act='care_setup' then
  select * into ch from public.daddy_bob_jooseyo_children where telegram_chat_id=p_chat_id and name=args->>'name' for update;
  if ch.id is null then raise exception 'Child not found';end if;
  if args->>'care_kind' is null or args->>'care_kind' not in ('temperature','medicine') then raise exception 'Care kind required';end if;
  if jsonb_typeof(args->'record_new') is distinct from 'boolean' then raise exception 'record_new required';end if;
  is_new:=(args->>'record_new')::boolean;
  gap:=(args->>'interval_minutes')::integer;
  if gap is null or gap not between 15 and 10080 then raise exception 'Interval must be 15..10080 minutes';end if;
  finish:=(args->>'end_at')::timestamptz;
  left_count:=(args->>'reminder_count')::integer;
  if left_count is not null and left_count not between 1 and 1000 then raise exception 'Invalid reminder count';end if;
  if args->'overnight' is not null and args->'overnight'<>'null'::jsonb and jsonb_typeof(args->'overnight')<>'boolean' then raise exception 'Invalid overnight choice';end if;
  if is_new then
   stamp:=coalesce((args->>'time')::timestamptz,now());
   if stamp>now() or (stamp at time zone 'Asia/Seoul')::date<ch.date_of_birth then raise exception 'Invalid health time';end if;
   if args->>'care_kind'='temperature' and (args->>'temperature' is null or (args->>'temperature')::numeric not between 30 and 45) then raise exception 'Actual temperature required';end if;
   if args->>'care_kind'='medicine' and (nullif(trim(args->>'medicine'),'') is null or args->>'dose' is null or (args->>'dose')::numeric<=0 or args->>'dose_unit' is null or args->>'dose_unit' not in ('ml','mg','g','방울','정','포')) then raise exception 'Actual medicine, dose and unit required';end if;
   args:=args||jsonb_build_object('time',stamp);
  else
   if args ? 'anchor_id' then
    select * into h from public.daddy_bob_jooseyo_health where id=(args->>'anchor_id')::uuid and child_id=ch.id and kind=args->>'care_kind';
   else
    select * into h from public.daddy_bob_jooseyo_health where child_id=ch.id and kind=args->>'care_kind'
     and (kind='temperature' or medicine=args->>'medicine') order by occurred_at desc limit 1;
   end if;
   if h.id is null then
    r:=jsonb_build_object('chat_id',p_chat_id,'reply','아버님, 기준이 될 첫 실제 기록이 필요합니다. 잰 체온이나 실제 약 이름·투여량·시각을 먼저 알려주세요.','buttons','[]'::jsonb);
   else
    stamp:=h.occurred_at;
    args:=args||jsonb_build_object('anchor_id',h.id,'medicine',h.medicine,'dose',h.dose,'dose_unit',h.dose_unit);
   end if;
  end if;
  if r is null then
   first_due:=stamp+make_interval(mins=>gap);
   if finish is not null and (finish<=now() or finish<first_due) then raise exception 'End time must include at least the first reminder';end if;
   reply:='아버님, '||ch.name||case args->>'care_kind' when 'temperature' then ' 체온 확인' else ' 투약 계획 '||(args->>'medicine')||' '||(args->>'dose')||(args->>'dose_unit') end||
    E'\n기준 실제 시각: '||to_char(stamp at time zone 'Asia/Seoul','MM-DD HH24:MI')||E'\n간격: '||gap||'분 · 다음 확인: '||to_char(first_due at time zone 'Asia/Seoul','MM-DD HH24:MI')||
    case when finish is null then '' else E'\n종료: '||to_char(finish at time zone 'Asia/Seoul','MM-DD HH24:MI') end||
    case when left_count is null then '' else E'\n알림 횟수: '||left_count end||
    case when finish is null and left_count is null then E'\n아버님이 중지할 때까지 반복합니다.' else '' end;
   if not approved then
    token:=gen_random_uuid()::text;
    insert into public.daddy_bob_jooseyo_sessions values(p_chat_id,jsonb_build_object('action','care_setup','args',args,'token',token),now()+interval '15 minutes')
     on conflict(chat_id) do update set state=excluded.state,expires_at=excluded.expires_at;
    if jsonb_typeof(args->'overnight')='boolean' then
     reply:=reply||case when(args->>'overnight')::boolean then E'\n야간에도 알림 포함. 이대로 설정할까요?' else E'\n22:00~08:00에는 이 알림은 중지합니다. 이대로 설정할까요?' end;
     buttons:=jsonb_build_array(jsonb_build_object('text','응, 설정해줘','data','confirm:'||token),jsonb_build_object('text','취소','data','cancel'));
    else
     reply:=reply||E'\n밤에도 포함할지 선택해 주세요. 선택하면 위 내용으로 설정합니다.';
     buttons:=jsonb_build_array(jsonb_build_object('text','밤에도 포함해서 설정','data','care_night:'||token),jsonb_build_object('text','낮에만 설정','data','care_day:'||token),jsonb_build_object('text','취소','data','cancel'));
    end if;
    if is_new then reply:=reply||E'\n첫 실제 기록도 함께 저장할게.';end if;
   else
    if is_new then
     insert into public.daddy_bob_jooseyo_health(child_id,kind,occurred_at,temperature_c,medicine,dose,dose_unit,note)
      values(ch.id,args->>'care_kind',stamp,(args->>'temperature')::numeric,args->>'medicine',(args->>'dose')::numeric,args->>'dose_unit',args->>'note');
    end if;
    insert into public.daddy_bob_jooseyo_care_plans(child_id,kind,medicine,dose,dose_unit,interval_minutes,anchor_at,next_due_at,overnight,end_at,remaining)
     values(ch.id,args->>'care_kind',case when args->>'care_kind'='medicine' then args->>'medicine' else '' end,
      (args->>'dose')::numeric,args->>'dose_unit',gap,stamp,first_due,(args->>'overnight')::boolean,finish,left_count)
    on conflict(child_id,kind,medicine) do update set dose=excluded.dose,dose_unit=excluded.dose_unit,interval_minutes=excluded.interval_minutes,
     anchor_at=excluded.anchor_at,next_due_at=excluded.next_due_at,overnight=excluded.overnight,end_at=excluded.end_at,
     remaining=excluded.remaining,active=true,claim_token=null,claim_until=null,updated_at=now();
    delete from public.daddy_bob_jooseyo_sessions where chat_id=p_chat_id;
    reply:=reply||E'\n설정했습니다. 실제로 다시 기록하면 그 시각부터 간격을 다시 계산합니다.';
   end if;
   if args->>'care_kind'='medicine' then reply:=reply||E'\n용량과 간격은 아버님이 정한 계획을 저장한 계획입니다. 투약 전에는 의료진·약 안내를 확인해 주세요.';
   elsif is_new then
    if (args->>'temperature')::numeric>=38 and (stamp at time zone 'Asia/Seoul')::date<(ch.date_of_birth+interval '3 months')::date then
     reply:=reply||E'\n생후 3개월 미만 아기가 38℃ 이상이면 즉시 의료진에게 연락해 주세요.';
    elsif (args->>'temperature')::numeric>=40 then reply:=reply||E'\n40℃ 이상으로 기록됐어요. 즉시 의료진에게 연락해 주세요.';end if;
   end if;
   r:=jsonb_build_object('chat_id',p_chat_id,'reply',reply,'buttons',buttons);
  end if;
 elsif r is null and act in ('care_cancel','care_snooze') then
  select p.* into plan from public.daddy_bob_jooseyo_care_plans p join public.daddy_bob_jooseyo_children c on c.id=p.child_id
   where p.id=(args->>'plan_id')::uuid and c.telegram_chat_id=p_chat_id and p.active for update of p;
  if plan.id is null then reply:='아버님, 이미 중지됐거나 없는 알림입니다.';
  elsif act='care_cancel' then
   update public.daddy_bob_jooseyo_care_plans set active=false,claim_token=null,claim_until=null where id=plan.id;
   reply:='아버님, 이 알림은 중지했습니다. 실제 기록은 유지합니다.';
  else
   gap:=(args->>'minutes')::integer;
   if gap is null or gap not between 1 and 1440 then raise exception 'Snooze minutes required';end if;
   if plan.end_at is not null and now()+make_interval(mins=>gap)>plan.end_at then
    reply:='아버님, 그만큼 미루면 정해둔 종료 시각이 지납니다. 기존 알림은 유지합니다. 종료 시각을 먼저 변경해 주세요.';
   else
    update public.daddy_bob_jooseyo_care_plans set next_due_at=now()+make_interval(mins=>gap),claim_token=null,claim_until=null where id=plan.id;
    reply:='아버님, 알림을 '||gap||'분 미뤘습니다. 약 투여 시각을 변경하거나 실제 기록을 만들지는 않습니다.'||case when not plan.overnight then ' 야간이면 오전 8시 이후에 알려드리겠습니다.' else '' end;
   end if;
  end if;
  r:=jsonb_build_object('chat_id',p_chat_id,'reply',reply,'buttons','[]'::jsonb);
 elsif r is null and act='care_list' then
  select string_agg(c.name||' · '||case p.kind when 'temperature' then '체온' else p.medicine end||' · '||p.interval_minutes||'분 간격 · 다음 '||to_char(p.next_due_at at time zone 'Asia/Seoul','MM-DD HH24:MI')||
   case when p.overnight then ' (야간 포함)' else ' (22~08시 쉬기)' end||E'\n알림 ID: '||p.id,E'\n\n') into reply
   from public.daddy_bob_jooseyo_care_plans p join public.daddy_bob_jooseyo_children c on c.id=p.child_id
   where c.telegram_chat_id=p_chat_id and p.active;
  r:=jsonb_build_object('chat_id',p_chat_id,'reply','아버님, 현재 건강 알림 설정입니다.'||E'\n'||coalesce(reply,'켜진 알림이 없습니다.'),'buttons','[]'::jsonb);
 end if;
 if r is null then
  r:=public.daddy_bob_jooseyo_bot_v4(p_chat_id,act,args);
  if act='help' then r:=r||jsonb_build_object('reply',r->>'reply'||E'\n\n[투약·체온 반복 알림]\n별이 지금 37.5도, 2시간마다 체온 확인 알려줘\n별이 약이름 2.5ml 줬어. 6시간마다 3번 알려줘\n별이 체온 알림 2시간 간격으로 설정해줘\n현재 건강 알림 보여줘\n알림을 30분 미뤄줘 / 이 약 알림 중지해줘\n야간 포함 여부는 설정할 때 직접 고르면 돼.');end if;
 end if;
 if uid is not null then
  insert into public.daddy_bob_jooseyo_updates(update_id,response) values(uid,r)
   on conflict(update_id) do update set response=excluded.response;
 end if;
 return r;
end;
$v5$;
revoke all on function public.daddy_bob_jooseyo_bot_v5(text,text,jsonb) from public,anon,authenticated;
grant execute on function public.daddy_bob_jooseyo_bot_v5(text,text,jsonb) to service_role;


-- Source: daddy_bob_jooseyo_v6.sql
-- Requires V5. Preserves existing records; adds fixed medication reminders and transactional batches.

create table if not exists public.daddy_bob_jooseyo_med_slots (
 id uuid primary key default gen_random_uuid(),
 child_id uuid not null references public.daddy_bob_jooseyo_children(id) on delete cascade,
 medicine text not null check(length(trim(medicine))>0),
 dose numeric not null check(dose>0),dose_unit text not null check(dose_unit in ('ml','mg','g','방울','정','포')),
 slot_key text not null,
 next_due_at timestamptz not null,
 repeat_daily boolean not null default false,
 end_at timestamptz,
 active boolean not null default true,
 claim_token uuid,claim_until timestamptz,last_sent_at timestamptz,
 updated_at timestamptz not null default now(),
 unique(child_id,medicine,slot_key)
);
alter table public.daddy_bob_jooseyo_med_slots enable row level security;
revoke all on public.daddy_bob_jooseyo_med_slots from public,anon,authenticated;
grant all on public.daddy_bob_jooseyo_med_slots to service_role;

create or replace function public.daddy_bob_jooseyo_batch_warnings(p_chat_id text,p_operations jsonb)
returns text language plpgsql stable security definer set search_path=pg_catalog,public,auth as $$
declare op jsonb;a jsonb;child public.daddy_bob_jooseyo_children;t timestamptz;warning text;result text:='';
begin
 if auth.role() is distinct from 'service_role' or p_chat_id is distinct from '9114513581' then raise exception 'Not authorized';end if;
 for op in select value from jsonb_array_elements(p_operations) loop
  a:=case when op ? 'args' then op->'args' else op end;
  if ((op->>'action'='health' and a->>'health_kind'='temperature') or(op->>'action'='care_setup' and a->>'care_kind'='temperature' and a->'record_new'='true'::jsonb)) and jsonb_typeof(a->'temperature')='number' then
   select * into child from public.daddy_bob_jooseyo_children where name=a->>'name' and telegram_chat_id=p_chat_id;
   begin t:=coalesce((a->>'time')::timestamptz,now());exception when others then t:=now();end;
   warning:=null;
   if (a->>'temperature')::numeric>=38 and (t at time zone 'Asia/Seoul')::date<(child.date_of_birth+interval '3 months')::date then warning:='생후 3개월 미만 아기가 38℃ 이상이면 즉시 의료진에게 연락해 주세요.';
   elsif (a->>'temperature')::numeric>=40 then warning:='40℃ 이상으로 입력되었습니다. 즉시 의료진에게 연락해 주세요.';end if;
   if warning is not null and position(warning in result)=0 then result:=result||E'\n'||warning;end if;
  end if;
 end loop;
 return result;
end;
$$;
revoke all on function public.daddy_bob_jooseyo_batch_warnings(text,jsonb) from public,anon,authenticated;
grant execute on function public.daddy_bob_jooseyo_batch_warnings(text,jsonb) to service_role;

-- Display only. Absolute stored timestamps and reminder comparisons are unchanged.
create or replace function public.daddy_bob_jooseyo_format_kst(p_at timestamptz)
returns text language sql immutable strict set search_path=pg_catalog as $$
 select to_char(p_at at time zone 'Asia/Seoul','YYYY"년" FMMM"월" FMDD"일" ')||
  case when extract(hour from p_at at time zone 'Asia/Seoul')<12 then '오전 ' else '오후 ' end||
  to_char(p_at at time zone 'Asia/Seoul','FMHH12:MI')||' (한국 시간)';
$$;
revoke all on function public.daddy_bob_jooseyo_format_kst(timestamptz) from public,anon,authenticated;
grant execute on function public.daddy_bob_jooseyo_format_kst(timestamptz) to service_role;

create or replace function public.daddy_bob_jooseyo_bot_v6(p_chat_id text,p_action text,p_args jsonb default '{}'::jsonb)
returns jsonb language plpgsql security definer set search_path=pg_catalog,public,auth
as $v6$
declare
 r jsonb;sub jsonb;pending jsonb;op jsonb;a jsonb;operations jsonb;msg jsonb;
 ch public.daddy_bob_jooseyo_children;slot public.daddy_bob_jooseyo_med_slots;
 rec record;act text:=p_action;uid text:=p_args->>'update_id';
 preview text:='';details text:='';warnings text:='';label text;key text;question text;token text;
 stamp timestamptz;finish timestamptz;is_repeat boolean;
 approved boolean:=false;n integer:=0;failed integer:=0;state_code text;
 allowed text[]:=array['feed','edit','delete','health','care_setup','medicine_schedule','growth','stock','sleep','morning','childadd','reset','childdelete','care_cancel','care_snooze','medicine_cancel','medicine_snooze','children','history','status','healthhistory','care_list'];
begin
 if auth.role() is distinct from 'service_role' or p_chat_id is distinct from '9114513581' then raise exception 'Not authorized';end if;
 perform pg_advisory_xact_lock(9114513581::bigint);
 if uid is not null then
  select response into r from public.daddy_bob_jooseyo_updates where update_id=uid;
  if found then return r||jsonb_build_object('chat_id',p_chat_id,'silent',false,'reply',coalesce(nullif(r->>'reply',''),'아버님, 이미 처리한 요청입니다. 중복 변경하지 않았습니다.'));end if;
 end if;
 select state into pending from public.daddy_bob_jooseyo_sessions where chat_id=p_chat_id and expires_at>now();
 if act='context' then
  r:=public.daddy_bob_jooseyo_bot_v5(p_chat_id,act,'{}'::jsonb);
  return r||jsonb_build_object('fixed_schedules',coalesce((select jsonb_agg(to_jsonb(x)) from(
    select s.id,c.name,s.medicine,s.dose,s.dose_unit,s.next_due_at,s.repeat_daily,s.end_at
    from public.daddy_bob_jooseyo_med_slots s join public.daddy_bob_jooseyo_children c on c.id=s.child_id
    where c.telegram_chat_id=p_chat_id and s.active order by s.next_due_at)x),'[]'::jsonb));
 elsif act='care_due' then
  r:=public.daddy_bob_jooseyo_bot_v5(p_chat_id,act,'{}'::jsonb);
  update public.daddy_bob_jooseyo_med_slots set active=false,claim_token=null,claim_until=null where active and end_at<now();
  for rec in update public.daddy_bob_jooseyo_med_slots s set claim_token=gen_random_uuid(),claim_until=now()+interval '2 minutes'
   from public.daddy_bob_jooseyo_children c where c.id=s.child_id and c.telegram_chat_id=p_chat_id and c.active and s.active
    and s.next_due_at<=now() and(s.end_at is null or s.end_at>=now()) and(s.claim_until is null or s.claim_until<=now())
   returning s.*,c.name
  loop
   msg:=jsonb_build_object('chat_id',p_chat_id,'kind','fixed_medicine','schedule_id',rec.id,'child_id',rec.child_id,
    'claim_token',rec.claim_token,'occurrence_due',rec.next_due_at,
    'reply','아버님, '||rec.name||' 투약 계획을 확인할 시간입니다.'||E'\n등록한 계획: '||rec.medicine||' '||rec.dose||rec.dose_unit||E'\n마지막 실제 투여 시각과 의료진·약 안내를 확인해 주세요. 실제 투약은 별도로 기록해 주세요.',
    'buttons',jsonb_build_array(jsonb_build_object('text','이 일정 중지','data','fixed_stop:'||rec.id),jsonb_build_object('text','30분 미루기','data','fixed_later:'||rec.id)));
   r:=jsonb_set(r,'{messages}',coalesce(r->'messages','[]'::jsonb)||jsonb_build_array(msg));
  end loop;
  return r;
 elsif act='mark' and p_args->>'kind'='fixed_medicine' then
  update public.daddy_bob_jooseyo_med_slots set
   next_due_at=case when repeat_daily then next_due_at+interval '24 hours'*(floor(extract(epoch from(now()-next_due_at))/86400)+1)::double precision else next_due_at end,
   active=repeat_daily,claim_token=null,claim_until=null,last_sent_at=now(),updated_at=now()
   where id=(p_args->>'schedule_id')::uuid and claim_token=(p_args->>'claim_token')::uuid
    and next_due_at=(p_args->>'occurrence_due')::timestamptz and active;
  return jsonb_build_object('ok',true);
 elsif act='batch_draft' then
  operations:=p_args->'draft_operations';question:=left(p_args->>'question',1400);
  if jsonb_typeof(operations) is distinct from 'array' or jsonb_array_length(operations) not between 1 and 12 or length(operations::text)>40000 or question is null then raise exception 'Invalid draft';end if;
  -- Freeze implicit 'now' for the first reported observation while details are being clarified.
  select jsonb_agg(case when x->>'action' in ('feed','health') or(x->>'action'='care_setup' and x->'record_new'='true'::jsonb)
    then case when nullif(x->>'time','') is null then x||jsonb_build_object('time',now()) else x end else x end)
   into operations from jsonb_array_elements(operations)x;
  token:=gen_random_uuid()::text;
  insert into public.daddy_bob_jooseyo_sessions values(p_chat_id,jsonb_build_object('action','batch_draft','operations',operations,'question',question,'token',token),now()+interval '30 minutes')
   on conflict(chat_id) do update set state=excluded.state,expires_at=excluded.expires_at;
  warnings:=public.daddy_bob_jooseyo_batch_warnings(p_chat_id,operations);
  r:=jsonb_build_object('chat_id',p_chat_id,'reply','아버님, 요청을 나누어 확인했습니다. 아직 기록은 변경하지 않았습니다.'||E'\n'||question||warnings,'buttons','[]'::jsonb);
 else
  if act in ('confirm','decision') and pending->>'action' in ('batch','batch_draft') then
   token:=case when act='confirm' then p_args->>'token' else p_args->>'expected_token' end;
   if token is distinct from pending->>'token' or(act='decision' and jsonb_typeof(p_args->'decision') is distinct from 'boolean') then
    r:=jsonb_build_object('chat_id',p_chat_id,'reply','아버님, 확인 요청이 만료되었습니다. 내용을 다시 말씀해 주세요.','buttons','[]'::jsonb);
   elsif act='decision' and not(p_args->>'decision')::boolean then
    delete from public.daddy_bob_jooseyo_sessions where chat_id=p_chat_id;
    r:=jsonb_build_object('chat_id',p_chat_id,'reply','아버님, 취소했습니다. 기존 기록은 유지했습니다.','buttons','[]'::jsonb);
   elsif pending->>'action'='batch_draft' then
    r:=jsonb_build_object('chat_id',p_chat_id,'reply','아버님, 다음 내용을 먼저 확인해 주세요.'||E'\n'||(pending->>'question'),'buttons','[]'::jsonb);
   else act:='batch';operations:=pending->'operations';approved:=true;end if;
  elsif act='batch' then operations:=p_args->'operations';
  end if;
  if r is null and act='batch' then
   if jsonb_typeof(operations) is distinct from 'array' or jsonb_array_length(operations) not between 1 and 12 then raise exception 'Batch must contain 1..12 operations';end if;
   if not approved then
    select jsonb_agg(case when x->>'action' in ('feed','health') or(x->>'action'='care_setup' and x->'args'->'record_new'='true'::jsonb)
      then case when nullif(x->'args'->>'time','') is null then jsonb_set(x,'{args}',x->'args'||jsonb_build_object('time',now())) else x end else x end)
     into operations from jsonb_array_elements(operations)x;
   end if;
   for op in select value from jsonb_array_elements(operations) loop
    if op->>'action' is null or not(op->>'action'=any(allowed)) or jsonb_typeof(op->'args') is distinct from 'object' then raise exception 'Unsupported batch operation';end if;
    a:=op->'args';
    if a ? 'confirmed' or a ? 'token' or a ? 'update_id' then raise exception 'Untrusted batch authorization';end if;
    if op->>'action'='care_setup' and jsonb_typeof(a->'overnight') is distinct from 'boolean' then raise exception 'Night option is required for batch';end if;
    n:=n+1;
    label:=case op->>'action'
     when 'feed' then coalesce(a->>'name','아이')||' 수유 '||(a->>'amount')||'ml / 조유량 '||coalesce(a->>'prepared',a->>'amount')||'ml'
     when 'health' then coalesce(a->>'name','아이')||' '||case a->>'health_kind' when 'temperature' then '체온 '||(a->>'temperature')||'℃' when 'medicine' then (a->>'medicine')||' 실제 투여 '||(a->>'dose')||(a->>'dose_unit') else a->>'note' end
     when 'care_setup' then (a->>'name')||' '||case a->>'care_kind' when 'temperature' then '체온' else a->>'medicine' end||' 확인 알림 '||(a->>'interval_minutes')||'분 간격'||case when(a->>'overnight')::boolean then ' · 야간 포함' else ' · 22~08시 제외' end||
      case when a->'record_new'='true'::jsonb then case a->>'care_kind' when 'temperature' then ' · 첫 체온 '||(a->>'temperature')||'℃ 기록' else ' · 실제 투여 '||(a->>'dose')||(a->>'dose_unit')||' 기록' end else ' · 기존 실제 기록 기준' end||
      case when a ? 'reminder_count' then ' · 알림 '||(a->>'reminder_count')||'회' when a->>'end_at' is null then ' · 중지할 때까지' else '' end
     when 'medicine_schedule' then (a->>'name')||' '||(a->>'medicine')||' '||(a->>'dose')||(a->>'dose_unit')||' 투약 계획 · '||public.daddy_bob_jooseyo_format_kst((a->>'scheduled_at')::timestamptz)||case when(a->>'repeat_daily')::boolean then ' · 매일 반복' else ' · 1회' end||case when(a->>'repeat_daily')::boolean and a->>'end_at' is null then ' · 중지할 때까지' else '' end
     when 'medicine_cancel' then '고정 투약 알림 중지 · ID '||(a->>'schedule_id')
     when 'medicine_snooze' then '고정 투약 알림 '||(a->>'minutes')||'분 미루기 · ID '||(a->>'schedule_id')
     when 'delete' then '수유 한 건 삭제 · ID '||(a->>'feed_id')
     when 'reset' then (a->>'name')||' 수유 기록 전체 삭제'
     when 'childdelete' then (a->>'name')||' 프로필·연결 기록 전체 삭제'
     else coalesce(a->>'name','')||' · '||(op->>'action') end;
    if label is null then raise exception 'Incomplete operation';end if;
    preview:=preview||n||'. '||left(label,350)||case when a ? 'time' then ' · 실제 시각 '||public.daddy_bob_jooseyo_format_kst((a->>'time')::timestamptz) else '' end||case when a ? 'end_at' then ' · 종료 '||public.daddy_bob_jooseyo_format_kst((a->>'end_at')::timestamptz) else '' end||E'\n';
   end loop;
   warnings:=public.daddy_bob_jooseyo_batch_warnings(p_chat_id,operations);
   if not approved then
    token:=gen_random_uuid()::text;
    insert into public.daddy_bob_jooseyo_sessions values(p_chat_id,jsonb_build_object('action','batch','operations',operations,'token',token),now()+interval '15 minutes')
     on conflict(chat_id) do update set state=excluded.state,expires_at=excluded.expires_at;
    r:=jsonb_build_object('chat_id',p_chat_id,'reply','아버님, 아래 '||n||'개 요청을 함께 처리할까요?'||E'\n'||left(preview,3200)||E'\n확인 전에는 기존 기록을 변경하지 않습니다.'||warnings,
      'buttons',jsonb_build_array(jsonb_build_object('text','확인','data','confirm:'||token),jsonb_build_object('text','취소','data','cancel')));
   else
    -- Everything in this nested block is a PostgreSQL subtransaction. One failure rolls ALL changes back.
    begin
     delete from public.daddy_bob_jooseyo_sessions where chat_id=p_chat_id;
     for op in select value from jsonb_array_elements(operations) loop
      failed:=failed+1;a:=op->'args';
      if op->>'action'='medicine_schedule' then
       select * into ch from public.daddy_bob_jooseyo_children where name=a->>'name' and telegram_chat_id=p_chat_id;
       if ch.id is null or nullif(trim(a->>'medicine'),'') is null or a->>'dose' is null or(a->>'dose')::numeric<=0 or a->>'dose_unit' not in ('ml','mg','g','방울','정','포') or a->>'dose_unit' is null or jsonb_typeof(a->'repeat_daily') is distinct from 'boolean' then raise exception 'Invalid medicine schedule';end if;
       stamp:=(a->>'scheduled_at')::timestamptz;finish:=(a->>'end_at')::timestamptz;is_repeat:=(a->>'repeat_daily')::boolean;
       if stamp is null or stamp<=now() or(finish is not null and finish<stamp) then raise exception 'Future exact schedule time required';end if;
       key:=case when is_repeat then 'daily:'||to_char(stamp at time zone 'Asia/Seoul','HH24:MI:SS') else 'once:'||to_char(stamp at time zone 'UTC','YYYYMMDDHH24MISS') end;
       insert into public.daddy_bob_jooseyo_med_slots(child_id,medicine,dose,dose_unit,slot_key,next_due_at,repeat_daily,end_at)
        values(ch.id,a->>'medicine',(a->>'dose')::numeric,a->>'dose_unit',key,stamp,is_repeat,finish)
       on conflict(child_id,medicine,slot_key) do update set dose=excluded.dose,dose_unit=excluded.dose_unit,
        next_due_at=excluded.next_due_at,repeat_daily=excluded.repeat_daily,end_at=excluded.end_at,active=true,claim_token=null,claim_until=null,updated_at=now();
      else
       if op->>'action'<>'childadd' and a ? 'name' and not exists(select 1 from public.daddy_bob_jooseyo_children where name=a->>'name' and telegram_chat_id=p_chat_id) then raise exception 'Child scope missing';end if;
       if a ? 'feed_id' and not exists(select 1 from public.daddy_bob_jooseyo_feedings f join public.daddy_bob_jooseyo_children c on c.id=f.child_id where f.id=(a->>'feed_id')::uuid and c.telegram_chat_id=p_chat_id) then raise exception 'Feeding scope missing';end if;
       sub:=public.daddy_bob_jooseyo_bot_v5(p_chat_id,op->>'action',a);
       select state into pending from public.daddy_bob_jooseyo_sessions where chat_id=p_chat_id and expires_at>now();
       if pending is not null and pending->>'action'=op->>'action' then
        sub:=public.daddy_bob_jooseyo_bot_v5(p_chat_id,'decision',jsonb_build_object('decision',true,'expected_token',pending->>'token'));
       end if;
       if jsonb_array_length(coalesce(sub->'buttons','[]'::jsonb))>0 or exists(select 1 from public.daddy_bob_jooseyo_sessions where chat_id=p_chat_id) then raise exception 'Operation needs more input';end if;
       if sub->>'reply' like '%첫 실제 기록%' or sub->>'reply' like '%찾지 못%' or sub->>'reply' like '%찾을 수 없%' or sub->>'reply' like '%못 찾%' then raise exception 'Record scope could not be resolved';end if;
       if op->>'action' in ('children','history','status','healthhistory','care_list') then details:=details||E'\n'||coalesce(sub->>'reply','');end if;
      end if;
     end loop;
     r:=jsonb_build_object('chat_id',p_chat_id,'ok',true,'reply','아버님, 기록을 업데이트했습니다. ('||n||'개 요청 처리)'||case when details<>'' then E'\n'||left(details,2800) else '' end||warnings,'buttons','[]'::jsonb);
    exception when others then
     get stacked diagnostics state_code=returned_sqlstate;
     delete from public.daddy_bob_jooseyo_sessions where chat_id=p_chat_id and state->>'action'='batch';
     r:=jsonb_build_object('chat_id',p_chat_id,'ok',false,'rolled_back',true,'failed_operation',failed,'error_code',state_code,
      'reply','아버님, '||failed||'번째 요청을 처리하지 못해 이번 묶음의 변경을 모두 되돌렸습니다. 기존 기록은 유지했습니다. 해당 항목을 확인해 다시 말씀해 주세요.'||warnings,'buttons','[]'::jsonb);
    end;
   end if;
  elsif r is null and act in ('medicine_cancel','medicine_snooze') then
   select s.* into slot from public.daddy_bob_jooseyo_med_slots s join public.daddy_bob_jooseyo_children c on c.id=s.child_id
    where s.id=(p_args->>'schedule_id')::uuid and c.telegram_chat_id=p_chat_id and s.active for update of s;
   if slot.id is null then label:='이미 중지됐거나 없는 일정입니다.';
   elsif act='medicine_cancel' then
    update public.daddy_bob_jooseyo_med_slots set active=false,claim_token=null,claim_until=null where id=slot.id;label:='해당 투약 알림을 중지했습니다. 실제 투약 기록은 유지합니다.';
   else
    n:=(p_args->>'minutes')::integer;if n is null or n not between 1 and 1440 then raise exception 'Invalid snooze';end if;
    if slot.end_at is not null and now()+make_interval(mins=>n)>slot.end_at then label:='종료 시각을 넘어 미루지 않았습니다.';
    else update public.daddy_bob_jooseyo_med_slots set next_due_at=now()+make_interval(mins=>n),claim_token=null,claim_until=null where id=slot.id;label:='알림을 '||n||'분 미뤘습니다. 약 투여 시각을 변경하는 지시는 아닙니다.';end if;
   end if;
   r:=jsonb_build_object('chat_id',p_chat_id,'reply','아버님, '||label,'buttons','[]'::jsonb);
  end if;
 end if;
 if r is null then
  begin r:=public.daddy_bob_jooseyo_bot_v5(p_chat_id,p_action,p_args);
  exception when others then
   r:=jsonb_build_object('chat_id',p_chat_id,'ok',false,'rolled_back',true,'reply','아버님, 업데이트하지 못해 이번 요청의 변경을 되돌렸습니다. 기존 기록은 유지했습니다. 입력 내용을 확인해 주세요.','buttons','[]'::jsonb);
  end;
 end if;
 if p_action='care_list' then
  select string_agg(c.name||' · '||s.medicine||' '||s.dose||s.dose_unit||' · 다음 '||to_char(s.next_due_at at time zone 'Asia/Seoul','MM-DD HH24:MI')||case when s.repeat_daily then ' (매일)' else ' (1회)' end||E'\n일정 ID: '||s.id,E'\n') into details
   from public.daddy_bob_jooseyo_med_slots s join public.daddy_bob_jooseyo_children c on c.id=s.child_id where c.telegram_chat_id=p_chat_id and s.active;
  if details is not null then r:=r||jsonb_build_object('reply',coalesce(r->>'reply','아버님, 현재 알림입니다.')||E'\n\n[고정 투약 일정]\n'||details);end if;
 end if;
 if uid is not null then
  if coalesce((r->>'silent')::boolean,false) or nullif(r->>'reply','') is null then
   r:=r||jsonb_build_object('silent',false,'reply',case when p_action in ('clarify','quiet_clarify') then '아버님, '||coalesce(p_args->>'question','변경할 내용을 확인해 주세요.') else '아버님, 요청을 확인했습니다. 추가 변경은 없습니다.' end,'buttons','[]'::jsonb);
  end if;
  r:=r||jsonb_build_object('silent',false);
  insert into public.daddy_bob_jooseyo_updates(update_id,response) values(uid,r) on conflict(update_id) do update set response=excluded.response;
 end if;
 return r;
end;
$v6$;
revoke all on function public.daddy_bob_jooseyo_bot_v6(text,text,jsonb) from public,anon,authenticated;
grant execute on function public.daddy_bob_jooseyo_bot_v6(text,text,jsonb) to service_role;

select to_regprocedure('public.daddy_bob_jooseyo_bot_v6(text,text,jsonb)') is not null as v6_ready;

-- Source: daddy_bob_jooseyo_korean_io.sql
-- Apply after V6. Keep original timestamptz as the canonical instant.
-- Generated stored columns materialize UTC/KST automatically for existing and future rows.
-- Do not insert/update generated columns from n8n. Write only the original instant.

alter table public.daddy_bob_jooseyo_feedings
 add column if not exists fed_at_utc timestamp without time zone generated always as (fed_at at time zone 'UTC') stored,
 add column if not exists fed_at_kst timestamp without time zone generated always as (fed_at at time zone 'Asia/Seoul') stored;
alter table public.daddy_bob_jooseyo_health
 add column if not exists occurred_at_utc timestamp without time zone generated always as (occurred_at at time zone 'UTC') stored,
 add column if not exists occurred_at_kst timestamp without time zone generated always as (occurred_at at time zone 'Asia/Seoul') stored;
alter table public.daddy_bob_jooseyo_care_plans
 add column if not exists anchor_at_utc timestamp without time zone generated always as (anchor_at at time zone 'UTC') stored,
 add column if not exists anchor_at_kst timestamp without time zone generated always as (anchor_at at time zone 'Asia/Seoul') stored;
alter table public.daddy_bob_jooseyo_care_plans
 add column if not exists next_due_at_utc timestamp without time zone generated always as (next_due_at at time zone 'UTC') stored,
 add column if not exists next_due_at_kst timestamp without time zone generated always as (next_due_at at time zone 'Asia/Seoul') stored;
alter table public.daddy_bob_jooseyo_care_plans
 add column if not exists end_at_utc timestamp without time zone generated always as (end_at at time zone 'UTC') stored,
 add column if not exists end_at_kst timestamp without time zone generated always as (end_at at time zone 'Asia/Seoul') stored;
alter table public.daddy_bob_jooseyo_care_plans
 add column if not exists last_sent_at_utc timestamp without time zone generated always as (last_sent_at at time zone 'UTC') stored,
 add column if not exists last_sent_at_kst timestamp without time zone generated always as (last_sent_at at time zone 'Asia/Seoul') stored;
alter table public.daddy_bob_jooseyo_med_slots
 add column if not exists next_due_at_utc timestamp without time zone generated always as (next_due_at at time zone 'UTC') stored,
 add column if not exists next_due_at_kst timestamp without time zone generated always as (next_due_at at time zone 'Asia/Seoul') stored;
alter table public.daddy_bob_jooseyo_med_slots
 add column if not exists end_at_utc timestamp without time zone generated always as (end_at at time zone 'UTC') stored,
 add column if not exists end_at_kst timestamp without time zone generated always as (end_at at time zone 'Asia/Seoul') stored;
alter table public.daddy_bob_jooseyo_med_slots
 add column if not exists last_sent_at_utc timestamp without time zone generated always as (last_sent_at at time zone 'UTC') stored,
 add column if not exists last_sent_at_kst timestamp without time zone generated always as (last_sent_at at time zone 'Asia/Seoul') stored;

-- Display only. Absolute stored timestamps and reminder comparisons are unchanged.
create or replace function public.daddy_bob_jooseyo_format_kst(p_at timestamptz)
returns text language sql immutable strict set search_path=pg_catalog as $$
 select to_char(p_at at time zone 'Asia/Seoul','YYYY"년" FMMM"월" FMDD"일" ')||
  case when extract(hour from p_at at time zone 'Asia/Seoul')<12 then '오전 ' else '오후 ' end||
  to_char(p_at at time zone 'Asia/Seoul','FMHH12:MI')||' (한국 시간)';
$$;
revoke all on function public.daddy_bob_jooseyo_format_kst(timestamptz) from public,anon,authenticated;
grant execute on function public.daddy_bob_jooseyo_format_kst(timestamptz) to service_role;

create or replace function public.daddy_bob_jooseyo_bot_v6(p_chat_id text,p_action text,p_args jsonb default '{}'::jsonb)
returns jsonb language plpgsql security definer set search_path=pg_catalog,public,auth
as $v6$
declare
 r jsonb;sub jsonb;pending jsonb;op jsonb;a jsonb;operations jsonb;msg jsonb;
 ch public.daddy_bob_jooseyo_children;slot public.daddy_bob_jooseyo_med_slots;
 rec record;act text:=p_action;uid text:=p_args->>'update_id';
 preview text:='';details text:='';warnings text:='';label text;key text;question text;token text;
 stamp timestamptz;finish timestamptz;is_repeat boolean;
 approved boolean:=false;n integer:=0;failed integer:=0;state_code text;
 allowed text[]:=array['feed','edit','delete','health','care_setup','medicine_schedule','growth','stock','sleep','morning','childadd','reset','childdelete','care_cancel','care_snooze','medicine_cancel','medicine_snooze','children','history','status','healthhistory','care_list'];
begin
 if auth.role() is distinct from 'service_role' or p_chat_id is distinct from '9114513581' then raise exception 'Not authorized';end if;
 perform pg_advisory_xact_lock(9114513581::bigint);
 if uid is not null then
  select response into r from public.daddy_bob_jooseyo_updates where update_id=uid;
  if found then return r||jsonb_build_object('chat_id',p_chat_id,'silent',false,'reply',coalesce(nullif(r->>'reply',''),'아버님, 이미 처리한 요청입니다. 중복 변경하지 않았습니다.'));end if;
 end if;
 select state into pending from public.daddy_bob_jooseyo_sessions where chat_id=p_chat_id and expires_at>now();
 if act='context' then
  r:=public.daddy_bob_jooseyo_bot_v5(p_chat_id,act,'{}'::jsonb);
  return r||jsonb_build_object('fixed_schedules',coalesce((select jsonb_agg(to_jsonb(x)) from(
    select s.id,c.name,s.medicine,s.dose,s.dose_unit,s.next_due_at,s.repeat_daily,s.end_at
    from public.daddy_bob_jooseyo_med_slots s join public.daddy_bob_jooseyo_children c on c.id=s.child_id
    where c.telegram_chat_id=p_chat_id and s.active order by s.next_due_at)x),'[]'::jsonb));
 elsif act='care_due' then
  r:=public.daddy_bob_jooseyo_bot_v5(p_chat_id,act,'{}'::jsonb);
  update public.daddy_bob_jooseyo_med_slots set active=false,claim_token=null,claim_until=null where active and end_at<now();
  for rec in update public.daddy_bob_jooseyo_med_slots s set claim_token=gen_random_uuid(),claim_until=now()+interval '2 minutes'
   from public.daddy_bob_jooseyo_children c where c.id=s.child_id and c.telegram_chat_id=p_chat_id and c.active and s.active
    and s.next_due_at<=now() and(s.end_at is null or s.end_at>=now()) and(s.claim_until is null or s.claim_until<=now())
   returning s.*,c.name
  loop
   msg:=jsonb_build_object('chat_id',p_chat_id,'kind','fixed_medicine','schedule_id',rec.id,'child_id',rec.child_id,
    'claim_token',rec.claim_token,'occurrence_due',rec.next_due_at,
    'reply','아버님, '||rec.name||' 투약 계획을 확인할 시간입니다.'||E'\n등록한 계획: '||rec.medicine||' '||rec.dose||rec.dose_unit||E'\n마지막 실제 투여 시각과 의료진·약 안내를 확인해 주세요. 실제 투약은 별도로 기록해 주세요.',
    'buttons',jsonb_build_array(jsonb_build_object('text','이 일정 중지','data','fixed_stop:'||rec.id),jsonb_build_object('text','30분 미루기','data','fixed_later:'||rec.id)));
   r:=jsonb_set(r,'{messages}',coalesce(r->'messages','[]'::jsonb)||jsonb_build_array(msg));
  end loop;
  return r;
 elsif act='mark' and p_args->>'kind'='fixed_medicine' then
  update public.daddy_bob_jooseyo_med_slots set
   next_due_at=case when repeat_daily then next_due_at+interval '24 hours'*(floor(extract(epoch from(now()-next_due_at))/86400)+1)::double precision else next_due_at end,
   active=repeat_daily,claim_token=null,claim_until=null,last_sent_at=now(),updated_at=now()
   where id=(p_args->>'schedule_id')::uuid and claim_token=(p_args->>'claim_token')::uuid
    and next_due_at=(p_args->>'occurrence_due')::timestamptz and active;
  return jsonb_build_object('ok',true);
 elsif act='batch_draft' then
  operations:=p_args->'draft_operations';question:=left(p_args->>'question',1400);
  if jsonb_typeof(operations) is distinct from 'array' or jsonb_array_length(operations) not between 1 and 12 or length(operations::text)>40000 or question is null then raise exception 'Invalid draft';end if;
  -- Freeze implicit 'now' for the first reported observation while details are being clarified.
  select jsonb_agg(case when x->>'action' in ('feed','health') or(x->>'action'='care_setup' and x->'record_new'='true'::jsonb)
    then case when nullif(x->>'time','') is null then x||jsonb_build_object('time',now()) else x end else x end)
   into operations from jsonb_array_elements(operations)x;
  token:=gen_random_uuid()::text;
  insert into public.daddy_bob_jooseyo_sessions values(p_chat_id,jsonb_build_object('action','batch_draft','operations',operations,'question',question,'token',token),now()+interval '30 minutes')
   on conflict(chat_id) do update set state=excluded.state,expires_at=excluded.expires_at;
  warnings:=public.daddy_bob_jooseyo_batch_warnings(p_chat_id,operations);
  r:=jsonb_build_object('chat_id',p_chat_id,'reply','아버님, 요청을 나누어 확인했습니다. 아직 기록은 변경하지 않았습니다.'||E'\n'||question||warnings,'buttons','[]'::jsonb);
 else
  if act in ('confirm','decision') and pending->>'action' in ('batch','batch_draft') then
   token:=case when act='confirm' then p_args->>'token' else p_args->>'expected_token' end;
   if token is distinct from pending->>'token' or(act='decision' and jsonb_typeof(p_args->'decision') is distinct from 'boolean') then
    r:=jsonb_build_object('chat_id',p_chat_id,'reply','아버님, 확인 요청이 만료되었습니다. 내용을 다시 말씀해 주세요.','buttons','[]'::jsonb);
   elsif act='decision' and not(p_args->>'decision')::boolean then
    delete from public.daddy_bob_jooseyo_sessions where chat_id=p_chat_id;
    r:=jsonb_build_object('chat_id',p_chat_id,'reply','아버님, 취소했습니다. 기존 기록은 유지했습니다.','buttons','[]'::jsonb);
   elsif pending->>'action'='batch_draft' then
    r:=jsonb_build_object('chat_id',p_chat_id,'reply','아버님, 다음 내용을 먼저 확인해 주세요.'||E'\n'||(pending->>'question'),'buttons','[]'::jsonb);
   else act:='batch';operations:=pending->'operations';approved:=true;end if;
  elsif act='batch' then operations:=p_args->'operations';
  end if;
  if r is null and act='batch' then
   if jsonb_typeof(operations) is distinct from 'array' or jsonb_array_length(operations) not between 1 and 12 then raise exception 'Batch must contain 1..12 operations';end if;
   if not approved then
    select jsonb_agg(case when x->>'action' in ('feed','health') or(x->>'action'='care_setup' and x->'args'->'record_new'='true'::jsonb)
      then case when nullif(x->'args'->>'time','') is null then jsonb_set(x,'{args}',x->'args'||jsonb_build_object('time',now())) else x end else x end)
     into operations from jsonb_array_elements(operations)x;
   end if;
   for op in select value from jsonb_array_elements(operations) loop
    if op->>'action' is null or not(op->>'action'=any(allowed)) or jsonb_typeof(op->'args') is distinct from 'object' then raise exception 'Unsupported batch operation';end if;
    a:=op->'args';
    if a ? 'confirmed' or a ? 'token' or a ? 'update_id' then raise exception 'Untrusted batch authorization';end if;
    if op->>'action'='care_setup' and jsonb_typeof(a->'overnight') is distinct from 'boolean' then raise exception 'Night option is required for batch';end if;
    n:=n+1;
    label:=case op->>'action'
     when 'feed' then coalesce(a->>'name','아이')||' 수유 '||(a->>'amount')||'ml / 조유량 '||coalesce(a->>'prepared',a->>'amount')||'ml'
     when 'health' then coalesce(a->>'name','아이')||' '||case a->>'health_kind' when 'temperature' then '체온 '||(a->>'temperature')||'℃' when 'medicine' then (a->>'medicine')||' 실제 투여 '||(a->>'dose')||(a->>'dose_unit') else a->>'note' end
     when 'care_setup' then (a->>'name')||' '||case a->>'care_kind' when 'temperature' then '체온' else a->>'medicine' end||' 확인 알림 '||(a->>'interval_minutes')||'분 간격'||case when(a->>'overnight')::boolean then ' · 야간 포함' else ' · 22~08시 제외' end||
      case when a->'record_new'='true'::jsonb then case a->>'care_kind' when 'temperature' then ' · 첫 체온 '||(a->>'temperature')||'℃ 기록' else ' · 실제 투여 '||(a->>'dose')||(a->>'dose_unit')||' 기록' end else ' · 기존 실제 기록 기준' end||
      case when a ? 'reminder_count' then ' · 알림 '||(a->>'reminder_count')||'회' when a->>'end_at' is null then ' · 중지할 때까지' else '' end
     when 'medicine_schedule' then (a->>'name')||' '||(a->>'medicine')||' '||(a->>'dose')||(a->>'dose_unit')||' 투약 계획 · '||public.daddy_bob_jooseyo_format_kst((a->>'scheduled_at')::timestamptz)||case when(a->>'repeat_daily')::boolean then ' · 매일 반복' else ' · 1회' end||case when(a->>'repeat_daily')::boolean and a->>'end_at' is null then ' · 중지할 때까지' else '' end
     when 'medicine_cancel' then '고정 투약 알림 중지 · ID '||(a->>'schedule_id')
     when 'medicine_snooze' then '고정 투약 알림 '||(a->>'minutes')||'분 미루기 · ID '||(a->>'schedule_id')
     when 'delete' then '수유 한 건 삭제 · ID '||(a->>'feed_id')
     when 'reset' then (a->>'name')||' 수유 기록 전체 삭제'
     when 'childdelete' then (a->>'name')||' 프로필·연결 기록 전체 삭제'
     else coalesce(a->>'name','')||' · '||(op->>'action') end;
    if label is null then raise exception 'Incomplete operation';end if;
    preview:=preview||n||'. '||left(label,350)||case when a ? 'time' then ' · 실제 시각 '||public.daddy_bob_jooseyo_format_kst((a->>'time')::timestamptz) else '' end||case when a ? 'end_at' then ' · 종료 '||public.daddy_bob_jooseyo_format_kst((a->>'end_at')::timestamptz) else '' end||E'\n';
   end loop;
   warnings:=public.daddy_bob_jooseyo_batch_warnings(p_chat_id,operations);
   if not approved then
    token:=gen_random_uuid()::text;
    insert into public.daddy_bob_jooseyo_sessions values(p_chat_id,jsonb_build_object('action','batch','operations',operations,'token',token),now()+interval '15 minutes')
     on conflict(chat_id) do update set state=excluded.state,expires_at=excluded.expires_at;
    r:=jsonb_build_object('chat_id',p_chat_id,'reply','아버님, 아래 '||n||'개 요청을 함께 처리할까요?'||E'\n'||left(preview,3200)||E'\n확인 전에는 기존 기록을 변경하지 않습니다.'||warnings,
      'buttons',jsonb_build_array(jsonb_build_object('text','확인','data','confirm:'||token),jsonb_build_object('text','취소','data','cancel')));
   else
    -- Everything in this nested block is a PostgreSQL subtransaction. One failure rolls ALL changes back.
    begin
     delete from public.daddy_bob_jooseyo_sessions where chat_id=p_chat_id;
     for op in select value from jsonb_array_elements(operations) loop
      failed:=failed+1;a:=op->'args';
      if op->>'action'='medicine_schedule' then
       select * into ch from public.daddy_bob_jooseyo_children where name=a->>'name' and telegram_chat_id=p_chat_id;
       if ch.id is null or nullif(trim(a->>'medicine'),'') is null or a->>'dose' is null or(a->>'dose')::numeric<=0 or a->>'dose_unit' not in ('ml','mg','g','방울','정','포') or a->>'dose_unit' is null or jsonb_typeof(a->'repeat_daily') is distinct from 'boolean' then raise exception 'Invalid medicine schedule';end if;
       stamp:=(a->>'scheduled_at')::timestamptz;finish:=(a->>'end_at')::timestamptz;is_repeat:=(a->>'repeat_daily')::boolean;
       if stamp is null or stamp<=now() or(finish is not null and finish<stamp) then raise exception 'Future exact schedule time required';end if;
       key:=case when is_repeat then 'daily:'||to_char(stamp at time zone 'Asia/Seoul','HH24:MI:SS') else 'once:'||to_char(stamp at time zone 'UTC','YYYYMMDDHH24MISS') end;
       insert into public.daddy_bob_jooseyo_med_slots(child_id,medicine,dose,dose_unit,slot_key,next_due_at,repeat_daily,end_at)
        values(ch.id,a->>'medicine',(a->>'dose')::numeric,a->>'dose_unit',key,stamp,is_repeat,finish)
       on conflict(child_id,medicine,slot_key) do update set dose=excluded.dose,dose_unit=excluded.dose_unit,
        next_due_at=excluded.next_due_at,repeat_daily=excluded.repeat_daily,end_at=excluded.end_at,active=true,claim_token=null,claim_until=null,updated_at=now();
      else
       if op->>'action'<>'childadd' and a ? 'name' and not exists(select 1 from public.daddy_bob_jooseyo_children where name=a->>'name' and telegram_chat_id=p_chat_id) then raise exception 'Child scope missing';end if;
       if a ? 'feed_id' and not exists(select 1 from public.daddy_bob_jooseyo_feedings f join public.daddy_bob_jooseyo_children c on c.id=f.child_id where f.id=(a->>'feed_id')::uuid and c.telegram_chat_id=p_chat_id) then raise exception 'Feeding scope missing';end if;
       sub:=public.daddy_bob_jooseyo_bot_v5(p_chat_id,op->>'action',a);
       select state into pending from public.daddy_bob_jooseyo_sessions where chat_id=p_chat_id and expires_at>now();
       if pending is not null and pending->>'action'=op->>'action' then
        sub:=public.daddy_bob_jooseyo_bot_v5(p_chat_id,'decision',jsonb_build_object('decision',true,'expected_token',pending->>'token'));
       end if;
       if jsonb_array_length(coalesce(sub->'buttons','[]'::jsonb))>0 or exists(select 1 from public.daddy_bob_jooseyo_sessions where chat_id=p_chat_id) then raise exception 'Operation needs more input';end if;
       if sub->>'reply' like '%첫 실제 기록%' or sub->>'reply' like '%찾지 못%' or sub->>'reply' like '%찾을 수 없%' or sub->>'reply' like '%못 찾%' then raise exception 'Record scope could not be resolved';end if;
       if op->>'action' in ('children','history','status','healthhistory','care_list') then details:=details||E'\n'||coalesce(sub->>'reply','');end if;
      end if;
     end loop;
     r:=jsonb_build_object('chat_id',p_chat_id,'ok',true,'reply','아버님, 기록을 업데이트했습니다. ('||n||'개 요청 처리)'||case when details<>'' then E'\n'||left(details,2800) else '' end||warnings,'buttons','[]'::jsonb);
    exception when others then
     get stacked diagnostics state_code=returned_sqlstate;
     delete from public.daddy_bob_jooseyo_sessions where chat_id=p_chat_id and state->>'action'='batch';
     r:=jsonb_build_object('chat_id',p_chat_id,'ok',false,'rolled_back',true,'failed_operation',failed,'error_code',state_code,
      'reply','아버님, '||failed||'번째 요청을 처리하지 못해 이번 묶음의 변경을 모두 되돌렸습니다. 기존 기록은 유지했습니다. 해당 항목을 확인해 다시 말씀해 주세요.'||warnings,'buttons','[]'::jsonb);
    end;
   end if;
  elsif r is null and act in ('medicine_cancel','medicine_snooze') then
   select s.* into slot from public.daddy_bob_jooseyo_med_slots s join public.daddy_bob_jooseyo_children c on c.id=s.child_id
    where s.id=(p_args->>'schedule_id')::uuid and c.telegram_chat_id=p_chat_id and s.active for update of s;
   if slot.id is null then label:='이미 중지됐거나 없는 일정입니다.';
   elsif act='medicine_cancel' then
    update public.daddy_bob_jooseyo_med_slots set active=false,claim_token=null,claim_until=null where id=slot.id;label:='해당 투약 알림을 중지했습니다. 실제 투약 기록은 유지합니다.';
   else
    n:=(p_args->>'minutes')::integer;if n is null or n not between 1 and 1440 then raise exception 'Invalid snooze';end if;
    if slot.end_at is not null and now()+make_interval(mins=>n)>slot.end_at then label:='종료 시각을 넘어 미루지 않았습니다.';
    else update public.daddy_bob_jooseyo_med_slots set next_due_at=now()+make_interval(mins=>n),claim_token=null,claim_until=null where id=slot.id;label:='알림을 '||n||'분 미뤘습니다. 약 투여 시각을 변경하는 지시는 아닙니다.';end if;
   end if;
   r:=jsonb_build_object('chat_id',p_chat_id,'reply','아버님, '||label,'buttons','[]'::jsonb);
  end if;
 end if;
 if r is null then
  begin r:=public.daddy_bob_jooseyo_bot_v5(p_chat_id,p_action,p_args);
  exception when others then
   r:=jsonb_build_object('chat_id',p_chat_id,'ok',false,'rolled_back',true,'reply','아버님, 업데이트하지 못해 이번 요청의 변경을 되돌렸습니다. 기존 기록은 유지했습니다. 입력 내용을 확인해 주세요.','buttons','[]'::jsonb);
  end;
 end if;
 if p_action='care_list' then
  select string_agg(c.name||' · '||s.medicine||' '||s.dose||s.dose_unit||' · 다음 '||to_char(s.next_due_at at time zone 'Asia/Seoul','MM-DD HH24:MI')||case when s.repeat_daily then ' (매일)' else ' (1회)' end||E'\n일정 ID: '||s.id,E'\n') into details
   from public.daddy_bob_jooseyo_med_slots s join public.daddy_bob_jooseyo_children c on c.id=s.child_id where c.telegram_chat_id=p_chat_id and s.active;
  if details is not null then r:=r||jsonb_build_object('reply',coalesce(r->>'reply','아버님, 현재 알림입니다.')||E'\n\n[고정 투약 일정]\n'||details);end if;
 end if;
 if uid is not null then
  if coalesce((r->>'silent')::boolean,false) or nullif(r->>'reply','') is null then
   r:=r||jsonb_build_object('silent',false,'reply',case when p_action in ('clarify','quiet_clarify') then '아버님, '||coalesce(p_args->>'question','변경할 내용을 확인해 주세요.') else '아버님, 요청을 확인했습니다. 추가 변경은 없습니다.' end,'buttons','[]'::jsonb);
  end if;
  r:=r||jsonb_build_object('silent',false);
  insert into public.daddy_bob_jooseyo_updates(update_id,response) values(uid,r) on conflict(update_id) do update set response=excluded.response;
 end if;
 return r;
end;
$v6$;
revoke all on function public.daddy_bob_jooseyo_bot_v6(text,text,jsonb) from public,anon,authenticated;
grant execute on function public.daddy_bob_jooseyo_bot_v6(text,text,jsonb) to service_role;


create or replace function public.daddy_bob_jooseyo_bot(
 p_chat_id text, p_action text, p_args jsonb default '{}'::jsonb
) returns jsonb
language plpgsql security definer set search_path = pg_catalog, public, auth
as $bot$
declare
 c public.daddy_bob_jooseyo_children;
 f public.daddy_bob_jooseyo_feedings;
 i public.daddy_bob_jooseyo_formula_inventory;
 s jsonb; result jsonb; buttons jsonb := '[]'; messages jsonb := '[]';
 reply text; act text := p_action; args jsonb := p_args;
 child_name text; token text; amount integer; prepared integer; delta integer;
 stamp timestamptz; rec record; daily numeric; days numeric; age_days integer;
 v_update text := p_args->>'update_id';
begin
 if auth.role() is distinct from 'service_role' or p_chat_id is distinct from '9114513581' then
   raise exception 'Not authorized';
 end if;
 -- Serialize interactions and duplicate update checks for the sole permitted chat.
 perform pg_advisory_xact_lock(9114513581::bigint);
 delete from public.daddy_bob_jooseyo_sessions where expires_at<=now();
 if v_update is not null then
   select u.response into result from public.daddy_bob_jooseyo_updates u where update_id=v_update;
   if found then return result; end if;
 end if;

 -- Context contains only this private chat's profiles/recent record IDs and active session.
 if act='context' then
   select state into s from public.daddy_bob_jooseyo_sessions where chat_id=p_chat_id and expires_at>now();
   return jsonb_build_object('children',coalesce((select jsonb_agg(jsonb_build_object('id',id,'name',name))
     from public.daddy_bob_jooseyo_children where telegram_chat_id=p_chat_id),'[]'::jsonb),
     'recent',coalesce((select jsonb_agg(to_jsonb(x)) from (
       select fg.id, ch.name, fg.amount_ml, fg.prepared_ml,
         to_char(fg.fed_at at time zone 'Asia/Seoul','YYYY-MM-DD"T"HH24:MI:SS')||'+09:00' as fed_at
       from public.daddy_bob_jooseyo_feedings fg join public.daddy_bob_jooseyo_children ch on ch.id=fg.child_id
       where ch.telegram_chat_id=p_chat_id order by fg.fed_at desc limit 20) x),'[]'::jsonb),
     'pending',s,'now_kst',to_char(now() at time zone 'Asia/Seoul','YYYY-MM-DD"T"HH24:MI:SS')||'+09:00');
 end if;
 if act='decision' then
   select state into s from public.daddy_bob_jooseyo_sessions where chat_id=p_chat_id and expires_at>now();
   if s is null or s->>'action'='await_amount' or s->>'token' is distinct from args->>'expected_token'
     or jsonb_typeof(args->'decision') is distinct from 'boolean' then
     reply := '확인할 요청이 없거나 만료되었어요. 처리할 내용을 다시 말씀해 주세요.';
   elsif (args->>'decision')::boolean then
     act := 'confirm'; args := jsonb_build_object('token',s->>'token');
   else act := 'cancel'; end if;
 elsif act='clarify' then
   reply := left(coalesce(nullif(args->>'question',''),'어느 아이의 어떤 기록을 처리할까요? 이름과 양을 알려주세요.'),1500);
 end if;

 -- Schedule only queries targets. Sending/marking happens in n8n after successful delivery.
 if act='due' then
   for rec in select r.* from public.daddy_bob_jooseyo_get_due_reminders() r
     join public.daddy_bob_jooseyo_children ch on ch.id=r.child_id
     where r.chat_id=p_chat_id and not (ch.quiet_enabled and public.daddy_bob_jooseyo_is_quiet(
       ch.quiet_start,ch.quiet_end,(now() at time zone 'Asia/Seoul')::time)) loop
     messages := messages || jsonb_build_array(jsonb_build_object(
       'chat_id',p_chat_id,'child_id',rec.child_id,'kind','feeding',
       'reply','🍼 '||rec.child_name||' 수유 기록 리마인더'||E'\n설정한 수유 간격이 지났어요. 수유 여부를 알려주세요.'||E'\n아기의 배고픔 신호와 의료진 지침을 우선해 주세요.',
       'buttons',jsonb_build_array(
         jsonb_build_object('text','먹였어요','data','fed:'||rec.child_id),
         jsonb_build_object('text','아직이에요','data','later:'||rec.child_id))));
   end loop;
   for rec in
     select inv.*, ch.name from public.daddy_bob_jooseyo_formula_inventory inv
     join public.daddy_bob_jooseyo_children ch on ch.id=inv.child_id
     where ch.telegram_chat_id=p_chat_id and ch.active
       and not (ch.quiet_enabled and public.daddy_bob_jooseyo_is_quiet(
         ch.quiet_start,ch.quiet_end,(now() at time zone 'Asia/Seoul')::time))
       and (inv.last_alerted_at is null or inv.last_alerted_at < now()-interval '24 hours')
   loop
     select sum(x.prepared_ml)::numeric / least(7, greatest(1,
       extract(epoch from (now()-min(x.fed_at)))/86400)) into daily
     from public.daddy_bob_jooseyo_feedings x where x.child_id=rec.child_id
       and x.stock_deducted_ml>0 and x.fed_at>=now()-interval '7 days';
     days := case when daily>0 then rec.stock_ml_equivalent/daily else null end;
     if rec.stock_ml_equivalent<=rec.reorder_threshold_ml
        or days<=rec.delivery_lead_days+rec.buffer_days then
       messages := messages || jsonb_build_array(jsonb_build_object(
        'chat_id',p_chat_id,'child_id',rec.child_id,'kind','stock','buttons','[]'::jsonb,
        'reply','📦 '||rec.name||' 분유 구매 확인: '||rec.product_name||E'\n남은 조유 환산량: '||rec.stock_ml_equivalent||'ml'||
         case when days is null then E'\n사용 기록이 부족해 소진일을 계산하지 못했어요.'
         else E'\n예상 잔여: 약 '||round(days,1)||'일 (최근 기록 기준 추정)' end||
         E'\n배송 '||rec.delivery_lead_days||'일 + 여유 '||rec.buffer_days||'일 기준입니다.'));
     end if;
   end loop;
   return jsonb_build_object('messages',messages);
 elsif act='mark' then
   if args->>'kind'='feeding' then
     update public.daddy_bob_jooseyo_children set last_reminded_at=now(),updated_at=now()
      where id=(args->>'child_id')::uuid and telegram_chat_id=p_chat_id;
   elsif args->>'kind'='stock' then
     update public.daddy_bob_jooseyo_formula_inventory set last_alerted_at=now()
      where child_id in (select id from public.daddy_bob_jooseyo_children
        where id=(args->>'child_id')::uuid and telegram_chat_id=p_chat_id);
   end if;
   return jsonb_build_object('ok',true);
 end if;

 select state into s from public.daddy_bob_jooseyo_sessions
  where chat_id=p_chat_id and expires_at>now();
 if act='cancel' then
   delete from public.daddy_bob_jooseyo_sessions where chat_id=p_chat_id;
   reply := '취소했어요. 기록은 변경하지 않았습니다.';
 elsif act='confirm' then
   if s is null or s->>'token' is distinct from args->>'token' then
     reply := '만료되었거나 이미 처리한 확인 버튼입니다. 명령을 다시 입력해 주세요.';
   else
     act := s->>'action'; args := s->'args';
     -- Consume before executing; a SQL failure rolls back both state and operation.
     delete from public.daddy_bob_jooseyo_sessions where chat_id=p_chat_id;
   end if;
 elsif act='amount' then
   if s->>'action'='await_amount' then
     args := s->'args' || args; act := 'feed';
   else reply := '먼저 /feed 아이이름 먹인양 [조유량]을 입력해 주세요.'; end if;
 end if;

 if reply is null then
  if act in ('help','unknown') then
   reply := $help$🍼 개인 수유 도우미 — 자연어·명령어 안내
"별이 120 먹고 150 탔어", "별이 최근 기록 보여줘"처럼 말해도 됩니다.
저장·수정·삭제 확인 질문에 "응" 또는 "아니"로 답할 수 있어요. 모호한 답변은 실행하지 않습니다.
/sleep 별이 22:00 08:00 — 한국 시간 자동 알림 휴식 설정. 확인 필요.
/sleep 별이 off — 야간 알림 중지 해제. 확인 필요.
기본 22:00~08:00에는 자동 알림만 쉬며 수유 필요 여부를 판단하지 않습니다.

[수유 기록]
/feed 별이 120 150
→ 실제 먹은 양 120ml, 준비한 조유량 150ml. 확인 후 현재 시각으로 저장합니다.
/feed 별이 120
→ 먹은 양·조유량 모두 120ml로 가정합니다. 남겼다면 두 값을 입력하세요.
/history 별이
→ 최근 10건, 한국 시간, 수정·삭제용 기록 ID(UUID)를 보여줍니다.

[수정·삭제]
/edit UUID 110 150
→ 해당 기록을 먹은 양 110ml, 조유량 150ml로 수정합니다. 확인이 필요합니다.
/edit UUID 110 150 2026-11-25T19:23:00+09:00
→ 시각도 수정합니다. 시간대를 포함해야 하며 미래 시각은 입력할 수 없습니다.
/delete UUID
→ 수유 한 건을 삭제합니다. 확인이 필요합니다.
UUID는 /history에서 나온 실제 기록 ID로 바꿔 입력하세요.

[아이·성장]
/children
→ 등록된 아이 목록을 보여줍니다.
/childadd 둘째 2026-07-13
→ 아이를 추가합니다. 같은 이름이 있으면 유지합니다. 실제 생년월일을 입력하세요.
/growth 별이 6.5 62
→ 오늘 체중 6.5kg·키 62cm를 기록하고 현재 체중을 갱신합니다.
/status 별이
→ 최근 성장, 최근 24시간 섭취, 체중 기반 참고 범위, 재고를 보여줍니다. 참고량은 처방이 아닙니다.

[분유 재고]
/stock 별이 제품명 700 5 40 2 3 2
→ 순서: 한 통 가루g / 한 스푼 가루g / 스푼당 조유ml / 남은 통수 / 배송일 / 여유일.
입력 숫자는 문법 예시입니다. 실제 제품 라벨의 조유 비율을 사용하세요. 700은 ml가 아닌 가루 g입니다.
재고는 더하지 않고 입력한 잔량으로 교체합니다. 확인이 필요합니다. 아이 이름·제품명에는 공백을 넣지 마세요.

[초기화·취소]
/reset 별이
→ 모든 수유 기록을 삭제합니다. 프로필·성장·재고는 유지하고 추적된 재고 차감량은 복원합니다. 확인이 필요합니다.
/childdelete 별이
→ 해당 아이의 프로필·수유·성장·재고를 영구 삭제합니다. 확인이 필요합니다.
/cancel
→ 대기 중 확인·양 입력을 취소합니다.

확인 버튼은 15분 동안 유효하며 새 확인 요청을 만들면 이전 버튼은 만료됩니다.
알림의 먹였어요 → 실제 먹은 양 입력 → 확인 순서로 저장합니다. 아직이에요는 수유 기록 없이 알림을 미룹니다.
/help 또는 /start로 이 안내를 다시 볼 수 있습니다.$help$;
  elsif act='children' then
   select string_agg(name,' · ' order by created_at) into reply
    from public.daddy_bob_jooseyo_children where telegram_chat_id=p_chat_id;
   reply := '등록된 아이: '||coalesce(reply,'없음');
  elsif act='childadd' then
   if coalesce(args->>'confirmed','false')<>'true' then
    token := gen_random_uuid()::text;
    insert into public.daddy_bob_jooseyo_sessions values(p_chat_id,
      jsonb_build_object('action','childadd','token',token,'args',args||jsonb_build_object('confirmed',true)),now()+interval '15 minutes')
      on conflict(chat_id) do update set state=excluded.state,expires_at=excluded.expires_at;
    reply := (args->>'name')||' 아이를 생년월일 '||(args->>'dob')||'로 등록할까요?';
    buttons := jsonb_build_array(jsonb_build_object('text','확인','data','confirm:'||token),jsonb_build_object('text','취소','data','cancel'));
   else
   if (args->>'dob')::date>(now() at time zone 'Asia/Seoul')::date or length(trim(args->>'name')) not between 1 and 80 then
    raise exception 'Invalid birth date or name'; end if;
   insert into public.daddy_bob_jooseyo_children(name,date_of_birth,telegram_chat_id)
    values(trim(args->>'name'),(args->>'dob')::date,p_chat_id)
    on conflict (telegram_chat_id,name) do nothing;
   reply := '아이 등록을 확인했어요. /children 으로 목록을 볼 수 있습니다.';
   end if;
  else
   -- Resolve an exact child name or an opaque callback/record ID inside this chat only.
   if args ? 'feed_id' then
    select * into f from public.daddy_bob_jooseyo_feedings where id=(args->>'feed_id')::uuid for update;
    select * into c from public.daddy_bob_jooseyo_children where id=f.child_id and telegram_chat_id=p_chat_id for update;
   elsif args ? 'child_id' then
    select * into c from public.daddy_bob_jooseyo_children where id=(args->>'child_id')::uuid and telegram_chat_id=p_chat_id for update;
   else
    select * into c from public.daddy_bob_jooseyo_children where name=args->>'name' and telegram_chat_id=p_chat_id for update;
   end if;
   if c.id is null then
    reply := '아이 또는 기록을 찾지 못했어요. /children 또는 /history 아이이름으로 확인해 주세요.';
   elsif act='fed' then
    token := gen_random_uuid()::text;
    insert into public.daddy_bob_jooseyo_sessions values(p_chat_id,
     jsonb_build_object('action','await_amount','token',token,'args',jsonb_build_object('child_id',c.id)),now()+interval '15 minutes')
     on conflict(chat_id) do update set state=excluded.state,expires_at=excluded.expires_at;
    reply := c.name||E'에게 실제 먹인 양을 숫자로 보내주세요.\n예: 120 또는 120 150 (먹은 양 / 조유량)';
   elsif act='later' then
    -- Explicit snooze: no fictitious feed; retry reminders after at least 30 minutes.
    update public.daddy_bob_jooseyo_children set last_reminded_at=now()-interval '30 minutes' where id=c.id;
    reply := '수유 기록은 추가하지 않았어요. 약 30~45분 뒤 다시 확인할게요.';
   elsif act in ('feed','edit','delete','reset','childdelete','stock','sleep','growth') and coalesce(args->>'confirmed','false')<>'true' then
    if act in ('feed','edit') then
      amount := (args->>'amount')::integer;
      prepared := coalesce((args->>'prepared')::integer, amount);
      if amount is null or amount not between 1 and 1000 or prepared not between amount and 2000 then
        raise exception 'Invalid consumed/prepared amounts'; end if;
    end if;
    if act='sleep' then
      if jsonb_typeof(args->'enabled') is distinct from 'boolean' then raise exception 'Sleep enabled must be boolean'; end if;
      if (args->>'enabled')::boolean and ((args->>'start') is null or (args->>'end') is null
        or (args->>'start')::time=(args->>'end')::time) then raise exception 'Invalid quiet hours'; end if;
    end if;
    token := gen_random_uuid()::text;
    args := args || jsonb_build_object('child_id',c.id,'confirmed',true);
    insert into public.daddy_bob_jooseyo_sessions values(p_chat_id,
     jsonb_build_object('action',act,'token',token,'args',args),now()+interval '15 minutes')
     on conflict(chat_id) do update set state=excluded.state,expires_at=excluded.expires_at;
    reply := case act
     when 'feed' then c.name||' 먹은 양 '||amount||'ml / 조유량 '||prepared||'ml를 저장할까요?'||case when args ? 'time' then E'\n기록 시각: '||public.daddy_bob_jooseyo_format_kst((args->>'time')::timestamptz) else ' (확인 시각으로 기록)' end
     when 'edit' then c.name||' 기록 '||f.amount_ml||'ml → '||amount||'ml로 수정할까요? 조유량 '||prepared||'ml.'
     when 'delete' then c.name||' 수유 기록 한 건('||f.amount_ml||'ml)을 삭제할까요?'
     when 'reset' then c.name||'의 수유 기록을 모두 삭제할까요? 프로필·성장 기록은 유지하며 추적된 재고 차감은 복원합니다.'
     when 'childdelete' then c.name||' 프로필·수유·성장·재고를 모두 영구 삭제할까요?'
     when 'growth' then c.name||' 체중 '||(args->>'weight')||'kg · 키 '||(args->>'height')||'cm를 오늘 성장 기록으로 저장할까요?'
     when 'sleep' then c.name||case when (args->>'enabled')::boolean then ' 자동 알림을 매일 '||(args->>'start')||'~'||(args->>'end')||' (한국 시간)에 쉬도록 설정할까요?' else ' 야간 알림 중지를 해제할까요?' end
     when 'stock' then c.name||' 재고를 입력한 잔량으로 교체할까요? 과거 기록은 새 재고에서 차감하지 않습니다.' end;
    buttons := jsonb_build_array(jsonb_build_object('text','확인','data','confirm:'||token),jsonb_build_object('text','취소','data','cancel'));
   elsif act='feed' then
    amount := (args->>'amount')::integer; prepared := coalesce((args->>'prepared')::integer,amount);
    if amount is null or amount not between 1 and 1000 or prepared not between amount and 2000 then raise exception 'Invalid amount'; end if;
    select * into i from public.daddy_bob_jooseyo_formula_inventory where child_id=c.id for update;
    if i.id is not null and i.stock_ml_equivalent<prepared then raise exception 'Insufficient tracked stock; update /stock first'; end if;
    stamp := coalesce((args->>'time')::timestamptz,now());
    if stamp>now() then raise exception 'Future feeding time is not allowed'; end if;
    insert into public.daddy_bob_jooseyo_feedings(child_id,amount_ml,prepared_ml,stock_deducted_ml,fed_at)
     values(c.id,amount,prepared,case when i.id is null then 0 else prepared end,stamp) returning * into f;
    update public.daddy_bob_jooseyo_formula_inventory set stock_ml_equivalent=stock_ml_equivalent-prepared,updated_at=now() where child_id=c.id;
    update public.daddy_bob_jooseyo_children set last_reminded_at=null where id=c.id;
    reply := c.name||' '||amount||'ml 저장 완료 ('||to_char(stamp at time zone 'Asia/Seoul','MM-DD HH24:MI')||E')\n기록 ID: '||f.id;
   elsif act='history' then
    select string_agg(to_char(x.fed_at at time zone 'Asia/Seoul','MM-DD HH24:MI')||' · '||x.amount_ml||E'ml\n'||x.id,E'\n\n' order by x.fed_at desc) into reply
     from (select * from public.daddy_bob_jooseyo_feedings where child_id=c.id order by fed_at desc limit 10) x;
    reply := c.name||E' 최근 기록 (한국 시간)\n'||coalesce(reply,'아직 기록이 없습니다.');
   elsif act='edit' then
    amount := (args->>'amount')::integer; prepared := coalesce((args->>'prepared')::integer,amount);
    if amount is null or amount not between 1 and 1000 or prepared not between amount and 2000 then raise exception 'Invalid amount'; end if;
    stamp := coalesce((args->>'time')::timestamptz,f.fed_at);
    if stamp>now() then raise exception 'Future feeding time is not allowed'; end if;
    -- Rows from before tracking/baseline are not retroactively charged.
    delta := case when f.stock_deducted_ml>0 then prepared-f.stock_deducted_ml else 0 end;
    select * into i from public.daddy_bob_jooseyo_formula_inventory where child_id=c.id for update;
    if i.id is not null and i.stock_ml_equivalent<delta then raise exception 'Insufficient tracked stock'; end if;
    update public.daddy_bob_jooseyo_formula_inventory set stock_ml_equivalent=stock_ml_equivalent-delta,updated_at=now() where child_id=c.id;
    update public.daddy_bob_jooseyo_feedings set amount_ml=amount,prepared_ml=prepared,fed_at=stamp,
      stock_deducted_ml=case when stock_deducted_ml>0 then prepared else 0 end where id=f.id;
    reply := '수유 기록을 수정했어요. 추적 중인 조유량 차이는 재고에 반영했습니다.';
   elsif act in ('delete','reset') then
    select coalesce(sum(stock_deducted_ml),0)::integer into delta from public.daddy_bob_jooseyo_feedings
     where child_id=c.id and (act='reset' or id=f.id);
    update public.daddy_bob_jooseyo_formula_inventory set stock_ml_equivalent=stock_ml_equivalent+delta,updated_at=now() where child_id=c.id;
    delete from public.daddy_bob_jooseyo_feedings where child_id=c.id and (act='reset' or id=f.id);
    reply := '수유 기록 삭제 완료. 추적된 차감량은 재고에 복원했어요.';
   elsif act='childdelete' then
    delete from public.daddy_bob_jooseyo_children where id=c.id;
    -- Keep update IDs to prevent replay, but erase cached personal response text.
    update public.daddy_bob_jooseyo_updates set response=jsonb_build_object(
      'chat_id',p_chat_id,'reply','이미 처리된 요청입니다. /children 으로 현재 상태를 확인하세요.','buttons','[]'::jsonb);
    reply := '아이 프로필과 연결된 수유·성장·재고 기록을 삭제했어요.';
   elsif act='growth' then
    if (args->>'weight')::numeric not between 0.3 and 80 or (args->>'height')::numeric not between 20 and 150 then raise exception 'Invalid growth values'; end if;
    insert into public.daddy_bob_jooseyo_growth(child_id,weight_kg,height_cm) values(c.id,(args->>'weight')::numeric,(args->>'height')::numeric);
    update public.daddy_bob_jooseyo_children set weight_kg=(args->>'weight')::numeric,updated_at=now() where id=c.id;
    reply := '체중·키를 오늘 날짜로 기록했어요. /status '||c.name||'으로 확인하세요.';
   elsif act='sleep' then
    update public.daddy_bob_jooseyo_children set quiet_enabled=(args->>'enabled')::boolean,
      quiet_start=case when (args->>'enabled')::boolean then (args->>'start')::time else quiet_start end,
      quiet_end=case when (args->>'enabled')::boolean then (args->>'end')::time else quiet_end end,
      updated_at=now() where id=c.id;
    reply := '알림 시간 설정을 변경했어요. 야간에도 기록 입력은 가능하며, 이 설정은 수유 필요 여부를 판단하지 않습니다.';
   elsif act='stock' then
    if (args->>'grams')::numeric<=0 or (args->>'scoop_g')::numeric<=0 or (args->>'scoop_ml')::numeric<=0
     or (args->>'tins')::numeric<0 or (args->>'lead')::integer not between 0 and 60 or (args->>'buffer')::integer not between 0 and 60 then raise exception 'Invalid stock inputs'; end if;
    prepared := round((args->>'grams')::numeric/(args->>'scoop_g')::numeric*(args->>'scoop_ml')::numeric)::integer;
    amount := round(prepared*(args->>'tins')::numeric)::integer;
    insert into public.daddy_bob_jooseyo_formula_inventory(child_id,product_name,stock_ml_equivalent,package_yield_ml,delivery_lead_days,buffer_days)
     values(c.id,args->>'product',amount,prepared,(args->>'lead')::integer,(args->>'buffer')::integer)
     on conflict(child_id) do update set product_name=excluded.product_name,stock_ml_equivalent=excluded.stock_ml_equivalent,
      package_yield_ml=excluded.package_yield_ml,delivery_lead_days=excluded.delivery_lead_days,buffer_days=excluded.buffer_days,last_alerted_at=null,updated_at=now();
    -- Set a baseline; do not refund deductions preceding this stock count.
    update public.daddy_bob_jooseyo_feedings set stock_deducted_ml=0 where child_id=c.id;
    reply := '재고 기준을 설정했어요. 한 통 조유 환산 '||prepared||'ml, 잔량 '||amount||'ml. 제품 라벨 비율 기준으로만 입력하세요.';
   elsif act='status' then
    select * into i from public.daddy_bob_jooseyo_formula_inventory where child_id=c.id;
    age_days := (now() at time zone 'Asia/Seoul')::date-c.date_of_birth;
    select coalesce(sum(amount_ml),0) into amount from public.daddy_bob_jooseyo_feedings where child_id=c.id and fed_at>=now()-interval '24 hours';
    reply := c.name||' · 생후 '||age_days||'일 · 최근 24시간 기록 '||amount||'ml';
    select * into rec from public.daddy_bob_jooseyo_growth where child_id=c.id order by created_at desc limit 1;
    if found then reply := reply||E'\n최근 성장: '||rec.weight_kg||'kg / '||coalesce(rec.height_cm::text,'미등록')||'cm ('||rec.measured_on||')'; end if;
    if c.weight_kg is not null and age_days between 7 and 182 then
      reply := reply||E'\n체중 기반 하루 참고 범위: '||round(c.weight_kg*150)||'~'||round(c.weight_kg*200)||'ml.'||
        case when c.weight_kg*200>=960 then E'\n계산 범위에 960ml 이상이 포함되므로 소아과에 개별 필요량을 확인하세요.' else '' end;
    else reply := reply||E'\n이 월령 또는 체중 미등록 상태에서는 참고량을 계산하지 않습니다.'; end if;
    reply := reply||case when c.quiet_enabled then E'\n자동 알림 휴식: '||to_char(c.quiet_start,'HH24:MI')||'~'||to_char(c.quiet_end,'HH24:MI')||' (한국 시간)' else E'\n야간 알림 중지: 해제' end;
    reply := reply||E'\n키는 성장 기록용이며 수유량 계산에 직접 사용하지 않습니다. 계산값은 목표·처방이 아닙니다. 모유·이유식 병행, 미숙아·질환 등에는 단순 계산을 적용하지 마세요.';
    if i.id is not null then reply := reply||E'\n재고: '||i.product_name||' / 조유 환산 '||i.stock_ml_equivalent||'ml'; end if;
   else reply := '지원하지 않는 명령입니다. /help 를 확인하세요.';
   end if;
  end if;
 end if;
 result := jsonb_build_object('chat_id',p_chat_id,'reply',reply,'buttons',buttons);
 if v_update is not null then
  insert into public.daddy_bob_jooseyo_updates(update_id,response) values(v_update,result);
 end if;
 return result;
end;
$bot$;
revoke all on function public.daddy_bob_jooseyo_bot(text,text,jsonb) from public, anon, authenticated;
grant execute on function public.daddy_bob_jooseyo_bot(text,text,jsonb) to service_role;



-- Both views of the same instant; only KST is shown in bot replies.


-- Source: daddy_bob_jooseyo_v7.sql
-- Apply AFTER V6. Existing health/feeding/reminder records are preserved.

create table if not exists public.daddy_bob_jooseyo_rests (
 id uuid primary key default gen_random_uuid(),
 child_id uuid not null references public.daddy_bob_jooseyo_children(id) on delete cascade,
 kind text not null check(kind in ('nap','night')),
 started_at timestamptz not null,ended_at timestamptz,
 note text,created_at timestamptz not null default now(),
 started_at_utc timestamp generated always as(started_at at time zone 'UTC') stored,
 started_at_kst timestamp generated always as(started_at at time zone 'Asia/Seoul') stored,
 ended_at_utc timestamp generated always as(ended_at at time zone 'UTC') stored,
 ended_at_kst timestamp generated always as(ended_at at time zone 'Asia/Seoul') stored,
 duration_minutes numeric generated always as(round(extract(epoch from(ended_at-started_at))/60,1)) stored,
 check(ended_at is null or ended_at>started_at)
);
create unique index if not exists daddy_bob_jooseyo_one_open_rest on public.daddy_bob_jooseyo_rests(child_id) where ended_at is null;
alter table public.daddy_bob_jooseyo_rests enable row level security;
revoke all on public.daddy_bob_jooseyo_rests from public,anon,authenticated;
grant all on public.daddy_bob_jooseyo_rests to service_role;

-- Display only. Absolute stored timestamps and reminder comparisons are unchanged.
create or replace function public.daddy_bob_jooseyo_format_kst(p_at timestamptz)
returns text language sql immutable strict set search_path=pg_catalog as $$
 select to_char(p_at at time zone 'Asia/Seoul','YYYY"년" FMMM"월" FMDD"일" ')||
  case when extract(hour from p_at at time zone 'Asia/Seoul')<12 then '오전 ' else '오후 ' end||
  to_char(p_at at time zone 'Asia/Seoul','FMHH12:MI')||' (한국 시간)';
$$;
revoke all on function public.daddy_bob_jooseyo_format_kst(timestamptz) from public,anon,authenticated;
grant execute on function public.daddy_bob_jooseyo_format_kst(timestamptz) to service_role;


create or replace function public.daddy_bob_jooseyo_bot_v6(p_chat_id text,p_action text,p_args jsonb default '{}'::jsonb)
returns jsonb language plpgsql security definer set search_path=pg_catalog,public,auth
as $v6$
declare
 r jsonb;sub jsonb;pending jsonb;op jsonb;a jsonb;operations jsonb;msg jsonb;
 ch public.daddy_bob_jooseyo_children;slot public.daddy_bob_jooseyo_med_slots;
 rec record;act text:=p_action;uid text:=p_args->>'update_id';
 preview text:='';details text:='';warnings text:='';label text;key text;question text;token text;
 stamp timestamptz;finish timestamptz;is_repeat boolean;
 approved boolean:=false;n integer:=0;failed integer:=0;state_code text;
 allowed text[]:=array['feed','edit','delete','health','care_setup','medicine_schedule','growth','stock','sleep','morning','childadd','reset','childdelete','care_cancel','care_snooze','medicine_cancel','medicine_snooze','children','history','status','healthhistory','care_list','stop_health_alerts','rest_start','rest_end','rest_record','rest_history'];
begin
 if auth.role() is distinct from 'service_role' or p_chat_id is distinct from '9114513581' then raise exception 'Not authorized';end if;
 perform pg_advisory_xact_lock(9114513581::bigint);
 if uid is not null then
  select response into r from public.daddy_bob_jooseyo_updates where update_id=uid;
  if found then return r||jsonb_build_object('chat_id',p_chat_id,'silent',false,'reply',coalesce(nullif(r->>'reply',''),'아버님, 이미 처리한 요청입니다. 중복 변경하지 않았습니다.'));end if;
 end if;
 select state into pending from public.daddy_bob_jooseyo_sessions where chat_id=p_chat_id and expires_at>now();
 if act='context' then
  r:=public.daddy_bob_jooseyo_bot_v5(p_chat_id,act,'{}'::jsonb);
  return r||jsonb_build_object('fixed_schedules',coalesce((select jsonb_agg(to_jsonb(x)) from(
    select s.id,c.name,s.medicine,s.dose,s.dose_unit,s.next_due_at,s.repeat_daily,s.end_at
    from public.daddy_bob_jooseyo_med_slots s join public.daddy_bob_jooseyo_children c on c.id=s.child_id
    where c.telegram_chat_id=p_chat_id and s.active order by s.next_due_at)x),'[]'::jsonb));
 elsif act='care_due' then
  r:=public.daddy_bob_jooseyo_bot_v5(p_chat_id,act,'{}'::jsonb);
  update public.daddy_bob_jooseyo_med_slots set active=false,claim_token=null,claim_until=null where active and end_at<now();
  for rec in update public.daddy_bob_jooseyo_med_slots s set claim_token=gen_random_uuid(),claim_until=now()+interval '2 minutes'
   from public.daddy_bob_jooseyo_children c where c.id=s.child_id and c.telegram_chat_id=p_chat_id and c.active and s.active
    and s.next_due_at<=now() and(s.end_at is null or s.end_at>=now()) and(s.claim_until is null or s.claim_until<=now())
   returning s.*,c.name
  loop
   msg:=jsonb_build_object('chat_id',p_chat_id,'kind','fixed_medicine','schedule_id',rec.id,'child_id',rec.child_id,
    'claim_token',rec.claim_token,'occurrence_due',rec.next_due_at,
    'reply','아버님, '||rec.name||' 투약 계획을 확인할 시간입니다.'||E'\n등록한 계획: '||rec.medicine||' '||rec.dose||rec.dose_unit||E'\n마지막 실제 투여 시각과 의료진·약 안내를 확인해 주세요. 실제 투약은 별도로 기록해 주세요.',
    'buttons',jsonb_build_array(jsonb_build_object('text','이 일정 중지','data','fixed_stop:'||rec.id),jsonb_build_object('text','30분 미루기','data','fixed_later:'||rec.id)));
   r:=jsonb_set(r,'{messages}',coalesce(r->'messages','[]'::jsonb)||jsonb_build_array(msg));
  end loop;
  return r;
 elsif act='mark' and p_args->>'kind'='fixed_medicine' then
  update public.daddy_bob_jooseyo_med_slots set
   next_due_at=case when repeat_daily then next_due_at+interval '24 hours'*(floor(extract(epoch from(now()-next_due_at))/86400)+1)::double precision else next_due_at end,
   active=repeat_daily,claim_token=null,claim_until=null,last_sent_at=now(),updated_at=now()
   where id=(p_args->>'schedule_id')::uuid and claim_token=(p_args->>'claim_token')::uuid
    and next_due_at=(p_args->>'occurrence_due')::timestamptz and active;
  return jsonb_build_object('ok',true);
 elsif act='batch_draft' then
  operations:=p_args->'draft_operations';question:=left(p_args->>'question',1400);
  if jsonb_typeof(operations) is distinct from 'array' or jsonb_array_length(operations) not between 1 and 12 or length(operations::text)>40000 or question is null then raise exception 'Invalid draft';end if;
  -- Freeze implicit 'now' for the first reported observation while details are being clarified.
  select jsonb_agg(case when x->>'action' in ('feed','health','rest_start','rest_end') or(x->>'action'='care_setup' and x->'record_new'='true'::jsonb)
    then case when nullif(x->>'time','') is null then x||jsonb_build_object('time',now()) else x end else x end)
   into operations from jsonb_array_elements(operations)x;
  token:=gen_random_uuid()::text;
  insert into public.daddy_bob_jooseyo_sessions values(p_chat_id,jsonb_build_object('action','batch_draft','operations',operations,'question',question,'token',token),now()+interval '30 minutes')
   on conflict(chat_id) do update set state=excluded.state,expires_at=excluded.expires_at;
  warnings:=public.daddy_bob_jooseyo_batch_warnings(p_chat_id,operations);
  r:=jsonb_build_object('chat_id',p_chat_id,'reply','아버님, 요청을 나누어 확인했습니다. 아직 기록은 변경하지 않았습니다.'||E'\n'||question||warnings,'buttons','[]'::jsonb);
 else
  if act in ('confirm','decision') and pending->>'action' in ('batch','batch_draft') then
   token:=case when act='confirm' then p_args->>'token' else p_args->>'expected_token' end;
   if token is distinct from pending->>'token' or(act='decision' and jsonb_typeof(p_args->'decision') is distinct from 'boolean') then
    r:=jsonb_build_object('chat_id',p_chat_id,'reply','아버님, 확인 요청이 만료되었습니다. 내용을 다시 말씀해 주세요.','buttons','[]'::jsonb);
   elsif act='decision' and not(p_args->>'decision')::boolean then
    delete from public.daddy_bob_jooseyo_sessions where chat_id=p_chat_id;
    r:=jsonb_build_object('chat_id',p_chat_id,'reply','아버님, 취소했습니다. 기존 기록은 유지했습니다.','buttons','[]'::jsonb);
   elsif pending->>'action'='batch_draft' then
    r:=jsonb_build_object('chat_id',p_chat_id,'reply','아버님, 다음 내용을 먼저 확인해 주세요.'||E'\n'||(pending->>'question'),'buttons','[]'::jsonb);
   else act:='batch';operations:=pending->'operations';approved:=true;end if;
  elsif act='batch' then operations:=p_args->'operations';
  end if;
  if r is null and act='batch' then
   if jsonb_typeof(operations) is distinct from 'array' or jsonb_array_length(operations) not between 1 and 12 then raise exception 'Batch must contain 1..12 operations';end if;
   if not approved then
    select jsonb_agg(case when x->>'action' in ('feed','health','rest_start','rest_end') or(x->>'action'='care_setup' and x->'args'->'record_new'='true'::jsonb)
      then case when nullif(x->'args'->>'time','') is null then jsonb_set(x,'{args}',x->'args'||jsonb_build_object('time',now())) else x end else x end)
     into operations from jsonb_array_elements(operations)x;
   end if;
   for op in select value from jsonb_array_elements(operations) loop
    if op->>'action' is null or not(op->>'action'=any(allowed)) or jsonb_typeof(op->'args') is distinct from 'object' then raise exception 'Unsupported batch operation';end if;
    a:=op->'args';
    if a ? 'confirmed' or a ? 'token' or a ? 'update_id' then raise exception 'Untrusted batch authorization';end if;
    if op->>'action'='care_setup' and jsonb_typeof(a->'overnight') is distinct from 'boolean' then raise exception 'Night option is required for batch';end if;
    n:=n+1;
    label:=case op->>'action'
     when 'feed' then coalesce(a->>'name','아이')||' 수유 '||(a->>'amount')||'ml / 조유량 '||coalesce(a->>'prepared',a->>'amount')||'ml'
     when 'health' then coalesce(a->>'name','아이')||' '||case a->>'health_kind' when 'temperature' then '체온 '||(a->>'temperature')||'℃' when 'medicine' then (a->>'medicine')||' 실제 투여 '||(a->>'dose')||(a->>'dose_unit') else a->>'note' end
     when 'care_setup' then (a->>'name')||' '||case a->>'care_kind' when 'temperature' then '체온' else a->>'medicine' end||' 확인 알림 '||(a->>'interval_minutes')||'분 간격'||case when(a->>'overnight')::boolean then ' · 야간 포함' else ' · 22~08시 제외' end||
      case when a->'record_new'='true'::jsonb then case a->>'care_kind' when 'temperature' then ' · 첫 체온 '||(a->>'temperature')||'℃ 기록' else ' · 실제 투여 '||(a->>'dose')||(a->>'dose_unit')||' 기록' end else ' · 기존 실제 기록 기준' end||
      case when a ? 'reminder_count' then ' · 알림 '||(a->>'reminder_count')||'회' when a->>'end_at' is null then ' · 중지할 때까지' else '' end
     when 'medicine_schedule' then (a->>'name')||' '||(a->>'medicine')||' '||(a->>'dose')||(a->>'dose_unit')||' 투약 계획 · '||public.daddy_bob_jooseyo_format_kst((a->>'scheduled_at')::timestamptz)||case when(a->>'repeat_daily')::boolean then ' · 매일 반복' else ' · 1회' end||case when(a->>'repeat_daily')::boolean and a->>'end_at' is null then ' · 중지할 때까지' else '' end
     when 'rest_start' then (a->>'name')||' '||(a->>'rest_kind')||' 수면 시작 · '||public.daddy_bob_jooseyo_format_kst((a->>'time')::timestamptz)
     when 'rest_end' then (a->>'name')||' 기상 · '||public.daddy_bob_jooseyo_format_kst((a->>'time')::timestamptz)
     when 'rest_record' then (a->>'name')||' '||(a->>'rest_kind')||' · '||public.daddy_bob_jooseyo_format_kst((a->>'started_at')::timestamptz)||' ~ '||public.daddy_bob_jooseyo_format_kst((a->>'ended_at')::timestamptz)
     when 'stop_health_alerts' then coalesce(a->>'name','모든 아이')||' 투약·체온 알림 중지 (기존 기록 유지)'
     when 'medicine_cancel' then '고정 투약 알림 중지 · ID '||(a->>'schedule_id')
     when 'medicine_snooze' then '고정 투약 알림 '||(a->>'minutes')||'분 미루기 · ID '||(a->>'schedule_id')
     when 'delete' then '수유 한 건 삭제 · ID '||(a->>'feed_id')
     when 'reset' then (a->>'name')||' 수유 기록 전체 삭제'
     when 'childdelete' then (a->>'name')||' 프로필·연결 기록 전체 삭제'
     else coalesce(a->>'name','')||' · '||(op->>'action') end;
    if label is null then raise exception 'Incomplete operation';end if;
    preview:=preview||n||'. '||left(label,350)||case when a ? 'time' then ' · 실제 시각 '||public.daddy_bob_jooseyo_format_kst((a->>'time')::timestamptz) else '' end||case when a ? 'end_at' then ' · 종료 '||public.daddy_bob_jooseyo_format_kst((a->>'end_at')::timestamptz) else '' end||E'\n';
   end loop;
   warnings:=public.daddy_bob_jooseyo_batch_warnings(p_chat_id,operations);
   if not approved then
    token:=gen_random_uuid()::text;
    insert into public.daddy_bob_jooseyo_sessions values(p_chat_id,jsonb_build_object('action','batch','operations',operations,'token',token),now()+interval '15 minutes')
     on conflict(chat_id) do update set state=excluded.state,expires_at=excluded.expires_at;
    r:=jsonb_build_object('chat_id',p_chat_id,'reply','아버님, 아래 '||n||'개 요청을 함께 처리할까요?'||E'\n'||left(preview,3200)||E'\n확인 전에는 기존 기록을 변경하지 않습니다.'||warnings,
      'buttons',jsonb_build_array(jsonb_build_object('text','확인','data','confirm:'||token),jsonb_build_object('text','취소','data','cancel')));
   else
    -- Everything in this nested block is a PostgreSQL subtransaction. One failure rolls ALL changes back.
    begin
     delete from public.daddy_bob_jooseyo_sessions where chat_id=p_chat_id;
     for op in select value from jsonb_array_elements(operations) loop
      failed:=failed+1;a:=op->'args';
      if op->>'action'='medicine_schedule' then
       select * into ch from public.daddy_bob_jooseyo_children where name=a->>'name' and telegram_chat_id=p_chat_id;
       if ch.id is null or nullif(trim(a->>'medicine'),'') is null or a->>'dose' is null or(a->>'dose')::numeric<=0 or a->>'dose_unit' not in ('ml','mg','g','방울','정','포') or a->>'dose_unit' is null or jsonb_typeof(a->'repeat_daily') is distinct from 'boolean' then raise exception 'Invalid medicine schedule';end if;
       stamp:=(a->>'scheduled_at')::timestamptz;finish:=(a->>'end_at')::timestamptz;is_repeat:=(a->>'repeat_daily')::boolean;
       if stamp is null or stamp<=now() or(finish is not null and finish<stamp) then raise exception 'Future exact schedule time required';end if;
       key:=case when is_repeat then 'daily:'||to_char(stamp at time zone 'Asia/Seoul','HH24:MI:SS') else 'once:'||to_char(stamp at time zone 'UTC','YYYYMMDDHH24MISS') end;
       insert into public.daddy_bob_jooseyo_med_slots(child_id,medicine,dose,dose_unit,slot_key,next_due_at,repeat_daily,end_at)
        values(ch.id,a->>'medicine',(a->>'dose')::numeric,a->>'dose_unit',key,stamp,is_repeat,finish)
       on conflict(child_id,medicine,slot_key) do update set dose=excluded.dose,dose_unit=excluded.dose_unit,
        next_due_at=excluded.next_due_at,repeat_daily=excluded.repeat_daily,end_at=excluded.end_at,active=true,claim_token=null,claim_until=null,updated_at=now();
      else
       if op->>'action'<>'childadd' and a ? 'name' and not exists(select 1 from public.daddy_bob_jooseyo_children where name=a->>'name' and telegram_chat_id=p_chat_id) then raise exception 'Child scope missing';end if;
       if a ? 'feed_id' and not exists(select 1 from public.daddy_bob_jooseyo_feedings f join public.daddy_bob_jooseyo_children c on c.id=f.child_id where f.id=(a->>'feed_id')::uuid and c.telegram_chat_id=p_chat_id) then raise exception 'Feeding scope missing';end if;
       if op->>'action' in ('stop_health_alerts','rest_start','rest_end','rest_record','rest_history') then sub:=public.daddy_bob_jooseyo_bot_v7(p_chat_id,op->>'action',a);else sub:=public.daddy_bob_jooseyo_bot_v5(p_chat_id,op->>'action',a);end if;
       select state into pending from public.daddy_bob_jooseyo_sessions where chat_id=p_chat_id and expires_at>now();
       if pending is not null and pending->>'action'=op->>'action' then
        if op->>'action' in ('stop_health_alerts','rest_start','rest_end','rest_record','rest_history') then sub:=public.daddy_bob_jooseyo_bot_v7(p_chat_id,'decision',jsonb_build_object('decision',true,'expected_token',pending->>'token'));else sub:=public.daddy_bob_jooseyo_bot_v5(p_chat_id,'decision',jsonb_build_object('decision',true,'expected_token',pending->>'token'));end if;
       end if;
       if sub->'ok'='false'::jsonb then raise exception 'Nested operation failed';end if;
       if jsonb_array_length(coalesce(sub->'buttons','[]'::jsonb))>0 or exists(select 1 from public.daddy_bob_jooseyo_sessions where chat_id=p_chat_id) then raise exception 'Operation needs more input';end if;
       if sub->>'reply' like '%첫 실제 기록%' or sub->>'reply' like '%찾지 못%' or sub->>'reply' like '%찾을 수 없%' or sub->>'reply' like '%못 찾%' then raise exception 'Record scope could not be resolved';end if;
       if op->>'action' in ('children','history','status','healthhistory','care_list','rest_history') then details:=details||E'\n'||coalesce(sub->>'reply','');end if;
      end if;
     end loop;
     r:=jsonb_build_object('chat_id',p_chat_id,'ok',true,'reply','아버님, 기록을 업데이트했습니다. ('||n||'개 요청 처리)'||case when details<>'' then E'\n'||left(details,2800) else '' end||warnings,'buttons','[]'::jsonb);
    exception when others then
     get stacked diagnostics state_code=returned_sqlstate;
     delete from public.daddy_bob_jooseyo_sessions where chat_id=p_chat_id and state->>'action'='batch';
     r:=jsonb_build_object('chat_id',p_chat_id,'ok',false,'rolled_back',true,'failed_operation',failed,'error_code',state_code,
      'reply','아버님, '||failed||'번째 요청을 처리하지 못해 이번 묶음의 변경을 모두 되돌렸습니다. 기존 기록은 유지했습니다. 해당 항목을 확인해 다시 말씀해 주세요.'||warnings,'buttons','[]'::jsonb);
    end;
   end if;
  elsif r is null and act in ('medicine_cancel','medicine_snooze') then
   select s.* into slot from public.daddy_bob_jooseyo_med_slots s join public.daddy_bob_jooseyo_children c on c.id=s.child_id
    where s.id=(p_args->>'schedule_id')::uuid and c.telegram_chat_id=p_chat_id and s.active for update of s;
   if slot.id is null then label:='이미 중지됐거나 없는 일정입니다.';
   elsif act='medicine_cancel' then
    update public.daddy_bob_jooseyo_med_slots set active=false,claim_token=null,claim_until=null where id=slot.id;label:='해당 투약 알림을 중지했습니다. 실제 투약 기록은 유지합니다.';
   else
    n:=(p_args->>'minutes')::integer;if n is null or n not between 1 and 1440 then raise exception 'Invalid snooze';end if;
    if slot.end_at is not null and now()+make_interval(mins=>n)>slot.end_at then label:='종료 시각을 넘어 미루지 않았습니다.';
    else update public.daddy_bob_jooseyo_med_slots set next_due_at=now()+make_interval(mins=>n),claim_token=null,claim_until=null where id=slot.id;label:='알림을 '||n||'분 미뤘습니다. 약 투여 시각을 변경하는 지시는 아닙니다.';end if;
   end if;
   r:=jsonb_build_object('chat_id',p_chat_id,'reply','아버님, '||label,'buttons','[]'::jsonb);
  end if;
 end if;
 if r is null then
  begin r:=public.daddy_bob_jooseyo_bot_v5(p_chat_id,p_action,p_args);
  exception when others then
   r:=jsonb_build_object('chat_id',p_chat_id,'ok',false,'rolled_back',true,'reply','아버님, 업데이트하지 못해 이번 요청의 변경을 되돌렸습니다. 기존 기록은 유지했습니다. 입력 내용을 확인해 주세요.','buttons','[]'::jsonb);
  end;
 end if;
 if p_action='care_list' then
  select string_agg(c.name||' · '||s.medicine||' '||s.dose||s.dose_unit||' · 다음 '||to_char(s.next_due_at at time zone 'Asia/Seoul','MM-DD HH24:MI')||case when s.repeat_daily then ' (매일)' else ' (1회)' end||E'\n일정 ID: '||s.id,E'\n') into details
   from public.daddy_bob_jooseyo_med_slots s join public.daddy_bob_jooseyo_children c on c.id=s.child_id where c.telegram_chat_id=p_chat_id and s.active;
  if details is not null then r:=r||jsonb_build_object('reply',coalesce(r->>'reply','아버님, 현재 알림입니다.')||E'\n\n[고정 투약 일정]\n'||details);end if;
 end if;
 if uid is not null then
  if coalesce((r->>'silent')::boolean,false) or nullif(r->>'reply','') is null then
   r:=r||jsonb_build_object('silent',false,'reply',case when p_action in ('clarify','quiet_clarify') then '아버님, '||coalesce(p_args->>'question','변경할 내용을 확인해 주세요.') else '아버님, 요청을 확인했습니다. 추가 변경은 없습니다.' end,'buttons','[]'::jsonb);
  end if;
  r:=r||jsonb_build_object('silent',false);
  insert into public.daddy_bob_jooseyo_updates(update_id,response) values(uid,r) on conflict(update_id) do update set response=excluded.response;
 end if;
 return r;
end;
$v6$;
create or replace function public.daddy_bob_jooseyo_bot_v7(p_chat_id text,p_action text,p_args jsonb default '{}'::jsonb)
returns jsonb language plpgsql security definer set search_path=pg_catalog,public,auth
as $v7$
declare
 act text:=p_action;args jsonb:=p_args;uid text:=p_args->>'update_id';
 r jsonb;pending jsonb;token text;reply text;buttons jsonb:='[]';approved boolean:=false;
 child public.daddy_bob_jooseyo_children;rest public.daddy_bob_jooseyo_rests;
 kinds text[];targets uuid[];a timestamptz;b timestamptz;count1 integer:=0;count2 integer:=0;cleared integer:=0;
begin
 if auth.role() is distinct from 'service_role' or p_chat_id is distinct from '9114513581' then raise exception 'Not authorized';end if;
 perform pg_advisory_xact_lock(9114513581::bigint);
 if uid is not null then
  select response into r from public.daddy_bob_jooseyo_updates where update_id=uid;
  if found then return r||jsonb_build_object('silent',false);end if;
 end if;
 select state into pending from public.daddy_bob_jooseyo_sessions where chat_id=p_chat_id and expires_at>now();
 if act='context' then
  r:=public.daddy_bob_jooseyo_bot_v6(p_chat_id,act,'{}'::jsonb);
  return r||jsonb_build_object('rest_recent',coalesce((select jsonb_agg(to_jsonb(x)) from(
   select rr.id,c.name,rr.kind,rr.started_at,rr.ended_at,rr.duration_minutes,rr.note
   from public.daddy_bob_jooseyo_rests rr join public.daddy_bob_jooseyo_children c on c.id=rr.child_id
   where c.telegram_chat_id=p_chat_id order by rr.started_at desc limit 20)x),'[]'::jsonb));
 end if;
 begin
  if act='stop_health_alerts' then
   if jsonb_typeof(args->'stop_kinds') is distinct from 'array' then raise exception 'Stop kinds required';end if;
   select array_agg(distinct value) into kinds from jsonb_array_elements_text(args->'stop_kinds');
   if kinds is null or cardinality(kinds)=0 or not(kinds<@array['temperature','medicine']::text[]) then raise exception 'Invalid stop kinds';end if;
   if args->'all_children'='true'::jsonb then
    select array_agg(id) into targets from public.daddy_bob_jooseyo_children where telegram_chat_id=p_chat_id;
   else
    select array_agg(id) into targets from public.daddy_bob_jooseyo_children where telegram_chat_id=p_chat_id and name=args->>'name';
   end if;
   if targets is null then raise exception 'Specify child';end if;
   update public.daddy_bob_jooseyo_care_plans set active=false,claim_token=null,claim_until=null,updated_at=now()
    where child_id=any(targets) and kind=any(kinds) and active
     and(kind<>'medicine' or nullif(args->>'medicine','') is null or medicine=args->>'medicine');
   get diagnostics count1=row_count;
   if 'medicine'=any(kinds) then
    update public.daddy_bob_jooseyo_med_slots set active=false,claim_token=null,claim_until=null,updated_at=now()
     where child_id=any(targets) and active and(nullif(args->>'medicine','') is null or medicine=args->>'medicine');
    get diagnostics count2=row_count;
   end if;
   -- A previously staged schedule must not reactivate after an explicit stop.
   delete from public.daddy_bob_jooseyo_sessions ss where ss.chat_id=p_chat_id and (
    (ss.state->>'action'='care_setup' and ss.state->'args'->>'care_kind'=any(kinds) and (ss.state->'args'->>'care_kind'<>'medicine' or nullif(args->>'medicine','') is null or ss.state->'args'->>'medicine'=args->>'medicine') and exists(select 1 from public.daddy_bob_jooseyo_children c where c.id=any(targets) and c.name=ss.state->'args'->>'name'))
    or(ss.state->>'action' in ('batch','batch_draft') and exists(
     select 1 from jsonb_array_elements(coalesce(ss.state->'operations','[]'::jsonb))o
     join public.daddy_bob_jooseyo_children c on c.name=coalesce(o->'args'->>'name',o->>'name')
     where c.id=any(targets) and ((o->>'action'='medicine_schedule' and 'medicine'=any(kinds)) or(o->>'action'='care_setup' and coalesce(o->'args'->>'care_kind',o->>'care_kind')=any(kinds))) and(nullif(args->>'medicine','') is null or coalesce(o->'args'->>'medicine',o->>'medicine')=args->>'medicine'))));
   get diagnostics cleared=row_count;
   r:=jsonb_build_object('chat_id',p_chat_id,'ok',true,'stopped',count1+count2,
    'reply','아버님, '||case when 'temperature'=any(kinds) and 'medicine'=any(kinds) then '투약·체온' when 'medicine'=any(kinds) then '투약' else '체온' end||' 알림 '||(count1+count2)||'개를 중지했습니다. 기존 기록은 유지하며, 이후 수동 기록은 가능합니다.'||case when cleared>0 then ' 대기 중인 알림 설정 요청도 취소했습니다.' else '' end,
    'buttons','[]'::jsonb);
  elsif act in ('confirm','decision') and pending->>'action' in ('rest_start','rest_end','rest_record') then
   token:=case when act='confirm' then args->>'token' else args->>'expected_token' end;
   if token is distinct from pending->>'token' or(act='decision' and jsonb_typeof(args->'decision') is distinct from 'boolean') then
    r:=jsonb_build_object('chat_id',p_chat_id,'reply','아버님, 수면 확인 요청이 만료되었습니다. 다시 말씀해 주세요.','buttons','[]'::jsonb);
   elsif act='decision' and not(args->>'decision')::boolean then
    delete from public.daddy_bob_jooseyo_sessions where chat_id=p_chat_id;
    r:=jsonb_build_object('chat_id',p_chat_id,'reply','아버님, 취소했습니다. 수면 기록은 변경하지 않았습니다.','buttons','[]'::jsonb);
   else act:=pending->>'action';args:=pending->'args';approved:=true;end if;
  end if;
  if r is null and act in ('rest_start','rest_end','rest_record','rest_history') then
   select * into child from public.daddy_bob_jooseyo_children where telegram_chat_id=p_chat_id and name=args->>'name' for update;
   if child.id is null then raise exception 'Child required';end if;
   if act='rest_history' then
    select string_agg(case rr.kind when 'nap' then '낮잠' else '밤잠' end||' · '||public.daddy_bob_jooseyo_format_kst(rr.started_at)||' ~ '||coalesce(public.daddy_bob_jooseyo_format_kst(rr.ended_at),'수면 중')||case when rr.duration_minutes is null then '' else ' · '||rr.duration_minutes||'분' end,E'\n' order by rr.started_at desc)
     into reply from(select * from public.daddy_bob_jooseyo_rests where child_id=child.id order by started_at desc limit 10)rr;
    r:=jsonb_build_object('chat_id',p_chat_id,'reply','아버님, '||child.name||E' 최근 수면 기록입니다.\n'||coalesce(reply,'아직 기록이 없습니다.'),'buttons','[]'::jsonb);
   else
    if act='rest_end' then
     select * into rest from public.daddy_bob_jooseyo_rests where child_id=child.id and ended_at is null for update;
     if rest.id is null then raise exception 'No open rest';end if;
     if approved and args->>'rest_id' is distinct from rest.id::text then raise exception 'Open rest changed';end if;
     a:=rest.started_at;b:=coalesce((args->>'time')::timestamptz,now());
     args:=args||jsonb_build_object('time',b,'rest_id',rest.id,'rest_kind',rest.kind);
    elsif act='rest_start' then
     a:=coalesce((args->>'time')::timestamptz,now());b:=null;args:=args||jsonb_build_object('time',a);
    else
     a:=(args->>'started_at')::timestamptz;b:=(args->>'ended_at')::timestamptz;
     if b is null then raise exception 'End time required';end if;
    end if;
    if args->>'rest_kind' is null or args->>'rest_kind' not in ('nap','night') then raise exception 'Nap/night kind required';end if;
    if a is null or a>now() or(b is not null and(b<=a or b>now())) or(a at time zone 'Asia/Seoul')::date<child.date_of_birth then raise exception 'Invalid actual rest times';end if;
    if exists(select 1 from public.daddy_bob_jooseyo_rests rr where rr.child_id=child.id
     and(act<>'rest_end' or rr.id<>rest.id)
     and rr.started_at<coalesce(b,'infinity'::timestamptz) and coalesce(rr.ended_at,'infinity'::timestamptz)>a) then raise exception 'Overlapping rest';end if;
    reply:='아버님, '||child.name||case args->>'rest_kind' when 'nap' then ' 낮잠' else ' 밤잠' end||E'\n시작: '||public.daddy_bob_jooseyo_format_kst(a)||case when b is null then '' else E'\n기상: '||public.daddy_bob_jooseyo_format_kst(b)||E'\n수면 시간: '||round(extract(epoch from(b-a))/60,1)||'분' end;
    if not approved then
     token:=gen_random_uuid()::text;
     insert into public.daddy_bob_jooseyo_sessions values(p_chat_id,jsonb_build_object('action',act,'args',args,'token',token),now()+interval '15 minutes')
      on conflict(chat_id) do update set state=excluded.state,expires_at=excluded.expires_at;
     r:=jsonb_build_object('chat_id',p_chat_id,'reply',reply||E'\n이대로 기록할까요?',
      'buttons',jsonb_build_array(jsonb_build_object('text','확인','data','confirm:'||token),jsonb_build_object('text','취소','data','cancel')));
    else
     if act='rest_end' then update public.daddy_bob_jooseyo_rests set ended_at=b where id=rest.id;
     else insert into public.daddy_bob_jooseyo_rests(child_id,kind,started_at,ended_at,note) values(child.id,args->>'rest_kind',a,b,args->>'note');end if;
     delete from public.daddy_bob_jooseyo_sessions where chat_id=p_chat_id;
     r:=jsonb_build_object('chat_id',p_chat_id,'ok',true,'reply',reply||E'\n기록했습니다.','buttons','[]'::jsonb);
    end if;
   end if;
  end if;
 exception when others then
  if approved then delete from public.daddy_bob_jooseyo_sessions where chat_id=p_chat_id and state->>'token'=token;end if;
  r:=jsonb_build_object('chat_id',p_chat_id,'ok',false,'rolled_back',true,'reply','아버님, 처리하지 못해 이번 변경을 되돌렸습니다. 아이 이름, 진행 중인 수면, 기록 시각과 겹치는 구간을 확인해 주세요. 기존 기록은 유지했습니다.','buttons','[]'::jsonb);
 end;
 if r is null then r:=public.daddy_bob_jooseyo_bot_v6(p_chat_id,act,args);end if;
 if act='help' then r:=r||jsonb_build_object('reply',r->>'reply'||E'\n\n[알림 중지·수면]\n약이랑 체온은 그만 기록해도 돼 → 알림만 중지, 기존 기록 유지\n별이 낮잠 들었어 / 별이 밤잠 시작했어 / 별이 깼어\n별이 어제 오후 1시부터 2시까지 낮잠 잤어\n별이 수면 기록 보여줘 또는 /rest 별이');end if;
 if uid is not null then insert into public.daddy_bob_jooseyo_updates(update_id,response) values(uid,r) on conflict(update_id) do update set response=excluded.response;end if;
 return r;
end;
$v7$;
revoke all on function public.daddy_bob_jooseyo_bot_v7(text,text,jsonb) from public,anon,authenticated;
grant execute on function public.daddy_bob_jooseyo_bot_v7(text,text,jsonb) to service_role;

select to_regprocedure('public.daddy_bob_jooseyo_bot_v7(text,text,jsonb)') is not null as v7_ready;

-- Source: daddy_bob_jooseyo_v8.sql
-- Apply AFTER V7. Adds a read-only clinical timeline RPC; existing records are preserved.

create or replace function public.daddy_bob_jooseyo_bot_v8(p_chat_id text,p_action text,p_args jsonb default '{}'::jsonb)
returns jsonb language plpgsql security definer set search_path=pg_catalog,public,auth
as $v8$
declare
 r jsonb;uid text:=p_args->>'update_id';day date;start_at timestamptz;finish_at timestamptz;
 ids uuid[];lines jsonb;amount bigint;feeds bigint;count_events integer;label text;
begin
 if auth.role() is distinct from 'service_role' or p_chat_id is distinct from '9114513581' then raise exception 'Not authorized';end if;
 perform pg_advisory_xact_lock(9114513581::bigint);
 if uid is not null then select response into r from public.daddy_bob_jooseyo_updates where update_id=uid;if found then return r;end if;end if;
 if p_action='daily_timeline' then
  begin
   day:=coalesce((p_args->>'report_date')::date,(now() at time zone 'Asia/Seoul')::date);
   start_at:=day::timestamp at time zone 'Asia/Seoul';finish_at:=(day+1)::timestamp at time zone 'Asia/Seoul';
   select array_agg(id) into ids from public.daddy_bob_jooseyo_children where telegram_chat_id=p_chat_id and(nullif(p_args->>'name','') is null or name=p_args->>'name');
   if ids is null and nullif(p_args->>'name','') is not null then
    r:=jsonb_build_object('chat_id',p_chat_id,'reply','아버님, 해당 아이의 이름을 찾지 못했습니다. /children에서 확인해 주세요.','buttons','[]'::jsonb);
   else
    with events as (
     select f.fed_at as event_at,1 as rank,f.id::text as tie,
      to_char(f.fed_at at time zone 'Asia/Seoul','HH24:MI') as clock,
      c.name||' · 수유 '||f.amount_ml||'ml'||case when f.prepared_ml is not null then ' (조유 '||f.prepared_ml||'ml)' else '' end||case when nullif(f.note,'') is null then '' else ' · '||f.note end as text
     from public.daddy_bob_jooseyo_feedings f join public.daddy_bob_jooseyo_children c on c.id=f.child_id
     where f.child_id=any(ids) and f.fed_at>=start_at and f.fed_at<finish_at
     union all
     select h.occurred_at,2,h.id::text,to_char(h.occurred_at at time zone 'Asia/Seoul','HH24:MI'),
      c.name||' · '||case h.kind when 'temperature' then '체온 '||h.temperature_c||'℃' when 'medicine' then '실제 투약 '||h.medicine||' '||h.dose||h.dose_unit else '메모 · '||h.note end||
       case when h.kind<>'note' and nullif(h.note,'') is not null then ' · '||h.note else '' end
     from public.daddy_bob_jooseyo_health h join public.daddy_bob_jooseyo_children c on c.id=h.child_id
     where h.child_id=any(ids) and h.occurred_at>=start_at and h.occurred_at<finish_at
     union all
     select s.started_at,3,s.id::text,to_char(s.started_at at time zone 'Asia/Seoul','HH24:MI'),
      c.name||' · '||case s.kind when 'nap' then '낮잠' else '밤잠' end||' 시작'||case when s.ended_at is null then ' (현재 수면 중)' else '' end||case when nullif(s.note,'') is null then '' else ' · '||s.note end
     from public.daddy_bob_jooseyo_rests s join public.daddy_bob_jooseyo_children c on c.id=s.child_id
     where s.child_id=any(ids) and s.started_at>=start_at and s.started_at<finish_at
     union all
     select s.ended_at,4,s.id::text,to_char(s.ended_at at time zone 'Asia/Seoul','HH24:MI'),
      c.name||' · '||case s.kind when 'nap' then '낮잠' else '밤잠' end||' 기상 · 총 '||s.duration_minutes||'분'||case when s.started_at<start_at then ' (시작 '||public.daddy_bob_jooseyo_format_kst(s.started_at)||')' else '' end
     from public.daddy_bob_jooseyo_rests s join public.daddy_bob_jooseyo_children c on c.id=s.child_id
     where s.child_id=any(ids) and s.ended_at>=start_at and s.ended_at<finish_at
     union all
     select start_at,0,s.id::text,'00:00',c.name||' · 전날부터 '||case s.kind when 'nap' then '낮잠' else '밤잠' end||' 이어짐 (시작 '||public.daddy_bob_jooseyo_format_kst(s.started_at)||')'
     from public.daddy_bob_jooseyo_rests s join public.daddy_bob_jooseyo_children c on c.id=s.child_id
     where s.child_id=any(ids) and s.started_at<start_at and(s.ended_at is null or s.ended_at>start_at)
     union all
     select case when(g.created_at at time zone 'Asia/Seoul')::date=day then g.created_at else start_at end,5,g.id::text,
      case when(g.created_at at time zone 'Asia/Seoul')::date=day then to_char(g.created_at at time zone 'Asia/Seoul','HH24:MI') else '시각 미입력' end,
      c.name||' · 성장 기록'||case when(g.created_at at time zone 'Asia/Seoul')::date=day then ' (등록 시각)' else '' end||' '||g.weight_kg||'kg'||case when g.height_cm is null then '' else ' / '||g.height_cm||'cm' end
     from public.daddy_bob_jooseyo_growth g join public.daddy_bob_jooseyo_children c on c.id=g.child_id
     where g.child_id=any(ids) and g.measured_on=day
    )
    select coalesce(jsonb_agg(clock||'  '||text order by event_at,rank,tie),'[]'::jsonb),count(*)::integer into lines,count_events from events;
    select coalesce(sum(amount_ml),0),count(*) into amount,feeds from public.daddy_bob_jooseyo_feedings where child_id=any(ids) and fed_at>=start_at and fed_at<finish_at;
    label:=coalesce(nullif(p_args->>'name',''),'전체 아이');
    r:=jsonb_build_object('chat_id',p_chat_id,'report_date',day,'timeline_lines',lines,'event_count',count_events,
     'reply','아버님, '||to_char(day,'YYYY"년" FMMM"월" FMDD"일"')||' '||label||E' 기록입니다. (한국 시간)\n'||
      '수유 '||feeds||'회 · 총 '||amount||'ml · 타임라인 '||count_events||'항목'||case when count_events=0 then E'\n이 날짜의 실제 기록이 없습니다.' else '' end,
     'buttons','[]'::jsonb);
   end if;
  exception when others then
   r:=jsonb_build_object('chat_id',p_chat_id,'ok',false,'reply','아버님, 하루 기록을 불러오지 못했습니다. 날짜와 아이 이름을 확인해 주세요. 기존 기록은 변경하지 않았습니다.','buttons','[]'::jsonb);
  end;
 else r:=public.daddy_bob_jooseyo_bot_v7(p_chat_id,p_action,p_args);end if;
 -- Today totals use every actual feeding in the Korean calendar day, not the last-ten history list.
 if p_action='history' then
  select array_agg(c.id) into ids from public.daddy_bob_jooseyo_children c
   where c.telegram_chat_id=p_chat_id and (c.name=p_args->>'name' or
    (nullif(p_args->>'name','') is null and (select count(*) from public.daddy_bob_jooseyo_children where telegram_chat_id=p_chat_id)=1));
  if cardinality(ids)=1 and r->>'reply' is not null then
   start_at:=((now() at time zone 'Asia/Seoul')::date)::timestamp at time zone 'Asia/Seoul';
   finish_at:=start_at+interval '24 hours';
   select coalesce(sum(amount_ml),0),count(*) into amount,feeds from public.daddy_bob_jooseyo_feedings
    where child_id=any(ids) and fed_at>=start_at and fed_at<finish_at;
   label:='오늘 총 수유량: '||amount||'ml / 1,000ml · '||feeds||'회 (한국 시간)'||E'\n'||
    case when amount<1000 then '설정 기준까지 남은 양: '||(1000-amount)||'ml'
     when amount=1000 then '설정 기준 1,000ml에 도달했습니다.'
     else '설정 기준보다 '||(amount-1000)||'ml 초과했습니다.' end;
   r:=r||jsonb_build_object('today_total_ml',amount,'today_feed_count',feeds,'daily_reference_ml',1000,
    'reply',label||E'\n\n'||(r->>'reply'));
  end if;
 end if;
 if uid is not null then insert into public.daddy_bob_jooseyo_updates(update_id,response) values(uid,r) on conflict(update_id) do update set response=excluded.response;end if;
 return r;
end;
$v8$;
revoke all on function public.daddy_bob_jooseyo_bot_v8(text,text,jsonb) from public,anon,authenticated;
grant execute on function public.daddy_bob_jooseyo_bot_v8(text,text,jsonb) to service_role;

select to_regprocedure('public.daddy_bob_jooseyo_bot_v8(text,text,jsonb)') is not null as v8_ready;

notify pgrst, 'reload schema';
commit;
select to_regprocedure('public.daddy_bob_jooseyo_bot_v8(text,text,jsonb)') is not null as v8_ready;
