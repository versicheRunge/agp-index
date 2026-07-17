-- ============================================================
-- AGP INDEX · Supabase Schema · Welle 1
-- Ausführen in: Supabase Dashboard → SQL Editor → Run
-- ============================================================

-- ---------- Profile & Rollen ----------
create table if not exists profiles (
  id uuid primary key references auth.users(id) on delete cascade,
  rolle text not null default 'agp' check (rolle in ('ldo','fk','agp')),
  vm_nr text,
  name text,
  created_at timestamptz default now()
);

-- Neues Auth-Konto → automatisch Profil (Rolle agp)
create or replace function handle_new_user() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  insert into profiles (id, name) values (new.id, new.email) on conflict do nothing;
  return new;
end $$;
drop trigger if exists on_auth_user_created on auth.users;
create trigger on_auth_user_created after insert on auth.users
  for each row execute function handle_new_user();

create or replace function is_ldo() returns boolean
language sql security definer stable set search_path = public as $$
  select exists (select 1 from profiles where id = auth.uid() and rolle = 'ldo');
$$;

create or replace function my_vm() returns text
language sql security definer stable set search_path = public as $$
  select vm_nr from profiles where id = auth.uid();
$$;

-- ---------- Stammdaten ----------
create table if not exists agp (
  id uuid primary key default gen_random_uuid(),
  vm_nr text unique not null,
  name text not null,
  eintritt date,
  wertungsbeginn date,
  fixum_aktuell numeric default 0,
  fixum_folge numeric default 0,
  unterverdienst numeric default 0,
  rueckzahlung numeric default 0,
  sonderverrechnung numeric default 0,
  phase text,
  aktiv boolean default true,
  notizen text,
  updated_at timestamptz default now()
);

-- ---------- Monatswerte (Upsert-Ziel beider Quellen) ----------
create table if not exists monatswert (
  id uuid primary key default gen_random_uuid(),
  agp_id uuid not null references agp(id) on delete cascade,
  monat date not null,
  quelle text not null check (quelle in ('datenblatt','tagesstatistik')),
  gesamt numeric,
  sparten jsonb,
  stueck jsonb,
  beitrag jsonb,
  importiert_am timestamptz default now(),
  unique (agp_id, monat, quelle)
);

-- ---------- Einzelsätze (Deal-Analytik, Storno-Proxy) ----------
create table if not exists einzelsatz (
  id uuid primary key default gen_random_uuid(),
  agp_id uuid not null references agp(id) on delete cascade,
  vsnr text,
  sparte text,
  buchung date,
  abrechnung date,
  betrag numeric
);
create index if not exists einzelsatz_agp on einzelsatz(agp_id);

-- ---------- Manuelle Bewertungen ----------
create table if not exists bewertung (
  id uuid primary key default gen_random_uuid(),
  agp_id uuid not null references agp(id) on delete cascade,
  kriterium text not null,
  wert int check (wert between 1 and 5),
  datum timestamptz default now(),
  bewerter uuid references auth.users(id),
  kommentar text
);

-- ---------- Maßnahmen ----------
create table if not exists massnahme (
  id uuid primary key default gen_random_uuid(),
  agp_id uuid not null references agp(id) on delete cascade,
  ziel text, text text, verantwortlich text,
  start date, faellig date,
  status text default 'geplant' check (status in ('geplant','gestartet','in_bearbeitung','abgeschlossen','pausiert','verworfen')),
  ergebnis text, kommentar text,
  created_at timestamptz default now()
);

-- ---------- Index-Historie ----------
create table if not exists index_snapshot (
  id uuid primary key default gen_random_uuid(),
  agp_id uuid not null references agp(id) on delete cascade,
  datum date not null default current_date,
  index numeric, scores jsonb, gewichte jsonb, datenqualitaet text,
  unique (agp_id, datum)
);

-- ---------- Wettbewerbs-Historie ----------
create table if not exists wettbewerb_snapshot (
  id uuid primary key default gen_random_uuid(),
  agp_id uuid not null references agp(id) on delete cascade,
  monat date not null,
  punkte numeric, rang int,
  unique (agp_id, monat)
);

-- ---------- Konfiguration ----------
create table if not exists config (
  key text primary key,
  value jsonb,
  geaendert_am timestamptz default now()
);

-- ============================================================
-- Row Level Security: LDO alles · AGP nur eigene Zeilen (lesend)
-- ============================================================
alter table profiles enable row level security;
alter table agp enable row level security;
alter table monatswert enable row level security;
alter table einzelsatz enable row level security;
alter table bewertung enable row level security;
alter table massnahme enable row level security;
alter table index_snapshot enable row level security;
alter table wettbewerb_snapshot enable row level security;
alter table config enable row level security;

create policy "own profile read"  on profiles for select using (id = auth.uid());
create policy "ldo profiles all"  on profiles for all using (is_ldo()) with check (is_ldo());

create policy "ldo agp all"       on agp for all using (is_ldo()) with check (is_ldo());
create policy "agp read own"      on agp for select using (vm_nr = my_vm());

create policy "ldo mw all"        on monatswert for all using (is_ldo()) with check (is_ldo());
create policy "agp mw own"        on monatswert for select using (agp_id in (select id from agp where vm_nr = my_vm()));

create policy "ldo es all"        on einzelsatz for all using (is_ldo()) with check (is_ldo());
create policy "agp es own"        on einzelsatz for select using (agp_id in (select id from agp where vm_nr = my_vm()));

create policy "ldo bew all"       on bewertung for all using (is_ldo()) with check (is_ldo());
-- Bewertungen bleiben intern: AGP haben KEINEN Lesezugriff.

create policy "ldo mas all"       on massnahme for all using (is_ldo()) with check (is_ldo());
create policy "agp mas own"       on massnahme for select using (agp_id in (select id from agp where vm_nr = my_vm()));

create policy "ldo snap all"      on index_snapshot for all using (is_ldo()) with check (is_ldo());
create policy "agp snap own"      on index_snapshot for select using (agp_id in (select id from agp where vm_nr = my_vm()));

create policy "ldo ws all"        on wettbewerb_snapshot for all using (is_ldo()) with check (is_ldo());
create policy "agp ws own"        on wettbewerb_snapshot for select using (agp_id in (select id from agp where vm_nr = my_vm()));

create policy "ldo cfg all"       on config for all using (is_ldo()) with check (is_ldo());
create policy "auth cfg read"     on config for select using (auth.uid() is not null);

-- ============================================================
-- NACH DEINEM ERSTEN LOGIN einmalig ausführen (E-Mail anpassen):
--   update profiles set rolle='ldo'
--   where id = (select id from auth.users where email = 'DEINE@MAIL.DE');
-- ============================================================
