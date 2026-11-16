# FadedAI · Hvad mangler vi?

Arbejdslisten følger forsøgsgrenen `codex/fadedai-repo-pilot`. Brug den før et nyt build, og sæt først flueben ved en test, når den er kørt. **I koden** betyder, at ændringen findes på grenen. **I gang** betyder, at der arbejdes på den. **Åben** betyder, at den stadig skal bygges eller afklares.

## De fem valg, vi går med

1. **Agenter i hverdagen.** Giv hver agent adgang til **Chat**, **Computer** og **Opgaver** fra profilen. Vis hvilken model og enhed der svarede. Ved slukket PC kan du vælge lokalt svar eller lade PC-opgaven vente i kø. Composio og den nuværende diktering er udgangspunktet.
2. **Landsbyen med liv.** Start med Harper i Live2D, der blinker og bevæger munden, når hun taler. Office får et hex-kort med papirlook og hårde skygger. Voxelverdenen prøves som ekstra visning.
3. **Én søgning.** Find chats, agenter og filer, også med tastefejl. Giv den enkelte agent søgning i dens egne delte dokumenter med tydelig filkilde.
4. **Studio.** Behold klipredigering på sin egen side. Saml PC-generering af video og 3D i Studio med **Hurtig** og **Høj kvalitet**, hvor modellerne understøtter det.
5. **Privat Studio.** Ryd den midlertidige session efter fem minutters inaktivitet. Giv manuelt gemte Lumi-scener deres egen tydelige indstilling for automatisk sletning. Kontrollér, at private resultater holdes ude af Hjem, Søg og det almindelige galleri.

## Næste test

- [ ] **Se film, mens du bruger appen · i koden.** Start en film i Underholdning. Gå til Landsbyen og Chat under afspilning, kontrollér lyden, og prøv pause og tilbage til samme sted. Prøv også **Billede i billede** med en kompatibel film. Test separat, at Chromecast bliver ved på TV’et.
- [ ] **Tal med Harper · i koden.** Vælg genvejen som Action Button-handling. Åbn Harper med PC’en slukket, send et dansk spørgsmål, og kontrollér, at svaret kommer fra iPhone. Hvis Harper mangler, så prøv den synlige mulighed for at oprette hende. Live2D har sin egen åbne opgave.
- [ ] **Lad PC-jobbet vente · kø og låseskærm i koden.** Sluk PC’en, sæt et videojob med et kendt klip i kø, tænd PC’en og kontrollér, at opgaven sendes én gang. Kontrollér procentsats og tidspunkt for seneste bekræftede status. Afbryd forbindelsen under et job og se efter **Afventer ny status fra PC’en**.
- [ ] **Gentag det, der plejer at virke.** QR-login og udløbet QR, tilbageknapper, chat med tastatur og streaming, almindelig søgning og tastefejl, Video Studio med først ét klip og derefter to. Kontrollér, at mapper kan åbnes og lukkes, og at originalen bliver liggende ved sletning af en redigeret video.
- [ ] **Før push eller installering.** Kør ContractTests med Xcode, og saml ændringerne, når den aftalte testpakke er klar og godkendt. Bekræft iPhone-funktioner på rigtig telefon og Cast på Chromecast, før de markeres som testet. Behold filnavne, eksisterende datafelter, indstillinger og forbindelser. Højst 600 linjer pr. berørt Swift-fil.

## Koden fra før forsøget

- **PocketPal 1–6, i koden.** GGUF på iPhone med import fra Filer, download og genoptagelse, lager- og hukommelsestjek, modelvalg, favoritter og sletning.
- **PocketPal 7–17, i koden.** Agentens modelvalg og modelnavn på svar, agentskabeloner, redigering og nyt svar, vågen skærm, Whisper, håndfri samtale og stemmevalg, regne- og datoværktøjer, offentlige webkilder, svarkort og deling af iPhone-model på Wi‑Fi. Test med iPhone, og test PC-funktionerne igen med den opdaterede PC-del.
- **Underholdning, i koden.** CastBrowser åbner som en del af FadedAI med browser, favoritter, kø og fjernbetjening. Favoritter og historik hører til denne installation. Det gamle filmbibliotekslink er erstattet af Underholdning. Afspilning på iPhone og Chromecast skal prøves på udstyr.
- **Tidligere fejl, som skal fanges igen.** PC-modellernes billedgenerering fra Chat og Privat Studio, download når skærmen slukkes, videokommentarer som passer til hændelsen, oprydning i gamle jobkort, Adam og Evas PC-status og genoprettelse efter genstart. Talegenkendelse og stemmer prøves med samme danske tekst hver gang.
- **Agenternes hverdag.** Prøv egne skriveborde, jobs og filer for flere agenter samt opstart efter Windows-genstart. Prøv Composio og den delte Vault med én godkendt opgave, kalender, påmindelse, alarm og Gmail. Kontrollér, at opgaven kan bruge en tilladelse, uden at adgangskoden vises i chatten.
- **Landsbyen og Studie.** Behold kirkegården og adskillelsen af profilfoto og landsbyfigur. Prøv zoom og lås på kortet. Test billede fra Chat og referencebillede i Privat Studio på telefon og PC. Kontrollér Lumi-ruten og brugerens foretrukne stemme. Prøv et tydeligt dobbelt kill i Fortnite og et klip fra The Finals, så kommentarerne kan vurderes mod det, der faktisk sker.

