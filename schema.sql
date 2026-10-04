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

-- =============================================================
--  Éditions du Korin : un Korin est programmé avec une date
--  d'ouverture, puis clôturé et gardé dans l'historique.
--  Une seule édition à la fois sans date de clôture (l'édition en cours).
-- =============================================================
create table if not exists public.editions (
  id          uuid primary key default gen_random_uuid(),
  name        text not null,
  starts_at   timestamptz not null,           -- ouverture au public (tableau, équipes, paris)
  ended_at    timestamptz,                    -- null = édition en cours
  created_at  timestamptz not null default now()
);
create unique index if not exists editions_une_seule_en_cours on public.editions ((true)) where ended_at is null;

alter table public.teams   add column if not exists edition_id uuid references public.editions(id) on delete cascade;
alter table public.matches add column if not exists edition_id uuid references public.editions(id) on delete cascade;
alter table public.bets    add column if not exists edition_id uuid references public.editions(id) on delete cascade;

-- Les noms d'équipe et les places du tableau sont uniques par édition (plus sur tout le site)
alter table public.teams   drop constraint if exists teams_name_key;
alter table public.matches drop constraint if exists matches_round_slot_key;
create unique index if not exists teams_nom_par_edition   on public.teams (edition_id, name);
create unique index if not exists matches_place_par_edition on public.matches (edition_id, round, slot);

-- Vrai si l'édition est en cours et sa date d'ouverture est passée
create or replace function public.edition_open(p_edition uuid)
returns boolean
language sql stable security definer
set search_path = public
as $$
  select exists (select 1 from public.editions where id = p_edition and ended_at is null and starts_at <= now());
$$;
grant execute on function public.edition_open(uuid) to anon, authenticated;

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

-- Clé d'un nom : sans accents ni majuscules (« Ryūta Chiiketsu » → ryuta.chiiketsu), comme l'e-mail invisible
create or replace function public.name_key(p text)
returns text
language sql immutable
as $$
  select btrim(regexp_replace(lower(regexp_replace(normalize(coalesce(p, ''), NFD), '[̀-ͯ]', '', 'g')), '[^a-z0-9]+', '.', 'g'), '.');
$$;

-- =============================================================
--  Blacklist du tournoi : un nom blacklisté ne peut ni s'inscrire,
--  ni parier, ni être inscrit dans une équipe.
-- =============================================================
create table if not exists public.blacklist (
  id          uuid primary key default gen_random_uuid(),
  name        text not null,
  key         text not null unique,
  reason      text,
  created_at  timestamptz not null default now()
);

create or replace function public.blacklist_set_key()
returns trigger
language plpgsql
set search_path = public
as $$
begin
  new.name := btrim(new.name);
  new.key := public.name_key(new.name);
  if new.key = '' then raise exception 'Indique un nom.'; end if;
  return new;
end;
$$;
drop trigger if exists blacklist_set_key on public.blacklist;
create trigger blacklist_set_key before insert or update on public.blacklist
  for each row execute function public.blacklist_set_key();

create or replace function public.is_blacklisted(p_name text)
returns boolean
language sql stable security definer
set search_path = public
as $$
  select exists (select 1 from public.blacklist where key = public.name_key(p_name));
$$;
grant execute on function public.is_blacklisted(text) to anon, authenticated;

-- Une équipe ne peut pas contenir un combattant blacklisté
create or replace function public.teams_check_blacklist()
returns trigger
language plpgsql security definer
set search_path = public
as $$
begin
  if public.is_blacklisted(new.player1) then raise exception '% est sur la blacklist du Korin.', new.player1; end if;
  if public.is_blacklisted(new.player2) then raise exception '% est sur la blacklist du Korin.', new.player2; end if;
  return new;
end;
$$;
drop trigger if exists teams_check_blacklist on public.teams;
create trigger teams_check_blacklist before insert or update on public.teams
  for each row execute function public.teams_check_blacklist();

-- Crée automatiquement le profil quand quelqu'un s'inscrit sur le site (inscription libre, sauf blacklist)
create or replace function public.handle_new_user()
returns trigger
language plpgsql security definer
set search_path = public
as $$
begin
  if public.is_blacklisted(coalesce(new.raw_user_meta_data->>'username', split_part(new.email, '@', 1))) then
    raise exception 'Ce nom est sur la blacklist du Korin.';
  end if;
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
--  Bilan en ryos : chaque compte a un solde (bilan, peut être négatif),
--  chaque mouvement est noté dans le registre. Pas de limite pour parier :
--  les ryos se règlent en RP avec la gérance. Le solde ne change QUE
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
    coalesce(nullif(trim(p_reason), ''), case when p_delta > 0 then 'Crédit de la gérance' else 'Retrait de la gérance' end), null, true);
