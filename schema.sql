-- =====================================================================
--  Madkastellet · arrangementsværktøj — databaseskema (v1, med roller)
--  Kør hele filen i Supabase → SQL Editor → New query → Run.
--  Roller: admin (IT-ansvarlig, org-bred) · coordinator (menig, egne arr.)
-- =====================================================================

drop trigger if exists on_auth_user_created on auth.users;
drop trigger if exists on_event_created on events;
drop table if exists activity_log       cascade;
drop table if exists agenda_items       cascade;
drop table if exists guests             cascade;
drop table if exists invites            cascade;
drop table if exists event_access       cascade;
drop table if exists event_staff        cascade;
drop table if exists event_rooms        cascade;
drop table if exists catalog_item_rooms cascade;
drop table if exists event_catalog_items cascade;
drop table if exists catalog_items      cascade;
drop table if exists events             cascade;
drop table if exists staff              cascade;
drop table if exists rooms              cascade;
drop table if exists venues             cascade;
drop table if exists superadmins        cascade;
drop table if exists organisations      cascade;

-- =====================================================================
--  1. TABELLER
-- =====================================================================
create table organisations (
  id uuid primary key default gen_random_uuid(),
  name text not null,
  onboarding_dismissed boolean not null default false,  -- admin har skjult "Kom godt i gang"-guiden
  created_at timestamptz not null default now()
);

-- Verta-medarbejdere: organisationsuafhængig adgang på tværs af alle kunde-/demo-organisationer.
-- Ingen org_id — det er hele pointen. Tilføjes manuelt via SQL, ikke selvbetjening.
create table superadmins (
  id uuid primary key references auth.users(id) on delete cascade,
  name text not null,
  created_at timestamptz not null default now()
);

create table venues (
  id uuid primary key default gen_random_uuid(),
  org_id uuid not null references organisations(id) on delete cascade,
  name text not null,
  address text,
  created_at timestamptz not null default now()
);

-- Lokaler (rum) på en lokation
create table rooms (
  id uuid primary key default gen_random_uuid(),
  venue_id uuid not null references venues(id) on delete cascade,
  name text not null,
  capacity_max integer,            -- max antal gæster i lokalet
  sort_order integer not null default 0,
  created_at timestamptz not null default now()
);

-- Én profilrække pr. medarbejder. id = auth-brugerens id.
create table staff (
  id uuid primary key references auth.users(id) on delete cascade,
  org_id uuid not null references organisations(id) on delete cascade,
  name text not null,
  role text not null default 'coordinator',   -- 'admin' | 'coordinator'
  created_at timestamptz not null default now()
);

-- Ventende invitationer. Admin opretter; trigger forbruger ved første login.
create table invites (
  id uuid primary key default gen_random_uuid(),
  org_id uuid not null references organisations(id) on delete cascade,
  email text not null,
  name text not null,
  role text not null default 'coordinator',
  created_at timestamptz not null default now(),
  unique (org_id, email)
);

create table events (
  id uuid primary key default gen_random_uuid(),
  venue_id uuid not null references venues(id) on delete cascade,
  org_id uuid not null references organisations(id) on delete cascade,
  title text not null,
  event_date date not null,
  offer_total_kr integer not null default 0,
  status text not null default 'bekræftet',   -- kladde | tilbud | bekræftet | afviklet
  event_type text not null default 'bryllup', -- bryllup | firmafest | konference | teambuilding | andet
  baseline_locked boolean not null default false,
  owner_staff_id uuid references staff(id),   -- den, der oprettede arrangementet
  created_at timestamptz not null default now()
);

create table event_staff (
  event_id uuid not null references events(id) on delete cascade,
  staff_id uuid not null references staff(id)  on delete cascade,
  primary key (event_id, staff_id)
);

create table event_access (
  id uuid primary key default gen_random_uuid(),
  event_id uuid not null references events(id) on delete cascade,
  user_id uuid not null references auth.users(id) on delete cascade,
  display_name text not null,
  first_visited_at timestamptz,     -- sat ved gæstens allerførste besøg, styrer velkomstkortet
  created_at timestamptz not null default now(),
  unique (event_id, user_id)
);

