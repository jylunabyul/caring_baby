-- Apply after V6. Keep original timestamptz as the canonical instant.
-- Generated stored columns materialize UTC/KST automatically for existing and future rows.
-- Do not insert/update generated columns from n8n. Write only the original instant.
begin;
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


commit;
notify pgrst, 'reload schema';
-- Both views of the same instant; only KST is shown in bot replies.
select fed_at, fed_at_utc, fed_at_kst from public.daddy_bob_jooseyo_feedings order by fed_at desc limit 5;
