# FadedAI — Landsbyen & Kontoret grafik

Original pixelgrafik til isometrisk landsbykort og pixelkontor.  
Stil: sammenhængende **2:1-isometrisk** pixelart. Palette: mørk petrol / natblå med varme vinduer og diskrete accenter.

**Licens for alle filer i denne mappe:** CC0 1.0 Universal (public domain dedication).  
Ophavsmand: FadedAI / generated for this repository.  
Ingen tredjepartsaktiver er genbrugt. Regenerér med:

```sh
python3 scripts/generate_village_assets.py
```

Grafikken indeholder **ikke** indbagte navne, knapper eller statusværdier — SwiftUI tegner dem ovenpå.

---

## Fod- og bundpunkter

| Aktiv | Størrelse | Anker | Note |
| --- | --- | --- | --- |
| Terræn-/stifliser | 64 × 32 | midt `(32, 16)` | Isometrisk diamant; fliser overlaps langs kanter |
| Bygninger (alle lag) | 192 × 192 | bundpunkt `(96, 176)` | Placér så ankeret ligger på flisens midte |
| `prop_tree` | 64 × 96 | bund `(32, 88)` | Stamme midt nederst |
| `prop_lamp` | 32 × 64 | bund `(16, 60)` | |
| `prop_sign` | 48 × 48 | bund `(24, 42)` | Tom tavle — app tegner tekst |
| `adam_idle` / `eva_idle` | 64 × 64 | fodpunkt `(32, 60)` | Samme fodpunkt på begge |
| Spritesheets | 256 × 128 | fodpunkt `(32, 60)` pr. frame | Se JSON |
| `office_background` | 320 × 180 | `(0, 0)` øverste venstre | Gulv + vægge |
| `office_desk` | 48 × 32 | bund midt `(24, 30)` | |
| `office_chair` | 24 × 28 | bund midt `(12, 26)` | |
| `office_monitor` | 28 × 24 | bund midt `(14, 22)` | |
| `office_decor_plant` | 16 × 24 | bund `(8, 22)` | |
| `office_decor_mug` | 10 × 10 | bund `(5, 9)` | |

Adam: blå detaljer, bredere silhuet, headset.  
Eva: lilla detaljer, længere hår, udadgående frakke/kjole.

---

## Lagordning (Landsbyen)

Tegn typisk i denne rækkefølge pr. celle/bygning:

1. Terrænfliser (`tiles/`)
2. Stier (`tiles/path_*`)
3. `building_*_shadow`
4. `building_*` (base)
5. `building_*_windows_night` (kun nat)
6. Figurer / props bagved forgrund
7. `building_*_foreground`
8. SwiftUI-labels / status

---

## Filoversigt

### `tiles/` — 64 × 32

| Fil | Beskrivelse |
| --- | --- |
| `terrain_grass.png` | Græs |
| `terrain_dirt.png` | Jord |
| `terrain_plaza.png` | Torv / sten |
| `path_straight_ne.png` | Sti NE–SW |
| `path_straight_nw.png` | Sti NW–SE |
| `path_cross.png` | Kryds |
| `path_corner_{n,e,s,w}.png` | Hjørner |
| `path_t_{n,e,s,w}.png` | T-kryds |

### `buildings/` — 192 × 192, transparente PNG

Fire steder × fire lag:

- `building_research_lab[.png|_shadow|_windows_night|_foreground]`
- `building_video_studio[…]`
- `building_cafe[…]`
- `building_sleep_nook[…]`

### `props/`

- `prop_tree.png`, `prop_lamp.png`, `prop_sign.png`

### `characters/`

- `adam_idle.png`, `eva_idle.png` — stillbilleder til appen i dag
- `adam_spritesheet.png` + `adam_spritesheet.json`
- `eva_spritesheet.png` + `eva_spritesheet.json`

Spritesheet-frames (fps **6**): `idle`, `walk_1`, `walk_2`, `work`, `talk`, `rest`, `sleep`.

### `office/`

- `office_background.png` — gulv + vægge (320 × 180)
- `office_desk.png`, `office_chair.png`, `office_monitor.png`
- `office_decor_plant.png`, `office_decor_mug.png`
- `office_composited_reference.png` — otte stationer i to rækker (reference)

### `previews/`

- `preview_village_day.png` / `preview_village_night.png`
- `preview_iphone_village_day.png` / `preview_iphone_village_night.png`
- `preview_iphone_office.png`

---

## Licens

```
CC0 1.0 Universal

To the extent possible under law, the author(s) have dedicated all copyright
and related rights in the assets under App/Assets/Village/ to the public domain.
You can copy, modify, distribute and perform the work, even for commercial
purposes, all without asking permission.

https://creativecommons.org/publicdomain/zero/1.0/
```

Ingen eksterne kilder er brugt; derfor er der ingen CC BY-kreditering at vedlægge.
