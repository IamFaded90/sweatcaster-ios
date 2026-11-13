# Del A status (Cursor)

Implementeret imod `docs/UNIVERSIM-SPLIT.md` minimumsskema.  
`docs/UNIVERSIM-LIFE-DESIGN.md` mangler stadig (Del B).

## Live nu
- PNG-landsby i `AgentHub` (bygninger, props, Adam/Eva, dag/nat-vinduer)
- Lokal `VillageLifeSimulator` med behov, zone-valg, gang, café-snak, fildeling-pakke
- Kontor-visning med 8 stationer + botliste
- Filmtilstand default; Landsby ↔ Kontor
- Demo uden PC kører (offline-banner, lokal sim)
- Hub-agenter spejles ind, når PC er online
- Unit tests for zone-mapping, need-clamp, sleep/café-valg

## Stub / senere
- Spritesheet-poses (bruger idle + activity-label indtil Del B/polish)
- Fuld decision table / eventkatalog fra Del B (`// LIFE-DESIGN:` markers)
- Asset Catalog imagesets (nu folder-resource `App/Assets/Village`)
- Mere præcis isometrisk tilemap-sammensætning

## Filer
- `App/VillageModels.swift`
- `App/VillageLifeSimulator.swift`
- `App/VillageAssets.swift`
- `App/VillageMapView.swift`
- `App/VillageOfficeView.swift`
- `App/SweatCasterApp.swift` (`AgentHub` integration)
