-- =====================================================================
--  Madkastellet · arrangementsværktøj — databaseskema (v1, med roller)
--  Kør hele filen i Supabase → SQL Editor → New query → Run.
--  Roller: admin (IT-ansvarlig, org-bred) · coordinator (menig, egne arr.)
-- =====================================================================

drop trigger if exists on_auth_user_created on auth.users;
drop trigger if exists on_event_created on events;
drop table if exists event_change_requests cascade;
drop table if exists event_approvals    cascade;
drop table if exists event_templates    cascade;
drop table if exists activity_log       cascade;
drop table if exists agenda_item_notes  cascade;
drop table if exists agenda_items       cascade;
drop table if exists task_templates     cascade;
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
drop table if exists superadmin_invites cascade;
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
-- Ingen org_id — det er hele pointen. role='ejer' kan invitere/fjerne andre superadmins (kun én
-- burde reelt have den rolle); 'admin' kan alt det praktiske i kontrolrummet, men ikke det.
create table superadmins (
  id uuid primary key references auth.users(id) on delete cascade,
  name text not null,
  role text not null default 'admin' check (role in ('ejer','admin')),
  created_at timestamptz not null default now()
);

-- Ventende invitationer til at blive Verta-medarbejder — samme mønster som `invites` nedenfor
-- for org-medarbejdere, men org-uafhængig (superadmins har ingen org_id).
create table superadmin_invites (
  id uuid primary key default gen_random_uuid(),
  email text not null unique,
  name text not null,
  role text not null default 'admin' check (role in ('ejer','admin')),
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
  owner_staff_id uuid references staff(id),  -- primær koordinator. IKKE not-null på databaseniveau, bevidst:
                                              -- schema.sql sår sit eget testarrangement (Emily & Lars m.fl.)
                                              -- FØR noget menneske nogensinde har logget ind, så der findes
                                              -- endnu ingen staff-række at pege på — et bootstrapping-problem,
                                              -- ikke et designvalg om at ejerskab er valgfrit. Krævet i praksis af
                                              -- app-laget i stedet: "Nyt arrangement"-formularen tillader ikke
                                              -- oprettelse uden et valgt owner_staff_id, og duplicate_event()
                                              -- kopierer altid kildens ejer. Rigtige organisationer oprettet via
                                              -- "Ny kunde"/"Ny demo" rammer aldrig dette hul, da deres første
                                              -- arrangement altid oprettes efter mindst én staff-række findes.
  secondary_staff_id uuid references staff(id),      -- valgfri sekundær koordinator
  day_of_owner_staff_id uuid references staff(id),   -- ansvarlig på selve arrangementsdagen (kan afvige fra primær)
  created_at timestamptz not null default now()
);

create table event_staff (
  event_id uuid not null references events(id) on delete cascade,
  staff_id uuid not null references staff(id)  on delete cascade,
  primary key (event_id, staff_id)
);

-- Understøtter allerede flere rækker pr. bruger (unique er på parret, ikke på user_id alene) — en gæst
-- kan derfor legitimt have adgang til flere arrangementer. Klienten afgør, hvilket der er "aktivt" for
-- den aktuelle session (se cloudBoot i app/index.html); denne tabel er stadig den eneste autoritative
-- adgangskilde, som RLS (is_event_guest()) slår op i.
create table event_access (
  id uuid primary key default gen_random_uuid(),
  event_id uuid not null references events(id) on delete cascade,
  user_id uuid not null references auth.users(id) on delete cascade,
  display_name text not null,
  email text,                       -- til admin-UI'ets liste over aktive gæsteadgange (auth.users er ikke læsbar via RLS)
  expires_at timestamptz,           -- valgfri udløbstid for invitationen; håndhævet i is_event_guest() nedenfor
  last_seen_at timestamptz,         -- opdateres ved hvert gæste-login, adskilt fra first_visited_at (kun engangs-velkomstkort)
  first_visited_at timestamptz,     -- sat ved gæstens allerførste besøg, styrer velkomstkortet
  created_at timestamptz not null default now(),
  unique (event_id, user_id)
);