-- Lokale pr. fase: ét lokale for hver fase i arrangementet
create table event_rooms (
  event_id uuid not null references events(id) on delete cascade,
  phase text not null,                 -- reception | middag | fest
  room_id uuid not null references rooms(id) on delete cascade,
  start_time time,                     -- tidsrum for denne fase (bruges til at forhindre dobbeltbooking)
  end_time time,                       -- hvis end_time <= start_time, regnes det som efter midnat
  primary key (event_id, phase)
);

-- Priskatalog: org'ens genbrugelige menuer/pakker/fri bar/tilvalg (fx natmad).
-- Prissat pr. person (grundlag = reception/middag) eller som fast beløb (grundlag = fast).
create table catalog_items (
  id uuid primary key default gen_random_uuid(),
  org_id uuid not null references organisations(id) on delete cascade,
  name text not null,
  category text not null default 'andet',    -- menu | bar | reception | tilvalg | andet — kun til gruppering
  price_kr integer not null default 0,       -- pr. person, medmindre grundlag = 'fast'
  basis text not null default 'middag',      -- reception | middag | fast
  child_half boolean not null default false, -- børn betaler halv pris (babyer er altid gratis)
  event_type text,                           -- null = alle typer, ellers samme værdier som events.event_type
  sort_order integer not null default 0,
  created_at timestamptz not null default now()
);

-- Hvilke katalogvarer er valgt til et bestemt arrangement
create table event_catalog_items (
  event_id uuid not null references events(id) on delete cascade,
  catalog_item_id uuid not null references catalog_items(id) on delete cascade,
  primary key (event_id, catalog_item_id)
);

-- Hvilke lokaler en katalogvare kan høre til. Ingen rækker for en vare = gælder alle lokaler.
create table catalog_item_rooms (
  catalog_item_id uuid not null references catalog_items(id) on delete cascade,
  room_id uuid not null references rooms(id) on delete cascade,
  primary key (catalog_item_id, room_id)
);

create table guests (
  id uuid primary key default gen_random_uuid(),
  event_id uuid not null references events(id) on delete cascade,
  name text not null default '',
  category text not null default 'voksen',   -- voksen | barn | baby
  reception boolean not null default true,
  dinner boolean not null default true,      -- middag
  dietary text not null default '',
  sort_order integer not null default 0,
  created_at timestamptz not null default now()
);

create table agenda_items (
  id uuid primary key default gen_random_uuid(),
  event_id uuid not null references events(id) on delete cascade,
  title text not null,
  owner text not null default 'jer',         -- 'jer' | 'kilden'
  status text not null default 'mangler',    -- mangler | udkast | aftalt
  due_date date,
  note text not null default '',
  sort_order integer not null default 0
);

create table activity_log (
  id uuid primary key default gen_random_uuid(),
  event_id uuid not null references events(id) on delete cascade,
  ts timestamptz not null default now(),
  actor_id uuid references auth.users(id),
  actor_name text not null,
  actor_side text not null,                  -- 'kilden' | 'kunde'
  entry_type text not null,                  -- 'change' | 'view' | 'message'
  area text not null default 'system',
  label text not null default '',
  from_val text not null default '',
  to_val text not null default '',
  customer_visible boolean not null default false,
  friendly text not null default '',
  message_text text not null default ''
);

create index on activity_log (event_id, ts desc);
create index on guests       (event_id);
create index on agenda_items (event_id);
create index on events       (org_id, event_date);

-- =====================================================================
--  2. HJÆLPEFUNKTIONER (security definer — undgår RLS-rekursion)
-- =====================================================================
create or replace function my_org()
returns uuid language sql security definer stable set search_path = public as $$
  select org_id from staff where id = auth.uid()
$$;

create or replace function my_role()
returns text language sql security definer stable set search_path = public as $$
  select role from staff where id = auth.uid()
$$;

-- Er denne bruger superadmin (Verta-medarbejder, organisationsuafhængig)?
create or replace function is_superadmin()
returns boolean language sql security definer stable set search_path = public as $$
  select exists (select 1 from superadmins where id = auth.uid())
$$;

-- Admin i en bestemt organisation? (superadmin tæller altid med)
create or replace function is_org_admin(target_org uuid)
returns boolean language sql security definer stable set search_path = public as $$
  select is_superadmin() or exists (select 1 from staff
                 where id = auth.uid() and org_id = target_org and role = 'admin')
