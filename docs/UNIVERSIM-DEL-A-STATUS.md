# Del A status (Cursor)

Implementeret imod `docs/UNIVERSIM-SPLIT.md` og Del B `docs/UNIVERSIM-LIFE-DESIGN.md`.

**IPA-klar samling** på `cursor/village-office-pixel-assets-6c4b` — start ikke IPA/merge før eksplicit ja (build tager lang tid; alt skal med i én runde).

## Live nu
- PNG-landsby i `AgentHub` (bygninger, props, Adam/Eva, dag/nat-vinduer)
- `VillageLifeSimulator` følger Del B: beslutning 8 s, gang 4 s, min. ophold 24 s, café 16 s, behovsrater, eventkatalog, demo-ur (1 s = 2 virtuelle minutter fra 09:00)
- Adam/Eva-seed: Research Lab 0,80/0,52/0,48 · Video Studio 0,76/0,38/0,55
- Første beslutning: Eva mod café (social), Adam bliver / øver lokalt indtil min. ophold
- Offline: lokal livscyklus + banner; hub-fejl rydder live-mærker
- Online: bekræftede hub-jobs som live-mærker (`working`/`queued`); søvn beholder ventetekst
- Gemte bots bevares via `mergeLocalProfiles` (Adam/Eva fjernes ikke)
- Zoom: 1× centreret uden pan; zoomet pan clampet til rammen; nulstil-knap
- Kontoret er egen skærm (`navigationDestination`)
- Tryk på bot → hub-agent / lokal profil / life-inspector efter stabilt id
- Filmtilstand default
- Automatiske tests for seed, prioritet, pause, offline, clamp, første Eva-café-beslutning

## Stub / senere (ikke blokerende for denne IPA)
- Spritesheet-poses (idle + activity-label)
- Fuld quest-joblog dedup på tværs af Integration Runde 6-motor (når gren samles)
- Asset Catalog imagesets (nu folder-resource `App/Assets/Village`)

## iPhone-testrunde (én IPA)
1. Demo uden PC: Adam Research, Eva Video → Eva går snart mod café; aktivitet ≤10 s
2. Café-samtale 16 s + demo-fildeling-hint
3. Zoom 1× fast / zoom ind pan / ud igen centreret
4. Kontor-knap → egen skærm; tryk bot → rigtig profil
5. Pause landsbyen; Reduce Motion
6. Med PC: working-job → live-mærke; afbryd → offline-banner, lokal rytme
7. Lad demo køre ~7 min → natlys + aftenhint

## Filer
- `App/VillageModels.swift`
- `App/VillageLifeSimulator.swift`
- `App/VillageAssets.swift`
- `App/VillageMapView.swift`
- `App/VillageOfficeView.swift`
- `App/SweatCasterApp.swift` (`AgentHub` integration)
- `docs/UNIVERSIM-LIFE-DESIGN.md` · `docs/UNIVERSIM-LIFE-SCHEMA.json`
