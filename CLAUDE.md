# Verta

Arrangementskoordinationsværktøj til catering/venue-virksomheder med flere lokationer. Erstatter den PDF-arrangementsseddel, der ellers sendes frem og tilbage over mail. Bygget med udgangspunkt i **Madkastellets** rigtige arbejdsgang og rigtige lokationer (testcase: brudeparret Emily & Lars' bryllup på lokationen Kilden, 4. september 2026) — **men Madkastellet er IKKE kunde og ved ikke, at projektet findes.** De må derfor aldrig optræde som reference, case, logo eller citat noget offentligt sted (marketingsiden, screenshots, demo-data). Alt offentligt vendt materiale bruger fiktive eksempeldata.

Verta er sit eget produkt/brand — adskilt fra Madkastellet. Mærket er besluttet: ordmærket "Verta" alene (kursiv Instrument Serif, blå #1435D6), intet logo-ikon ved siden af. Navnet kommer af "vært", bøjet fordi ordet ikke fungerer på engelsk.

UI-sproget er **dansk**. Behold det.

## Filstruktur
- `index.html` — **marketingsiden** (Verta som produkt, offentlig, ingen login). Ligger på roden af domænet.
- `app/index.html` — **selve appen** (arrangementskoordinationsværktøjet), én selvstændig fil (HTML + CSS + vanilla JS, ingen build, ingen framework). Tilgås via `/app`.
- `roadmap.html` — idéer/planlagt/udført, ikke linket fra nogen forside, ligger på `/roadmap`.
- `schema.sql` — Supabase Postgres-skema: tabeller, RLS-politikker, triggere, testdata. Kør hele filen i Supabase SQL Editor.
- `_redirects` — Netlify-stier: `/app` → `app/index.html`, `/roadmap` → `roadmap.html`.
- `README.md` — trin-for-trin deploy-guide.
- `docs/admin-preview.html` — statisk designmockup af admin-konsollen. Ikke en del af appen; kun reference.

## Arkitektur (app/index.html)
- **Dobbelt tilstand.** Øverst i `<script>` står `const SUPA = { url:'', anon:'' }`. Tomt → appen kører lokalt (localStorage, rolleskifter til demo). Udfyldt → cloud-tilstand med rigtigt login mod Supabase.
- **Backend:** Supabase (Postgres + Auth + RLS). Ingen server-kode endnu.
- **Auth:** magic link (passwordless). Medarbejdere ligger i `staff` (roller: `admin` | `coordinator`); brudepar bindes til ét arrangement via `event_access`.
- **Hierarki:** organisation → lokation (`venues`) → arrangement (`events`). Lokaler (`rooms`) hører til en lokation; `event_rooms` kobler hver fase (reception/middag/fest) til ét lokale. Medarbejdere kobles til arrangementer mange-til-mange via `event_staff`.
- **Log:** `activity_log` er append-only med tre typer (`change`, `view`, `message`) i én strøm. RLS sikrer, at brudeparret aldrig kan læse opslags-hændelser (kigge-tider) — kun beskeder og kundevendte ændringer.
- **Deploy:** GitHub → Netlify (auto-deploy ved push). Publish directory = roden. Ingen build-kommando.

## Vigtige regler
- **Madkastellet må aldrig optræde offentligt** — ikke i marketingsidens tekst, ikke i screenshots/mockups, ikke som "kunde" eller citat. De ved ikke, at Verta bygges. Intern testdata (rigtige venues/rooms/priser i Supabase) er fint til at teste selve appen, men må ikke lække ud i noget, der er vendt mod en ekstern besøgende.
- **anon (public)-nøglen er ikke hemmelig** og må gerne ligge i `app/index.html` og committes. Sikkerheden ligger i RLS.
- **service_role-nøglen er hemmelig.** Må ALDRIG i nogen fil, i repoet eller i en commit. Den bruges ikke i denne version.
- Ændringer i selve appen laves direkte i `app/index.html` — vanilla JS, ingen transpilering. Hold ene-fil-strukturen for både marketingside og app, medmindre andet aftales.
- Skemaet er "drop-and-recreate": at køre `schema.sql` igen nulstiller alt (også testdata). Det er med vilje under test.

## Kendt køreplan
Marketing-forsidens indhold (funktioner, sikkerhed, pris, kontakt/demo-CTA) — under opbygning. Herefter: rigtigt domænenavn (nuværende `vertacph.netlify.app` giver ikke mening for et produkt, der skal sælges bredt), rigtig pris-model, og notifikationsmail ved nye beskeder i selve appen (Edge Function + maildienst, nedprioriteret).