$$;

-- Må denne bruger arbejde på arrangementet?
-- Sandt hvis: superadmin, ELLER tildelt koordinator PÅ arrangementet, ELLER admin i arrangementets org.
create or replace function is_org_staff(target_event uuid)
returns boolean language sql security definer stable set search_path = public as $$
  select is_superadmin() or exists (
    select 1 from events e
    where e.id = target_event
      and ( exists (select 1 from event_staff es
                    where es.event_id = e.id and es.staff_id = auth.uid())
            or exists (select 1 from staff s
                    where s.id = auth.uid() and s.org_id = e.org_id and s.role = 'admin') )
  )
$$;

create or replace function is_event_guest(target_event uuid)
returns boolean language sql security definer stable set search_path = public as $$
  select exists (select 1 from event_access a
                 where a.event_id = target_event and a.user_id = auth.uid())
$$;

-- Kontaktpersonens navn til gæstens velkomstkort. Gæsten har ingen RLS-adgang
-- til staff-tabellen, så dette security-definer-kald er den eneste vej ind —
-- og kun for nogen, der faktisk er gæst eller medarbejder på arrangementet.
create or replace function get_event_contact(target_event uuid)
returns text language sql security definer stable set search_path = public as $$
  select s.name from events e join staff s on s.id = e.owner_staff_id
  where e.id = target_event and (is_event_guest(target_event) or is_org_staff(target_event))
$$;

-- =====================================================================
--  3. TRIGGERE
-- =====================================================================
-- Ny auth-bruger med en ventende invitation → bliv medarbejder automatisk.
create or replace function handle_new_user()
returns trigger language plpgsql security definer set search_path = public as $$
declare inv invites%rowtype;
begin
  select * into inv from invites where lower(email) = lower(new.email) limit 1;
  if found then
    insert into staff (id, org_id, name, role)
      values (new.id, inv.org_id, inv.name, inv.role)
      on conflict (id) do nothing;
    delete from invites where id = inv.id;
  end if;
  return new;
end;
$$;
create trigger on_auth_user_created
  after insert on auth.users
  for each row execute function handle_new_user();

-- Den, der opretter et arrangement, bliver automatisk ejer (før insert, så feltet er sat).
-- Kun hvis skaberen faktisk har en staff-række (fx superadmin har ikke, og owner_staff_id
-- er en FK til staff — ellers ville insert fejle for superadmin-oprettede arrangementer).
create or replace function set_event_owner()
returns trigger language plpgsql security definer set search_path = public as $$
begin
  if new.owner_staff_id is null and exists (select 1 from staff where id = auth.uid()) then
    new.owner_staff_id := auth.uid();
  end if;
  return new;
end;
$$;
create trigger on_event_owner_set
  before insert on events
  for each row execute function set_event_owner();

-- Den, der opretter et arrangement, kobles automatisk på det som medarbejder.
create or replace function assign_event_creator()
returns trigger language plpgsql security definer set search_path = public as $$
begin
  if exists (select 1 from staff where id = auth.uid()) then
    insert into event_staff (event_id, staff_id)
      values (new.id, auth.uid()) on conflict do nothing;
  end if;
  return new;
end;
$$;
create trigger on_event_created
  after insert on events
  for each row execute function assign_event_creator();

-- Forhindrer dobbeltbooking: samme lokale kan ikke bruges to steder samtidig
-- samme dag. Samme lokale samme dag men forskudte tidsrum er ok; samme
-- tidsrum i forskellige lokaler er ok.
create or replace function check_room_conflict()
returns trigger language plpgsql security definer set search_path = public as $$
declare
  ev_date date;
  new_start timestamptz;
  new_end timestamptz;
  conflict_row record;
