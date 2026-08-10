# Verta — regressionstests

Selvstændig, node-baseret testpakke for `app/index.html`. Ikke en del af appens egen "ingen
build"-arkitektur — et rent udviklingsværktøj, der aldrig deployes.

Alle tests udtrækker de RIGTIGE funktioner direkte fra `../app/index.html` (streng-udtræk + Node's
`vm`-modul, evt. suppleret med `jsdom` for DOM-afhængige tests) og kører dem i isolation. Der
genimplementeres intet — en test kan kun bestå, hvis den faktiske kildekode gør det rigtige.

## Kør testene

```
cd tests
npm install
npm test
```

## Dækning

- `test_mutate_guard.js` — `mutate()`/`assertCanMutate()` blokerer ALLE skrivninger i preview-mode,
  også ved direkte kald uden om UI'et.
- `test_readonly_ui.js` — `applyPreviewReadOnly()` låser de konkrete gæste-/opgave-/beskedfelter i
  kunde-visningen, uden at røre søgning/eksport.
- `test_preview_tab_reset.js` — skift til "Forhåndsvis som kunde" mens en kilden-only fane (fx "I dag")
  er åben, falder korrekt tilbage til Oversigt.
- `test_routing_resolution.js` — gæste-routing ved flere arrangementer: URL > sessionStorage > enkelt
  adgang > vælger, aldrig "nyeste vinder", og et fremmed event-id i URL/session ignoreres.
- `test_log_search.js` — logsøgning kan ryddes tre veje (backspace, ×-knap, Escape) uden at påvirke
  andre filtre.
- `test_save_feedback.js` — Admin-fanens "Gem"-knap viser Gemmer… → Gemt ✓ → Gem, og overlever at
  `render()` genskaber selve knappen undervejs.
- `test_export_feedback.js` — eksport-knappen viser Forbereder fil… → Download startet ✓, værner mod
  dobbeltklik, og viser en fejl-toast ved exception i stedet for at fejle tavst.
- `test_csv_export.js` — CSV-filens faktiske INDHOLD: BOM, semikolon, danske tegn, korrekt escaping af
  anførselstegn/semikolon/ægte linjeskift i felter, korrekt antal rækker/kolonner.
- `test_modal_dispatch_order.js` — regressionstest for en reel, kritisk fejl fundet under denne
  omgangs browserverifikation: `MODAL_RENDERERS.xxx`/`MODAL_BINDERS.xxx`-tildelinger endte tekstligt
  FØR deres egen `const`-erklæring, hvilket er en ReferenceError (temporal dead zone), der stoppede
  HELE `<script>`-blokken fra at køre på ethvert sidehit. Testen scanner kildekoden strukturelt for
  denne fejlklasse OG kører hele scriptet i en rigtig jsdom-DOM for at bevise, at det rent faktisk
  starter uden at kaste en fejl (bekræftet at ramme præcis den oprindelige fejlbesked, da fejlen blev
  genskabt midlertidigt under udvikling af denne test).
- `test_csv_import.js` — gæsteimport: delimiter-sniffing (komma/semikolon), anførselstegn/BOM,
  kolonnegætning uafhængigt af sprog/rækkefølge, kategori-/bool-normalisering, dublet-detektion
  (navn, case/whitespace-uafhængigt), gyldige/ugyldige rækker, kost-tag-normalisering.
- `test_change_request_pricing.js` — prisberegning (`computeEventTotal`) for tilbudslinjer på
  reception/middag-grundlag inkl. børnehalvpris og fast beløb, prisdelta-visning på ændringsforslag
  (`changeRequestSummary`, fortegn), og den tids-baserede (ikke felt-baserede) regel for hvornår en
  gæst mister direkte skriveadgang til gæstelisten (`guestEditsAreLocked`).
- `test_log_grouping.js` — loggruppering af gentagne "kiggede ind"-hændelser: kun konsekutive
  hændelser fra samme person grupperes, en rigtig ændring/besked midt i en stribe bryder grupperingen,
  forskellige personers kigge-hændelser blandes aldrig, og hele funktionen kan slås fra.
- `test_handover_tasks.js` — regressionstest for en reel fejl fundet under koordinator-gennemgangen:
  `handoverEvent()` flyttede tidligere ALLE åbne opgaver til den nye ejer ved overdragelse, ikke kun dem
  der rent faktisk var tildelt den afgivende ejer — en kollegas egne opgaver blev fejlagtigt fjernet fra
  dem ved enhver overdragelse. Testen bekræfter, at kun den afgivende ejers opgaver flyttes, at en
  tredje kollegas og uassignerede opgaver ikke røres, at allerede udførte opgaver ikke er med, og at
  `moveTasks=false` slet ikke rører `agenda_items`.

## Kendte begrænsninger

Miljøet, disse tests blev udviklet i, havde ikke netværksadgang fra en browser til det live Supabase-
projekt (kun via de dedikerede MCP-værktøjer) — derfor er der ingen ende-til-ende browsertest, der
logger ind og klikker sig igennem den rigtige app mod den rigtige database. I stedet er hver test
forankret i den faktiske kildekode og — hvor det er relevant — suppleret med direkte SQL-verifikation
af RLS/databasetilstand (se changelog/final rapport for de konkrete before/after-værdier).

Ting der IKKE kræver Supabase-netværksadgang, ER til gengæld verificeret i en rigtig Chromium-instans
(Playwright, med en stubbet `supabase.createClient()` der aldrig rammer netværket): berøringsflade-
størrelser (44px) og selve appens evne til at boote og rendere ved 390px viewportbredde. Sidstnævnte
var det, der fangede `test_modal_dispatch_order.js`s bagvedliggende fejl i første omgang — en reel
tavs regression, som ingen af de øvrige (rent kildekode-baserede) tests kunne opdage, fordi ingen af
dem rent faktisk kører hele scriptet fra ende til anden i en DOM. Playwright-scriptet selv er ikke
en del af denne mappe (kørt ad hoc mod en midlertidig lokal kopi af appen), men den samme kontrol er
nu permanent dækket af `test_modal_dispatch_order.js`s jsdom-baserede boot-test.
