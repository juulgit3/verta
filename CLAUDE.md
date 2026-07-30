# Verta

Arrangementskoordinationsværktøj for **Madkastellet** (dansk catering/venue-virksomhed med flere lokationer). Erstatter den PDF-arrangementsseddel, der før blev sendt frem og tilbage over mail. Første testcase: brudeparret Emily & Lars' bryllup på lokationen Kilden, 4. september 2026.

UI-sproget er **dansk**. Behold det.

## Filstruktur
- `index.html` — hele appen i én selvstændig fil (HTML + CSS + vanilla JS, ingen build, ingen framework).
- `schema.sql` — Supabase Postgres-skema: tabeller, RLS-politikker, triggere, testdata. Kør hele filen i Supabase SQL Editor.
- `README.md` — trin-for-trin deploy-guide.
- `docs/admin-preview.html` — statisk designmockup af admin-konsollen. Ikke en del af appen; kun reference.

## Arkitektur
- **Dobbelt tilstand.** Øverst i `<script>` står `const SUPA = { url:'', anon:'' }`. Tomt → appen kører lokalt (localStorage, rolleskifter til demo). Udfyldt → cloud-tilstand med rigtigt login mod Supabase.
- **Backend:** Supabase (Postgres + Auth + RLS). Ingen server-kode endnu.
- **Auth:** magic link (passwordless). Medarbejdere ligger i `staff` (roller: `admin` | `coordinator`); brudepar bindes til ét arrangement via `event_access`.
- **Hierarki:** organisation → lokation (`venues`) → arrangement (`events`). Lokaler (`rooms`) hører til en lokation; `event_rooms` kobler hver fase (reception/middag/fest) til ét lokale. Medarbejdere kobles til arrangementer mange-til-mange via `event_staff`.
- **Log:** `activity_log` er append-only med tre typer (`change`, `view`, `message`) i én strøm. RLS sikrer, at brudeparret aldrig kan læse opslags-hændelser (kigge-tider) — kun beskeder og kundevendte ændringer.
- **Deploy:** GitHub → Netlify (auto-deploy ved push). Publish directory = roden. Ingen build-kommando.

## Vigtige regler
- **anon (public)-nøglen er ikke hemmelig** og må gerne ligge i `index.html` og committes. Sikkerheden ligger i RLS.
- **service_role-nøglen er hemmelig.** Må ALDRIG i `index.html`, i repoet eller i en commit. Den bruges ikke i denne version.
- Ændringer laves direkte i `index.html` — vanilla JS, ingen transpilering. Hold den ene-fil-struktur, medmindre andet aftales.
- Skemaet er "drop-and-recreate": at køre `schema.sql` igen nulstiller alt (også testdata). Det er med vilje under test.

## Kendt køreplan (pass 2)
Admin-konsollens lokations- og brugerstyring som rigtige skærme, Supabase Realtime, og notifikationsmail ved nye beskeder (Edge Function + maildienst). Ikke bygget endnu.