begin
  if new.start_time is null or new.end_time is null then
    return new;   -- intet tidsrum sat endnu — kan ikke tjekkes
  end if;

  select event_date into ev_date from events where id = new.event_id;
  new_start := ev_date + new.start_time;
  new_end   := ev_date + new.end_time;
  if new.end_time <= new.start_time then
    new_end := new_end + interval '1 day';   -- fase går over midnat
  end if;

  select er.phase, e2.title into conflict_row
  from event_rooms er
  join events e2 on e2.id = er.event_id
  where er.room_id = new.room_id
    and er.start_time is not null and er.end_time is not null
    and not (er.event_id = new.event_id and er.phase = new.phase)
    and (e2.event_date + er.start_time) < new_end
    and new_start < (e2.event_date + er.end_time
        + (case when er.end_time <= er.start_time then interval '1 day' else interval '0' end))
  limit 1;

  if found then
    raise exception 'Lokalet er allerede booket % – % (% · %)',
      new.start_time, new.end_time, conflict_row.title, conflict_row.phase;
  end if;

  return new;
end;
$$;
create trigger on_event_rooms_conflict
  before insert or update on event_rooms
  for each row execute function check_room_conflict();

-- =====================================================================
--  4. RLS
-- =====================================================================
alter table organisations enable row level security;
alter table superadmins   enable row level security;
alter table venues        enable row level security;
alter table staff         enable row level security;
alter table invites       enable row level security;
alter table events        enable row level security;
alter table event_staff   enable row level security;
alter table event_access  enable row level security;
alter table guests        enable row level security;
alter table agenda_items  enable row level security;
alter table activity_log  enable row level security;
alter table rooms         enable row level security;
alter table event_rooms   enable row level security;
alter table catalog_items       enable row level security;
alter table event_catalog_items enable row level security;
alter table catalog_item_rooms  enable row level security;

-- Superadmin: kun læsbar for sig selv. Tilføjes/fjernes manuelt via SQL.
create policy superadmins_read_self on superadmins for select using (id = auth.uid());

-- Organisation / lokationer
create policy org_read on organisations for select using (
  id = my_org() or is_superadmin()
  or exists (select 1 from events e join event_access a on a.event_id = e.id
             where e.org_id = organisations.id and a.user_id = auth.uid())
);
-- Kun superadmin opretter/omdøber organisationer (fx nye demo-organisationer). Ingen sletning fra UI.
create policy org_insert on organisations for insert with check ( is_superadmin() );
create policy org_update on organisations for update using ( is_superadmin() ) with check ( is_superadmin() );

create policy venue_read on venues for select using (
  org_id = my_org() or is_superadmin()
  or exists (select 1 from events e join event_access a on a.event_id = e.id
             where e.venue_id = venues.id and a.user_id = auth.uid())
);
-- Kun admin må oprette/ændre/slette lokationer
create policy venue_insert on venues for insert with check ( is_org_admin(org_id) );
create policy venue_update on venues for update using ( is_org_admin(org_id) ) with check ( is_org_admin(org_id) );
create policy venue_delete on venues for delete using ( is_org_admin(org_id) );

-- Lokaler: læsbare for org'ens folk + brudepar ved lokationen; kun admin redigerer
create policy rooms_read on rooms for select using (
  exists (select 1 from venues v where v.id = rooms.venue_id and v.org_id = my_org())
  or is_superadmin()
  or exists (select 1 from events e join event_access a on a.event_id = e.id
             where e.venue_id = rooms.venue_id and a.user_id = auth.uid())
);
create policy rooms_ins on rooms for insert with check ( is_org_admin((select org_id from venues where id = rooms.venue_id)) );
create policy rooms_upd on rooms for update using ( is_org_admin((select org_id from venues where id = rooms.venue_id)) ) with check ( is_org_admin((select org_id from venues where id = rooms.venue_id)) );
create policy rooms_del on rooms for delete using ( is_org_admin((select org_id from venues where id = rooms.venue_id)) );

-- Lokale pr. fase: begge parter læser; medarbejdere sætter
create policy erooms_read on event_rooms for select using ( is_org_staff(event_id) or is_event_guest(event_id) );
create policy erooms_ins  on event_rooms for insert with check ( is_org_staff(event_id) );
create policy erooms_upd  on event_rooms for update using ( is_org_staff(event_id) ) with check ( is_org_staff(event_id) );
create policy erooms_del  on event_rooms for delete using ( is_org_staff(event_id) );

