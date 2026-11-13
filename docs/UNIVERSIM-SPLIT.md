# FadedAI — Universim-milepæl, todelt arbejdsbeskrivelse

**Formål:** Løfte Landsbyen fra “dashboard med avatarer” til en lille AI-civilisation, brugeren kan *se leve* og kun gribe ind i som gud — inspireret af The Universim.

**Status nu (~25–35%):**  
Fire zoner, zoom/pan, filmtilstand, søvn/rutine efter ur, Agent-Hub, lokal bot-builder, grafikpakke under `App/Assets/Village/` (CC0). Grafikken er **ikke** wired ind. Kontoret er **ikke** en skærm. Behovssystem, synlige relationer mellem bots og hukommelse→landsby mangler.

**Samlet mål for denne milepæl:**  
Når brugeren åbner Landsbyen (også i demo uden PC), ser Adam og Eva *leve*: gå mellem steder, arbejde, snakke, hvile, sove. Tryk åbner bottens verden. Filmtilstand er den primære oplevelse. PC-status forstærker livet, når den er online — den er ikke en forudsætning for, at landsbyen føles levende.

**Opdeling:**  
- **Del A — Cursor (denne agent / kode i repoet):** SwiftUI-integration, rendering, animation, demo-autonomi i klienten, Kontoret, overlays.  
- **Del B — ChatGPT (design + kontrakter + indhold):** Livsregler, behovsmodel, events, personlighed, hukommelseskortlægning, JSON-skemaer og acceptkriterier, som Del A implementerer imod.

**Samling:** Del B leverer et låst design-dokument + skemaer. Del A implementerer imod dem. Begge dele må gerne køre parallelt, hvis Del B først låser **minimumsskemaet** (se “Fælles kontrakt” nedenfor).

**Merge-regel:** Intet merges til `main`, før ejeren eksplicit godkender.

---

## Fælles kontrakt (skal begge dele respektere)

### Produktprincipper
1. **Observation først, kontrol bagefter.** Filmtilstand / roligt kort er default.
2. **Ingen indbagte navne, knapper eller statusværdier i grafikken.** SwiftUI tegner dem ovenpå.
3. **Demo skal leve uden PC.** Offline/demo = lokal simulation. Online = simulation + hub/jobs spejles ind.
4. **Adam = blå, logik/kode. Eva = lilla, kreativ/video.** Forskellige silhuetter; fælles fodpunkt `(32, 60)`.
5. **Fire steder:** Research Lab, Video Studio, café, sovekrog — forbundet med stier og torv.
6. **Max 10 bots; 2 skriveborde kan køre samtidigt** (PC-regel — landsbyen må gerne vise flere, men “aktiv computer” følger eksisterende kapacitet).

### Minimumsskema for bot-livstilstand (Del B må udvide, ikke bryde felter)

```json
{
  "id": "adam",
  "display_name": "Adam",
  "archetype": "logic",
  "sprite_id": "adam",
  "zone_id": "research",
  "activity": "work",
  "pose": "work",
  "needs": {
    "energy": 0.72,
    "social": 0.41,
    "fulfillment": 0.63,
    "mood": 0.55
  },
  "destination_zone_id": null,
  "path_progress": 0.0,
  "speech_hint": null,
  "carrying": null,
  "last_event_id": null,
  "updated_at": "2026-11-13T02:00:00Z"
}
```

Tilladte `zone_id`: `research` | `video` | `cafe` | `sleep`  
Tilladte `activity` / `pose` (start): `idle` | `walk` | `work` | `talk` | `rest` | `sleep`  
`needs.*`: `0.0`–`1.0`  
`carrying`: `null` eller `{ "kind": "file_share", "label_key": "shared_clip", "from_bot_id": "…", "to_bot_id": "…" }`  
`speech_hint`: `null` eller kort nøgle (ikke færdig UI-tekst nødvendigvis) — SwiftUI oversætter.

### Zone-kort

| zone_id | Dansk navn | Bygningsasset |
| --- | --- | --- |
| `research` | Research Lab | `building_research_lab*` |
| `video` | Video Studio | `building_video_studio*` |
| `cafe` | Café | `building_cafe*` |
| `sleep` | Sovekrog | `building_sleep_nook*` |

### Grafik-ankre (allerede leveret)

Se `App/Assets/Village/ASSETS.md`.  
Lagorden: terræn → stier → skygge → bygning → natvinduer → figurer/props → forgrund → SwiftUI-overlays.

