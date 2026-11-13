# Del A status (Cursor)

Implementeret imod `docs/UNIVERSIM-SPLIT.md` og Del B `docs/UNIVERSIM-LIFE-DESIGN.md`.

## Live nu
- PNG-landsby i `AgentHub` (bygninger, props, Adam/Eva, dag/nat-vinduer)
- `VillageLifeSimulator` følger Del B: beslutning hvert 8. s, gang 4 s, min. ophold 24 s, café 16 s, behovsrater, eventkatalog, demo-ur (1 s = 2 virtuelle minutter fra 09:00)
- Adam/Eva-seed: Research Lab 0,80/0,52/0,48 · Video Studio 0,76/0,38/0,55
- Offline: lokal livscyklus; online: bekræftede hub-jobs som live-mærker (`working`/`queued`)
- Gemte bots bevares via `mergeLocalProfiles` (Adam/Eva fjernes ikke)
- Zoom: 1× centreret uden pan; zoomet pan clampet til rammen; nulstil-knap
- Kontoret er egen skærm (`navigationDestination`)
- Tryk på bot → hub-agent / lokal profil / life-inspector efter stabilt id
- Filmtilstand default
- Automatiske tests: zone/needs, seed, PC vs søvn, pause, offline, kameraclamp

## Stub / senere
- Spritesheet-poses (idle + activity-label)
- Fuld quest-joblog dedup på tværs af Integration Runde 6-motor (når gren samles)
- Asset Catalog imagesets (nu folder-resource `App/Assets/Village`)
- Manuelle accepttest 1–18 på iPhone (se PR)

## Filer
- `App/VillageModels.swift`
- `App/VillageLifeSimulator.swift`
- `App/VillageAssets.swift`
- `App/VillageMapView.swift`
- `App/VillageOfficeView.swift`
- `App/SweatCasterApp.swift` (`AgentHub` integration)
- `docs/UNIVERSIM-LIFE-DESIGN.md` · `docs/UNIVERSIM-LIFE-SCHEMA.json`
