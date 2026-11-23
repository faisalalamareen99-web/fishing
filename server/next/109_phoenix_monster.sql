-- عنقاء النار: وحش القبيلة (قوته 1,000,000 نقطة، مشترك بين أعضاء القبيلة)
-- كل هجوم يستهلك سلاحًا ويُنقص من قوة الوحش، ويردّ الوحش بكرة نار تُنقص 10% من صحة السفينة المهاجمة.
-- عند هزيمة الوحش تُسجَّل هزيمة للقبيلة ويعود كامل القوة.
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
alter table public.tribe_monster enable row level security;
alter table public.monster_dmg enable row level security;
revoke all on public.tribe_monster from anon, authenticated;
revoke all on public.monster_dmg from anon, authenticated;

create or replace function public.monster_info()
returns jsonb language plpgsql security definer set search_path = public as $$
declare
  uid uuid := auth.uid();
  tk text;
  m public.tribe_monster%rowtype;
begin
  if uid is null then raise exception 'غير مسجّل الدخول'; end if;
  select tribe_id::text into tk from public.tribe_members where user_id = uid;
  if tk is null then raise exception 'يجب أن تكون في قبيلة'; end if;
  insert into public.tribe_monster (tribe_key) values (tk) on conflict (tribe_key) do nothing;
  select * into m from public.tribe_monster where tribe_key = tk;
  return jsonb_build_object('hp', m.hp, 'max', 1000000, 'kills', m.kills,
    'my_dmg', coalesce((select dmg from public.monster_dmg where tribe_key = tk and user_id = uid), 0));
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
  select * into m from public.tribe_monster where tribe_key = tk for update;

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

  return public.fg_state_json(uid) || jsonb_build_object('monster', jsonb_build_object(
    'hp', newm, 'prev_hp', m.hp, 'max', 1000000, 'killed', killed, 'dmg', dealt,
    'kills', m.kills + (case when killed then 1 else 0 end),
    'ship_slot', p_slot, 'ship_hp', newhp, 'ship_loss', s.hp - newhp));
end $$;

revoke all on function public.monster_info() from public, anon;
grant execute on function public.monster_info() to authenticated;
revoke all on function public.monster_attack(int, text) from public, anon;
grant execute on function public.monster_attack(int, text) to authenticated;
notify pgrst, 'reload schema';