-- Lokale pr. fase. Fri-tekst label + sort_order i stedet for en fast reception/
-- middag/fest-treenighed — et arrangement har ikke nødvendigvis tre faser, og
-- faser skal kunne tilføjes/fjernes/omdøbes fra UI'et.
create table event_rooms (
  id uuid primary key default gen_random_uuid(),
  event_id uuid not null references events(id) on delete cascade,
  label text not null,                 -- fasens navn, fx "Reception", "Frokost", "Foredrag"
  room_id uuid references rooms(id) on delete cascade,   -- kan være ubesat (fx en fase oprettet fra en skabelon på tværs af lokationer)
  start_time time,                     -- tidsrum for denne fase (bruges til at forhindre dobbeltbooking)
  end_time time,                       -- hvis end_time <= start_time, regnes det som efter midnat
  sort_order integer not null default 0,
  setup_minutes integer not null default 0,      -- opsætningstid før fasen, regnes med i konflikttjek
  teardown_minutes integer not null default 0,   -- oprydningstid efter fasen, regnes med i konflikttjek
  booking_status text not null default 'bekræftet'  -- tentativ | reserveret | bekræftet
);
create index on event_rooms (event_id);

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
  status text not null default 'mangler',    -- mangler | udkast | aftalt ("Udført" i UI'et)
  due_date date,
  note text not null default '',
  sort_order integer not null default 0,
  assigned_staff_id uuid references staff(id),  -- navngiven medarbejderansvarlig (ud over det brede jer/kilden-skel)
  priority text not null default 'normal'       -- kritisk | normal | lav
);

-- Tekst-noter og filbilag til aftalepunkter — synlige for begge parter, der kan se
-- punktet. event_id denormaliseret (samme mønster som resten af skemaet) til enkel RLS.
create table agenda_item_notes (
  id uuid primary key default gen_random_uuid(),
  agenda_item_id uuid not null references agenda_items(id) on delete cascade,
  event_id uuid not null references events(id) on delete cascade,
  author_name text not null,
  author_side text not null,          -- 'jer' | 'kilden'
  text text not null default '',
  file_path text,                     -- sti i Storage-bucket 'task-attachments', null hvis ingen fil
  file_name text,                     -- oprindeligt filnavn til visning
  created_at timestamptz not null default now()
);
create index on agenda_item_notes (agenda_item_id);
create index on agenda_item_notes (event_id);

-- Kundegodkendelser: en opgave er ikke det samme som en dokumenteret, versioneret godkendelse.
-- version + superseded_by giver fuld historik: en ny version gør den forrige historisk ('erstattet')
-- og ikke længere handlingsbar, uden at slette noget. Se guard_approval_update() nedenfor, som fryser
-- alt indhold på en allerede afgjort række, og decide_approval(), som er gæstens eneste vej til at
-- afgøre en godkendelse (server-side valideret, ikke en direkte UPDATE-RLS-politik for gæster).
create table event_approvals (
  id uuid primary key default gen_random_uuid(),
  event_id uuid not null references events(id) on delete cascade,
  title text not null,
  description text not null default '',
  approval_type text not null default 'andet',   -- tilbud | menu | bordplan | deltagerantal | prisaendring | praktisk | andet
  status text not null default 'kladde',         -- kladde | afventer | godkendt | afvist | erstattet | tilbagekaldt
  version integer not null default 1,
  amount numeric,
  currency text not null default 'DKK',
  payload jsonb,
  due_at timestamptz,
  requested_by uuid references auth.users(id),
  requested_by_name text,
  requested_at timestamptz,
  decided_by uuid references auth.users(id),
  decided_by_name text,
  decided_at timestamptz,
  decision_comment text,
  superseded_by uuid references event_approvals(id),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);
create index on event_approvals (event_id);
create index on event_approvals (event_id, status);

-- Ændringsforslag med prisvirkning: bruges når en gæst ønsker en pris-/driftsrelevant ændring, efter
-- arrangementet er bekræftet (se guests-RLS'en nedenfor, som lukker gæstens direkte skriveadgang til
-- guests-tabellen fra det tidspunkt). apply_change_request() nedenfor udfører selve skrivningen atomisk.
create table event_change_requests (
  id uuid primary key default gen_random_uuid(),
  event_id uuid not null references events(id) on delete cascade,
  requested_by uuid references auth.users(id),
  requested_by_role text not null default 'kunde',   -- 'kunde' | 'kilden'
  requested_by_name text not null default '',
  change_type text not null default 'guest_edit',    -- i dag: 'guest_edit' (se apply_change_request)
  status text not null default 'pending',            -- pending | accepted | rejected
  before_payload jsonb,
  after_payload jsonb not null,
  price_before numeric,
  price_after numeric,
  price_delta numeric,
  comment text,
  reviewed_by uuid references auth.users(id),
  reviewed_by_name text,
  reviewed_at timestamptz,
  review_comment text,
  created_at timestamptz not null default now()
);
create index on event_change_requests (event_id);
create index on event_change_requests (event_id, status);