-- Priskatalog: org'ens folk læser hele kataloget (til at tilføje til arrangementer);
-- brudepar må kun se de konkrete varer, der er valgt til deres eget arrangement.
-- Kun admin opretter/ændrer/sletter katalogvarer.
create policy catalog_read on catalog_items for select using (
  org_id = my_org() or is_superadmin()
  or exists (select 1 from event_catalog_items eci
             join event_access a on a.event_id = eci.event_id
             where eci.catalog_item_id = catalog_items.id and a.user_id = auth.uid())
);
create policy catalog_ins on catalog_items for insert with check ( is_org_admin(org_id) );
create policy catalog_upd on catalog_items for update using ( is_org_admin(org_id) ) with check ( is_org_admin(org_id) );
create policy catalog_del on catalog_items for delete using ( is_org_admin(org_id) );

-- Hvilke katalogvarer er koblet til et arrangement: begge parter læser; medarbejdere sætter
create policy eci_read on event_catalog_items for select using ( is_org_staff(event_id) or is_event_guest(event_id) );
create policy eci_ins  on event_catalog_items for insert with check ( is_org_staff(event_id) );
create policy eci_del  on event_catalog_items for delete using ( is_org_staff(event_id) );

-- Hvilke lokaler en katalogvare kan bruges i: org'ens folk læser; kun admin sætter
create policy cir_read on catalog_item_rooms for select using (
  exists (select 1 from catalog_items ci where ci.id = catalog_item_rooms.catalog_item_id and ci.org_id = my_org())
);
create policy cir_ins on catalog_item_rooms for insert with check (
  exists (select 1 from catalog_items ci where ci.id = catalog_item_rooms.catalog_item_id and is_org_admin(ci.org_id))
);
create policy cir_del on catalog_item_rooms for delete using (
  exists (select 1 from catalog_items ci where ci.id = catalog_item_rooms.catalog_item_id and is_org_admin(ci.org_id))
);

-- Medarbejdere kan se kolleger (til tildeling); kun admin må ændre brugere
create policy staff_read   on staff for select using ( org_id = my_org() or is_superadmin() );
create policy staff_insert on staff for insert with check ( is_org_admin(org_id) );
create policy staff_update on staff for update using ( is_org_admin(org_id) ) with check ( is_org_admin(org_id) );
create policy staff_delete on staff for delete using ( is_org_admin(org_id) );

-- Invitationer: kun admin
create policy invites_admin on invites for all
  using ( is_org_admin(org_id) ) with check ( is_org_admin(org_id) );

-- Arrangementer: admin ser alle i org; koordinator ser tildelte; brudepar ser eget
create policy event_read on events for select
  using ( is_org_staff(id) or is_event_guest(id) );
create policy event_insert on events for insert
  with check ( org_id = my_org() or is_superadmin() );   -- enhver medarbejder må oprette, superadmin i enhver org
create policy event_update on events for update
  using ( is_org_staff(id) ) with check ( is_org_staff(id) );
create policy event_delete on events for delete
  using ( is_org_admin(org_id) );                   -- kun admin må slette

-- Tildeling: admin eller nogen, der allerede er på arrangementet
create policy estaff_read   on event_staff for select using ( is_org_staff(event_id) );
create policy estaff_insert on event_staff for insert with check ( is_org_staff(event_id) );
create policy estaff_delete on event_staff for delete using ( is_org_staff(event_id) );

create policy eaccess_read   on event_access for select using ( user_id = auth.uid() or is_org_staff(event_id) );
create policy eaccess_insert on event_access for insert with check ( is_org_staff(event_id) );
create policy eaccess_delete on event_access for delete using ( is_org_staff(event_id) );

-- Gæster + punkter: begge parter må læse og redigere
create policy guests_all on guests for all
  using ( is_org_staff(event_id) or is_event_guest(event_id) )
  with check ( is_org_staff(event_id) or is_event_guest(event_id) );

create policy agenda_all on agenda_items for all
  using ( is_org_staff(event_id) or is_event_guest(event_id) )
  with check ( is_org_staff(event_id) or is_event_guest(event_id) );

-- LOG: append-only. Begge parter må indsætte.
create policy log_insert on activity_log for insert
  with check ( is_org_staff(event_id) or is_event_guest(event_id) );
-- Medarbejdere ser hele strømmen.
create policy log_read_staff on activity_log for select
  using ( is_org_staff(event_id) );
-- Brudeparret ser KUN beskeder + kundevendte ændringer (kigge-tid-spærring i db).
create policy log_read_guest on activity_log for select
  using ( is_event_guest(event_id) and (entry_type = 'message' or customer_visible = true) );