### Definition of Done for milepælen (samlet)
- [ ] Landsby bruger PNG-assets (ikke kun Canvas-former).
- [ ] Dag/nat skifter visuelt (natvinduer + mørkere himmel).
- [ ] Adam + Eva bevæger sig og skifter pose i demo uden PC.
- [ ] Behov påvirker, hvor de går hen (ikke kun ur-modulo).
- [ ] Mindst én synlig interaktion mellem bots (snak eller fildeling-pakke).
- [ ] Kontor-visning med 8 stationer; tryk på bot/plads åbner eksisterende bot-detalje/computer-flow.
- [ ] Filmtilstand er den rolige primære landsby-oplevelse.
- [ ] Ingen indbagte labels i assets.
- [ ] `docs/UNIVERSIM-SPLIT.md` + Del B’s designfil er opdateret, så næste agent kan fortsætte.

---

# DEL A — Cursor / kodeagent (Swift + assets i dette repo)

## Rolle
Du implementerer oplevelsen i iPhone-appen. Du må **ikke** opfinde livsregler ad hoc, hvis Del B har låst dem — følg skemaet. Hvis Del B mangler, implementér imod **minimumsskemaet** ovenfor og markér TODO’er.

## Scope (gør)
1. **Wire Landsby-grafik** ind i `AgentHub` / landsby-viewet i `App/SweatCasterApp.swift` (eller udtræk til egne Swift-filer hvis filen er for stor).
2. **Tilemap + bygninger + props** med korrekt anker og z-orden.
3. **Adam/Eva sprites** fra `App/Assets/Village/characters/` (idle først; spritesheets hvis tid).
4. **Dag/nat** via eksisterende time-logik + `*_windows_night`.
5. **Lokal livssimulator** i klienten (demo/offline), der opdaterer bot-state efter Del B’s regler (eller minimumsskema).
6. **Kontor-skærm** med `office_*` assets; plads til 8 stationer; botliste under/ved siden af som nu.
7. **Overlays:** navn, kort aktivitetslabel, diskrete behov (valgfrit som prikker/bjælker) — alt i SwiftUI.
8. **Tryk på bot** → eksisterende detalje/sheet (lokal bot eller hub-agent). Undgå nye login-flows.
9. **Filmtilstand** som tydelig “kig på livet”-mode (skjul støjende chrome).
10. Hold dig inden for eksisterende API-kontrakter; opfind ikke nye PC-endpoints uden at markere dem som forslag.

## Scope (gør ikke)
- Merge til `main` uden eksplicit ejergodkendelse.
- Indbag tekst/UI i PNG’er.
- Erstat hele video-studio / chat-flow.
- Kræv PC for at landsbyen virker.
- Store gameplay-systemer (byggeri, økonomi, kamp).

## Nuværende kode at bygge ovenpå
- `App/SweatCasterApp.swift` — `AgentHub`, `village`, `villageAvatar`, `localVillageAvatar`, `villagePoint`, filmtilstand, hub-snapshot.
- `VillageBot` + `VillageBotBuilder` — lokale bots, valgfri custom sprite.
- `App/Assets/Village/**` + `scripts/generate_village_assets.py` + `ASSETS.md`.
- Hub: `GET /api/v2/agent-hub` (+ events) — status `working|thinking|ready|offline`.

## Foreslået filopdeling (Cursor må justere)
```
App/
  Village/
    VillageMapView.swift          // kort, zoom/pan, lag
    VillageOfficeView.swift       // kontor 320×180 + stationer
    VillageLifeSimulator.swift    // lokal tick/demo-liv
    VillageModels.swift           // state matcher fælles JSON
    VillageAssetCatalog.swift     // Image-navne / lagorden
  Assets/Village/                 // allerede leveret
docs/
  UNIVERSIM-SPLIT.md              // denne fil
  UNIVERSIM-LIFE-DESIGN.md        // Del B leverer denne
```

Tilføj gerne assets til `Assets.xcassets` som imagesets, eller load via bundle-stier — vælg det, der er mest praktisk i dette Xcode-projekt.

## Implementeringsrækkefølge (Cursor)
1. **Asset-adgang** — Adam/Eva + én bygning + græs synlig i landsbyen.
2. **Kort-layout** — fire bygninger på `villagePoint`-zoner, stier/torv, dag/nat-lag.
3. **Figurer på ankre** — idle sprites, tryk virker stadig.
4. **Simulator-tick** — flyt Adam/Eva mellem zoner med walk-progress (demo).
5. **Poses** — work/talk/rest/sleep (spritesheet frames eller idle+opacity som fallback).
6. **Behovsdriven valg af destination** (efter Del B; ellers simpel energi→sleep, social→cafe, fulfillment→work zone).
7. **Kontor-view** + navigation Landsby ↔ Kontor.
8. **Én relation:** talk-boble *eller* carrying-pakke mellem bots.
9. **Hub-spejl:** online status mapper til activity (working→work, ready→idle/rest, offline→sleep), uden at slå demo-livet helt ihjel.
10. **Polish:** filmtilstand default i landsby-sheet, Reduce Motion respekteres.

