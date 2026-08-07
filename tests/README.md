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

## Kendte begrænsninger

Miljøet, disse tests blev udviklet i, havde ikke netværksadgang fra en browser til det live Supabase-
projekt (kun via de dedikerede MCP-værktøjer) — derfor er der ingen ende-til-ende browsertest, der
logger ind og klikker sig igennem den rigtige app mod den rigtige database. I stedet er hver test
forankret i den faktiske kildekode og — hvor det er relevant — suppleret med direkte SQL-verifikation
af RLS/databasetilstand (se changelog/final rapport for de konkrete before/after-værdier). Berørings-
fladestørrelser (44px) er til gengæld verificeret med en rigtig Chromium-instans (Playwright) ved
390px viewportbredde, da det ikke kræver netværksadgang til Supabase.
