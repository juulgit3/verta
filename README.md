# Verta — sådan får du det online

Følg trinene i rækkefølge. Regn med ca. 30 minutter første gang. Du behøver ingen terminal — alt kan gøres i browseren.

## Filerne
- `index.html` — marketingsiden (offentlig, ingen login), ligger på roden
- `app/index.html` — selve appen (én fil, kører lokalt uden config, mod Supabase når den er sat op), tilgås via `/app`
- `schema.sql` — databasen (tabeller, sikkerhedsregler, testdata)
- `README.md` — denne guide

## Om nøgler (vigtigt)
Supabase giver dig to nøgler under **Settings → API**:
- **anon (public)** — lavet til at ligge i browseren. Den er *ikke* hemmelig og må gerne committes til GitHub.
- **service_role** — hemmelig. Må **aldrig** i `index.html`, aldrig i GitHub, aldrig deles. Vi bruger den ikke i denne version.

Sikkerheden ligger i databasens RLS-regler, ikke i at skjule anon-nøglen.

---

## Trin 1 · GitHub-repo
1. Opret et nyt repo: `github.com/juulgit3/verta` (offentligt).
2. Læg `index.html`, `app/index.html`, `schema.sql`, `_redirects` og `README.md` ind (træk dem ind i GitHubs webflade → **Commit changes**).

## Trin 2 · Supabase-projekt + database
1. `supabase.com` → **New project**. Gratis-planen er nok. Vælg region **EU (Frankfurt)**. Sæt en db-adgangskode og gem den.
2. Vent ~2 min på, at projektet er klar.
3. Åbn **SQL Editor → New query**, indsæt *hele* `schema.sql`, tryk **Run**.
4. Tjek **Table Editor**: du bør se `events` (Emily & Lars), 77 gæster, og `rooms` med Kildens to lokaler.

> Kører du skemaet igen senere, dropper og genskaber det alt (også testdata). Det er med vilje — så kan du nulstille frit under test.

## Trin 3 · Sæt dine nøgler ind i appen
1. **Settings → API**: kopiér **Project URL** og **anon public**-nøglen.
2. Åbn `app/index.html`, find denne linje øverst i `<script>`:
   ```js
   const SUPA = { url:'', anon:'' };
   ```
   Indsæt dine værdier:
   ```js
   const SUPA = { url:'https://xxxx.supabase.co', anon:'eyJhbGciOi...' };
   ```
3. Commit ændringen til GitHub.

## Trin 4 · Netlify
1. `app.netlify.com` → **Add new site → Import an existing project → GitHub** → vælg `verta`.
2. Build-indstillinger: **build command tom**, **publish directory = `.`** (roden — appen er ren statisk HTML).
3. **Deploy**. Du får en URL som `noget-tilfældigt.netlify.app`.
4. (Valgfrit) **Site configuration → Change site name** for en pænere adresse, eller tilføj `verta.dk` / et subdomæne under **Domain management** — samme flow som `ambivalent.dk`.

Hvert fremtidigt push til GitHub deployer automatisk igen.

## Trin 5 · Fortæl Supabase, hvor appen bor
1. **Authentication → Providers → Email**: sørg for, den er slået til (det er den som standard — magic link virker uden videre).
2. **Authentication → URL Configuration**:
   - **Site URL** = din Netlify-URL.
   - Tilføj samme URL under **Redirect URLs**.
   Uden dette ved login-mailen ikke, hvor den skal sende dig hen bagefter.

## Trin 6 · Log ind og gør dig selv til admin
1. Åbn din Netlify-URL + `/app`. Du møder Verta-login-skærmen. Skriv din mail → **Send login-link**.
2. Tjek din indbakke, klik linket — du sendes tilbage til appen.
3. Første gang har du ingen rolle endnu, så du ser "du har ikke adgang til et arrangement". Det er forventet.
4. **Authentication → Users**: kopiér dit **User UID**.
5. **SQL Editor**, kør (indsæt dit UID):
   ```sql
   insert into staff (id, org_id, name, role) values
     ('DIT-USER-UID', '11111111-1111-1111-1111-111111111111', 'Dit navn', 'admin');
   ```
6. Genindlæs appen. Nu er du admin: du ser arrangementsoversigten og kan åbne Emily & Lars.

## Trin 7 · (Valgfrit) test brudeparrets side
1. Log ind med en anden mail (fx Emilys), så brugeren findes.
2. Kopiér hendes UID fra **Authentication → Users**.
3. **SQL Editor**:
   ```sql
   insert into event_access (event_id, user_id, display_name) values
     ('33333333-3333-3333-3333-333333333333', 'EMILYS-UID', 'Emily');
   ```
4. Når hun åbner appen, ser hun brudeparrets visning af Emily & Lars — kun tidslinje og beskeder, ingen kigge-tider.

---

## Hvis noget driller
- **Login-linket sender mig det forkerte sted hen / intet sker** → Site URL og Redirect URL i Trin 5 skal matche din Netlify-URL præcist (https, uden ekstra skråstreg).
- **"Ingen adgang" bliver ved** → tjek, at `staff`-rækken i Trin 6 har dit rigtige UID og org-id'et `1111...`.
- **Appen viser stadig rolleskifteren i stedet for login** → så er `SUPA.url` tom. Tjek, at Trin 3 blev committet og deployet.
- **Tom side / fejl** → åbn browserens konsol (F12) og noter den ordrette fejl.

## Bevidst gemt til pass 2
- Admin-konsollens **lokations- og brugerstyring** som rigtige skærme (oprette lokaler/brugere fra UI'et frem for SQL).
- **Realtime**, så begge parter ser ændringer live.
- **Notifikationsmail** ved nye beskeder (Edge Function + maildienst).
