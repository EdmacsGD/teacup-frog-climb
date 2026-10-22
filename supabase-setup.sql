-- Teacup Frog Climb: accounts and leaderboard
-- Run this once in Supabase: SQL Editor -> New query -> paste all of it -> Run.
-- Safe to run again: it only creates what is missing.

-- 1. Player names. One row per account, made automatically when someone signs up.
create table if not exists public.profiles (
  id uuid primary key references auth.users (id) on delete cascade,
  username text not null check (username ~ '^[A-Za-z0-9_]{3,16}$'),
  created_at timestamptz not null default now()
);
-- "Frog" and "frog" count as the same name
create unique index if not exists profiles_username_unique on public.profiles (lower(username));

-- 2. Finished climbs. The game adds one row every time someone reaches the top.
create table if not exists public.runs (
  id bigint generated always as identity primary key,
  user_id uuid not null default auth.uid() references public.profiles (id) on delete cascade,
  map_id text not null check (char_length(map_id) between 1 and 40),
  time_seconds numeric(10, 2) not null check (time_seconds >= 60 and time_seconds < 360000),
  falls integer not null default 0 check (falls between 0 and 100000),
  created_at timestamptz not null default now()
);
create index if not exists runs_board on public.runs (map_id, time_seconds);

-- 3. Who may do what (Row Level Security). Without these, anyone with the
--    public key could change or delete other people's times.
alter table public.profiles enable row level security;
alter table public.runs enable row level security;

drop policy if exists "names are public" on public.profiles;
create policy "names are public" on public.profiles for select to anon, authenticated using (true);

drop policy if exists "times are public" on public.runs;
create policy "times are public" on public.runs for select to anon, authenticated using (true);

drop policy if exists "add your own times" on public.runs;
create policy "add your own times" on public.runs for insert to authenticated
  with check (user_id = (select auth.uid()));
-- No update or delete policies: nobody can edit or remove a time from the game.

-- At most one finished climb per player per minute, so a broken script can't flood the board.
create or replace function public.limit_runs() returns trigger
language plpgsql security definer set search_path = '' as $$
begin
  if exists (select 1 from public.runs r where r.user_id = new.user_id and r.created_at > now() - interval '1 minute') then
    raise exception 'Too many runs. Wait a minute.';
  end if;
  return new;
end; $$;
drop trigger if exists runs_limit on public.runs;
create trigger runs_limit before insert on public.runs for each row execute function public.limit_runs();

-- 4. Make the profile when an account is created. The game sends the name along
--    with the sign-up; a taken or invalid name makes the sign-up fail.
create or replace function public.handle_new_user() returns trigger
language plpgsql security definer set search_path = '' as $$
begin
  insert into public.profiles (id, username) values (new.id, new.raw_user_meta_data ->> 'username');
  return new;
end; $$;
drop trigger if exists on_auth_user_created on auth.users;
create trigger on_auth_user_created after insert on auth.users for each row execute function public.handle_new_user();

-- 5. The leaderboard: each player's best time on each map.
create or replace view public.leaderboard with (security_invoker = true) as
select distinct on (r.map_id, r.user_id)
  r.map_id, r.user_id, p.username, r.time_seconds, r.falls, r.created_at
from public.runs r
join public.profiles p on p.id = r.user_id
order by r.map_id, r.user_id, r.time_seconds asc, r.created_at asc;

grant select on public.leaderboard to anon, authenticated;

-- 6. Admins: players who may publish the main map. Only you add them, here in SQL.
create table if not exists public.admins (
  user_id uuid primary key references auth.users (id) on delete cascade
);
alter table public.admins enable row level security;
drop policy if exists "see if you are an admin" on public.admins;
create policy "see if you are an admin" on public.admins for select to authenticated
  using (user_id = (select auth.uid()));

-- 7. The main map, as published from the map maker. Everyone reads it; only admins write it.
create table if not exists public.maps (
  id text primary key check (id ~ '^[a-z0-9-]{1,40}$'),
  data jsonb not null check (octet_length(data::text) < 3000000),
  version integer not null default 1,
  board text not null default 'main-v2' check (board ~ '^[a-z0-9-]{1,40}$'),
  updated_at timestamptz not null default now(),
  updated_by uuid default auth.uid()
);
alter table public.maps enable row level security;
drop policy if exists "maps are public" on public.maps;
create policy "maps are public" on public.maps for select to anon, authenticated using (true);
drop policy if exists "admins publish maps" on public.maps;
create policy "admins publish maps" on public.maps for insert to authenticated
  with check (exists (select 1 from public.admins a where a.user_id = (select auth.uid())));
