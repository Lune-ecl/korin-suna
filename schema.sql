-- =============================================================
--  KORIN DE SUNA : base de données Supabase
--  À coller en entier dans Supabase → SQL Editor → New query → Run
-- =============================================================

-- Équipes (2 combattants)
create table if not exists public.teams (
  id          uuid primary key default gen_random_uuid(),
  name        text not null unique,
  player1     text not null,
  player2     text not null,
  created_at  timestamptz not null default now()
);

-- Combats du tableau (élimination directe)
create table if not exists public.matches (
  id          uuid primary key default gen_random_uuid(),
  round       int  not null,                 -- 1 = premier tour
  slot        int  not null,                 -- position dans le tour
  team_a      uuid references public.teams(id) on delete set null,
  team_b      uuid references public.teams(id) on delete set null,
  odds_a      numeric(6,2) not null default 2,
  odds_b      numeric(6,2) not null default 2,
  winner      uuid references public.teams(id) on delete set null,
  status      text not null default 'a_venir'
              check (status in ('a_venir','ouvert','ferme','termine')),
  bye         boolean not null default false, -- équipe exemptée
  decided_at  timestamptz,
  unique (round, slot)
);

-- Paris (la cote est gelée au moment du pari)
create table if not exists public.bets (
  id          uuid primary key default gen_random_uuid(),
  bettor      text not null,
  match_id    uuid not null references public.matches(id) on delete cascade,
  team_id     uuid not null references public.teams(id) on delete cascade,
  amount      int  not null check (amount > 0),
  odds        numeric(6,2) not null,
  status      text not null default 'en_cours'
              check (status in ('en_cours','gagne','perdu')),
  payout      int  not null default 0,
  created_at  timestamptz not null default now()
);

-- Organisateurs (famille Chiiketsu)
create table if not exists public.admins (
  user_id uuid primary key references auth.users(id) on delete cascade
);

-- Comptes : le nom d'utilisateur est le nom RP (ex. « Ryuta Chiiketsu »).
-- Le site fabrique un e-mail invisible à partir de ce nom (ryuta.chiiketsu@korin-suna.app).
create table if not exists public.profiles (
  user_id     uuid primary key references auth.users(id) on delete cascade,
  username    text not null unique,
  created_at  timestamptz not null default now()
);
alter table public.profiles drop constraint if exists profiles_username_check;
alter table public.profiles add constraint profiles_username_check
  check (username = btrim(username) and char_length(username) between 3 and 40);

-- Crée automatiquement le profil quand quelqu'un s'inscrit sur le site
create or replace function public.handle_new_user()
returns trigger
language plpgsql security definer
set search_path = public
as $$
begin
  insert into public.profiles (user_id, username)
  values (new.id, btrim(coalesce(new.raw_user_meta_data->>'username', split_part(new.email, '@', 1))));
  return new;
end;
$$;

drop trigger if exists on_auth_user_created on auth.users;
create trigger on_auth_user_created
  after insert on auth.users
  for each row execute function public.handle_new_user();

create or replace function public.is_admin()
returns boolean
language sql stable security definer
set search_path = public
as $$
  select exists (select 1 from public.admins where user_id = auth.uid());
$$;