-- =====================================================================
--  5. REALTIME — begge parter ser nye beskeder/log-hændelser live.
--     RLS ovenfor filtrerer stadig hvem der må se hvad.
-- =====================================================================
alter publication supabase_realtime add table activity_log;

-- =====================================================================
--  6. SEED — Madkastellet, to lokationer, flere arrangementer
-- =====================================================================
insert into organisations (id, name) values
  ('11111111-1111-1111-1111-111111111111', 'Madkastellet');

insert into venues (id, org_id, name) values
  ('22222222-2222-2222-2222-222222222222','11111111-1111-1111-1111-111111111111','Kilden'),
  ('22222222-2222-2222-2222-222222222223','11111111-1111-1111-1111-111111111111','Madkastellet Havnen');

insert into rooms (id, venue_id, name, sort_order) values
  ('44444444-4444-4444-4444-444444444441','22222222-2222-2222-2222-222222222222','Terrassen ved vejen',1),
  ('44444444-4444-4444-4444-444444444442','22222222-2222-2222-2222-222222222222','Lokalet indendørs',2),
  ('44444444-4444-4444-4444-444444444443','22222222-2222-2222-2222-222222222223','Havnesalen',1);

-- Hovedarrangementet: Emily & Lars (kommende)
insert into events (id, venue_id, org_id, title, event_date, offer_total_kr, status, event_type) values
  ('33333333-3333-3333-3333-333333333333','22222222-2222-2222-2222-222222222222',
   '11111111-1111-1111-1111-111111111111','Emily & Lars','2026-09-04',108245,'bekræftet','bryllup');

-- Ekstra arrangementer, så admin-overblikket har noget at vise
insert into events (venue_id, org_id, title, event_date, offer_total_kr, status, event_type) values
  ('22222222-2222-2222-2222-222222222222','11111111-1111-1111-1111-111111111111','Sofie & Mikkel','2026-05-16',94500,'afviklet','bryllup'),
  ('22222222-2222-2222-2222-222222222223','11111111-1111-1111-1111-111111111111','Firmajubilæum · Nordkraft','2026-06-20',61200,'afviklet','firmafest'),
  ('22222222-2222-2222-2222-222222222222','11111111-1111-1111-1111-111111111111','Anna & Jonas','2026-10-11',102300,'bekræftet','bryllup'),
  ('22222222-2222-2222-2222-222222222223','11111111-1111-1111-1111-111111111111','Konfirmation · Berg','2026-11-01',0,'kladde','andet');

-- Priskatalog for Madkastellet: menuer, pakker, fri bar, tilvalg (fx natmad) — prissat pr. person
insert into catalog_items (id, org_id, name, category, price_kr, basis, child_half, event_type, sort_order) values
  ('55555555-5555-5555-5555-555555555551','11111111-1111-1111-1111-111111111111','Bryllupspakke, middag','menu',1220,'middag',true,'bryllup',1),
  ('55555555-5555-5555-5555-555555555552','11111111-1111-1111-1111-111111111111','Reception 14–15:30','reception',150,'reception',true,'bryllup',2),
  ('55555555-5555-5555-5555-555555555553','11111111-1111-1111-1111-111111111111','Ekstra time','tilvalg',100,'middag',false,null,3),
  ('55555555-5555-5555-5555-555555555554','11111111-1111-1111-1111-111111111111','Natmad, gourmet hotdogs','tilvalg',85,'middag',false,null,4),
  ('55555555-5555-5555-5555-555555555555','11111111-1111-1111-1111-111111111111','Naturvin','bar',75,'middag',false,null,5),
  ('55555555-5555-5555-5555-555555555556','11111111-1111-1111-1111-111111111111','Forplejning fotograf + DJ','tilvalg',325,'fast',false,null,6),
  ('55555555-5555-5555-5555-555555555557','11111111-1111-1111-1111-111111111111','DJ-udstyr','tilvalg',3000,'fast',false,null,7);

