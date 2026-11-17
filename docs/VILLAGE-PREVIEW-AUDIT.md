# Landsbyen: sammenligning med desktoppreviewet

**Ny grafik 16. november:** Dette er den historiske kontrol af det tidligere desktoppreview. Aktuel integration af brugerens nye pakke, figurvælgeren med 5 mænd/5 kvinder og dens åbne begrænsninger står i [FINAL-INTEGRATION.md](village-art/FINAL-INTEGRATION.md). Den tidligere beskrivelse nedenfor dokumenterer ikke de nye billeders kvalitet.

Gennemgangen sammenligner iPhone-implementeringen med Craft Anything-previewet i `unitycrashhandler64/app`. Den bygger på previewets `src/main.rs`, `README.md`, `design/HANDOFF.md` og `assets/fadedai`.

| Del i previewet | iPhone-integration |
| --- | --- |
| Kort med ti navngivne bots, dag/aften, zoom og låst panorering | `VillageMapView` og `VillageLifeSimulator`; manuel lysindstilling og zoom føjet til. Alle 89 originale PNG'er fra `assets/fadedai` er i appen. |
| Tryk på fire bygninger | Kortets fire områder åbner hver sin bygningsside med stedets bots. |
| Statue på torvet → Skaberkontoret | Trykbart skabermonument på kortet åbner Kontoret. Originalt brugerportræt er med som `creator.png`; iOS tegner monumentet i 2D. |
| Kontor, opret bot, søg og højst ti bots | Kontoret åbner den eksisterende botbygger og viser de faktiske gemte profiler. |
| Ung bot, voksen efter syv dage | Oprettelsesdato gemmes; alder vises i Kontoret og profilen, og unge bots tegnes mindre på kortet. Ældre eksisterende bots behandles som voksne grundlæggere. |
| Slet bot → kirkegård | Kontor og profil kræver bekræftelse; minde med navn og rolle gemmes lokalt. Profilens Fortryd gendanner botten og fjerner mindet. |
| Kirkegård med kirke og gravsten | Trykbart sted på kortet og selvstændig Kirkegården-side. Viser navngivne minder og en mindehave. |
| Botprofil og personligt rum | Profilen viser alder, eget rum, relation og rytme; computerens eget rum og rigtige PC-status bruges fortsat. |
| Opgavebrev og botcomputer | Selvstændig Opgaver-side lader brugeren vælge bot og åbner dens faktiske computer, hvor job sendes og filer vises. Ingen demoresultater sendes. |
| Landsbyindstillinger | Selvstændig side med dag/aften/automatisk, navne, mindre bevægelse og zoom/nulstilling. |
| Vedvarende liv og minder | Den eksisterende livsmotor bevares. Nye fødsler og minder lagres lokalt og er føjet til FadedAI-backup med støtte for ældre backupfiler. |
| Animationsark med 16 retninger | Eksisterende 8-frame animation bruger nu arkets retningsrække under gang. |

Rust-programmet er et designpreview. Dets falske online/Docker-knapper, lokale eksempeljob og eksempelresultatfiler er ikke produktionsfunktioner og er ikke kopieret ind i iPhone-appen. Dets egen lydknap er deaktiveret i kilden, og iPhone-siden forklarer samme status.

Statuen og kirken er tegnet som native 2D-elementer i iPhone-appen. Den visuelle lighed og trykvejene skal verificeres på en fysisk iPhone.