end;
$$;
revoke execute on function public.adjust_ryos(uuid, int, text) from public, anon;
grant  execute on function public.adjust_ryos(uuid, int, text) to authenticated;

-- =============================================================
--  Gestion des comptes par la gérance (pas d'e-mail, donc pas de
--  « mot de passe oublié » automatique : la gérance en donne un nouveau)
-- =============================================================
create extension if not exists pgcrypto with schema extensions;

create or replace function public.admin_set_password(p_user uuid, p_password text)
returns void
language plpgsql security definer
set search_path = public, extensions
as $$
begin
  if not public.is_admin() then raise exception 'Réservé à la gérance.'; end if;
  if char_length(coalesce(p_password, '')) < 6 then raise exception 'Le mot de passe doit faire au moins 6 caractères.'; end if;
  update auth.users set encrypted_password = extensions.crypt(p_password, extensions.gen_salt('bf')), updated_at = now()
    where id = p_user;
  if not found then raise exception 'Compte introuvable.'; end if;
end;
$$;
revoke execute on function public.admin_set_password(uuid, text) from public, anon;
grant  execute on function public.admin_set_password(uuid, text) to authenticated;

-- Supprime un compte (profil, rôle et registre partent avec ; ses paris restent, sans lien au compte)
create or replace function public.admin_delete_user(p_user uuid)
returns void
language plpgsql security definer
set search_path = public
as $$
begin
  if not public.is_admin() then raise exception 'Réservé à la gérance.'; end if;
  if p_user = auth.uid() then raise exception 'Tu ne peux pas supprimer ton propre compte.'; end if;
  delete from auth.users where id = p_user;
  if not found then raise exception 'Compte introuvable.'; end if;
end;
$$;
revoke execute on function public.admin_delete_user(uuid) from public, anon;
grant  execute on function public.admin_delete_user(uuid) to authenticated;

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
  if not public.is_admin() and not public.edition_open(m.edition_id) then
    raise exception 'Le Korin n''est pas encore ouvert.';
  end if;
  new.edition_id := m.edition_id;
  new.odds := case when new.team_id = m.team_a then m.odds_a else m.odds_b end;
  new.status := 'en_cours';
  new.payout := 0;
  new.created_at := now();
  if new.user_id is not null then
    select username into uname from public.profiles where user_id = new.user_id;
    if uname is null then raise exception 'Compte introuvable.'; end if;
    new.bettor := uname;
    if public.is_blacklisted(uname) then
      raise exception 'Ce compte est sur la blacklist du Korin : paris interdits.';
    end if;
    if exists (select 1 from public.bets where match_id = new.match_id and user_id = new.user_id and team_id <> new.team_id) then
      raise exception 'Ce compte a déjà parié sur l''autre équipe de ce combat.';
    end if;
    -- Pas de limite de solde : le solde est un bilan qui peut être négatif, les ryos se règlent en RP
    perform public.move_ryos(new.user_id, -new.amount, 'Mise sur un combat', new.id, true);
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
alter table public.editions enable row level security;

