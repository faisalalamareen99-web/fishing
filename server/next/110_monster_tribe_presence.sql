-- عنقاء النار: هجوم جماعي لأعضاء القبيلة، وظهور سفنهم في محيط الوحش
-- ملف مستقل: يُنشئ الجداول إن لم تكن موجودة ويستبدل الدالتين (آمن سواء شُغّل 109 أم لا).
create table if not exists public.tribe_monster (
  tribe_key text primary key,
  hp bigint not null default 1000000,
  kills int not null default 0,
  updated_at timestamptz not null default now()
);
create table if not exists public.monster_dmg (
  tribe_key text not null,
  user_id uuid not null,
  dmg bigint not null default 0,
  hits int not null default 0,
  primary key (tribe_key, user_id)
);
create table if not exists public.monster_ships (
  tribe_key text not null,
  user_id uuid not null,
  slot int not null,
  last_seen timestamptz not null default now(),
  last_w text,
  seq bigint not null default 0,
  primary key (tribe_key, user_id)
);
create sequence if not exists public.monster_seq;
alter table public.tribe_monster enable row level security;
alter table public.monster_dmg enable row level security;
alter table public.monster_ships enable row level security;
revoke all on public.tribe_monster, public.monster_dmg, public.monster_ships from anon, authenticated;

drop function if exists public.monster_info();
create or replace function public.monster_info(p_slot int default null)
returns jsonb language plpgsql security definer set search_path = public as $$
declare
  uid uuid := auth.uid();
  tk text;
  m public.tribe_monster%rowtype;
  lst jsonb;
begin
  if uid is null then raise exception 'غير مسجّل الدخول'; end if;
  select tribe_id::text into tk from public.tribe_members where user_id = uid;
  if tk is null then raise exception 'يجب أن تكون في قبيلة'; end if;
  insert into public.tribe_monster (tribe_key) values (tk) on conflict (tribe_key) do nothing;
  select * into m from public.tribe_monster where tribe_key = tk;
  -- بقاء سفينتي ظاهرة لبقية الأعضاء (نبضة كل بضع ثوانٍ)
  if p_slot is not null and exists (select 1 from public.ships where user_id = uid and slot = p_slot and owned) then
    insert into public.monster_ships (tribe_key, user_id, slot, last_seen) values (tk, uid, p_slot, now())
    on conflict (tribe_key, user_id) do update set slot = excluded.slot, last_seen = now();
  end if;
  select coalesce(jsonb_agg(jsonb_build_object(
      'k', p.public_id, 'name', p.name, 'type', s.type, 'hp', s.hp, 'max', t.max_hp,
      'w', ms.last_w, 'seq', ms.seq) order by p.public_id), '[]'::jsonb)
    into lst
    from public.monster_ships ms
    join public.players p on p.user_id = ms.user_id
    join public.ships s on s.user_id = ms.user_id and s.slot = ms.slot
    join public.ship_types t on t.type = s.type
   where ms.tribe_key = tk and ms.user_id <> uid and ms.last_seen > now() - interval '45 seconds';
  return jsonb_build_object('hp', m.hp, 'max', 1000000, 'kills', m.kills,
    'my_dmg', coalesce((select dmg from public.monster_dmg where tribe_key = tk and user_id = uid), 0),
    'ships', lst);
end $$;

create or replace function public.monster_attack(p_slot int, p_weapon text)
returns jsonb language plpgsql security definer set search_path = public as $$
declare
  uid uuid := auth.uid();
  tk text;
  w public.weapon_types%rowtype;
  s public.ships%rowtype;
  t public.ship_types%rowtype;
  m public.tribe_monster%rowtype;
  q bigint;
  newm bigint;
  dealt bigint;
  killed boolean;
  loss int := 0;
  newhp int;
begin
  if uid is null then raise exception 'غير مسجّل الدخول'; end if;
  perform public.fg_ensure(uid);
  select tribe_id::text into tk from public.tribe_members where user_id = uid;
  if tk is null then raise exception 'يجب أن تكون في قبيلة'; end if;
  if p_weapon is null or p_weapon = 'msgbomb' then raise exception 'سلاح غير صالح'; end if;
  select * into w from public.weapon_types where weapon = p_weapon;
  if not found then raise exception 'سلاح غير معروف'; end if;
  select qty into q from public.weapons where user_id = uid and weapon = p_weapon for update;
  if q is null or q < 1 then raise exception 'لا تملك هذا السلاح'; end if;
  select * into s from public.ships where user_id = uid and slot = p_slot and owned and hp > 0 for update;
  if not found then raise exception 'السفينة غير صالحة للهجوم'; end if;
  select * into t from public.ship_types where type = s.type;

  insert into public.tribe_monster (tribe_key) values (tk) on conflict (tribe_key) do nothing;
  select * into m from public.tribe_monster where tribe_key = tk for update;  -- يقفل الصف: الهجمات المتزامنة تُنفَّذ بالتتابع

  newm := greatest(0, m.hp - w.dmg);
  dealt := m.hp - newm;
  killed := newm = 0;
  update public.weapons set qty = qty - 1 where user_id = uid and weapon = p_weapon;
  insert into public.monster_dmg (tribe_key, user_id, dmg, hits) values (tk, uid, dealt, 1)
  on conflict (tribe_key, user_id) do update set dmg = public.monster_dmg.dmg + excluded.dmg, hits = public.monster_dmg.hits + 1;

  if killed then
    update public.tribe_monster set hp = 1000000, kills = kills + 1, updated_at = now() where tribe_key = tk;
    newhp := s.hp;
  else
    update public.tribe_monster set hp = newm, updated_at = now() where tribe_key = tk;
    loss := ceil(t.max_hp * 0.10);
    newhp := greatest(0, s.hp - loss);
    update public.ships
       set hp = newhp,
           state = case when newhp < t.max_hp * 0.1 then 'idle' else state end,
           started_at = case when newhp < t.max_hp * 0.1 then null else started_at end,
           fish = case when newhp < t.max_hp * 0.1 then null else fish end
     where user_id = uid and slot = p_slot;
  end if;

  insert into public.monster_ships (tribe_key, user_id, slot, last_seen, last_w, seq)
  values (tk, uid, p_slot, now(), p_weapon, nextval('public.monster_seq'))
  on conflict (tribe_key, user_id) do update
    set slot = excluded.slot, last_seen = now(), last_w = excluded.last_w, seq = excluded.seq;

  return public.fg_state_json(uid) || jsonb_build_object('monster', jsonb_build_object(
    'hp', newm, 'prev_hp', m.hp, 'max', 1000000, 'killed', killed, 'dmg', dealt,
    'kills', m.kills + (case when killed then 1 else 0 end),
    'ship_slot', p_slot, 'ship_hp', newhp, 'ship_loss', s.hp - newhp));
end $$;

revoke all on function public.monster_info(int) from public, anon;
grant execute on function public.monster_info(int) to authenticated;
revoke all on function public.monster_attack(int, text) from public, anon;
grant execute on function public.monster_attack(int, text) to authenticated;
notify pgrst, 'reload schema';
