-- =====================================================================
--  Verta · arrangementskoordinationsværktøj — databaseskema (v1, forenklet)
--  Kør hele filen i Supabase → SQL Editor → New query → Run.
--  Roller: admin (IT-ansvarlig, org-bred) · coordinator (menig, egne arr.)
--
--  v1-forenkling: en lang række funktioner fra det oprindelige, bredere
--  produkt er bevidst skåret her for at gøre værktøjet nemmere at overskue
--  for en ny bruger. Se roadmap.html ("Skåret fra v1") for den fulde liste
--  og begrundelsen for hver enkelt. Intet er slettet af historiske
--  grunde — kun fordi det gjorde produktet sværere at lære.
-- =====================================================================

drop trigger if exists on_auth_user_created on auth.users;
drop trigger if exists on_event_created on events;
drop table if exists activity_log       cascade;
drop table if exists agenda_item_notes  cascade;
drop table if exists agenda_items       cascade;
drop table if exists guests             cascade;
drop table if exists invites            cascade;
drop table if exists event_access       cascade;
drop table if exists event_staff        cascade;
drop table if exists event_rooms        cascade;
drop table if exists events             cascade;
drop table if exists staff              cascade;
drop table if exists rooms              cascade;
drop table if exists venues             cascade;
drop table if exists superadmins        cascade;
drop table if exists superadmin_invites cascade;
drop table if exists organisations      cascade;
-- Løsstående funktioner fra før v1, der IKKE forsvinder automatisk med tabellerne ovenfor (de er
-- ikke triggere/views afhængige af tabellen i Postgres' forstand, kun almindelige RPC'er, der
-- forespørger den) — droppet eksplicit, ellers overlever de som forældreløse, men stadig kaldbare
-- RPC'er, der fejler ved kald (fanget af Supabase-linteren efter første v1-kørsel mod en database,
-- der havde kørt det gamle skema).
drop function if exists apply_change_request(uuid, text);
drop function if exists decide_approval(uuid, text, text);
drop function if exists guard_approval_update();

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
  title text,                                 -- fritekst jobtitel (fx "Selskabsansvarlig"), valgfri, sat af personen selv
  avatar_url text,                            -- offentlig URL i storage-bucket 'staff-avatars', valgfri
  onboarding jsonb not null default '{}'::jsonb,  -- {steps:{stepKey:true,...}, dismissed:bool} — koordinatorens "lær værktøjet"-tjekliste, se update_own_onboarding()
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
  end_date date,                              -- valgfri: sat = arrangementet dækker event_date..end_date (flere dage).
                                               -- Ingen dag-for-dag-model (forskellige lokaler pr. dag) i v1 — hele
                                               -- intervallet deler samme lokalevalg. Se roadmap for evt. udvidelse.
  event_kind text not null default 'privat' check (event_kind in ('privat','virksomhed')),
                                               -- valgt ved oprettelse, styrer hvilke felter der vises i Admin-fanen
  company_name text,                          -- kun relevant når event_kind = 'virksomhed'
  company_cvr text,
  invoice_recipient_name text,
  invoice_recipient_email text,
  po_number text,                             -- evt. ordre-/PO-nummer fra virksomhedskunden
  expected_guests integer,                    -- forventet antal gæster — altid synligt/redigerbart, uafhængigt af
                                               -- om der findes en navngiven gæsteliste (den er en opgave, se agenda_items)
  offer_total_kr integer not null default 0,
  status text not null default 'bekræftet',   -- kladde | tilbud | bekræftet | afviklet
  event_type text not null default 'bryllup', -- bryllup | firmafest | konference | teambuilding | andet
  owner_staff_id uuid references staff(id),  -- primær koordinator. IKKE not-null på databaseniveau, bevidst:
                                              -- schema.sql sår sit eget testarrangement FØR noget menneske
                                              -- nogensinde har logget ind, så der findes endnu ingen staff-række
                                              -- at pege på — et bootstrapping-problem, ikke et designvalg om at
                                              -- ejerskab er valgfrit. Krævet i praksis af app-laget i stedet:
                                              -- "Nyt arrangement"-formularen tillader ikke oprettelse uden et
                                              -- valgt owner_staff_id, og duplicate_event() kopierer altid
                                              -- kildens ejer. Rigtige organisationer oprettet via "Ny kunde"/
                                              -- "Ny demo" rammer aldrig dette hul, da deres første arrangement
                                              -- altid oprettes efter mindst én staff-række findes.
  archived_at timestamptz,   -- sat = "slettet"/"arkiveret" fra brugerens synsvinkel, men ALDRIG en rigtig
                              -- DELETE FROM events — kun arkivering, uanset om UI'et kalder det "Slet" eller
                              -- "Arkivér" (afgøres af status: et afviklet arrangement kan kun arkiveres, et
                              -- arrangement der stadig er i gang "slettes" fra den aktive liste, men ender
                              -- samme sted). Arkiverede arrangementer forsvinder fra den aktive oversigt, men
                              -- forbliver læsbare i en foldet "Arkiverede"-sektion. Skrivning spærres af
                              -- mutate() i app/index.html ud fra state.eventArchived — samme mønster som
                              -- previewMode tidligere brugte, og af samme grund IKKE duplikeret som en
                              -- RLS-politik pr. tabel: det er en bevidst UX-lås for nogen, der allerede har
                              -- legitim skriveadgang, ikke en reel adgangsbegrænsning mod en fremmed aktør.
  created_at timestamptz not null default now()
);

create table event_staff (
  event_id uuid not null references events(id) on delete cascade,
  staff_id uuid not null references staff(id)  on delete cascade,
  primary key (event_id, staff_id)
);

-- Understøtter allerede flere rækker pr. bruger (unique er på parret, ikke på user_id alene) — en gæst
-- kan derfor teknisk have adgang til flere arrangementer, men v1's UI antager én aktiv adgang pr.
-- gæstelogin (ingen "skift arrangement"-vælger mere) — se cloudBoot() i app/index.html.
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

-- Hvilke lokaler et arrangement bruger. Fladt join, IKKE pr. fase (v1 har ingen dynamiske faser
-- længere) — koordinator vælger blot ét eller flere lokaler for hele arrangementet, med ét fælles
-- tidsrum på selve arrangementet (start_time/end_time nedenfor), i stedet for et tidsrum pr. lokale.
create table event_rooms (
  event_id uuid not null references events(id) on delete cascade,
  room_id uuid not null references rooms(id) on delete cascade,
  primary key (event_id, room_id)
);

alter table events add column start_time time;   -- valgfrit fælles tidsrum for hele arrangementet
alter table events add column end_time time;     -- (bruges til konfliktkontrol i Lokalekalenderen; intet
                                                  --  tidsrum sat = hele dagen/dagene antages optaget)

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