-- Emily & Lars har valgt hele det klassiske bryllupssortiment
insert into event_catalog_items (event_id, catalog_item_id) values
  ('33333333-3333-3333-3333-333333333333','55555555-5555-5555-5555-555555555551'),
  ('33333333-3333-3333-3333-333333333333','55555555-5555-5555-5555-555555555552'),
  ('33333333-3333-3333-3333-333333333333','55555555-5555-5555-5555-555555555553'),
  ('33333333-3333-3333-3333-333333333333','55555555-5555-5555-5555-555555555554'),
  ('33333333-3333-3333-3333-333333333333','55555555-5555-5555-5555-555555555555'),
  ('33333333-3333-3333-3333-333333333333','55555555-5555-5555-5555-555555555556'),
  ('33333333-3333-3333-3333-333333333333','55555555-5555-5555-5555-555555555557');

-- lokale pr. fase for Emily & Lars: reception på terrassen, resten indendørs
insert into event_rooms (event_id, phase, room_id, start_time, end_time) values
  ('33333333-3333-3333-3333-333333333333','reception','44444444-4444-4444-4444-444444444441','15:00','17:00'),
  ('33333333-3333-3333-3333-333333333333','middag',   '44444444-4444-4444-4444-444444444442','18:00','21:00'),
  ('33333333-3333-3333-3333-333333333333','fest',     '44444444-4444-4444-4444-444444444442','21:00','01:00');

-- Gæster til Emily & Lars: 65 voksne (64 middag), 6 børn, 6 babyer
insert into guests (event_id, name, category, reception, dinner, dietary, sort_order) values
 ('33333333-3333-3333-3333-333333333333','Emily',    'voksen',true,true,'',1),
 ('33333333-3333-3333-3333-333333333333','Lars',     'voksen',true,true,'',2),
 ('33333333-3333-3333-3333-333333333333','Sarah K',  'voksen',true,true,'Glutenallergi',3),
 ('33333333-3333-3333-3333-333333333333','Christina','voksen',true,true,'Glutenallergi',4),
 ('33333333-3333-3333-3333-333333333333','Lærke',    'voksen',true,true,'Laktoseintolerant',5),
 ('33333333-3333-3333-3333-333333333333','Helle',    'voksen',true,true,'Nøddeallergi',6),
 ('33333333-3333-3333-3333-333333333333','Nanna E',  'voksen',true,true,'Ingen jordskokker',7),
 ('33333333-3333-3333-3333-333333333333','Mie',      'voksen',true,true,'Skaldyrsallergi',8),
 ('33333333-3333-3333-3333-333333333333','Per',      'voksen',true,true,'Spiser ikke fisk',9);
insert into guests (event_id, name, category, reception, dinner, dietary, sort_order)
select '33333333-3333-3333-3333-333333333333','Voksen '||g,'voksen',true,true,'',100+g from generate_series(1,56) g;
update guests set dinner=false where id=(select id from guests
  where event_id='33333333-3333-3333-3333-333333333333' and category='voksen' order by sort_order desc limit 1);
insert into guests (event_id, name, category, reception, dinner, dietary, sort_order)
select '33333333-3333-3333-3333-333333333333','Barn '||g,'barn',true,false,'',200+g from generate_series(1,6) g;
insert into guests (event_id, name, category, reception, dinner, dietary, sort_order)
select '33333333-3333-3333-3333-333333333333','Baby '||g,'baby',true,(g<=3),'',300+g from generate_series(1,6) g;