-- Éditions : la date du prochain Korin est publique, seule la gérance les gère
drop policy if exists "lecture publique" on public.editions;
drop policy if exists "gerance gere les editions" on public.editions;
create policy "lecture publique" on public.editions for select using (true);
create policy "gerance gere les editions" on public.editions for all to authenticated
  using (public.is_admin()) with check (public.is_admin());

-- Équipes et combats : visibles du public seulement quand le Korin est ouvert
-- (avant la date d'ouverture et après la clôture, seule la gérance les voit)
drop policy if exists "lecture publique" on public.teams;
drop policy if exists "orgas ecrivent"   on public.teams;
create policy "lecture publique" on public.teams for select
  using (public.is_admin() or public.edition_open(edition_id));
create policy "orgas ecrivent"   on public.teams for all to authenticated
  using (public.is_admin()) with check (public.is_admin());

drop policy if exists "lecture publique" on public.matches;
drop policy if exists "orgas ecrivent"   on public.matches;
create policy "lecture publique" on public.matches for select
  using (public.is_admin() or public.edition_open(edition_id));
create policy "orgas ecrivent"   on public.matches for all to authenticated
  using (public.is_admin()) with check (public.is_admin());

-- Paris : chacun ne voit que les siens, la gérance voit tout.
-- Le public n'a accès qu'aux totaux (fonctions bet_totals et leaderboard plus bas).
drop policy if exists "lecture publique" on public.bets;
drop policy if exists "voir ses paris"   on public.bets;
drop policy if exists "orgas ecrivent"   on public.bets;
create policy "voir ses paris" on public.bets for select to authenticated
  using (user_id = auth.uid() or public.is_admin());
create policy "orgas ecrivent"   on public.bets for all to authenticated
  using (public.is_admin()) with check (public.is_admin());

-- Totaux par combat et par équipe (ryos misés, nombre de paris), sans le détail
create or replace function public.bet_totals()
returns table (match_id uuid, team_id uuid, n int, total int)
language sql stable security definer
set search_path = public
as $$
  select match_id, team_id, count(*)::int, coalesce(sum(amount), 0)::int from public.bets group by match_id, team_id;
$$;
grant execute on function public.bet_totals() to anon, authenticated;

-- Classement des parieurs (bilan par personne, sans le détail des paris)
create or replace function public.leaderboard()
returns table (bettor text, n int, won int, lost int, staked int, returned int, pending int)
language sql stable security definer
set search_path = public
as $$
  select bettor,
         count(*)::int,
         (count(*) filter (where status = 'gagne'))::int,
         (count(*) filter (where status = 'perdu'))::int,
         coalesce(sum(amount) filter (where status <> 'en_cours'), 0)::int,
         coalesce(sum(payout) filter (where status <> 'en_cours'), 0)::int,
         coalesce(sum(amount) filter (where status = 'en_cours'), 0)::int
  from public.bets group by bettor;
$$;
grant execute on function public.leaderboard() to anon, authenticated;

alter table public.blacklist enable row level security;
drop policy if exists "gerance gere la blacklist" on public.blacklist;
create policy "gerance gere la blacklist" on public.blacklist for all to authenticated
  using (public.is_admin()) with check (public.is_admin());

-- Un joueur connecté (pas blacklisté, vérifié par le trigger) parie pour lui-même, et peut annuler tant que les paris sont ouverts
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
  begin alter publication supabase_realtime add table public.blacklist; exception when duplicate_object then null; end;
  begin alter publication supabase_realtime add table public.editions;  exception when duplicate_object then null; end;
end $$;

-- =============================================================
--  ÉTAPE FINALE : crée d'abord ton compte sur le site (onglet Compte
--  → Créer un compte), puis remplace le pseudo ci-dessous et lance
--  seulement cette ligne. Ensuite tu valideras les autres depuis le site.
-- =============================================================
-- insert into public.admins (user_id)
--   select user_id from public.profiles where lower(username) = lower('Ton Nom');