drop policy if exists "admins update maps" on public.maps;
create policy "admins update maps" on public.maps for update to authenticated
  using (exists (select 1 from public.admins a where a.user_id = (select auth.uid())))
  with check (exists (select 1 from public.admins a where a.user_id = (select auth.uid())));

-- Every publish gets the next version number, so the game knows a newer map exists
create or replace function public.bump_map_version() returns trigger
language plpgsql set search_path = '' as $$
begin
  if tg_op = 'UPDATE' then new.version := old.version + 1; end if;
  new.updated_at := now();
  new.updated_by := auth.uid();
  return new;
end; $$;
drop trigger if exists maps_version on public.maps;
create trigger maps_version before insert or update on public.maps for each row execute function public.bump_map_version();

-- 8. Make the player named Edmacs an admin. Make that account in the game FIRST,
--    then run this file again (or just these lines). Change the name to add someone else.
insert into public.admins (user_id)
select id from public.profiles where lower(username) = 'edmacs'
on conflict do nothing;

-- 9. Player levels: anyone logged in can upload maps from the map maker; everyone can play them.
create table if not exists public.levels (
  id bigint generated always as identity primary key,
  user_id uuid not null default auth.uid() references public.profiles (id) on delete cascade,
  title text not null check (char_length(btrim(title)) between 1 and 40),
  data jsonb not null check (octet_length(data::text) < 1500000),
  plays integer not null default 0,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);
create index if not exists levels_new on public.levels (created_at desc);
alter table public.levels enable row level security;
drop policy if exists "levels are public" on public.levels;
create policy "levels are public" on public.levels for select to anon, authenticated using (true);
drop policy if exists "upload your own levels" on public.levels;
create policy "upload your own levels" on public.levels for insert to authenticated
  with check (user_id = (select auth.uid()));
drop policy if exists "update your own levels" on public.levels;
create policy "update your own levels" on public.levels for update to authenticated
  using (user_id = (select auth.uid())) with check (user_id = (select auth.uid()));
-- you can delete your own levels; admins can delete any level (for anything mean or broken)
drop policy if exists "delete your own levels" on public.levels;
create policy "delete your own levels" on public.levels for delete to authenticated
  using (user_id = (select auth.uid()) or exists (select 1 from public.admins a where a.user_id = (select auth.uid())));

-- At most 30 levels per player, one upload every 15 seconds, and nobody can fake their play count
create or replace function public.guard_levels() returns trigger
language plpgsql security definer set search_path = '' as $$
begin
  if current_setting('teacup.counting_play', true) = 'on' then return new; end if;   -- count_play below
  if tg_op = 'INSERT' then
    new.plays := 0; new.created_at := now();
    if (select count(*) from public.levels l where l.user_id = new.user_id) >= 30 then
      raise exception 'You have 30 levels already. Delete one first.';
    end if;
  else
    new.plays := old.plays; new.user_id := old.user_id; new.created_at := old.created_at;
  end if;
  if exists (select 1 from public.levels l where l.user_id = new.user_id and l.updated_at > now() - interval '15 seconds'
             and (tg_op = 'INSERT' or l.id <> new.id)) then
    raise exception 'Too fast. Wait a few seconds and try again.';
  end if;
  new.updated_at := now();
  return new;
end; $$;
drop trigger if exists levels_guard on public.levels;
create trigger levels_guard before insert or update on public.levels for each row execute function public.guard_levels();

-- Counting a play: the only way to change "plays", one at a time
create or replace function public.count_play(level_id bigint) returns void
language plpgsql security definer set search_path = '' as $$
begin
  perform set_config('teacup.counting_play', 'on', true);   -- lets this one update past the guard
  update public.levels set plays = plays + 1 where id = level_id;
  perform set_config('teacup.counting_play', 'off', true);
end; $$;
revoke all on function public.count_play(bigint) from public;
grant execute on function public.count_play(bigint) to anon, authenticated;

-- The list players browse: no map data, plus the maker's name
create or replace view public.level_list with (security_invoker = true) as
select l.id, l.title, l.user_id, p.username, l.plays, l.created_at, l.updated_at
from public.levels l join public.profiles p on p.id = l.user_id;
grant select on public.level_list to anon, authenticated;

-- Times on player levels go on that level's own board (map_id "lvl-<id>"); short levels are fine there
alter table public.runs drop constraint if exists runs_time_seconds_check;
alter table public.runs add constraint runs_time_seconds_check
  check (time_seconds < 360000 and time_seconds >= case when map_id like 'lvl-%' then 3 else 60 end);
