-- Apply AFTER V3. Data-preserving personal bot upgrade; only prefixed objects change.
begin;
alter table public.daddy_bob_jooseyo_children
 add column if not exists morning_enabled boolean not null default true,
 add column if not exists morning_time time not null default '08:00',
 add column if not exists morning_end time not null default '09:00',
 add column if not exists morning_plan_ml integer not null default 200,
 add column if not exists morning_sent_on date,
 add column if not exists morning_claim_until timestamptz;
create table if not exists public.daddy_bob_jooseyo_health (
 id uuid primary key default gen_random_uuid(),
 child_id uuid not null references public.daddy_bob_jooseyo_children(id) on delete cascade,
 kind text not null check (kind in ('temperature','medicine','note')),
 occurred_at timestamptz not null default now(),
 temperature_c numeric(4,1),
 medicine text, dose numeric, dose_unit text, note text,
 created_at timestamptz not null default now(),
 check (kind<>'temperature' or temperature_c between 30 and 45),
 check (kind<>'temperature' or temperature_c is not null),
 check (kind<>'medicine' or (nullif(trim(medicine),'') is not null and dose>0 and dose_unit in ('ml','mg','g','방울','정','포'))),
 check (kind<>'medicine' or (dose is not null and dose_unit is not null)),
 check (kind<>'note' or nullif(trim(note),'') is not null)
);
create index if not exists daddy_bob_jooseyo_health_child_time on public.daddy_bob_jooseyo_health(child_id,occurred_at desc);
create table if not exists public.daddy_bob_jooseyo_chat_guard (
 chat_id text primary key check(chat_id='9114513581'),
 last_hint_at timestamptz
);
alter table public.daddy_bob_jooseyo_health enable row level security;
alter table public.daddy_bob_jooseyo_chat_guard enable row level security;
revoke all on public.daddy_bob_jooseyo_health, public.daddy_bob_jooseyo_chat_guard from public,anon,authenticated;
grant all on public.daddy_bob_jooseyo_health, public.daddy_bob_jooseyo_chat_guard to service_role;

