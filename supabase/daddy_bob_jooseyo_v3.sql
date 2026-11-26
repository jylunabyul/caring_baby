-- Apply AFTER the V2 upgrade. Preserves existing application records.
-- Creates/replaces only daddy_bob_jooseyo_ objects. No shared Auth/settings changes.
begin;
alter table public.daddy_bob_jooseyo_children
 add column if not exists quiet_enabled boolean not null default true,
 add column if not exists quiet_start time not null default '22:00',
 add column if not exists quiet_end time not null default '08:00';

create or replace function public.daddy_bob_jooseyo_is_quiet(p_start time,p_end time,p_clock time)
returns boolean language sql immutable set search_path = pg_catalog as $$
 select case when p_start=p_end then false
   when p_start<p_end then p_clock>=p_start and p_clock<p_end
   else p_clock>=p_start or p_clock<p_end end;
$$;
revoke all on function public.daddy_bob_jooseyo_is_quiet(time,time,time) from public, anon, authenticated;
grant execute on function public.daddy_bob_jooseyo_is_quiet(time,time,time) to service_role;

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
     when 'feed' then c.name||' 먹은 양 '||amount||'ml / 조유량 '||prepared||'ml를 저장할까요?'||case when args ? 'time' then E'\n기록 시각: '||(args->>'time') else ' (확인 시각으로 기록)' end
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
commit;