-- Opgaver. Dækker i v1 tre ting, der før var separate mekanismer:
--  1. Almindelig to-do (som hidtil): title/owner/status/due_date/note/assigned_staff_id/priority.
--  2. Kundegodkendelser (tidligere event_approvals, egen fane/tabel) — en opgave kan markeres
--     requires_confirmation, hvorved gæsten i stedet for "marker som udført" får en godkend/afvis-
--     handling (guest_decision). Ingen versionering/audit-historik i v1 (det var det tunge ved den
--     gamle model) — en genåbnet/rettet opgave er bare en opgave, der redigeres som enhver anden.
--  3. Gæstelistens deadline (tidligere et separat, overvejet felt) — én opgave pr. arrangement kan
--     flages is_guest_list_deadline. Den opgave er samtidig det, der gør Gæster-fanen synlig for
--     gæsten (før den findes, er der ingen navngiven gæsteliste at vise — kun events.expected_guests,
--     som altid er synligt), OG dens due_date er den frist, hvorefter guests-tabellen låses for
--     gæstens direkte redigering (se guests-RLS'en nedenfor, som allerede var tidsstyret).
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
  priority text not null default 'normal',      -- kritisk | normal | lav
  requires_confirmation boolean not null default false,
  guest_decision text check (guest_decision in ('godkendt','afvist')),
  guest_decision_at timestamptz,
  guest_decision_comment text,
  is_guest_list_deadline boolean not null default false
);
-- Kun én "gæstelistefrist"-opgave pr. arrangement.
create unique index one_guest_list_deadline_per_event on agenda_items(event_id) where is_guest_list_deadline;

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

