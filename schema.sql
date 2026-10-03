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

-- Comptes : connexion par nom d'utilisateur (le site fabrique un e-mail invisible)
create table if not exists public.profiles (
  user_id     uuid primary key references auth.users(id) on delete cascade,
  username    text not null unique check (username ~ '^[a-z0-9_.-]{3,20}$'),
  created_at  timestamptz not null default now()
);

-- Crée automatiquement le profil quand quelqu'un s'inscrit sur le site
create or replace function public.handle_new_user()
returns trigger
language plpgsql security definer
set search_path = public
as $$
begin
  insert into public.profiles (user_id, username)
  values (new.id, lower(coalesce(new.raw_user_meta_data->>'username', split_part(new.email, '@', 1))));
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
end $$;

-- =============================================================
--  ÉTAPE FINALE : crée d'abord ton compte sur le site (onglet Orga
--  → Créer un compte), puis remplace le pseudo ci-dessous et lance
--  seulement cette ligne. Ensuite tu valideras les autres depuis le site.
-- =============================================================
-- insert into public.admins (user_id)
--   select user_id from public.profiles where username = 'ton_pseudo';
