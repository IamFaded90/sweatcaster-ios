# FadedAI · Hvad mangler vi?

Arbejdslisten følger forsøgsgrenen `codex/fadedai-repo-pilot`. Brug den før et nyt build, og sæt først flueben ved en test, når den er kørt. **I koden** betyder, at ændringen findes på grenen. **I gang** betyder, at der arbejdes på den. **Åben** betyder, at den stadig skal bygges eller afklares.

## Afgrænsning bekræftet 16. november

Brugeren ønsker **alle resterende punkter på den gemte liste, inklusive de 37 projekter, plus de nye links og rettelser**. Allerede færdige funktioner skal ikke bygges igen. De fire nye prioriteter er PocketPal, Lottie, CrewAI og Godot. Bedre løsninger må erstatte overlappende løsninger, men før en udskiftning skal brugeren have besked om hvad, hvorfor og konsekvensen. Nye knapper, afhængigheder og undersøgelser tæller ikke som færdige integrationer.

- PocketPal: `PhoneMemoryBudget.swift` adapterer den konservative hukommelsesvurdering fra `useMemoryCheck.ts`; en stram vurdering er en advarsel, mens OS-råderummet forbliver den faktiske grænse. GGUF-listen og indlæsning bruger den. MIT-notice medfølger. Ikke bevis for at LFM2.5 eller billedgenerering er rettet.
- Lottie: version 4.6.1 tilføjet med en egen lokal prik-animation i agentchat og Lumi. Skjult/baggrund og reduceret bevægelse pauser animationen. Apache-licensen medfølger. Swift-syntaks og projektkontrol bestået; Xcode/telefon afventer.
- CrewAI: valgfri lokal forslag/gennemgang i `crew_proposals.py`, koblet til den eksisterende CodeBatch via `FADEDAI_CODE_BATCH_ENGINE=crewai`. Samme kø, modeladgang og manuelle godkendelse. CrewAI 1.15.41 er installeret i et isoleret testmiljø under `build/crewai-review`, **ikke** i den kørende PC-app. Fire nye enhedstests samt fem eksisterende kø/workflow-tests bestået. Den rigtige CrewAI-dispatcher er også prøvet med simulerede modelsvar, inklusive optaget model og afvisning af uautoriserede filstier. Rigtige modelresultater og deployment afventer.
- Godot: separat PC-projekt i `VillageGodot` med et hex-kort og en voxelvisning. Indlæs en eksport fra Office → Hex-kort for at se egne agenter. En kørt Godot 4.6.1-test kontrollerede indlæsning, begge kort og zoom. iPhone bruger sin egen Office-visning, hvor kirkegård, profiler og computere er tilgængelige gennem de eksisterende sider.
- Musik: fanen åbner Spotify-genvejen. Brugeren prøver Eevee selv. [ByTune](https://github.com/rishiteja21/ByTune) er gemt som mulighed til senere.

Ændringerne ligger lokalt på arbejdsgrenen. En del af punkterne har en fungerende del i koden og mangler stadig den test eller funktion, som står i tabellen. Ingen push eller IPA er startet.

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
- [ ] **Agent og dokumenter.** Vælg en PDF fra Filer i en almindelig agentchat, slå PC’en fra og spørg om noget i dokumentet. Se efter filnavn og sidetal. Prøv også en dansk oversættelse med en installeret telefonmodel, og brug global søgning med tastefejl og relaterede ord.
- [ ] **Office.** Prøv Scan mit værelse på iPhone med LiDAR, se USDZ-filen og flyt et møbel i layoutet. Åbn hex-kortet, prøv agent, computer og kirkegård, og indlæs derefter korteksporten i PC-projektet.
- [ ] **Kreativt Studio.** Opdatér PC-modulet, og åbn Generér video på PC. Afprøv tilgængelige modeller med tekst, et billede og eventuelt to billeder i rækkefølge. Gå tilbage med et job i gang, åbn siden igen og hent videoen. Afprøv en model, der mangler.
- [ ] **Code Bot.** Find en fil i et valgt repo, læs dens tekst, og opret et forslag med prioritet. Prøv Afvis. Godkend et andet gennemgået forslag med telefonens godkendelse.
- [ ] **Chief.** Åbn Opgaver → Planlæg med Chief. Lav en plan på telefonen, ret opgave, agent og prioritet, og genåbn kladden. Godkend afsendelse til PC’en. Afbryd forbindelsen midtvejs, og prøv samme afsendelse igen.
- [ ] **Privat Studio.** Gem en midlertidig Lumi-scene, og kontrollér, at den forsvinder efter fem minutter, mens appen er åben, eller ved næste åbning. Afprøv det lokale billede med en hentet model og se betingelserne for at starte.
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
| 3 | Kingfisher | **Delvis i koden.** Kingfisher 8.16.0 cacher agentportrætter i hukommelsen med placeholder og fade. Diskcache og galleri afventer. |
| 4 | SwiftAgent | **Delvis i koden.** Fælles typer for lokalt agentsvar og én lokal værktøjsrunde. Apple-modellen kan vælges gennem den eksisterende telefonmotor. Prøv på enheden. |
| 5 | AgentKit.swift | **Delvis i koden.** Telefon og PC bruger samme svarforløb. Telefonen streamer tekst, mens PC’en bruger den eksisterende modelrute. |
| 6 | SwiftMCP | **Delvis i koden.** JSON-RPC-værktøjsforløbet er lagt på den fælles, parrede PC-forbindelse via det officielle SDK. |
| 7 | Officielt MCP Swift SDK | **Delvis i koden.** Code Bot kan søge og læse kildefiler via MCP. Kodeforslag, billede og video har egne FadedAI-ruter. Der mangler MCP-værktøjer til dem. |
| 8 | VecturaKit | **Delvis i koden.** Lokal betydningssøgning i en agents valgte dokumenter efter vektorprincippet. Bruger Apples tilgængelige sprogmodeller. |
| 9 | LumoKit | **I koden.** Dokumenter opdeles ved afsnit, relevante passager vælges til et lokalt svar, og kilder vises med navn og PDF-side. Prøv PDF og TXT på telefonen. |
| 10 | Wax | **Delvis i koden.** Lumi-scener ligger i en beskyttet lokal fil med valg om sletning efter fem minutter. Den slettes under brug eller ved næste åbning. Wax-format og hybrid hukommelse afventer. |
| 11 | SQLiteVecKit | **Delvis i koden.** Global Søg kombinerer ordmatch, tastefejl og valgfri betydningssøgning. Swift-udgaven bruger BM25 og RRF uden en ny database. |
| 12 | Swift Google Drive Client | **Åben.** Direkte Drive som valg ved siden af Composio. Afhænger af login og en tilladelse til de relevante filer. |
| 13 | fuse-swift | **I koden.** Tastefejl som *Fornite* kan finde *Fortnite*. Prøv det i iPhone-appen. |
| 14 | SwiftResilience | **Delvis i koden.** iOS kan kalde den eksisterende PC-chatkø i baggrunden, når telefonens data er tilgængelige. Test afbrudt forbindelse, genstart og dubletter på telefonen. |
| 15 | mlx.promptcache | **Åben.** Genbrug modelinstruktioner, hvis en måling viser en forskel. Hold private sessioner adskilt. |
| 16 | Open-LLM-VTuber | **Delvis i koden.** Eksisterende landsbyfigurer har blink og mundbevægelse til oplæsning i agentchat og kortet. Harpers Live2D-model, rig og faktisk Live2D-integration er stadig åbne. Se `VILLAGE-VOICE-MOTION.md`. |
| 17 | avatar | **Åben.** VRM-visning til den talende agent. Afprøves som ekstra visning. |
| 18 | 3DSeen | **I koden.** Scan mit værelse bruger LiDAR via RoomPlan og gemmer en lokal USDZ. Prøv på en LiDAR-iPhone. |
| 19 | 3d-model-anything | **Delvis i koden.** Vis scanningen i 3D og flyt møbler i det gemte plantegningslayout. En fuld redigerbar 3D-scene med teksturer afventer. |
| 20 | Shap‑E | **Åben.** Lav en 3D-model fra tekst eller billede via PC’en, og vis den på iPhone. |
| 21 | TripoSG | **Åben.** Lav en detaljeret 3D-model fra et billede via samme Studio. |
| 22 | Auto-GPT | **I koden.** Chief deler målet op i konkrete opgaver via en model på iPhone. Brugeren gennemgår, retter og bekræfter, før opgaverne sendes. |
| 23 | OpenInterpreter | **Delvis i koden.** Code Bot viser ændringerne med Godkend og Afvis. Godkendelse kræver telefonens biometrik. Frie kodescripts er en separat åben opgave. |
| 24 | babyagi | **I koden.** Chief sender de godkendte opgaver til agenternes eksisterende PC-kø i prioritetsrækkefølge. Modtagne opgaver får kvitteringer, og genforsøg bruger samme opgave-id. Code Bot har separat prioritet og venteretfærdighed. |
| 25 | voxelcraft | **Delvis i koden.** Fritstående Godot-projekt bruger fBm til et terræn med bjerge og floder og kan indlæse en Office-eksport. |
| 26 | Matrix-Game | **Åben.** Generér en prøveverden fra et Office-billede på en kompatibel PC. |
| 27 | Oasis | **Åben.** Prøv en interaktiv verden, hvis der er en understøttet PC-motor. |
| 28 | Wan2.1 | **Delvis i koden.** Kreativt Studio kan sende en fast opskrift til PC’en fra tekst, billede eller start- og slutbillede. De særskilte modeller skal være installeret og afprøvet. |
| 29 | AnimateDiff | **Delvis i koden.** Kreativt Studio sender et valgt foto til en SD1.5- og AnimateDiff-opskrift, når ComfyUI rapporterer nødvendig model og udvidelse. Rendering afventer. |
| 30 | LTX-Video | **Delvis i koden.** Hurtig prøve fra tekst eller foto bruger LTX og dens tekstmodel på PC’en. Rendering afventer. |
| 31 | LiteReality-Agent | **Delvis i koden.** Møbler og agenter kan flyttes lokalt i layoutet fra en scan. Den interaktive 3D-visning afventer. |
| 32 | HexEngine | **Delvis i koden.** Office har eget hex-kort med papirkort, hårde skygger og genveje til profiler, computere og kirkegård. Prøv iPhone-navigation og kontrol med zoom. |
| 33 | GameOfLife-Swift | **Åben.** Kilde-URL mangler. Behold den nuværende tidsmotor, mens behov, jobs og de fire foreslåede epoker afprøves. |
| 34 | isowords | **Åben.** Saml visningens tilstand og gemning, med genåbning af eksisterende landsbyer som test. |
| 35 | moonshine-mlx | **Åben.** Eksisterende diktering har nu særskilt dansk/engelsk valg, hjælpeord og valgfri håndfri ventepause. Moonshine-motoren og måling af dansk afventer. |
| 36 | swift-parakeet-mlx | **Delvis i koden.** Den eksisterende Whisper-motor viser nu segmenter med tidsmærker. Parakeet og identifikation af talere afventer. |
| 37 | ihunyuan | **Delvis i koden.** Dansk oversættelse bruger en valgt, installeret telefonmodel. Hunyuan angiver ikke dansk som understøttet. |

Videovalgene er afledt af [ComfyUI's LTX-opskrift](https://comfyanonymous.github.io/ComfyUI_examples/ltxv/), [Wan 2.1](https://comfyanonymous.github.io/ComfyUI_examples/wan/) og [AnimateDiff Evolved](https://github.com/Kosinkadink/ComfyUI-AnimateDiff-Evolved/blob/main/documentation/nodes/README.md). Appen viser manglende modeller, og PC’en afviser jobs, hvis de mangler. De valgte billeder sendes kun til den parrede PC og gemmes midlertidigt af ComfyUI. Resultatet kan hentes fra seneste job i appen og ligger i ComfyUI's outputmappe.

**Kontrolleret på arbejdsgrenen.** 14 PC-tests bestået for Code Bot, søgning, CrewAI og videogenerering med testdata. MCP-forbindelsen listede værktøjer, søgte og læste en fil i et isoleret miljø. Godot bestod korttesten. Xcode-projektkontrollen og syntakskontrollen af de berørte Swift-filer bestod. På den kørende ComfyUI er MP4-eksport tilgængelig. Videovalgene mangler stadig deres særskilte modeller eller udvidelser. Mac-kompilering, ContractTests, rigtig rendering og iPhone- og Chromecast-prøver afventer.

## MAX på iPhone 17 Pro Max

1. **Lokal AI.** Start med Apples lokale model til dansk chat og billedanalyse, hvor funktionen er tilgængelig på telefonen. Mål svarstart, varme og batteri før endnu en model tilføjes. MiniCPM5 er i kataloget, men dets nuværende pakke mangler en motor i appen. Flash‑MoE er et forsøg til senere, og store video- og 3D-opgaver bliver på PC.
2. **Kamera.** LiDAR til Office først. Derefter Log 2-farvebehandling med bevaret original, genkendelse af genstande, Manga fra referencefoto og Object Capture af stillestående genstande. Afprøv ProRes RAW og SSD på telefonen. Rumlig video kan afspilles i 3D. Et Office man kan gå rundt i kræver en 3D-scene.
3. **Knapper.** Vælg **Tal med Harper** på Action Button. Brug Camera Control i Faded Camera og et synligt agentvalg i appen. Afprøv lille vibration ved færdigt svar, færdig video og fejl.
4. **Skærm.** Video og Code Bot har allerede Live Activity. Byg videre med joblink, fremdrift, sidste opdatering og eventuelt StandBy, widget og Apple Watch. Brug senest kendte status ved ren lokal drift og mål jævn scrolling på telefonen.
5. **Forbindelse.** QR og privat Wi‑Fi/Tailscale er grundlaget. Test NFC som Office-genvej, SSD til store klip og lokalt lys via kompatibelt Apple Home-udstyr. UWB kræver kompatibelt udstyr. Satellit er en Apple-tjeneste.
6. **Sensorer.** LiDAR først, TrueDepth til Harper efter mundsynkronisering. Bevægelsesgenveje og ørelyd kan prøves som valg. Brug direkte låseknap til Privat Studio. Kompas kan orientere et AR-kort, og barometer giver ændring i højde.
7. **Lyd.** Behold den foretrukne danske stemme, og gør det let at høre en prøve. Prøv klarere mikrofoninput og derefter positioneret lyd. Kokoro er et valg til understøttede sprog.
8. **Systemgenveje.** **Tal med Harper**, **Åbn Landsbyen** og **Lav videokladde** er i koden. Test via Genveje eller Siri. Kamera i Kontrolcenter og en frivillig morgenrutine er åbne.

## Grænser på tværs

- Hold standardfunktioner brugbare lokalt uden AI-nøgle. PC-forbindelsen bruger privat net eller Tailscale. Claude er valgfri.
- Spotify-metadata vises kun i brugerfladen. Google Photos vælges via Picker. Hold private sessionsdata ude af fælles søgning, jobstatus og almindeligt galleri.
- Genbrug danske tekster, maskot, glas og de aftalte farver. Brug gradient på kort, knapper og HUD. Baggrunden får tekstur, og Office får hårde skygger.