-- =============================================================
--  Porte-monnaie en ryos : chaque compte a un solde, chaque
--  mouvement est noté dans le registre. Le solde ne change QUE
--  par les fonctions ci-dessous (personne ne peut l'éditer à la main).
-- =============================================================
alter table public.profiles add column if not exists balance int not null default 0;
alter table public.bets     add column if not exists user_id uuid references auth.users(id) on delete set null;

create table if not exists public.ledger (
  id             uuid primary key default gen_random_uuid(),
  user_id        uuid not null references public.profiles(user_id) on delete cascade,
  delta          int  not null,
  balance_after  int  not null,
  reason         text not null,
  bet_id         uuid,
  created_at     timestamptz not null default now()
);

-- Bouge des ryos sur un compte et l'inscrit au registre (usage interne)
create or replace function public.move_ryos(p_user uuid, p_delta int, p_reason text, p_bet uuid default null, p_allow_negative boolean default false)
returns int
language plpgsql security definer
set search_path = public
as $$
declare v int;
begin
  update public.profiles set balance = balance + p_delta
    where user_id = p_user and (p_allow_negative or balance + p_delta >= 0)
    returning balance into v;
  if v is null then
    if exists (select 1 from public.profiles where user_id = p_user) then
      raise exception 'Solde insuffisant.';
    end if;
    raise exception 'Compte introuvable.';
  end if;
  insert into public.ledger (user_id, delta, balance_after, reason, bet_id)
    values (p_user, p_delta, v, p_reason, p_bet);
  return v;
end;
$$;
revoke execute on function public.move_ryos(uuid, int, text, uuid, boolean) from public, anon, authenticated;

-- Les orgas créditent ou retirent des ryos à un compte
create or replace function public.adjust_ryos(p_user uuid, p_delta int, p_reason text default null)
returns int
language plpgsql security definer
set search_path = public
as $$
begin
  if not public.is_admin() then raise exception 'Réservé aux organisateurs.'; end if;
  if coalesce(p_delta, 0) = 0 then raise exception 'Indique un montant.'; end if;
  return public.move_ryos(p_user, p_delta,
    coalesce(nullif(trim(p_reason), ''), case when p_delta > 0 then 'Crédit des organisateurs' else 'Retrait des organisateurs' end));
end;
$$;
revoke execute on function public.adjust_ryos(uuid, int, text) from public, anon;
grant  execute on function public.adjust_ryos(uuid, int, text) to authenticated;

-- Nouveau pari : vérifie le combat, gèle la cote, prélève la mise
create or replace function public.bets_before_insert()
returns trigger
language plpgsql security definer
set search_path = public
as $$
declare m public.matches; uname text;
begin
  select * into m from public.matches where id = new.match_id for share;
  if not found then raise exception 'Combat introuvable.'; end if;
  if m.status <> 'ouvert' then raise exception 'Les paris sont fermés pour ce combat.'; end if;
  if new.team_id is distinct from m.team_a and new.team_id is distinct from m.team_b then
    raise exception 'Cette équipe ne participe pas à ce combat.';
  end if;
  if not public.is_admin() and (auth.uid() is null or new.user_id is distinct from auth.uid()) then
    raise exception 'Connecte-toi pour parier.';
  end if;
  new.odds := case when new.team_id = m.team_a then m.odds_a else m.odds_b end;
  new.status := 'en_cours';
  new.payout := 0;
  new.created_at := now();
  if new.user_id is not null then
    select username into uname from public.profiles where user_id = new.user_id;
    if uname is null then raise exception 'Compte introuvable.'; end if;
    new.bettor := uname;
    if exists (select 1 from public.bets where match_id = new.match_id and user_id = new.user_id and team_id <> new.team_id) then
      raise exception 'Ce compte a déjà parié sur l''autre équipe de ce combat.';
    end if;
    perform public.move_ryos(new.user_id, -new.amount, 'Mise sur un combat', new.id);
  end if;
  return new;
end;
$$;

-- Pari réglé (ou résultat annulé) : verse ou reprend le gain
create or replace function public.bets_before_update()
returns trigger
language plpgsql security definer
set search_path = public
as $$
begin
  new.amount := old.amount;
  new.odds := old.odds;
  new.payout := case when new.status = 'gagne' then round(new.amount * new.odds)::int else 0 end;
  if old.user_id is not null and new.user_id is not null and new.status <> old.status then
    if old.status = 'gagne' then
      perform public.move_ryos(old.user_id, -old.payout, 'Résultat annulé', old.id, true);
    end if;
    if new.status = 'gagne' then
      perform public.move_ryos(new.user_id, new.payout, 'Pari gagné', new.id);
    end if;
  end if;
  return new;
end;
$$;

-- Pari supprimé avant le résultat : la mise est rendue
create or replace function public.bets_before_delete()
returns trigger
language plpgsql security definer
set search_path = public
as $$
begin
  if old.user_id is not null and old.status = 'en_cours' then
    perform public.move_ryos(old.user_id, old.amount, 'Pari annulé, mise rendue', old.id);
  end if;
  return old;
end;
$$;

drop trigger if exists bets_before_insert on public.bets;
create trigger bets_before_insert before insert on public.bets
  for each row execute function public.bets_before_insert();
drop trigger if exists bets_before_update on public.bets;
create trigger bets_before_update before update on public.bets
  for each row execute function public.bets_before_update();
drop trigger if exists bets_before_delete on public.bets;
create trigger bets_before_delete before delete on public.bets
  for each row execute function public.bets_before_delete();

-- =============================================================
--  Sécurité : tout le monde peut LIRE, seuls les orgas ÉCRIVENT
-- =============================================================
alter table public.teams   enable row level security;
alter table public.matches enable row level security;
alter table public.bets    enable row level security;
alter table public.admins   enable row level security;
alter table public.profiles enable row level security;

drop policy if exists "lecture publique" on public.teams;
drop policy if exists "orgas ecrivent"   on public.teams;
create policy "lecture publique" on public.teams for select using (true);
create policy "orgas ecrivent"   on public.teams for all to authenticated
  using (public.is_admin()) with check (public.is_admin());

drop policy if exists "lecture publique" on public.matches;
drop policy if exists "orgas ecrivent"   on public.matches;
create policy "lecture publique" on public.matches for select using (true);
create policy "orgas ecrivent"   on public.matches for all to authenticated
  using (public.is_admin()) with check (public.is_admin());

drop policy if exists "lecture publique" on public.bets;
drop policy if exists "orgas ecrivent"   on public.bets;
create policy "lecture publique" on public.bets for select using (true);
create policy "orgas ecrivent"   on public.bets for all to authenticated
  using (public.is_admin()) with check (public.is_admin());

-- Un joueur connecté parie pour lui-même, et peut annuler tant que les paris sont ouverts
drop policy if exists "joueur parie"  on public.bets;
drop policy if exists "joueur annule" on public.bets;
create policy "joueur parie" on public.bets for insert to authenticated
  with check (user_id = auth.uid());
create policy "joueur annule" on public.bets for delete to authenticated
  using (user_id = auth.uid() and status = 'en_cours'
         and exists (select 1 from public.matches m where m.id = match_id and m.status = 'ouvert'));

alter table public.ledger enable row level security;
drop policy if exists "voir ses mouvements" on public.ledger;
create policy "voir ses mouvements" on public.ledger for select to authenticated
  using (user_id = auth.uid() or public.is_admin());

drop policy if exists "voir son statut" on public.admins;
drop policy if exists "orgas gerent les orgas" on public.admins;
create policy "voir son statut" on public.admins for select to authenticated
  using (user_id = auth.uid() or public.is_admin());
create policy "orgas gerent les orgas" on public.admins for all to authenticated
  using (public.is_admin()) with check (public.is_admin());

drop policy if exists "voir son profil" on public.profiles;
create policy "voir son profil" on public.profiles for select to authenticated
  using (user_id = auth.uid() or public.is_admin());

-- =============================================================
--  Mise à jour en direct sur toutes les pages ouvertes
-- =============================================================
do $$
begin
  begin alter publication supabase_realtime add table public.teams;   exception when duplicate_object then null; end;
  begin alter publication supabase_realtime add table public.matches; exception when duplicate_object then null; end;
  begin alter publication supabase_realtime add table public.bets;    exception when duplicate_object then null; end;
  begin alter publication supabase_realtime add table public.profiles; exception when duplicate_object then null; end;
  begin alter publication supabase_realtime add table public.ledger;   exception when duplicate_object then null; end;
end $$;

-- =============================================================
--  ÉTAPE FINALE : crée d'abord ton compte sur le site (onglet Compte
--  → Créer un compte), puis remplace le pseudo ci-dessous et lance
--  seulement cette ligne. Ensuite tu valideras les autres depuis le site.
-- =============================================================
-- insert into public.admins (user_id)
--   select user_id from public.profiles where lower(username) = lower('Ton Nom');