## De 37 GitHub-punkter

| Nr. | Kilde | Status og næste skridt |
| --- | --- | --- |
| 1 | swift-chat | **Delvis i koden.** Liquid Glass og farvede chatbobler. Test eksisterende composer, Markdown og streaming. |
| 2 | QRCameraKit | **Delvis i koden.** Scanramme, lommelygte, autofokus og vibration. Prøv kamera og gyldig/udløbet kode på iPhone. |
| 3 | Kingfisher | **Åben.** Billedcache til avatars og galleri. Behold landsbyfigur og profilbillede som to valg. |
| 4 | SwiftAgent | **Åben.** Lokalt agentforløb oven på den nuværende modelvælger. |
| 5 | AgentKit.swift | **Åben.** Fælles agentbetjening til PC og telefon. Grok kan vælges særskilt. |
| 6 | SwiftMCP | **Åben.** Værktøjsklient som del af én fælles forbindelse. |
| 7 | Officielt MCP Swift SDK | **Åben.** Definér Søg, Hent fil, Lav kode, Lav billede og Lav video i samme forbindelse som punkt 6. |
| 8 | VecturaKit | **Åben.** Lokal søgning i de dokumenter, hver agent må se. |
| 9 | LumoKit | **Åben.** Klargør vedhæftede dokumenter til søgning, og vis hvilken fil et svar bygger på. Bygger på punkt 8. |
| 10 | Wax | **Åben.** Samlet lokal hukommelse og sletning i Privat Studio. Test tidsfristen og valget for gemte scener. |
| 11 | SQLiteVecKit | **Åben.** Kombinér søgning efter ord og betydning i den eksisterende globale søgning. |
| 12 | Swift Google Drive Client | **Åben.** Direkte Drive som valg ved siden af Composio. Afhænger af login og en tilladelse til de relevante filer. |
| 13 | fuse-swift | **I koden.** Tastefejl som *Fornite* kan finde *Fortnite*. Prøv det i iPhone-appen. |
| 14 | SwiftResilience | **Åben.** Fortsæt den nuværende PC-udbakke og afprøv genforsøg i baggrunden. Test genstart og dubletter. |
| 15 | mlx.promptcache | **Åben.** Genbrug modelinstruktioner, hvis en måling viser en forskel. Hold private sessioner adskilt. |
| 16 | Open-LLM-VTuber | **Åben.** Harper blinker og taler via Live2D. Kræver hendes avatarfiler og en enhedstest. |
| 17 | avatar | **Åben.** VRM-visning til den talende agent. Afprøves som ekstra visning. |
| 18 | 3DSeen | **Åben.** Scan mit værelse med LiDAR og gem en lokal USDZ-fil. |
| 19 | 3d-model-anything | **Åben.** Indlæs rumscanningen som redigerbart Office. Bygger på punkt 18. |
| 20 | Shap‑E | **Åben.** Lav en 3D-model fra tekst eller billede via PC’en, og vis den på iPhone. |
| 21 | TripoSG | **Åben.** Lav en detaljeret 3D-model fra et billede via samme Studio. |
| 22 | Auto-GPT | **Åben.** Chief laver en plan, som brugeren gennemgår og godkender. |
| 23 | OpenInterpreter | **Åben.** Vis den konkrete PC-handling med **Godkend** og **Afvis**. Godkend med Face ID før kørsel. |
| 24 | babyagi | **Åben.** Prioritér og fordel godkendte opgaver til agenterne. Bygger på punkt 22. |
| 25 | voxelcraft | **Åben.** Voxelvisning til Landsbyen som et selvstændigt forsøg. |
| 26 | Matrix-Game | **Åben.** Generér en prøveverden fra et Office-billede på en kompatibel PC. |
| 27 | Oasis | **Åben.** Prøv en interaktiv verden, hvis der er en understøttet PC-motor. |
| 28 | Wan2.1 | **Åben.** Generér video fra tekst eller billede via PC’en. Prøv start- og slutbilleder særskilt. |
| 29 | AnimateDiff | **Åben.** Bevæg et valgt billede via PC’en. |
| 30 | LTX-Video | **Åben.** Afprøv en hurtigere videoprøve via PC’en før den færdige rendering. |
| 31 | LiteReality-Agent | **Åben.** Flyt møbler og agenter i redigerbart Office. Kan bygge oven på punkt 18–19. |
| 32 | HexEngine | **Åben.** Office-kort med hex-felter, papir og hårde skygger. Behold separate kort og brug den nuværende zoom og lås. |
| 33 | GameOfLife-Swift | **Åben.** Kilde-URL mangler. Behold den nuværende tidsmotor, mens behov, jobs og de fire foreslåede epoker afprøves. |
| 34 | isowords | **Åben.** Saml visningens tilstand og gemning, med genåbning af eksisterende landsbyer som test. |
| 35 | moonshine-mlx | **Åben.** Prøv diktering under talen ved siden af den nuværende iPhone-diktering. |
| 36 | swift-parakeet-mlx | **Åben.** Prøv offline lyd til tekst med tidsmærker. Identifikation af talere skal valideres særskilt. |
| 37 | ihunyuan | **Åben.** Prøv lokal dansk oversættelse i Landsbyen. |