-- Globale arrangementsskabeloner ("Heldagskonference", "Bryllup" osv). En enkelt jsonb-spec i stedet for
-- en fuld separat tabelfamilie — skabelonen bruges kun til at forudfylde et NYT arrangement, ikke som en
-- levende reference bagefter, så en fladere struktur er tilstrækkelig og langt enklere at vedligeholde.
create table event_templates (
  id uuid primary key default gen_random_uuid(),
  org_id uuid not null references organisations(id) on delete cascade,
  name text not null,
  event_type text not null default 'andet',
  spec jsonb not null default '{}'::jsonb,   -- {phases:[{label,startOffsetMin,endOffsetMin,roomHint}], catalogItemIds:[], taskTemplates:[{title,owner,daysBeforeEvent,note}], approvalTypes:[], notes:'', defaultOwnerRole:''}
  archived boolean not null default false,
  created_by uuid references auth.users(id),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);
create index on event_templates (org_id);

-- Org-genbrugelige opgaveskabeloner ("standardpakke"), samme mønster som catalog_items.
-- Frist er relativ (dage før arrangementet), da skabeloner bruges på tværs af datoer.
create table task_templates (
  id uuid primary key default gen_random_uuid(),
  org_id uuid not null references organisations(id) on delete cascade,
  title text not null,
  owner text not null default 'jer',          -- 'jer' | 'kilden'
  days_before_event integer,                  -- frist = event_date - days_before_event; null = ingen automatisk frist
  note text not null default '',
  event_type text,                            -- null = alle typer, ellers samme værdier som events.event_type
  sort_order integer not null default 0,
  created_at timestamptz not null default now()
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
  message_text text not null default '',
  ip_address text                            -- stemplet server-side, se stamp_activity_log_ip()
);

create index on activity_log (event_id, ts desc);
create index on guests       (event_id);
create index on agenda_items (event_id);
create index on events       (org_id, event_date);

-- Fremmednøgler der slås op direkte fra klienten (ikke kun via RLS).
-- event_access.user_id er vigtigst: slås op ved hver gæste-login (cloudBoot).
create index on event_access  (user_id);
create index on staff         (org_id);
create index on catalog_items (org_id);
create index on task_templates(org_id);
create index on venues        (org_id);
create index on invites       (org_id);
create index on rooms         (venue_id);

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

-- Er denne bruger specifikt 'ejer' blandt superadmins? Styrer alene retten til at invitere/fjerne
-- andre Verta-medarbejdere — ikke adgang til selve kontrolrummets øvrige funktioner.
create or replace function is_superadmin_owner()
returns boolean language sql security definer stable set search_path = public as $$
  select exists (select 1 from superadmins where id = auth.uid() and role = 'ejer')
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
                 where a.event_id = target_event and a.user_id = auth.uid()
                   and (a.expires_at is null or a.expires_at > now()))
$$;

-- Kontaktpersonens navn til gæstens velkomstkort. Gæsten har ingen RLS-adgang
-- til staff-tabellen, så dette security-definer-kald er den eneste vej ind —
-- og kun for nogen, der faktisk er gæst eller medarbejder på arrangementet.
create or replace function get_event_contact(target_event uuid)
returns text language sql security definer stable set search_path = public as $$
  select s.name from events e join staff s on s.id = e.owner_staff_id
  where e.id = target_event and (is_event_guest(target_event) or is_org_staff(target_event))
$$;

-- Bekvem status-opslag til RLS-policyer (undgår at gentage samme subquery flere steder).
create or replace function event_status(target_event uuid)
returns text language sql security definer stable set search_path = public as $$
  select status from events where id = target_event
$$;

-- Gæstens ENESTE vej til at afgøre en godkendelse — ingen direkte UPDATE-RLS-politik for gæster på
-- event_approvals findes, med vilje. Validerer server-side at godkendelsen rent faktisk er sendt
-- ('afventer'), uanset hvad klienten viste, før afgørelsen registreres.
create or replace function decide_approval(p_id uuid, p_decision text, p_comment text default null)
returns void language plpgsql security definer set search_path = public as $$
declare
  appr event_approvals%rowtype;
  guest_name text;
begin
  if p_decision not in ('godkendt','afvist') then
    raise exception 'Ugyldig afgørelse';
  end if;
  select * into appr from event_approvals where id = p_id;
  if not found then raise exception 'Godkendelsen findes ikke'; end if;
  if not is_event_guest(appr.event_id) then
    raise exception 'Ingen adgang til dette arrangement';
  end if;
  if appr.status <> 'afventer' then
    raise exception 'Denne godkendelse er ikke længere afventer (status: %)', appr.status;
  end if;

  select display_name into guest_name from event_access
    where event_id = appr.event_id and user_id = auth.uid() limit 1;

  update event_approvals set
    status = p_decision,
    decided_by = auth.uid(),
    decided_by_name = coalesce(guest_name, 'Gæst'),
    decided_at = now(),
    decision_comment = p_comment,
    updated_at = now()
  where id = p_id;