-- Deterministic style changes: never ask another model to rewrite recorded facts or medical warnings.
create or replace function public.daddy_bob_jooseyo_tone(p_text text)
returns text language plpgsql immutable set search_path=pg_catalog as $$
declare t text:=p_text;
begin
 if t is null then return null; end if;
 t:=replace(t,'저장 완료','기록해뒀어');
 t:=replace(t,'ml를 저장할까요?','ml, 이대로 남겨둘까?');
 t:=replace(t,'확인해 주세요','확인해줘');
 t:=replace(t,'알려주세요','알려줘');
 t:=replace(t,'입력해 주세요','입력해줘');
 t:=replace(t,'취소했어요. 기록은 변경하지 않았습니다.','취소했어. 기록은 그대로 둘게.');
 t:=replace(t,'수유 기록을 수정했어요.','수유 기록 바꿔뒀어.');
 t:=replace(t,'수유 기록 삭제 완료.','수유 기록 지웠어.');
 t:=replace(t,'알림 시간 설정을 변경했어요.','알림 시간 바꿔뒀어.');
 if left(t,2)<>'오빠' then t:='오빠, '||t; end if;
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
     'reply','오빠, 아침이야 ☀️ '||rec.name||' 일어났으면 수유 챙겨주자.'||E'\n오빠가 정해둔 아침 수유 계획은 '||rec.morning_plan_ml||'ml야. 이미 먹였으면 또 먹이지 말고 실제 먹은 양만 알려줘.'||E'\n아기 상태와 의료진 지침을 우선해 주세요.'));
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
    r:=jsonb_build_object('chat_id',p_chat_id,'reply',public.daddy_bob_jooseyo_tone(coalesce(args->>'question','조금 애매하네. 확인 버튼을 눌러주거나 바꿀 내용만 알려줘.')),'buttons','[]'::jsonb);
   end if;
 else
   -- New health/morning actions use the same one-time confirmation session as feeding.
   if act in ('confirm','decision') and pending->>'action' in ('health','morning') then
    token:=case when act='confirm' then args->>'token' else args->>'expected_token' end;
    if token is distinct from pending->>'token' or (act='decision' and jsonb_typeof(args->'decision') is distinct from 'boolean') then
     r:=jsonb_build_object('chat_id',p_chat_id,'silent',true,'buttons','[]'::jsonb);
    elsif act='decision' and not (args->>'decision')::boolean then
     delete from public.daddy_bob_jooseyo_sessions where chat_id=p_chat_id;
     r:=jsonb_build_object('chat_id',p_chat_id,'reply','오빠, 취소했어. 기록은 그대로 둘게.','buttons','[]'::jsonb);
    else act:=pending->>'action';args:=pending->'args';ok:=true;end if;
   end if;
   if r is null and act in ('health','healthhistory','morning') then
    select * into ch from public.daddy_bob_jooseyo_children where telegram_chat_id=p_chat_id and name=args->>'name' for update;
    if ch.id is null then
     r:=jsonb_build_object('chat_id',p_chat_id,'reply','오빠, 아이 이름을 못 찾았어. /children에서 한 번 확인해줘.','buttons','[]'::jsonb);
    elsif act='healthhistory' then
     select string_agg(to_char(hh.occurred_at at time zone 'Asia/Seoul','MM-DD HH24:MI')||' · '||case hh.kind
       when 'temperature' then '체온 '||hh.temperature_c||'℃'
       when 'medicine' then hh.medicine||' '||hh.dose||hh.dose_unit
       else hh.note end,E'\n' order by hh.occurred_at desc) into reply
      from (select * from public.daddy_bob_jooseyo_health where child_id=ch.id order by occurred_at desc limit 10)hh;
     r:=jsonb_build_object('chat_id',p_chat_id,'reply','오빠, '||ch.name||E' 특이사항 최근 기록이야.\n'||coalesce(reply,'아직 기록은 없어.'),'buttons','[]'::jsonb);
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
      reply:='아침 알림 '||case when (args->>'enabled')::boolean then '08:00~09:00, 오빠가 정한 계획 '||(args->>'plan_ml')||'ml' else '끄기' end;
     end if;
     if not ok then
      token:=gen_random_uuid()::text;
      insert into public.daddy_bob_jooseyo_sessions values(p_chat_id,jsonb_build_object('action',act,'args',args,'token',token),now()+interval '15 minutes')
       on conflict(chat_id) do update set state=excluded.state,expires_at=excluded.expires_at;
      buttons:=jsonb_build_array(jsonb_build_object('text','응, 맞아','data','confirm:'||token),jsonb_build_object('text','아니, 취소','data','cancel'));
      reply:='오빠, '||ch.name||' '||reply||case when act='health' then E'\n시각: '||to_char(t at time zone 'Asia/Seoul','MM-DD HH24:MI') else '' end||E'\n이대로 남겨둘까?';
     else
      delete from public.daddy_bob_jooseyo_sessions where chat_id=p_chat_id;
      if act='health' then
       insert into public.daddy_bob_jooseyo_health(child_id,kind,occurred_at,temperature_c,medicine,dose,dose_unit,note)
        values(ch.id,args->>'health_kind',t,(args->>'temperature')::numeric,args->>'medicine',(args->>'dose')::numeric,args->>'dose_unit',args->>'note') returning * into h;
       reply:='오빠, '||ch.name||' '||reply||' 기록해뒀어. ('||to_char(t at time zone 'Asia/Seoul','MM-DD HH24:MI')||')';
      else
       update public.daddy_bob_jooseyo_children set morning_enabled=(args->>'enabled')::boolean,morning_plan_ml=case when (args->>'enabled')::boolean then (args->>'plan_ml')::integer else morning_plan_ml end where id=ch.id;
       reply:='오빠, 아침 알림 설정해뒀어. 먹은 양은 알림만으로 기록하지 않을게.';
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
     if act='help' then r:=r||jsonb_build_object('reply',r->>'reply'||E'\n\n[특이사항]\n별이 체온 38.2도야 / 별이 타이레놀 2.5ml 줬어 / 별이 오늘 기침했어\n별이 특이사항 보여줘\n/temp 별이 38.2\n/medicine 별이 약이름 2.5 ml\n/note 별이 기침했어\n/health 별이\n/morning 별이 200 — 아침 8~9시 계획 알림 설정\n응·웅·ㅇㅇ / 아니·아뇨·ㄴㄴ로 답해도 돼. 애매하면 확인 버튼을 눌러줘.');end if;
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
commit;