## MAX på iPhone 17 Pro Max

1. **Lokal AI.** Start med Apples lokale model til dansk chat og billedanalyse, hvor funktionen er tilgængelig på telefonen. Mål svarstart, varme og batteri før endnu en model tilføjes. MiniCPM5 er i kataloget, men dets nuværende pakke mangler en motor i appen. Flash‑MoE er et forsøg til senere, og store video- og 3D-opgaver bliver på PC.
2. **Kamera.** LiDAR til Office først. Derefter Log 2-farvebehandling med bevaret original, genkendelse af genstande, Manga fra referencefoto og Object Capture af stillestående genstande. Afprøv ProRes RAW og SSD på telefonen. Rumlig video kan afspilles i 3D. Et Office man kan gå rundt i kræver en 3D-scene.
3. **Knapper.** Vælg **Tal med Harper** på Action Button. Brug Camera Control i Faded Camera og et synligt agentvalg i appen. Afprøv lille vibration ved færdigt svar, færdig video og fejl.
4. **Skærm.** Video og Code Bot har allerede Live Activity. Byg videre med joblink, fremdrift, sidste opdatering og eventuelt StandBy, widget og Apple Watch. Brug senest kendte status ved ren lokal drift og mål jævn scrolling på telefonen.
5. **Forbindelse.** QR og privat Wi‑Fi/Tailscale er grundlaget. Test NFC som Office-genvej, SSD til store klip og lokalt lys via kompatibelt Apple Home-udstyr. UWB kræver kompatibelt udstyr. Satellit er en Apple-tjeneste.
6. **Sensorer.** LiDAR først, TrueDepth til Harper efter mundsynkronisering. Bevægelsesgenveje og ørelyd kan prøves som valg. Brug direkte låseknap til Privat Studio. Kompas kan orientere et AR-kort, og barometer giver ændring i højde.
7. **Lyd.** Behold den foretrukne danske stemme, og gør det let at høre en prøve. Prøv klarere mikrofoninput og derefter positioneret lyd. Kokoro er et valg til understøttede sprog.
8. **Systemgenveje.** Byg videre på genvejene til Chat og Video med **Tal med Harper**, **Åbn Landsbyen** og **Lav videokladde**. Prøv åbning fra Siri og Spotlight, en genvej til kamera i Kontrolcenter og en frivillig morgenrutine, der kan lægge et job i kø.

## Grænser på tværs

- Hold standardfunktioner brugbare lokalt uden AI-nøgle. PC-forbindelsen bruger privat net eller Tailscale. Claude er valgfri.
- Spotify-metadata vises kun i brugerfladen. Google Photos vælges via Picker. Hold private sessionsdata ude af fælles søgning, jobstatus og almindeligt galleri.
- Genbrug danske tekster, maskot, glas og de aftalte farver. Brug gradient på kort, knapper og HUD. Baggrunden får tekstur, og Office får hårde skygger.