## Tekniske krav
- iOS 18+, SwiftUI, existing project `SweatCaster.xcodeproj`.
- `.interpolation(.none)` på pixelart.
- Respektér `accessibilityReduceMotion`.
- Danske UI-strenge som resten af appen.
- Ingen secrets. Ingen ny backend-afhængighed for demo.
- Tests: udvid gerne `Tests/ContractTests.swift` eller tilføj lette unit tests for simulator (zone-valg, behov-klamp).

## Handoff fra Del B (input Cursor forventer)
Fil: `docs/UNIVERSIM-LIFE-DESIGN.md` med:
- behovsformler / ticks
- beslutningstabel zone-valg
- eventkatalog (id → hvornår → synligt hint)
- mapping hub-status → activity
- copy-nøgler på dansk
- accepttests i Givet/Når/Så

Hvis filen mangler: implementér minimumsskema + TODO-kommentarer `// LIFE-DESIGN:`.

## Cursor deliverables
- [ ] Kode + assets wired, kører i simulator/build så vidt miljøet tillader.
- [ ] Kort note i PR/besked: hvad der er live vs. stub.
- [ ] Ingen merge uden ejer-OK.
- [ ] Bevar ejerens PR-beskrivelse ved opdatering.

## Cursor acceptkriterier
- Åbn Landsby: se PNG-landsby dag og nat.
- Demo: Adam/Eva skifter sted inden for få minutter (eller accelereret tick i debug).
- Tryk bot → sheet/detalje.
- Kontor viser 8 stationer uden indbagte navne.
- Reduce Motion: ingen påkrævet gang-animation; teleport/fade OK.
- Offline banner kan stadig vises; bots “lever” lokalt alligevel.

---

# DEL B — ChatGPT (design, regler, indhold, kontrakter)

## Rolle
Du designer **AI-livet**: regler, balance, events, personlighed og den kontrakt, klienten simulerer imod. Du skriver ikke Swift, medmindre brugeren eksplicit beder om uddrag. Du leverer dokumentation, som Cursor kan implementere uden at gætte.

## Scope (gør)
1. Skriv `docs/UNIVERSIM-LIFE-DESIGN.md` (fuld designfil).
2. Udvid gerne minimumsskemaet med valgfrie felter — markér breaking vs. non-breaking.
3. Definér **døgnrytme**, behovsdrift, tærskler, cooldowns.
4. Definér **beslutningslogik** for destination (prioritet ved konflikt).
5. Definér **Adam vs Eva** forskelle (archetypes), uden at låse kun to bots for evigt (skal skalere til 10).
6. Definér **events** (10–20) med id, trigger, varighed, synligt hint, om brugeren kan gribe ind.
7. Definér **inter-bot**: snak i café + fildeling-pakke (regler, ikke UI-pixels).
8. Mapping **hub/PC-status → landsby-activity** og hvad der vinder ved konflikt (PC vs lokal sim).
9. Dansk **copy**: aktivitetslabels, event-tekster, tomme tilstande, VoiceOver-forslag.
10. **Accepttests** (Givet/Når/Så) og et lille **balance-afsnit** (hvor ofte de må skifte zone, så det ikke ser epileptisk ud).

## Scope (gør ikke)
- Omskriv hele app-arkitekturen.
- Kræv nye PC-API’er som blocker for demo (må foreslås som “fase 2”).
- Indfør valuta/kamp/byggeri.
- Indbag tekst i grafikkrav.
- Antag at Cursor har merged noget.

## Kontekst ChatGPT skal kende
- App: SwiftUI iPhone, demo uden PC, QR/LAN til Windows-PC, Ollama lokalt, Docker-skriveborde, max 10 bots / 2 samtidige desktops.
- Landsby: isometrisk kort + Kontor; grafik klar i `App/Assets/Village/`.
- Eksisterende hub-status: `working`, `thinking`, `ready`, `offline`.
- Hukommelse findes backend-side (`agent-memory` / hub memory endpoints) men er ikke landsby-synlig endnu.
- Målet er Universim-følelse: livet kører; brugeren er gud.

## Obligatorisk indhold i `UNIVERSIM-LIFE-DESIGN.md`

### 1. Vision (½ side)
Hvad brugeren skal *føle* på 10 sekunder i Landsbyen.

### 2. Entities
Bot, Zone, Need, Activity, Event, CarryItem — feltdefinitioner.

### 3. Simulation tick
- Anbefalet tick (fx 1s UI / 5–15s beslutning).
- Accelereret demo-tick.
- Reduce Motion-adfærd.

### 4. Needs
For hver need (`energy`, `social`, `fulfillment`, `mood`):
- hvad øger/sænker den
- tærskler (lav/mid/høj)
- synlig manifestation (pose, zone, overlay)