end;
$$;

-- Atomisk anvendelse af et accepteret ændringsforslag (i dag: change_type='guest_edit'). Kun staff kan
-- kalde den (is_org_staff), og hele funktionskroppen kører i kalderens transaktion — fejler et skridt,
-- rulles det hele tilbage, så "accepteret" og "gæstedata opdateret" aldrig kan komme ud af trit.
create or replace function apply_change_request(p_id uuid, p_comment text default null)
returns void language plpgsql security definer set search_path = public as $$
declare
  req event_change_requests%rowtype;
  g jsonb;
  staff_name text;
  action text;
begin
  select * into req from event_change_requests where id = p_id;
  if not found then raise exception 'Ændringsforslaget findes ikke'; end if;
  if not is_org_staff(req.event_id) then raise exception 'Ingen adgang'; end if;
  if req.status <> 'pending' then raise exception 'Forslaget er allerede behandlet'; end if;

  if req.change_type = 'guest_edit' then
    g := req.after_payload->'guest';
    action := req.after_payload->>'action';
    if action = 'insert' then
      insert into guests (id, event_id, name, category, reception, dinner, dietary, sort_order)
        values (coalesce((g->>'id')::uuid, gen_random_uuid()), req.event_id, coalesce(g->>'navn',''),
                coalesce(g->>'kat','voksen'), coalesce((g->>'reception')::boolean, true),
                coalesce((g->>'middag')::boolean, true), coalesce(g->>'kost',''), 999);
    elsif action = 'update' then
      update guests set name = coalesce(g->>'navn', name), category = coalesce(g->>'kat', category),
        reception = coalesce((g->>'reception')::boolean, reception),
        dinner = coalesce((g->>'middag')::boolean, dinner),
        dietary = coalesce(g->>'kost', dietary)
        where id = (g->>'id')::uuid and event_id = req.event_id;
    elsif action = 'delete' then
      delete from guests where id = (g->>'id')::uuid and event_id = req.event_id;
    else
      raise exception 'Ukendt handling i ændringsforslaget: %', action;
    end if;
  else
    raise exception 'Ukendt ændringstype: %', req.change_type;
  end if;

  select name into staff_name from staff where id = auth.uid();
  update event_change_requests set status = 'accepted', reviewed_by = auth.uid(),
    reviewed_by_name = coalesce(staff_name, 'Medarbejder'), reviewed_at = now(), review_comment = p_comment
    where id = p_id;
end;
$$;

-- Dublikering sker atomisk server-side (én transaktion, hele funktionskroppen), autoriseret via
-- is_org_staff() på KILDE-arrangementet. Kopierer kun det, kalderen har valgt via p_options — resten
-- (gæster, event_access, magic links, beskeder, aktivitetslog, godkendelsesafgørelser, uploadede filer)
-- kopieres ALDRIG, uanset options. Det nye arrangement starter altid som 'kladde'.
create or replace function duplicate_event(
  p_source_id uuid, p_new_title text, p_new_date date, p_new_venue_id uuid,
  p_options jsonb default '{}'::jsonb
)
returns uuid language plpgsql security definer set search_path = public as $$
declare
  src events%rowtype;
  new_id uuid;
  shift_minutes integer;
  r record;
  new_agenda_id uuid;
  agenda_map jsonb := '{}'::jsonb;
