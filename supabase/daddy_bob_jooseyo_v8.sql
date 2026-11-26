-- Apply AFTER V7. Adds a read-only clinical timeline RPC; existing records are preserved.
begin;
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
commit;
select to_regprocedure('public.daddy_bob_jooseyo_bot_v8(text,text,jsonb)') is not null as v8_ready;