create table activity_log (
  id uuid primary key default gen_random_uuid(),
  event_id uuid not null references events(id) on delete cascade,
  ts timestamptz not null default now(),
  actor_id uuid references auth.users(id),
  actor_name text not null,
  actor_side text not null,                  -- 'kilden' | 'kunde'
  entry_type text not null,                  -- 'change' | 'view' | 'message' | 'note'
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
create index on venues        (org_id);
create index on invites       (org_id);
create index on rooms         (venue_id);
create index on event_rooms   (room_id);

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

-- Kontaktpersonens navn/titel/billede til gæstens velkomstkort og kontaktkort. Gæsten har ingen RLS-
-- adgang til staff-tabellen, så dette security-definer-kald er den eneste vej ind — og kun for nogen,
-- der faktisk er gæst eller medarbejder på arrangementet.
create or replace function get_event_contact(target_event uuid)
returns table(name text, title text, avatar_url text) language sql security definer stable set search_path = public as $$
  select s.name, s.title, s.avatar_url from events e join staff s on s.id = e.owner_staff_id
  where e.id = target_event and (is_event_guest(target_event) or is_org_staff(target_event))
$$;

-- Selvbetjent profilredigering (navn/titel/billede) — bevidst IKKE en bred "opdater egen staff-række"-
-- RLS-politik, da staff også rummer org_id/role, og en almindelig koordinator ellers kunne forfremme
-- sig selv til admin eller flytte sig til en anden org via samme åbning. RPC'en rører derfor kun de
-- tre navngivne felter, og kun på kalderens EGEN række (where id = auth.uid()).
create or replace function update_own_profile(p_name text, p_title text default null, p_avatar_url text default null)
returns void language plpgsql security definer set search_path = public as $$
begin
  if p_name is null or trim(p_name) = '' then
    raise exception 'Navn må ikke være tomt';
  end if;
  update staff set name = trim(p_name), title = nullif(trim(coalesce(p_title,'')),''), avatar_url = p_avatar_url
  where id = auth.uid();
end;
$$;

-- Samme selvbetjenings-princip som update_own_profile ovenfor, men for koordinatorens "lær værktøjet"-
-- tjekliste (se app/index.html: ONBOARDING_STEPS/markOnboardingStep) — skrives ofte og automatisk, hver
-- gang brugeren udfører en ny handling appen sporer, derfor sin egen snævre RPC frem for at overloade
-- update_own_profile med endnu et parameter, der opdateres på et helt andet tidspunkt.
create or replace function update_own_onboarding(p_onboarding jsonb)
returns void language plpgsql security definer set search_path = public as $$
begin
  update staff set onboarding = coalesce(p_onboarding, '{}'::jsonb) where id = auth.uid();
end;
$$;

-- Bekvem status-opslag til RLS-policyer (undgår at gentage samme subquery flere steder).
create or replace function event_status(target_event uuid)
returns text language sql security definer stable set search_path = public as $$
  select status from events where id = target_event
$$;

-- Dublikering sker atomisk server-side (én transaktion, hele funktionskroppen), autoriseret via
-- is_org_staff() på KILDE-arrangementet. Kopierer kun det, kalderen har valgt via p_options — resten
-- (gæster, event_access, magic links, beskeder, aktivitetslog) kopieres ALDRIG, uanset options.
-- Det nye arrangement starter altid som 'kladde'.
create or replace function duplicate_event(
  p_source_id uuid, p_new_title text, p_new_date date, p_new_venue_id uuid,
  p_options jsonb default '{}'::jsonb
)
returns uuid language plpgsql security definer set search_path = public as $$
declare
  src events%rowtype;
  new_id uuid;
  r record;
begin
  select * into src from events where id = p_source_id;
  if not found then raise exception 'Kilde-arrangementet findes ikke'; end if;
  if not is_org_staff(p_source_id) then raise exception 'Ingen adgang til kilde-arrangementet'; end if;
  if p_new_venue_id is not null and not exists (select 1 from venues where id = p_new_venue_id and org_id = src.org_id) then
    raise exception 'Lokationen tilhører ikke samme organisation';
  end if;

  -- owner_staff_id kopieres altid fra kilden (aldrig valgfrit) — et arrangement uden koordinator må
  -- ikke kunne opstå via duplikering, ligesom det ikke kan ved almindelig oprettelse.
  insert into events (venue_id, org_id, title, event_date, offer_total_kr, status, event_type, event_kind, owner_staff_id)
    values (coalesce(p_new_venue_id, src.venue_id), src.org_id, p_new_title, p_new_date, 0, 'kladde', src.event_type, src.event_kind, src.owner_staff_id)
    returning id into new_id;

  if coalesce((p_options->>'staff')::boolean, false) then
    insert into event_staff (event_id, staff_id)
      select new_id, staff_id from event_staff where event_id = p_source_id
      on conflict do nothing;
  end if;

  if coalesce((p_options->>'rooms')::boolean, false) then
    insert into event_rooms (event_id, room_id)
      select new_id, room_id from event_rooms where event_id = p_source_id
      on conflict do nothing;
  end if;

  if coalesce((p_options->>'agenda')::boolean, false) then
    for r in select * from agenda_items where event_id = p_source_id loop
      insert into agenda_items (event_id, title, owner, status, due_date, note, sort_order, priority, requires_confirmation)
        values (new_id, r.title, r.owner, 'mangler',
          case when r.due_date is not null then p_new_date + (r.due_date - src.event_date) else null end,
          r.note, r.sort_order, r.priority, r.requires_confirmation);
    end loop;
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

-- Gæsten må kun ændre status på egne aftalepunkter, plus — hvis opgaven kræver bekræftelse
-- (requires_confirmation) — afgive sin godkend/afvis-beslutning (guest_decision/-comment). Alt andet
-- klappes tilbage til den gamle værdi, uanset hvad et forsøgt API-kald indeholder. RLS (agenda_update)
-- begrænser i forvejen HVILKE rækker gæsten overhovedet kan forsøge at ramme (kun egne "jer"-punkter).
-- guest_decision_at stemples altid server-side, uanset hvem der ændrer guest_decision.
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
    new.assigned_staff_id := old.assigned_staff_id;
    new.priority := old.priority;
    new.requires_confirmation := old.requires_confirmation;
    new.is_guest_list_deadline := old.is_guest_list_deadline;

    if new.guest_decision is distinct from old.guest_decision then
      if not old.requires_confirmation or old.guest_decision is not null then
        raise exception 'Denne opgave kan ikke besvares (kræver ikke bekræftelse, eller er allerede besvaret)';
      end if;
      if new.guest_decision not in ('godkendt','afvist') then
        raise exception 'Ugyldig beslutning';
      end if;
      new.status := 'aftalt';
    end if;
  end if;

  if new.guest_decision is distinct from old.guest_decision then
    new.guest_decision_at := now();
  end if;

  return new;
end;
$$;
create trigger on_agenda_item_update
  before update on agenda_items
  for each row execute function guard_agenda_item_update();

-- Forhindrer dobbeltbooking: samme lokale kan ikke bruges til to arrangementer med overlappende
-- datoer. v1 har ingen fasestruktur/tidspræcision længere — konflikt afgøres på hele arrangementets
-- dato-interval (event_date..coalesce(end_date,event_date)), krydset med hvert arrangements fælles
-- start_time/end_time hvis begge er sat (ellers antages hele dagen optaget).
create or replace function check_room_conflict()
returns trigger language plpgsql security definer set search_path = public as $$
declare
  this_ev events%rowtype;
  conflict_row record;
begin
  select * into this_ev from events where id = new.event_id;

  select e2.title into conflict_row
  from event_rooms er
  join events e2 on e2.id = er.event_id
  where er.room_id = new.room_id
    and e2.id <> this_ev.id
    and e2.archived_at is null
    and this_ev.event_date <= coalesce(e2.end_date, e2.event_date)
    and e2.event_date <= coalesce(this_ev.end_date, this_ev.event_date)
    and (
      this_ev.start_time is null or this_ev.end_time is null
      or e2.start_time is null or e2.end_time is null
      or this_ev.start_time < e2.end_time and e2.start_time < this_ev.end_time
    )
  limit 1;

  if found then
    raise exception 'Lokalet er allerede booket til "%" i samme periode', conflict_row.title;
  end if;

  return new;
end;
$$;
create trigger on_event_rooms_conflict
  before insert on event_rooms
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

-- Lokaler: læsbare for org'ens folk + gæsten ved lokationen; kun admin redigerer
create policy rooms_read on rooms for select using (
  exists (select 1 from venues v where v.id = rooms.venue_id and v.org_id = my_org())
  or is_superadmin()
  or exists (select 1 from events e join event_access a on a.event_id = e.id
             where e.venue_id = rooms.venue_id and a.user_id = auth.uid())
);
create policy rooms_ins on rooms for insert with check ( is_org_admin((select org_id from venues where id = rooms.venue_id)) );
create policy rooms_upd on rooms for update using ( is_org_admin((select org_id from venues where id = rooms.venue_id)) ) with check ( is_org_admin((select org_id from venues where id = rooms.venue_id)) );
create policy rooms_del on rooms for delete using ( is_org_admin((select org_id from venues where id = rooms.venue_id)) );

-- Hvilke lokaler et arrangement bruger: begge parter læser; medarbejdere sætter
create policy erooms_read on event_rooms for select using ( is_org_staff(event_id) or is_event_guest(event_id) );
create policy erooms_ins  on event_rooms for insert with check ( is_org_staff(event_id) );
create policy erooms_del  on event_rooms for delete using ( is_org_staff(event_id) );

-- Medarbejdere kan se kolleger (til tildeling); kun admin må ændre brugere direkte i tabellen.
-- En almindelig koordinator redigerer sin EGEN profil (navn/titel/billede/onboarding) udelukkende via
-- update_own_profile()/update_own_onboarding() ovenfor, ikke via en UPDATE-politik her — se kommentaren
-- ved de to funktioner for hvorfor en bred selv-opdaterings-politik ville være en privilegie-eskalering.
create policy staff_read   on staff for select using ( org_id = my_org() or is_superadmin() );
create policy staff_insert on staff for insert with check ( is_org_admin(org_id) );
create policy staff_update on staff for update using ( is_org_admin(org_id) ) with check ( is_org_admin(org_id) );
create policy staff_delete on staff for delete using ( is_org_admin(org_id) );

-- Invitationer: kun admin
create policy invites_admin on invites for all
  using ( is_org_admin(org_id) ) with check ( is_org_admin(org_id) );

-- Arrangementer: admin ser alle i org; koordinator ser tildelte; gæst ser eget
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
-- arrangementet endnu ikke er bekræftet (kladde/tilbud) — derefter er der i v1 ingen formel
-- ændringsforslag-mekanisme (den er skåret, se roadmap.html): gæsten skriver i stedet en almindelig
-- besked til koordinator, som selv retter gæstelisten manuelt.
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

-- Opgaver: kun koordinator opretter/sletter. Gæsten ser alt, men må kun opdatere status (og, for en
-- opgave der kræver bekræftelse, sin egen godkend/afvis-beslutning) på egne ("jer") punkter —
-- håndhævet i with check her og på kolonneniveau af guard_agenda_item_update()-triggeren ovenfor.
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

-- LOG: append-only. Begge parter må indsætte.
create policy log_insert on activity_log for insert
  with check ( is_org_staff(event_id) or is_event_guest(event_id) );
-- Medarbejdere ser hele strømmen.
create policy log_read_staff on activity_log for select
  using ( is_org_staff(event_id) );
-- Gæsten ser KUN beskeder + kundevendte ændringer (kigge-tid-spærring i db).
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

-- Profilbilleder. Offentlig bucket, til forskel fra 'task-attachments' ovenfor — et profilbillede er
-- ikke et fortroligt forretningsdokument, så en almindelig public URL er rigtigt her og sparer signerede
-- URL'er/ekstra RPC-kald, hver gang et billede skal vises (personaleoversigt, gæstens kontaktkort).
-- Sti-konvention: {staff_id}/{filnavn} — kun ejeren af stiens første segment må skrive/slette sit eget.
insert into storage.buckets (id, name, public) values ('staff-avatars','staff-avatars', true)
  on conflict (id) do nothing;

create policy staff_avatars_read on storage.objects for select
  using (bucket_id = 'staff-avatars');
create policy staff_avatars_insert on storage.objects for insert
  with check (bucket_id = 'staff-avatars' and ((storage.foldername(name))[1])::uuid = auth.uid());
create policy staff_avatars_update on storage.objects for update
  using (bucket_id = 'staff-avatars' and ((storage.foldername(name))[1])::uuid = auth.uid());
create policy staff_avatars_delete on storage.objects for delete
  using (bucket_id = 'staff-avatars' and ((storage.foldername(name))[1])::uuid = auth.uid());

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
--  7. SEED — tre fiktive demo-organisationer
-- =====================================================================
-- Tidligere sås Madkastellets rigtige arbejdsgang/lokationer her som udviklingens testcase (se git-
-- historik). Fjernet: Madkastellet er ikke kunde og må ikke optræde i noget, der kan forveksles med en
-- rigtig kunde — heller ikke internt testdata, der i praksis lever videre i en delt Supabase-instans.
-- Erstattet af tre HELT igennem fiktive demo-organisationer, valgt til at dække reelt forskellige
-- profiler: en etableret privat selskabsvirksomhed med flere lokationer, et etableret B2B-konference-
-- center (event_kind='virksomhed'), og en lille, helt nystartet kunde (tynd data, ingen bekræftelses-
-- opgaver endnu — viser hvordan en ny konto reelt ser ud, ikke kun de fyldte eksempler). Hver org har
-- to faste demo-medarbejdere (en admin og en koordinator) med rigtige `staff`-rækker, så alle
-- arrangementer har en navngiven ansvarlig fra start — se kommentaren lige før hver orgs
-- `insert into auth.users` for hvorfor det er en bevidst undtagelse fra den normale regel om, at staff
-- kræver et rigtigt første login. Ingen af de tre kan reelt logges ind på (fiktive .example-
-- mailadresser, ingen rigtig indbakke) — de findes udelukkende for at attribuere demodataens
-- korrespondance/log/ejerskab til nogen. Tilgås derfor i praksis via Kontrolrummet (superadmin), som
-- kan se og handle i orgen uden selv at være tilknyttet som staff.

-- ---- Org 1: Havbrisen Selskabslokaler (privat, to lokationer) ----
insert into organisations (id, name, onboarding_dismissed) values
  ('a0000001-0000-0000-0000-000000000000','Havbrisen Selskabslokaler', true);

insert into venues (id, org_id, name, address) values
  ('a0000001-0000-0000-0000-000000000001','a0000001-0000-0000-0000-000000000000','Havbrisen Nord','Strandvejen 12, 8000 Aarhus C'),
  ('a0000001-0000-0000-0000-000000000002','a0000001-0000-0000-0000-000000000000','Havbrisen Have','Skovbrynet 4, 8240 Risskov');

insert into rooms (id, venue_id, name, capacity_max, sort_order) values
  ('a0000001-0000-0000-0000-000000000011','a0000001-0000-0000-0000-000000000001','Havsalen',140,0),
  ('a0000001-0000-0000-0000-000000000012','a0000001-0000-0000-0000-000000000001','Terrassen',60,1),
  ('a0000001-0000-0000-0000-000000000021','a0000001-0000-0000-0000-000000000002','Orangeriet',80,0);

-- Faste demo-medarbejdere: normalt kræver staff en ægte auth.users-login (se kommentaren ovenfor),
-- men denne org er varigt fiktiv demodata, så identiteterne oprettes direkte og idempotent her —
-- samme slutresultat som invites/handle_new_user()-vejen, blot uden at afvente et rigtigt første
-- login, som aldrig kommer. "on conflict do nothing" på auth.users, fordi den tabel IKKE droppes af
-- denne fil ved en gentagen kørsel (kun `staff`, som er fuldstændig tom igen på det tidspunkt, er).
insert into auth.users (instance_id, id, aud, role, email, encrypted_password, email_confirmed_at, raw_app_meta_data, raw_user_meta_data, created_at, updated_at) values
  ('00000000-0000-0000-0000-000000000000','a0000001-0000-0000-0000-0000000000a1','authenticated','authenticated','admin@havbrisen.example','',now(),'{"provider":"email","providers":["email"]}','{}',now(),now()),
  ('00000000-0000-0000-0000-000000000000','a0000001-0000-0000-0000-0000000000a2','authenticated','authenticated','coordinator@havbrisen.example','',now(),'{"provider":"email","providers":["email"]}','{}',now(),now())
on conflict (id) do nothing;

insert into staff (id, org_id, name, role, title) values
  ('a0000001-0000-0000-0000-0000000000a1','a0000001-0000-0000-0000-000000000000','Sofie Lindegaard','admin','Selskabsansvarlig'),
  ('a0000001-0000-0000-0000-0000000000a2','a0000001-0000-0000-0000-000000000000','Anders Mynster','coordinator','Bryllupskoordinator');

insert into events (id, venue_id, org_id, title, event_date, offer_total_kr, status, event_type, event_kind, expected_guests, owner_staff_id) values
  ('a0000001-0000-0000-0000-0000000000e1','a0000001-0000-0000-0000-000000000001','a0000001-0000-0000-0000-000000000000','Ida & Kasper','2026-04-18',118400,'afviklet','bryllup','privat',28,'a0000001-0000-0000-0000-0000000000a2'),
  ('a0000001-0000-0000-0000-0000000000e2','a0000001-0000-0000-0000-000000000002','a0000001-0000-0000-0000-000000000000','Firmafest · Solstrand Ejendomme','2026-06-06',72300,'afviklet','firmafest','virksomhed',45,'a0000001-0000-0000-0000-0000000000a1'),
  ('a0000001-0000-0000-0000-0000000000e3','a0000001-0000-0000-0000-000000000001','a0000001-0000-0000-0000-000000000000','Camilla & Rasmus','2026-09-19',132600,'bekræftet','bryllup','privat',28,'a0000001-0000-0000-0000-0000000000a1'),
  ('a0000001-0000-0000-0000-0000000000e4','a0000001-0000-0000-0000-000000000002','a0000001-0000-0000-0000-000000000000','Nanna & Frederik','2026-11-14',96000,'tilbud','bryllup','privat',60,'a0000001-0000-0000-0000-0000000000a1'),
  ('a0000001-0000-0000-0000-0000000000e5','a0000001-0000-0000-0000-000000000001','a0000001-0000-0000-0000-000000000000','60-års fødselsdag · Elsebeth','2027-01-09',0,'kladde','andet','privat',null,'a0000001-0000-0000-0000-0000000000a2');

update events set company_name = 'Solstrand Ejendomme A/S', company_cvr = '29847156',
  invoice_recipient_name = 'Michael Sørup', invoice_recipient_email = 'okonomi@solstrand.example'
  where id = 'a0000001-0000-0000-0000-0000000000e2';

insert into event_staff (event_id, staff_id) values
  ('a0000001-0000-0000-0000-0000000000e3','a0000001-0000-0000-0000-0000000000a1'),
  ('a0000001-0000-0000-0000-0000000000e3','a0000001-0000-0000-0000-0000000000a2');

insert into activity_log (event_id, ts, actor_name, actor_side, entry_type, area, label, from_val, to_val, customer_visible, friendly, message_text) values
  ('a0000001-0000-0000-0000-0000000000e1','2026-02-01 09:00:00+02','Sofie Lindegaard','kilden','change','system','Primær koordinator','','Anders Mynster',false,'Anders Mynster tilknyttet som koordinator',''),
  ('a0000001-0000-0000-0000-0000000000e2','2026-04-01 09:00:00+02','Sofie Lindegaard','kilden','change','system','Primær koordinator','','Sofie Lindegaard',false,'Sofie Lindegaard tilknyttet som koordinator',''),
  ('a0000001-0000-0000-0000-0000000000e3','2026-05-01 09:00:00+02','Sofie Lindegaard','kilden','change','system','Primær koordinator','','Sofie Lindegaard',false,'Sofie Lindegaard tilknyttet som koordinator',''),
  ('a0000001-0000-0000-0000-0000000000e4','2026-07-28 10:00:00+02','Sofie Lindegaard','kilden','change','system','Primær koordinator','','Sofie Lindegaard',false,'Sofie Lindegaard tilknyttet som koordinator',''),
  ('a0000001-0000-0000-0000-0000000000e5','2026-08-12 14:00:00+02','Sofie Lindegaard','kilden','change','system','Primær koordinator','','Anders Mynster',false,'Anders Mynster tilknyttet som koordinator','');

-- Flagskib: Camilla & Rasmus — fuldt udbygget (lokaler, gæsteliste, opgaver, bekræftelser, korrespondance)
insert into event_rooms (event_id, room_id) values
  ('a0000001-0000-0000-0000-0000000000e3','a0000001-0000-0000-0000-000000000011'),
  ('a0000001-0000-0000-0000-0000000000e3','a0000001-0000-0000-0000-000000000012');
update events set start_time = '16:00', end_time = '01:00' where id = 'a0000001-0000-0000-0000-0000000000e3';

insert into guests (event_id, name, category, reception, dinner, dietary, sort_order)
select 'a0000001-0000-0000-0000-0000000000e3', name, 'voksen', true, true, dietary, ord from (values
  ('Marie Holten','',0),('Jacob Ryberg','',1),('Louise Bech','Vegetar',2),('Peter Grønbæk','',3),
  ('Anne Sofie Dahl','',4),('Mikkel Storm','',5),('Cecilie Winther','Glutenfri',6),('Thomas Fogh','',7),
  ('Sara Kirkegaard','',8),('Anders Bloch','',9),('Julie Ellegaard','Nøddeallergi',10),('Kristian Aabo','',11),
  ('Emma Riis','',12),('Lasse Skov','',13),('Ida Toft','',14),('Rasmus Vang','',15),
  ('Nanna Lykke','',16),('Christian Sand','',17),('Maria Kastrup','Vegetar',18),('Simon Hedegaard','',19),
  ('Katrine Fjeldsted','',20),('Frederik Lindgren','',21),('Josefine Krogh','',22),('Martin Brunsgaard','',23)
) as g(name, dietary, ord);
insert into guests (event_id, name, category, reception, dinner, dietary, sort_order) values
  ('a0000001-0000-0000-0000-0000000000e3','Alma (barn)','barn',true,true,'',24),
  ('a0000001-0000-0000-0000-0000000000e3','Oscar (barn)','barn',true,true,'',25),
  ('a0000001-0000-0000-0000-0000000000e3','Noah (baby)','baby',false,false,'',26),
  ('a0000001-0000-0000-0000-0000000000e3','Villads Bang','',true,false,'',27);

insert into agenda_items (event_id, title, owner, status, due_date, sort_order, priority, requires_confirmation, guest_decision, guest_decision_at, is_guest_list_deadline) values
  ('a0000001-0000-0000-0000-0000000000e3','Godkend bordplan','jer','aftalt','2026-08-25',0,'normal',true,'godkendt','2026-08-22 20:10+02',false),
  ('a0000001-0000-0000-0000-0000000000e3','Bekræft allergiliste til køkkenet','jer','aftalt','2026-08-05',1,'normal',false,null,null,false),
  ('a0000001-0000-0000-0000-0000000000e3','Send sangliste til bryllupstale','jer','mangler','2026-09-05',2,'lav',false,null,null,false),
  ('a0000001-0000-0000-0000-0000000000e3','Bekræft endeligt gæsteantal','jer','mangler','2026-08-29',3,'kritisk',false,null,null,true),
  ('a0000001-0000-0000-0000-0000000000e3','Book blomsterdekoratør','kilden','aftalt','2026-07-01',4,'normal',false,null,null,false),
  ('a0000001-0000-0000-0000-0000000000e3','Bekræft AV-udstyr til talerne','kilden','udkast','2026-09-01',5,'kritisk',false,null,null,false),
  ('a0000001-0000-0000-0000-0000000000e3','Sæt bordplan op i Havsalen','kilden','mangler','2026-09-12',6,'normal',false,null,null,false);

insert into activity_log (event_id, ts, actor_name, actor_side, entry_type, area, label, from_val, to_val, customer_visible, friendly, message_text) values
  ('a0000001-0000-0000-0000-0000000000e3','2026-07-14 11:02:00+02','Rasmus','kunde','message','','','','',true,'','Hej Sofie! Vi vil gerne tilføje en ven i sidste øjeblik — er der plads til én mere ved bord 3?'),
  ('a0000001-0000-0000-0000-0000000000e3','2026-07-14 13:20:00+02','Sofie Lindegaard','kilden','message','','','','',true,'','Hej Rasmus, helt sikkert — jeg har lige tilføjet Villads til gæstelisten, så I kan se ham i oversigten.'),
  ('a0000001-0000-0000-0000-0000000000e3','2026-07-14 13:21:00+02','Sofie Lindegaard','kilden','change','gæst','Gæst tilføjet','','',true,'Gæst tilføjet: Villads Bang',''),
  ('a0000001-0000-0000-0000-0000000000e3','2026-08-22 20:05:00+02','Camilla','kunde','message','','','','',true,'','Bordplanen ser fin ud, men kan I flytte mine forældre væk fra højtaleren ved DJ-boothet?'),
  ('a0000001-0000-0000-0000-0000000000e3','2026-08-23 08:40:00+02','Sofie Lindegaard','kilden','note','','','','',false,'','Internt: har flyttet bord 2 væk fra scenen — kunden har godkendt bordplanen som helhed.');

-- Let indhold på de øvrige Havbrisen-arrangementer (ikke tomme, men langt fra flagskibets dybde)
insert into guests (event_id, name, category, reception, dinner, dietary, sort_order) values
  ('a0000001-0000-0000-0000-0000000000e1','Ida','voksen',true,true,'',0),
  ('a0000001-0000-0000-0000-0000000000e1','Kasper','voksen',true,true,'',1),
  ('a0000001-0000-0000-0000-0000000000e1','Bente Holten','voksen',true,true,'',2),
  ('a0000001-0000-0000-0000-0000000000e2','Michael Sørup','voksen',true,true,'',0),
  ('a0000001-0000-0000-0000-0000000000e2','Tina Overgaard','voksen',true,true,'Vegetar',1),
  ('a0000001-0000-0000-0000-0000000000e4','Nanna','voksen',true,true,'',0),
  ('a0000001-0000-0000-0000-0000000000e4','Frederik','voksen',true,true,'',1),
  ('a0000001-0000-0000-0000-0000000000e4','Grethe Nanna-mor','voksen',true,false,'',2);

insert into agenda_items (event_id, title, owner, status, due_date, sort_order, priority) values
  ('a0000001-0000-0000-0000-0000000000e4','Vælg menu','jer','mangler','2026-09-10',0,'normal'),
  ('a0000001-0000-0000-0000-0000000000e4','Book prøvesmagning','kilden','mangler','2026-09-05',1,'normal'),
  ('a0000001-0000-0000-0000-0000000000e5','Aftal dato endeligt med familien','jer','mangler','2026-10-01',0,'normal');

insert into activity_log (event_id, ts, actor_name, actor_side, entry_type, area, label, from_val, to_val, customer_visible, friendly, message_text) values
  ('a0000001-0000-0000-0000-0000000000e4','2026-08-01 10:00:00+02','Sofie Lindegaard','kilden','message','','','','',true,'','Hej Nanna og Frederik — tillykke med jeres kommende bryllup! Jeg har oprettet jeres side her, så I kan følge med i planlægningen.'),
  ('a0000001-0000-0000-0000-0000000000e4','2026-08-02 16:30:00+02','Nanna','kunde','message','','','','',true,'','Tak! Vi glæder os. Hvornår skal vi senest have valgt menu?');

-- ---- Org 2: Domicil Konference & Møder (B2B, én lokation) ----
insert into organisations (id, name, onboarding_dismissed) values
  ('a0000002-0000-0000-0000-000000000000','Domicil Konference & Møder', true);

insert into venues (id, org_id, name, address) values
  ('a0000002-0000-0000-0000-000000000001','a0000002-0000-0000-0000-000000000000','Domicil København','Kalvebod Brygge 24, 1560 København V');

insert into rooms (id, venue_id, name, capacity_max, sort_order) values
  ('a0000002-0000-0000-0000-000000000011','a0000002-0000-0000-0000-000000000001','Plenum',200,0),
  ('a0000002-0000-0000-0000-000000000012','a0000002-0000-0000-0000-000000000001','Mødelokale 3',24,1),
  ('a0000002-0000-0000-0000-000000000013','a0000002-0000-0000-0000-000000000001','Mødelokale 4',24,2);

-- Faste demo-medarbejdere: se den udførlige kommentar ved Org 1 ovenfor for hvorfor auth.users/staff
-- oprettes direkte her i stedet for via invites.
insert into auth.users (instance_id, id, aud, role, email, encrypted_password, email_confirmed_at, raw_app_meta_data, raw_user_meta_data, created_at, updated_at) values
  ('00000000-0000-0000-0000-000000000000','a0000002-0000-0000-0000-0000000000a1','authenticated','authenticated','admin@domicilkonference.example','',now(),'{"provider":"email","providers":["email"]}','{}',now(),now()),
  ('00000000-0000-0000-0000-000000000000','a0000002-0000-0000-0000-0000000000a2','authenticated','authenticated','coordinator@domicilkonference.example','',now(),'{"provider":"email","providers":["email"]}','{}',now(),now())
on conflict (id) do nothing;

insert into staff (id, org_id, name, role, title) values
  ('a0000002-0000-0000-0000-0000000000a1','a0000002-0000-0000-0000-000000000000','Peter Vang','admin','Konferenceansvarlig'),
  ('a0000002-0000-0000-0000-0000000000a2','a0000002-0000-0000-0000-000000000000','Mette Kold','coordinator','Eventkoordinator');

insert into events (id, venue_id, org_id, title, event_date, end_date, offer_total_kr, status, event_type, event_kind, expected_guests, owner_staff_id) values
  ('a0000002-0000-0000-0000-0000000000e1','a0000002-0000-0000-0000-000000000001','a0000002-0000-0000-0000-000000000000','Nordisk Forsikring — Generalforsamling','2026-03-25',null,84600,'afviklet','konference','virksomhed',60,'a0000002-0000-0000-0000-0000000000a2'),
  ('a0000002-0000-0000-0000-0000000000e2','a0000002-0000-0000-0000-000000000001','a0000002-0000-0000-0000-000000000000','TechSummit Øst 2026','2026-10-01','2026-10-02',156800,'bekræftet','konference','virksomhed',22,'a0000002-0000-0000-0000-0000000000a1'),
  ('a0000002-0000-0000-0000-0000000000e3','a0000002-0000-0000-0000-000000000001','a0000002-0000-0000-0000-000000000000','Byggeriets Dag','2026-11-25',null,210000,'tilbud','konference','virksomhed',null,'a0000002-0000-0000-0000-0000000000a1'),
  ('a0000002-0000-0000-0000-0000000000e4','a0000002-0000-0000-0000-000000000001','a0000002-0000-0000-0000-000000000000','Intern strategidag · Vindstød A/S','2027-01-20',null,0,'kladde','firmafest','virksomhed',null,'a0000002-0000-0000-0000-0000000000a2');

update events set company_name = 'Nordisk Forsikring A/S', company_cvr = '18293746',
  invoice_recipient_name = 'Birgitte Holm', invoice_recipient_email = 'faktura@nordiskforsikring.example'
  where id = 'a0000002-0000-0000-0000-0000000000e1';
update events set company_name = 'TechSummit ApS', company_cvr = '33019284',
  invoice_recipient_name = 'Henrik Bloch', invoice_recipient_email = 'okonomi@techsummit.example', po_number = 'PO-88213'
  where id = 'a0000002-0000-0000-0000-0000000000e2';
update events set company_name = 'Vindstød A/S', company_cvr = '55102938'
  where id = 'a0000002-0000-0000-0000-0000000000e4';

insert into event_staff (event_id, staff_id) values
  ('a0000002-0000-0000-0000-0000000000e2','a0000002-0000-0000-0000-0000000000a1'),
  ('a0000002-0000-0000-0000-0000000000e2','a0000002-0000-0000-0000-0000000000a2');

insert into activity_log (event_id, ts, actor_name, actor_side, entry_type, area, label, from_val, to_val, customer_visible, friendly, message_text) values
  ('a0000002-0000-0000-0000-0000000000e1','2026-01-15 09:00:00+02','Peter Vang','kilden','change','system','Primær koordinator','','Mette Kold',false,'Mette Kold tilknyttet som koordinator',''),
  ('a0000002-0000-0000-0000-0000000000e2','2026-06-01 09:00:00+02','Peter Vang','kilden','change','system','Primær koordinator','','Peter Vang',false,'Peter Vang tilknyttet som koordinator',''),
  ('a0000002-0000-0000-0000-0000000000e3','2026-07-20 09:00:00+02','Peter Vang','kilden','change','system','Primær koordinator','','Peter Vang',false,'Peter Vang tilknyttet som koordinator',''),
  ('a0000002-0000-0000-0000-0000000000e4','2026-08-13 09:00:00+02','Peter Vang','kilden','change','system','Primær koordinator','','Mette Kold',false,'Mette Kold tilknyttet som koordinator','');

-- Flagskib: TechSummit Øst 2026 (to-dages B2B-konference)
insert into event_rooms (event_id, room_id) values
  ('a0000002-0000-0000-0000-0000000000e2','a0000002-0000-0000-0000-000000000011'),
  ('a0000002-0000-0000-0000-0000000000e2','a0000002-0000-0000-0000-000000000012'),
  ('a0000002-0000-0000-0000-0000000000e2','a0000002-0000-0000-0000-000000000013');
update events set start_time = '08:00', end_time = '17:00' where id = 'a0000002-0000-0000-0000-0000000000e2';

insert into guests (event_id, name, category, reception, dinner, dietary, sort_order)
select 'a0000002-0000-0000-0000-0000000000e2', name, 'voksen', true, true, dietary, ord from (values
  ('Henrik Bloch','',0),('Signe Aabo','',1),('Morten Krogh','Vegetar',2),('Ditte Storm','',3),
  ('Kasper Winther','',4),('Line Sand','',5),('Jonas Fogh','Glutenfri',6),('Camilla Riis','',7),
  ('Anders Lykke','',8),('Sofie Vang','',9),('Nikolaj Bech','',10),('Rikke Dahl','',11),
  ('Frederik Kastrup','',12),('Amalie Toft','',13),('Christian Grønbæk','Nøddeallergi',14),('Josephine Ellegaard','',15),
  ('Rasmus Hedegaard','',16),('Maja Lindgren','',17),('Simon Brunsgaard','',18),('Emilie Skov','',19)
) as g(name, dietary, ord);

insert into agenda_items (event_id, title, owner, status, due_date, sort_order, priority, requires_confirmation, guest_decision, guest_decision_at, is_guest_list_deadline) values
  ('a0000002-0000-0000-0000-0000000000e2','Godkend AV-opsætning i Plenum','jer','mangler','2026-09-20',0,'kritisk',true,null,null,false),
  ('a0000002-0000-0000-0000-0000000000e2','Bekræft diætbehov til frokost','jer','aftalt','2026-08-30',1,'normal',false,null,null,false),
  ('a0000002-0000-0000-0000-0000000000e2','Bekræft endeligt deltagerantal','jer','mangler','2026-09-15',2,'kritisk',false,null,null,true),
  ('a0000002-0000-0000-0000-0000000000e2','Book teknikerassistance til mødelokalerne','kilden','aftalt','2026-08-01',3,'normal',false,null,null,false),
  ('a0000002-0000-0000-0000-0000000000e2','Sæt skiltning op ved registrering','kilden','mangler','2026-09-28',4,'normal',false,null,null,false),
  ('a0000002-0000-0000-0000-0000000000e2','Test livestream fra Plenum','kilden','udkast','2026-09-25',5,'kritisk',false,null,null,false);

insert into activity_log (event_id, ts, actor_name, actor_side, entry_type, area, label, from_val, to_val, customer_visible, friendly, message_text) values
  ('a0000002-0000-0000-0000-0000000000e2','2026-08-28 10:15:00+02','Henrik Bloch','kunde','message','','','','',true,'','Hej Peter — kan I bekræfte at der er ledningsfrit netværk til alle deltagere i både Plenum og de to mødelokaler?'),
  ('a0000002-0000-0000-0000-0000000000e2','2026-08-28 11:02:00+02','Peter Vang','kilden','message','','','','',true,'','Hej Henrik, ja — vi har en dedikeret konference-SSID med kapacitet til 300 samtidige enheder. Jeg sender adgangskoden dagen før.'),
  ('a0000002-0000-0000-0000-0000000000e2','2026-09-11 09:00:00+02','Henrik Bloch','kunde','message','','','','',true,'','Vi ender nok på 22-23 deltagere i alt — må jeg vende tilbage med det præcise tal i næste uge?'),
  ('a0000002-0000-0000-0000-0000000000e2','2026-09-11 09:20:00+02','Peter Vang','kilden','note','','','','',false,'','Internt: afventer endeligt tal fra kunden — holder foreløbig 25 pladser reserveret i Plenum til frokost.');

insert into guests (event_id, name, category, reception, dinner, dietary, sort_order) values
  ('a0000002-0000-0000-0000-0000000000e1','Birgitte Holm','voksen',true,true,'',0),
  ('a0000002-0000-0000-0000-0000000000e1','Ole Vestergaard','voksen',true,true,'',1),
  ('a0000002-0000-0000-0000-0000000000e3','Jens Bak','voksen',true,true,'',0),
  ('a0000002-0000-0000-0000-0000000000e3','Karen Munk','voksen',true,true,'Vegetar',1),
  ('a0000002-0000-0000-0000-0000000000e3','Torben Skaaning','voksen',true,true,'',2);

insert into agenda_items (event_id, title, owner, status, due_date, sort_order, priority) values
  ('a0000002-0000-0000-0000-0000000000e3','Bekræft lokalevalg (Plenum eller deling)','jer','mangler','2026-10-15',0,'normal'),
  ('a0000002-0000-0000-0000-0000000000e3','Send oplæg om AV-behov','kilden','mangler','2026-10-20',1,'normal');

insert into activity_log (event_id, ts, actor_name, actor_side, entry_type, area, label, from_val, to_val, customer_visible, friendly, message_text) values
  ('a0000002-0000-0000-0000-0000000000e3','2026-08-05 13:00:00+02','Peter Vang','kilden','message','','','','',true,'','Hej Jens — her er tilbuddet til Byggeriets Dag, som aftalt. Sig til hvis I har spørgsmål til lokalevalget.');

-- ---- Org 3: Lærkevang Gårdkøkken (nystartet, én lokation, bevidst tynd data) ----
-- Viser hvordan en helt ny konto reelt ser ud — ikke kun de udbyggede eksempler ovenfor.
insert into organisations (id, name, onboarding_dismissed) values
  ('a0000003-0000-0000-0000-000000000000','Lærkevang Gårdkøkken', false);

insert into venues (id, org_id, name, address) values
  ('a0000003-0000-0000-0000-000000000001','a0000003-0000-0000-0000-000000000000','Lærkevang Gård','Møllevej 8, 4390 Vipperød');

insert into rooms (id, venue_id, name, capacity_max, sort_order) values
  ('a0000003-0000-0000-0000-000000000011','a0000003-0000-0000-0000-000000000001','Laden',90,0),
  ('a0000003-0000-0000-0000-000000000012','a0000003-0000-0000-0000-000000000001','Gårdhaven',120,1);

-- Faste demo-medarbejdere: se den udførlige kommentar ved Org 1 ovenfor for hvorfor auth.users/staff
-- oprettes direkte her i stedet for via invites.
insert into auth.users (instance_id, id, aud, role, email, encrypted_password, email_confirmed_at, raw_app_meta_data, raw_user_meta_data, created_at, updated_at) values
  ('00000000-0000-0000-0000-000000000000','a0000003-0000-0000-0000-0000000000a1','authenticated','authenticated','admin@laerkevang.example','',now(),'{"provider":"email","providers":["email"]}','{}',now(),now()),
  ('00000000-0000-0000-0000-000000000000','a0000003-0000-0000-0000-0000000000a2','authenticated','authenticated','coordinator@laerkevang.example','',now(),'{"provider":"email","providers":["email"]}','{}',now(),now())
on conflict (id) do nothing;

insert into staff (id, org_id, name, role, title) values
  ('a0000003-0000-0000-0000-0000000000a1','a0000003-0000-0000-0000-000000000000','Anders Pihl','admin','Gårdejer'),
  ('a0000003-0000-0000-0000-0000000000a2','a0000003-0000-0000-0000-000000000000','Julie Holm','coordinator','Eventkoordinator');

insert into events (id, venue_id, org_id, title, event_date, offer_total_kr, status, event_type, event_kind, expected_guests, owner_staff_id) values
  ('a0000003-0000-0000-0000-0000000000e1','a0000003-0000-0000-0000-000000000001','a0000003-0000-0000-0000-000000000000','Prøvesmagning · Studiegruppen','2026-09-05',8200,'tilbud','andet','privat',3,'a0000003-0000-0000-0000-0000000000a1'),
  ('a0000003-0000-0000-0000-0000000000e2','a0000003-0000-0000-0000-000000000001','a0000003-0000-0000-0000-000000000000','Firmasommerfest · Nordly A/S','2027-06-12',0,'kladde','firmafest','virksomhed',null,'a0000003-0000-0000-0000-0000000000a2');

update events set company_name = 'Nordly A/S' where id = 'a0000003-0000-0000-0000-0000000000e2';

insert into activity_log (event_id, ts, actor_name, actor_side, entry_type, area, label, from_val, to_val, customer_visible, friendly, message_text) values
  ('a0000003-0000-0000-0000-0000000000e1','2026-08-05 09:00:00+02','Anders Pihl','kilden','change','system','Primær koordinator','','Anders Pihl',false,'Anders Pihl tilknyttet som koordinator',''),
  ('a0000003-0000-0000-0000-0000000000e2','2026-08-13 09:00:00+02','Anders Pihl','kilden','change','system','Primær koordinator','','Julie Holm',false,'Julie Holm tilknyttet som koordinator','');

insert into guests (event_id, name, category, reception, dinner, dietary, sort_order) values
  ('a0000003-0000-0000-0000-0000000000e1','Studiegruppe A','voksen',true,true,'',0),
  ('a0000003-0000-0000-0000-0000000000e1','Studiegruppe B','voksen',true,true,'Vegetar',1),
  ('a0000003-0000-0000-0000-0000000000e1','Studiegruppe C','voksen',true,true,'',2);

insert into agenda_items (event_id, title, owner, status, due_date, sort_order, priority) values
  ('a0000003-0000-0000-0000-0000000000e1','Bekræft dato for prøvesmagning','kilden','udkast','2026-08-28',0,'normal');

insert into activity_log (event_id, ts, actor_name, actor_side, entry_type, area, label, from_val, to_val, customer_visible, friendly, message_text) values
  ('a0000003-0000-0000-0000-0000000000e1','2026-08-10 15:00:00+02','Anders Pihl','kilden','message','','','','',true,'','Velkommen til Lærkevang! Vi glæder os til at vise jer gården og lave en prøvesmagning.');

-- =====================================================================
--  8. BOOTSTRAP — kør, når du har logget ind via magic link mindst én gang.
--     Find dit UUID under Authentication → Users.
-- =====================================================================
-- -- Gør dig selv til SUPERADMIN-EJER (Verta-medarbejder, organisationsuafhængig — kan invitere
-- -- andre Verta-brugere fra kontrolrummet bagefter, så dette bootstrap-trin kun skal køres én gang):
-- insert into superadmins (id, name, role) values ('DIT-AUTH-UUID','Dit navn','ejer');
--
-- -- Eller: gør dig selv til ADMIN i en af demo-organisationerne (almindelig org-scoped admin) —
-- -- fx Havbrisen Selskabslokaler:
-- insert into staff (id, org_id, name, role) values
--   ('DIT-AUTH-UUID','a0000001-0000-0000-0000-000000000000','Dit navn','admin');
--
-- Herefter styrer du resten fra konsollen: opret lokationer, inviter
-- koordinatorer (de forfremmes automatisk ved første login), og tildel
-- gæster til arrangementer. Superadmin lander i stedet i kontrolrummet,
-- hvor alle tre demo-organisationer allerede kan åbnes med det samme —
-- uden noget bootstrap-trin, da superadmin-adgang ikke er org-scoped.
--
-- -- Gæst/kunde (indtil adgang gives fra UI'et via "Del med gæsten"):
-- insert into event_access (event_id, user_id, display_name) values
--   ('a0000001-0000-0000-0000-0000000000e3','KUNDENS-AUTH-UUID','Camilla');