begin
  select * into src from events where id = p_source_id;
  if not found then raise exception 'Kilde-arrangementet findes ikke'; end if;
  if not is_org_staff(p_source_id) then raise exception 'Ingen adgang til kilde-arrangementet'; end if;
  if p_new_venue_id is not null and not exists (select 1 from venues where id = p_new_venue_id and org_id = src.org_id) then
    raise exception 'Lokationen tilhører ikke samme organisation';
  end if;

  shift_minutes := coalesce((p_options->>'shiftMinutes')::integer, 0);

  -- owner_staff_id kopieres altid fra kilden (aldrig valgfrit) — et arrangement uden koordinator må
  -- ikke kunne opstå via duplikering, ligesom det ikke kan ved almindelig oprettelse (createEvent()
  -- i app/index.html kræver nu et valgt owner_staff_id). "staff"-valget styrer kun sekundær koordinator
  -- og øvrige tilknyttede medarbejdere (event_staff) — ikke selve ejerskabet.
  insert into events (venue_id, org_id, title, event_date, offer_total_kr, status, event_type, owner_staff_id)
    values (coalesce(p_new_venue_id, src.venue_id), src.org_id, p_new_title, p_new_date, 0, 'kladde', src.event_type, src.owner_staff_id)
    returning id into new_id;

  if coalesce((p_options->>'staff')::boolean, false) then
    update events set secondary_staff_id = src.secondary_staff_id where id = new_id;
    insert into event_staff (event_id, staff_id)
      select new_id, staff_id from event_staff where event_id = p_source_id
      on conflict do nothing;
  end if;

  if coalesce((p_options->>'phases')::boolean, false) then
    insert into event_rooms (event_id, label, room_id, start_time, end_time, sort_order, setup_minutes, teardown_minutes, booking_status)
      select new_id, label, room_id,
        (start_time + (shift_minutes || ' minutes')::interval)::time,
        (end_time + (shift_minutes || ' minutes')::interval)::time,
        sort_order, setup_minutes, teardown_minutes, 'tentativ'
      from event_rooms where event_id = p_source_id;
  end if;

  if coalesce((p_options->>'catalog')::boolean, false) then
    insert into event_catalog_items (event_id, catalog_item_id)
      select new_id, catalog_item_id from event_catalog_items where event_id = p_source_id
      on conflict do nothing;
  end if;

  if coalesce((p_options->>'agenda')::boolean, false) then
    for r in select * from agenda_items where event_id = p_source_id loop
      insert into agenda_items (event_id, title, owner, status, due_date, note, sort_order, priority)
        values (new_id, r.title, r.owner, 'mangler',
          case when r.due_date is not null then p_new_date + (r.due_date - src.event_date) else null end,
          r.note, r.sort_order, r.priority)
        returning id into new_agenda_id;
      agenda_map := agenda_map || jsonb_build_object(r.id::text, new_agenda_id::text);
    end loop;

    if coalesce((p_options->>'notes')::boolean, false) then
      for r in select n.* from agenda_item_notes n
        join agenda_items a on a.id = n.agenda_item_id
        where a.event_id = p_source_id and n.file_path is null loop
        insert into agenda_item_notes (agenda_item_id, event_id, author_name, author_side, text)
          values ((agenda_map->>r.agenda_item_id::text)::uuid, new_id, r.author_name, r.author_side, r.text);
      end loop;
    end if;
  end if;

  if coalesce((p_options->>'taskTemplates')::boolean, false) then
    insert into agenda_items (event_id, title, owner, due_date, note, sort_order)
      select new_id, t.title, t.owner,
        case when t.days_before_event is not null then p_new_date - t.days_before_event else null end,
        coalesce(t.note,''), coalesce(t.sort_order,0)
      from task_templates t
      where t.org_id = src.org_id and (t.event_type is null or t.event_type = src.event_type);
  end if;

  if coalesce((p_options->>'approvalTypes')::boolean, false) then
    insert into event_approvals (event_id, title, approval_type, status)
      select new_id, 'Ny '||lower(coalesce(nullif(at.approval_type,''),'godkendelse')), at.approval_type, 'kladde'
      from (select distinct approval_type from event_approvals where event_id = p_source_id) at;
  end if;

  return new_id;
end;
$$;

-- =====================================================================
--  3. TRIGGERE
-- =====================================================================
-- Ny auth-bruger med en ventende invitation → bliv medarbejder automatisk. Tjekker begge
-- invitationstyper (org-medarbejder og Verta-superadmin) — en person kan i princippet være begge.
create or replace function handle_new_user()
returns trigger language plpgsql security definer set search_path = public as $$
declare inv invites%rowtype; sinv superadmin_invites%rowtype;
begin
  select * into inv from invites where lower(email) = lower(new.email) limit 1;
  if found then
    insert into staff (id, org_id, name, role)
      values (new.id, inv.org_id, inv.name, inv.role)
      on conflict (id) do nothing;
    delete from invites where id = inv.id;
  end if;

  select * into sinv from superadmin_invites where lower(email) = lower(new.email) limit 1;
  if found then
    insert into superadmins (id, name, role)
      values (new.id, sinv.name, sinv.role)
      on conflict (id) do nothing;
    delete from superadmin_invites where id = sinv.id;
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

-- Stempler ip_address på hvert log-opslag ud fra PostgRESTs request-headers.
-- Klienten kan ikke forfalske feltet — et BEFORE INSERT-trigger overskriver
-- altid, uanset hvad der blev sendt i insert-kaldet. Tekst med vilje (ikke
-- inet): en uventet/manglende header skal aldrig kunne fejle selve
-- indsættelsen og dermed blokere beskeder eller ændringer i loggen.
create or replace function stamp_activity_log_ip()
returns trigger language plpgsql security definer set search_path = public as $$
begin
  new.ip_address := nullif(split_part(current_setting('request.headers', true)::json->>'x-forwarded-for', ',', 1), '');
  return new;