### 5. Decision policy
Pseudokode eller prioriteret tabel:
```
hvis energy < X → sleep
ellers hvis social < Y og anden bot i cafe → cafe/talk
ellers hvis aktiv PC-job → work i matchende zone
ellers fulfillment-driven work zone efter archetype
ellers idle/rest i nuværende zone
```

### 6. Archetypes
- `logic` (Adam-default): research-biased  
- `creative` (Eva-default): video-biased  
- `care` / `playful` som valgfrie til VillageBot.personality

### 7. Events katalog
Tabel: `event_id | trigger | duration | speech_hint/key | player_action | notes`

Mindst:
- stuck_on_task
- inspired
- needs_break
- cafe_chat
- file_handoff
- night_wind_down
- morning_startup
- offline_rest

### 8. PC/hub mapping
| Hub status | Landsby activity | Må lokal sim overstyre? |
| --- | --- | --- |
| working | work | nej (mens job aktivt) |
| thinking | work eller talk | begrænset |
| ready | idle/rest/cafe | ja |
| offline | sleep/rest | ja |

### 9. Fase 2-forslag (ikke blocker)
Nye API-felter (mood/energy), server-side simulation, push “Eva er færdig”, CloudKit sync, osv.

### 10. Accepttests
Mindst 12 Givet/Når/Så, som Cursor kan afkrydse manuelt.

## ChatGPT deliverables
- [ ] `docs/UNIVERSIM-LIFE-DESIGN.md` (komplet).
- [ ] Evt. `docs/UNIVERSIM-LIFE-SCHEMA.json` (JSON Schema for bot-state + events).
- [ ] Kort “til Cursor”-afsnit øverst: hvad der er låst vs. forslag.
- [ ] Dansk copy-liste klar til UI.

## ChatGPT acceptkriterier
- Cursor kan implementere demo-liv **uden** at spørge dig igen om zone-valg.
- Ingen breaking ændring af minimumsskemaets påkrævede felter uden versionsnote.
- Events og copy er konkrete (ikke “gør det hyggeligt”).
- Tydelig grænse mellem fase 1 (klient-sim) og fase 2 (PC).

---

# Sådan arbejder I sammen

```
        ┌──────────────────────┐
        │  Fælles kontrakt i    │
        │  UNIVERSIM-SPLIT.md   │
        └──────────┬───────────┘
                   │
       ┌───────────┴───────────┐
       ▼                       ▼
┌──────────────┐        ┌──────────────┐
│ DEL B ChatGPT│        │ DEL A Cursor │
│ Life design  │───────▶│ Swift + UI   │
│ + schema     │  låst   │ implementering│
└──────────────┘  API    └──────┬───────┘
                                │
                                ▼
                        Samlet oplevelse
                        (ejer godkender PR)
```

**Anbefalet rækkefølge**
1. ChatGPT skriver og låser `UNIVERSIM-LIFE-DESIGN.md` + schema (fase 1).  
2. Cursor implementerer Del A imod det.  
3. ChatGPT review’er accepttests ud fra Cursor’s beskrivelse/screenshots.  
4. Ejer godkender → først derefter merge.

**Parallel start er OK**, hvis Cursor begynder med asset-wiring (trin 1–3), mens ChatGPT skriver livsdesign — men beslutningslogik må ikke hardcodes, før Del B’s policy er klar, medmindre minimumsskema-fallback bruges.

---

# Prompt-skabeloner

## Prompt til ChatGPT (Del B)
```
Du er Del B i FadedAI Universim-milepælen.
Læs og følg: docs/UNIVERSIM-SPLIT.md (sektion DEL B + Fælles kontrakt).
Lever docs/UNIVERSIM-LIFE-DESIGN.md (+ valgfri JSON Schema).
Skriv på dansk. Fase 1 skal kunne køres 100% lokalt i iPhone-demo uden PC.
Lås decision policy og eventkatalog, så en Swift-agent kan implementere uden at gætte.
```

## Prompt til Cursor (Del A)
```
Du er Del A i FadedAI Universim-milepælen.
Læs docs/UNIVERSIM-SPLIT.md (DEL A + Fælles kontrakt) og docs/UNIVERSIM-LIFE-DESIGN.md hvis den findes.
Implementér Landsby/Kontor med App/Assets/Village, lokal life simulator, filmtilstand, overlays.
Merge ikke til main før jeg eksplicit godkender.
Bevar min PR-beskrivelse ved opdateringer.
```

---

# Hurtig checklist til ejeren

- [ ] Send Del B-prompten til ChatGPT.  
- [ ] Læg `UNIVERSIM-LIFE-DESIGN.md` ind i repoet/`docs/`.  
- [ ] Send Del A-prompten til Cursor.  
- [ ] Review previews + demo i simulator.  
- [ ] Godkend PR først, når begge deles acceptkriterier er mødt.