insert into agenda_items (event_id, title, owner, status, due_date, note, sort_order) values
 ('33333333-3333-3333-3333-333333333333','Bordplan','jer','mangler','2026-08-28','',1),
 ('33333333-3333-3333-3333-333333333333','DJ – ankomsttidspunkt','jer','mangler','2026-08-21','DJ bruger Kildens udstyr',2),
 ('33333333-3333-3333-3333-333333333333','Endeligt deltagerantal','jer','udkast','2026-08-21','67/69 til middag skal blive ét tal',3),
 ('33333333-3333-3333-3333-333333333333','Allergier og særlig kost','jer','udkast','2026-08-25','Bekræftes mod gæstelisten',4),
 ('33333333-3333-3333-3333-333333333333','Bordkort og pynt afleveres','jer','aftalt','2026-09-03','Dagen inden',5),
 ('33333333-3333-3333-3333-333333333333','Blomster leveres','jer','aftalt','2026-09-03','Dagen inden eller på dagen. Kildens vaser',6),
 ('33333333-3333-3333-3333-333333333333','Bobler medbringes (2 slags)','jer','aftalt','2026-09-04','Serveres i champagneskål',7),
 ('33333333-3333-3333-3333-333333333333','Bryllupskage til reception','jer','aftalt','2026-09-04','Medbringes',8),
 ('33333333-3333-3333-3333-333333333333','Cocio til natmad','jer','aftalt','2026-09-04','Medbringes, sættes ud kl. 01',9),
 ('33333333-3333-3333-3333-333333333333','Weissbier på flaske','kilden','aftalt','2026-09-04','',10),
 ('33333333-3333-3333-3333-333333333333','Opdækning og servietringe','kilden','aftalt','2026-09-03','Lysegrå duge, hvide stofservietter, krondyrsservietringe, hvide bloklys',11),
 ('33333333-3333-3333-3333-333333333333','Bordopstilling','kilden','aftalt','2026-09-03','2 langborde + gavebord, DJ-udstyr stilles frem',12),
 ('33333333-3333-3333-3333-333333333333','Lejlighed til babyer','kilden','aftalt','2026-09-04','',13),
 ('33333333-3333-3333-3333-333333333333','Hovedret til fotograf','kilden','aftalt','2026-09-04','Anden ret end den almindelige menu',14),
 ('33333333-3333-3333-3333-333333333333','Vin på bordene','kilden','aftalt','2026-09-04','Både almindelig vin og naturvin',15);

insert into activity_log (event_id, ts, actor_name, actor_side, entry_type, area, label, from_val, to_val, customer_visible, friendly, message_text) values
 ('33333333-3333-3333-3333-333333333333', now()-interval '21 days','Christina (Kilden)','kilden','change','system','Aftale oprettet fra tilbud','','108.245 kr.',true,'Jeres aftale blev oprettet ud fra tilbuddet',''),
 ('33333333-3333-3333-3333-333333333333', now()-interval '14 days','Lars','kunde','change','gaester','Deltagerantal (middag)','62','64',true,'Deltagerantal til middag opdateret til 64',''),
 ('33333333-3333-3333-3333-333333333333', now()-interval '10 days','Emily','kunde','change','gaester','Særlig kost','','Helle: nøddeallergi',true,'Særlig kost tilføjet for Helle (nøddeallergi)',''),
 ('33333333-3333-3333-3333-333333333333', now()-interval '7 days','Malene (Kilden)','kilden','change','system','Medarbejder tildelt','','Christina',false,'',''),
 ('33333333-3333-3333-3333-333333333333', now()-interval '4 days','Emily','kunde','message','system','','','',false,'','Hej Kilden. Vi overvejer at rykke forretten en lille smule senere — er der plads i tidsplanen til det?'),
 ('33333333-3333-3333-3333-333333333333', now()-interval '3 days','Christina (Kilden)','kilden','message','system','','','',false,'','Hej Emily. Fint, vi rykker gerne forretten en anelse — sig til, når I har et ønsket tidspunkt, så justerer jeg programmet.');

-- =====================================================================
--  7. BOOTSTRAP — kør, når du har logget ind via magic link mindst én gang.
--     Find dit UUID under Authentication → Users.
-- =====================================================================
-- -- Gør dig selv til SUPERADMIN (Verta-medarbejder, organisationsuafhængig):
-- insert into superadmins (id, name) values ('DIT-AUTH-UUID','Dit navn');
--
-- -- Eller: gør dig selv til ADMIN i Madkastellet (almindelig org-scoped admin):
-- insert into staff (id, org_id, name, role) values
--   ('DIT-AUTH-UUID','11111111-1111-1111-1111-111111111111','Dit navn','admin');
--
-- Herefter styrer du resten fra konsollen: opret lokationer, inviter
-- koordinatorer (de forfremmes automatisk ved første login), og tildel
-- brudepar til arrangementer. Superadmin lander i stedet i kontrolrummet,
-- hvor nye (demo-)organisationer kan oprettes og åbnes.
--
-- -- Brudepar (indtil adgang gives fra UI'et):
-- insert into event_access (event_id, user_id, display_name) values
--   ('33333333-3333-3333-3333-333333333333','EMILYS-AUTH-UUID','Emily');