end;
$$;
create trigger on_activity_log_ip
  before insert on activity_log
  for each row execute function stamp_activity_log_ip();

-- Gæsten må kun ændre status på egne aftalepunkter — dette trigger klapper
-- ethvert andet felt tilbage til den gamle værdi, uanset hvad et forsøgt
-- API-kald indeholder. RLS (agenda_update) begrænser i forvejen HVILKE
-- rækker gæsten overhovedet kan forsøge at ramme.
create or replace function guard_agenda_item_update()
returns trigger language plpgsql security definer set search_path = public as $$
begin
  if not is_org_staff(new.event_id) then
    new.title := old.title;
    new.owner := old.owner;
    new.due_date := old.due_date;
    new.note := old.note;
    new.sort_order := old.sort_order;
    new.event_id := old.event_id;
  end if;
  return new;
end;
$$;
create trigger on_agenda_item_update
  before update on agenda_items
  for each row execute function guard_agenda_item_update();

-- "Godkendelser må ikke kunne ændres historisk efter beslutningen": når status allerede er godkendt/
-- afvist, klapper dette trigger alle indholdsfelter tilbage til den gamle værdi. Den eneste tilladte
-- ændring efter en afgørelse er status -> 'erstattet' + superseded_by, præcis det en ny version gør ved
-- den gamle. Gælder uanset kaldevej (staff-update eller decide_approval-RPC'en).
create or replace function guard_approval_update()
returns trigger language plpgsql security definer set search_path = public as $$
begin
  if old.status in ('godkendt','afvist') then
    new.title := old.title;
    new.description := old.description;
    new.approval_type := old.approval_type;
    new.amount := old.amount;
    new.currency := old.currency;
    new.payload := old.payload;
    new.due_at := old.due_at;
    new.decided_by := old.decided_by;
    new.decided_by_name := old.decided_by_name;
    new.decided_at := old.decided_at;
    new.decision_comment := old.decision_comment;
    new.requested_by := old.requested_by;
    new.requested_by_name := old.requested_by_name;
    new.requested_at := old.requested_at;
    if new.status not in (old.status, 'erstattet') then
      new.status := old.status;
    end if;
  end if;
  new.updated_at := now();
  return new;
end;
$$;
create trigger on_approval_update before update on event_approvals
  for each row execute function guard_approval_update();

-- Forhindrer dobbeltbooking: samme lokale kan ikke bruges to steder samtidig samme dag, inklusive
-- opsætnings-/oprydningstid rundt om hver fase. Samme lokale samme dag men forskudte tidsrum (med nok
-- luft til opsætning/oprydning) er ok; samme tidsrum i forskellige lokaler er ok.
create or replace function check_room_conflict()
returns trigger language plpgsql security definer set search_path = public as $$
declare
  ev_date date;
  new_start timestamptz;
  new_end timestamptz;
  conflict_row record;
begin
  if new.start_time is null or new.end_time is null or new.room_id is null then
    return new;   -- intet tidsrum/lokale sat endnu — kan ikke tjekkes
  end if;

  select event_date into ev_date from events where id = new.event_id;
  new_start := ev_date + new.start_time - (coalesce(new.setup_minutes,0) || ' minutes')::interval;
  new_end   := ev_date + new.end_time;
  if new.end_time <= new.start_time then
    new_end := new_end + interval '1 day';   -- fase går over midnat
  end if;
  new_end := new_end + (coalesce(new.teardown_minutes,0) || ' minutes')::interval;

  select er.label, e2.title, e2.id as other_event_id into conflict_row
  from event_rooms er
  join events e2 on e2.id = er.event_id
  where er.room_id = new.room_id
    and er.start_time is not null and er.end_time is not null
    and er.id <> new.id
    and (e2.event_date + er.start_time - (coalesce(er.setup_minutes,0) || ' minutes')::interval) < new_end
    and new_start < (e2.event_date + er.end_time
        + (case when er.end_time <= er.start_time then interval '1 day' else interval '0' end)
        + (coalesce(er.teardown_minutes,0) || ' minutes')::interval)
  limit 1;

  if found then
    raise exception 'Lokalet er allerede booket % – % (% · %), inkl. opsætning/oprydning',
      new.start_time, new.end_time, conflict_row.title, conflict_row.label;
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
alter table agenda_item_notes enable row level security;
alter table activity_log  enable row level security;
alter table rooms         enable row level security;
alter table event_rooms   enable row level security;
alter table catalog_items       enable row level security;
alter table event_catalog_items enable row level security;
alter table catalog_item_rooms  enable row level security;
alter table task_templates      enable row level security;
alter table event_approvals     enable row level security;
alter table event_change_requests enable row level security;
alter table event_templates     enable row level security;
alter table superadmin_invites  enable row level security;

-- Superadmin: læsbar for sig selv, og fuldt læsbar for 'ejer' (til "Verta-brugere"-listen i
-- kontrolrummet). Kun 'ejer' kan fjerne en anden superadmin — og aldrig sig selv (undgår at man
-- ved en fejl låser sig selv ude af kontrolrummet).
create policy superadmins_read_self on superadmins for select using (id = auth.uid());
create policy superadmins_read_owner on superadmins for select using (is_superadmin_owner());
create policy superadmins_delete_owner on superadmins for delete using (is_superadmin_owner() and id <> auth.uid());

-- Invitationer til at blive Verta-medarbejder: udelukkende 'ejer' må oprette/se/fjerne dem.
create policy sinvites_all_owner on superadmin_invites for all
  using (is_superadmin_owner()) with check (is_superadmin_owner());

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

-- Gæster: begge parter læser altid. Staff må altid skrive. Gæsten må KUN skrive direkte, mens
-- arrangementet endnu ikke er bekræftet (kladde/tilbud) — derefter er deltagerantal/kategori/kost
-- prisrelevant driftsdata, og ændringer skal i stedet indsendes som et event_change_requests-forslag
-- (se apply_change_request() ovenfor), som staff behandler. Dette er den "tydelige regel" for hvilke
-- felter kunden må ændre direkte kontra hvad der bliver et forslag: det er ikke feltspecifikt (alle
-- guests-felter er i praksis prisrelevante via computeEventTotal), men tidspunktspecifikt.
create policy guests_read on guests for select
  using ( is_org_staff(event_id) or is_event_guest(event_id) );
create policy guests_staff_insert on guests for insert with check ( is_org_staff(event_id) );
create policy guests_staff_update on guests for update using ( is_org_staff(event_id) ) with check ( is_org_staff(event_id) );
create policy guests_staff_delete on guests for delete using ( is_org_staff(event_id) );
create policy guests_guest_insert on guests for insert
  with check ( is_event_guest(event_id) and event_status(event_id) in ('kladde','tilbud') );
create policy guests_guest_update on guests for update
  using ( is_event_guest(event_id) and event_status(event_id) in ('kladde','tilbud') )
  with check ( is_event_guest(event_id) and event_status(event_id) in ('kladde','tilbud') );
create policy guests_guest_delete on guests for delete
  using ( is_event_guest(event_id) and event_status(event_id) in ('kladde','tilbud') );

-- Aftalepunkter: kun koordinator opretter/sletter. Gæsten ser alt, men må
-- kun opdatere status på egne ("jer") punkter — håndhævet i with check
-- her og på kolonneniveau af guard_agenda_item_update()-triggeren ovenfor.
create policy agenda_read on agenda_items for select
  using ( is_org_staff(event_id) or is_event_guest(event_id) );
create policy agenda_insert on agenda_items for insert
  with check ( is_org_staff(event_id) );
create policy agenda_update on agenda_items for update
  using ( is_org_staff(event_id) or (is_event_guest(event_id) and owner = 'jer') )
  with check ( is_org_staff(event_id) or (is_event_guest(event_id) and owner = 'jer') );
create policy agenda_delete on agenda_items for delete
  using ( is_org_staff(event_id) );

-- Noter/bilag til aftalepunkter: begge parter må læse og oprette; kun koordinator sletter.
create policy agenda_notes_read on agenda_item_notes for select
  using ( is_org_staff(event_id) or is_event_guest(event_id) );
create policy agenda_notes_insert on agenda_item_notes for insert
  with check ( is_org_staff(event_id) or is_event_guest(event_id) );
create policy agenda_notes_delete on agenda_item_notes for delete
  using ( is_org_staff(event_id) );

-- Opgaveskabeloner: org'ens folk læser; kun admin opretter/ændrer/sletter (som catalog_items).
create policy task_templates_read on task_templates for select
  using ( org_id = my_org() or is_superadmin() );
create policy task_templates_insert on task_templates for insert with check ( is_org_admin(org_id) );
create policy task_templates_update on task_templates for update using ( is_org_admin(org_id) ) with check ( is_org_admin(org_id) );
create policy task_templates_delete on task_templates for delete using ( is_org_admin(org_id) );

-- Godkendelser: begge parter læser (klienten skjuler kladder for gæsten); kun staff opretter/redigerer/
-- tilbagekalder. Gæsten afgør UDELUKKENDE via decide_approval()-RPC'en ovenfor — ingen guest-update-
-- politik her er en bevidst udeladelse, ikke en forglemmelse.
create policy approvals_read on event_approvals for select
  using ( is_org_staff(event_id) or is_event_guest(event_id) );
create policy approvals_staff_write on event_approvals for insert
  with check ( is_org_staff(event_id) );
create policy approvals_staff_update on event_approvals for update
  using ( is_org_staff(event_id) )
  with check ( is_org_staff(event_id) );
create policy approvals_staff_delete on event_approvals for delete
  using ( is_org_staff(event_id) and status = 'kladde' );

-- Ændringsforslag: begge parter læser og opretter (gæsten foreslår, staff kan også oprette til fx
-- dokumentation); kun staff må behandle (godkende via apply_change_request()-RPC'en, eller afvise via
-- en almindelig UPDATE, som ikke rører guests-tabellen og derfor ikke behøver egen RPC).
create policy change_requests_read on event_change_requests for select
  using ( is_org_staff(event_id) or is_event_guest(event_id) );
create policy change_requests_insert on event_change_requests for insert
  with check ( is_org_staff(event_id) or is_event_guest(event_id) );
create policy change_requests_staff_update on event_change_requests for update
  using ( is_org_staff(event_id) )
  with check ( is_org_staff(event_id) );

-- Arrangementsskabeloner: org-ejede, samme mønster som catalog_items/task_templates.
create policy templates_read on event_templates for select
  using ( org_id = my_org() or is_superadmin() );
create policy templates_insert on event_templates for insert with check ( is_org_admin(org_id) );
create policy templates_update on event_templates for update using ( is_org_admin(org_id) ) with check ( is_org_admin(org_id) );
create policy templates_delete on event_templates for delete using ( is_org_admin(org_id) );

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
--  5. STORAGE — filbilag til aftalepunkter
--     Privat bucket. Sti-konvention: {event_id}/{agenda_item_id}/{filnavn} —
--     genbruger is_org_staff()/is_event_guest() uændret via foldernavnet.
-- =====================================================================
insert into storage.buckets (id, name, public) values ('task-attachments','task-attachments', false)
  on conflict (id) do nothing;

create policy task_attachments_read on storage.objects for select
  using (bucket_id = 'task-attachments' and (
    is_org_staff(((storage.foldername(name))[1])::uuid) or is_event_guest(((storage.foldername(name))[1])::uuid)
  ));
create policy task_attachments_insert on storage.objects for insert
  with check (bucket_id = 'task-attachments' and (
    is_org_staff(((storage.foldername(name))[1])::uuid) or is_event_guest(((storage.foldername(name))[1])::uuid)
  ));
create policy task_attachments_delete on storage.objects for delete
  using (bucket_id = 'task-attachments' and is_org_staff(((storage.foldername(name))[1])::uuid));

-- =====================================================================
--  6. REALTIME — begge parter ser ændringer live.
--     RLS ovenfor filtrerer stadig hvem der må se hvad.
-- =====================================================================
alter publication supabase_realtime add table activity_log;
alter publication supabase_realtime add table guests;
alter publication supabase_realtime add table agenda_items;
alter publication supabase_realtime add table event_rooms;
alter publication supabase_realtime add table agenda_item_notes;

-- =====================================================================
--  7. SEED — Madkastellet, to lokationer, flere arrangementer
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
insert into event_rooms (event_id, label, room_id, start_time, end_time, sort_order) values
  ('33333333-3333-3333-3333-333333333333','Reception','44444444-4444-4444-4444-444444444441','15:00','17:00',1),
  ('33333333-3333-3333-3333-333333333333','Middag',   '44444444-4444-4444-4444-444444444442','18:00','21:00',2),
  ('33333333-3333-3333-3333-333333333333','Fest',     '44444444-4444-4444-4444-444444444442','21:00','01:00',3);

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
--  8. BOOTSTRAP — kør, når du har logget ind via magic link mindst én gang.
--     Find dit UUID under Authentication → Users.
-- =====================================================================
-- -- Gør dig selv til SUPERADMIN-EJER (Verta-medarbejder, organisationsuafhængig — kan invitere
-- -- andre Verta-brugere fra kontrolrummet bagefter, så dette bootstrap-trin kun skal køres én gang):
-- insert into superadmins (id, name, role) values ('DIT-AUTH-UUID','Dit navn','ejer');
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
