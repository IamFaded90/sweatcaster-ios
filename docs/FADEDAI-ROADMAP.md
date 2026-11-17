# FadedAI · Hvad mangler vi?

Arbejdslisten følger forsøgsgrenen `codex/fadedai-repo-pilot`. Brug den før et nyt build, og sæt først flueben ved en test, når den er kørt. **I koden** betyder, at ændringen findes på grenen. **I gang** betyder, at der arbejdes på den. **Åben** betyder, at den stadig skal bygges eller afklares.

## Afgrænsning bekræftet 16. november

Seneste lokale designarbejde: [ny landsbypakke, 5 mænd + 5 kvinder, alle rum og kirkegård](village-art/FINAL-INTEGRATION.md). Figurvalg gemmes særskilt fra profilfoto. De indbyggede Cubism-portrætter af originale Harper og nyeste Lumi bestod simulatorprøven med rigtig oplæsning, blink og åndedrætsbevægelse samtidig. Prøven på fysisk iPhone, VRM og komplet håndtegnet figuranimation står stadig åbne.

Den gamle liste med 37 projekter er stadig et arbejdsgrundlag. Den næste samlede IPA skal have dansk offline-diktering og VRM med, efter lokal prøve. Matrix-Game og Oasis er udskudt efter brugerens valg, og TripoSG udelades. Allerede færdige funktioner skal ikke bygges igen. Bedre løsninger må erstatte overlappende løsninger, men før en udskiftning får brugeren besked om hvad, hvorfor og konsekvensen. Nye knapper, afhængigheder og undersøgelser tæller ikke som færdige integrationer.

- PocketPal: `PhoneMemoryBudget.swift` adapterer den konservative hukommelsesvurdering fra `useMemoryCheck.ts`; en stram vurdering er en advarsel, mens OS-råderummet forbliver den faktiske grænse. GGUF-listen og indlæsning bruger den. MIT-notice medfølger. Ikke bevis for at LFM2.5 eller billedgenerering er rettet.
- Lottie: version 4.6.1 tilføjet med en egen lokal prik-animation i agentchat og Lumi. Skjult/baggrund og reduceret bevægelse pauser animationen. Apache-licensen medfølger. Swift-syntaks og projektkontrol bestået; Xcode/telefon afventer.
- CrewAI: det lokale agenthold er aktivt i Windows-genvejen og kører i en separat Python-proces under `build/crewai-review`. Den eksisterende Code Bot-kø, adgang til Ollama og brugergodkendelse styres stadig af FadedAI. Den installerede Code Bot-kode tog et privat testjob fra kø til godkendelse med to svar fra den lokale model. Ingen kildefil blev ændret. Den separate proces bestod også prøver for optaget model og stier uden for opgaven. Hvis holdet ikke kan starte, kan Code Bot stadig lave et almindeligt forslag. Lad mappen `build/crewai-review` ligge, da Windows-genvejen bruger den.
- Godot: separat PC-projekt i `VillageGodot` med et hex-kort og en voxelvisning. Indlæs en eksport fra Office → Hex-kort for at se egne agenter. En kørt Godot 4.6.1-test kontrollerede indlæsning, begge kort og zoom. iPhone bruger sin egen Office-visning, hvor kirkegård, profiler og computere er tilgængelige gennem de eksisterende sider.
- Musik: den officielle YouTube Music-side åbner i et browservindue i Musik-fanen. Fysiske iPhone-tests af åbning, afspilning og lukning afventer. ByTune har et separat link til Windows/Mac. Der er ingen ByTune-port til iPhone i denne ændring.

Ændringerne ligger lokalt på arbejdsgrenen. Den samlede usignerede iPhone-IPA 2611.17.12 blev bygget i Limrun med Xcode 26.4. Den hentede pakke bestod integritets-, ressource- og arm64-kontrol. Der blev ikke pushet.

Sletknapper er tilføjet ved genererede billeder, videoer og 3D-modeller samt de hentede modeller og lokale Git-kopier, der manglede sletning. PC-opdateringen blev startet med tomme køer. En sammenlagt lokal suite gav 150 beståede PC-tests, og de fem nye ruter blev kontrolleret med prøvedata efter genstart. Delingskopier uden for FadedAI og ældre Lumi-videoer uden en sikker jobkobling berøres ikke.

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
- [ ] **Før installering.** Kør ContractTests med Xcode, og kontrollér den signerede IPA. Pakkechecket afviser simulatorens binær, et Live Activity-widget med forkert version og manglende filer til Landsbyen eller Underholdning. Bekræft iPhone-funktioner på rigtig telefon og Cast på Chromecast, før de markeres som testet. Behold filnavne, eksisterende datafelter, indstillinger og forbindelser. Højst 600 linjer pr. berørt Swift-fil.

## Koden fra før forsøget

- **PocketPal 1–6, i koden.** GGUF på iPhone med import fra Filer, download og genoptagelse, lager- og hukommelsestjek, modelvalg, favoritter og sletning.
- **PocketPal 7–17, i koden.** Agentens modelvalg og modelnavn på svar, agentskabeloner, redigering og nyt svar, vågen skærm, Whisper, håndfri samtale og stemmevalg, regne- og datoværktøjer, offentlige webkilder, svarkort og deling af iPhone-model på Wi‑Fi. Test med iPhone, og test PC-funktionerne igen med den opdaterede PC-del.
- **Underholdning, i koden.** CastBrowser åbner som en del af FadedAI med browser, favoritter, kø og fjernbetjening. Favoritter og historik hører til denne installation. Det gamle filmbibliotekslink er erstattet af Underholdning. Afspilning på iPhone og Chromecast skal prøves på udstyr.
- **Tidligere fejl, som skal fanges igen.** PC-modellernes billedgenerering fra Chat og Privat Studio, download når skærmen slukkes, videokommentarer som passer til hændelsen, oprydning i gamle jobkort, Adam og Evas PC-status og genoprettelse efter genstart. Talegenkendelse og stemmer prøves med samme danske tekst hver gang.
- **Agenternes hverdag.** Prøv egne skriveborde, jobs og filer for flere agenter samt opstart efter Windows-genstart. Prøv Composio og den delte Vault med én godkendt opgave, kalender, påmindelse, alarm og Gmail. Kontrollér, at opgaven kan bruge en tilladelse, uden at adgangskoden vises i chatten.
- **Composio prøvet på PC.** Reelle læsekald bestod for Drive, Sheets, Notion og GitHub. Sheets bruger det godkendte Drive-login. Gmail bruger ejerens eksisterende Composio For You-forbindelse, og PC-testen hentede en rigtig liste og læste én valgt mail. Nøglerne gemmes i Windows' beskyttede lager. Søgning, forhåndsvisning og kladde har egne visninger. Ved afsendelse vises kladden, og iPhones systemgodkendelse kræves. Afsendelse og beskyttelse mod dobbelt afsendelse blev prøvet med en lokal testmodtager i testkoden. En rigtig afsendelse og iPhone-test afventer.
- **Landsbyen og Studie.** Behold kirkegården og adskillelsen af profilfoto og landsbyfigur. Prøv zoom og lås på kortet. Test billede fra Chat og referencebillede i Privat Studio på telefon og PC. Kontrollér Lumi-ruten og brugerens foretrukne stemme. Prøv et tydeligt dobbelt kill i Fortnite og et klip fra The Finals, så kommentarerne kan vurderes mod det, der faktisk sker.

## De 37 GitHub-punkter

| Nr. | Kilde | Status og næste skridt |
| --- | --- | --- |
| 1 | swift-chat | **Delvis i koden.** Liquid Glass og farvede chatbobler. Test eksisterende composer, Markdown og streaming. |
| 2 | QRCameraKit | **Delvis i koden.** Scanramme, lommelygte, autofokus og vibration. Prøv kamera og gyldig/udløbet kode på iPhone. |
| 3 | Kingfisher | **Delvis i koden.** Almindelige agentportrætter bruger nu Kingfisher-hukommelse og en beskyttet diskcache på 4 MB med syv dages udløb. Cacheposter fjernes ved ændring og sletning. Lumi bruger kun hukommelse. Logikken er prøvet lokalt. iPhone-prøve og galleri afventer. |
| 4 | SwiftAgent | **Delvis i koden.** Fælles typer for lokalt agentsvar og én lokal værktøjsrunde. Apple-modellen kan vælges gennem den eksisterende telefonmotor. Prøv på enheden. |
| 5 | AgentKit.swift | **Delvis i koden.** Telefon og PC bruger samme svarforløb. Telefonen streamer tekst, mens PC’en bruger den eksisterende modelrute. |
| 6 | SwiftMCP | **Delvis i koden.** JSON-RPC-værktøjsforløbet er lagt på den fælles, parrede PC-forbindelse via det officielle SDK. |
| 7 | Officielt MCP Swift SDK | **I koden.** Parrede MCP-klienter kan søge og læse kildefiler, oprette kodeforslag, generere PNG og starte samt følge et tekstbaseret videojob. Almindelig agentchat har genveje til de tre PC-værktøjer via eksisterende FadedAI-ruter. Kodeforslag kræver stadig gennemgang i Code Bot. Adgang og værktøjskald er prøvet med testdata på PC. Prøv rigtige genereringer og visninger på iPhone. |
| 8 | VecturaKit | **Delvis i koden.** Lokal betydningssøgning i en agents valgte dokumenter efter vektorprincippet. Bruger Apples tilgængelige sprogmodeller. |
| 9 | LumoKit | **I koden.** Dokumenter opdeles ved afsnit, relevante passager vælges til et lokalt svar, og kilder vises med navn og PDF-side. Prøv PDF og TXT på telefonen. |
| 10 | Wax | **Delvis i koden.** Flygtige Lumi-scener slettes automatisk efter fem minutter, også mens scenen ses. Senere svar kan ikke genskabe den. Midlertidige billeder og videoer skrives i appens beskyttede lager og ryddes ved lukning. Swift-prøver bestod lokalt. Wax-format, hybrid hukommelse og iPhone-prøve afventer. |
| 11 | SQLiteVecKit | **Delvis i koden.** Global Søg kombinerer ordmatch, tastefejl og valgfri betydningssøgning. Swift-udgaven bruger BM25 og RRF uden en ny database. |
| 12 | Swift Google Drive Client | **Prøvet på PC gennem Composio.** Det godkendte Drive-login gav dokumentliste og forhåndsvisning og kunne også læse en afgrænset visning af et regneark. Den direkte Drive-forbindelse står fortsat i koden. iPhone-prøve afventer. |
| 13 | fuse-swift | **I koden.** Tastefejl som *Fornite* kan finde *Fortnite*. Prøv det i iPhone-appen. |
| 14 | SwiftResilience | **Delvis i koden.** PC-chatkøen planlægger sig igen, hvis iOS afbryder et forsøg, før beskeden er sendt. Et forsøg med usikkert resultat gennemgås stadig manuelt for at undgå dubletter. Lokale Swift-prøver dækkede afbrydelse, vellykket svar og privat tilstand. Prøv låst skærm, afbrudt forbindelse og genstart på iPhone. |
| 15 | mlx.promptcache | **Åben.** Genbrug modelinstruktioner, hvis en måling viser en forskel. Hold private sessioner adskilt. |
| 16 | Open-LLM-VTuber | **I koden og simulatorprøvet.** Originale Harper og nyeste Lumi har indbyggede Cubism-rigs. Den fokuserede prøve dækkede rigtig oplæsning, blink og åndedræt samtidig. Prøv portrætknappen i agentchat på iPhone. |
| 17 | avatar | **Bygget og prøvet lokalt.** Harper og Lumi har hver et drejeligt 3D-portræt bygget af deres eksisterende udtryk. De kan blinke, tale og ånde samtidig. Portrætterne har dybde og kan ses skråt fra fronten. Orbit og import af en selvstændig VRM-fil pr. agent er stadig tilgængelige. VRM 1.0, VRM 0.0 og begge portrætter er prøvet i afspilleren på PC. Live2D-portrætterne er bevaret. WebKit og rigtig oplæsning i 3D-visningen skal prøves på iPhone. |
| 18 | 3DSeen | **I koden.** Scan mit værelse bruger LiDAR via RoomPlan og gemmer en lokal USDZ. Prøv på en LiDAR-iPhone. |
| 19 | 3d-model-anything | **Delvis i koden og prøvet på PC.** Eksportér en målt plantegning fra Office og åbn den i Godot. Prøven med en Swift-genereret fil dækkede bevægelse, møbelkollision, drejning og tilbage til landsbyen. Den originale USDZ kan stadig vises separat. Delingsark og LiDAR på iPhone, fototeksturer og AI-rekonstruktion afventer. |
| 20 | Shap‑E | **Prøvet og aktiveret på PC.** En rigtig tekstbeskrivelse gav OBJ og USDZ. Et rigtigt referencebillede gik gennem den parrede testrute, jobkøen og USDZ-downloaden. Den kørende Windows-installation blev genstartet og meldte klar til begge funktioner via sin parrede forbindelse. Lad mappen `build/pc-3d-engines` ligge, da Windows-genvejen bruger den. Prøve fra iPhone afventer. |
| 21 | TripoSG | **Udgår efter brugerens valg.** Kreativt Studio tilbyder Shap-E fra tekst eller referencebillede. |
| 22 | Auto-GPT | **I koden.** Chief deler målet op i konkrete opgaver via en model på iPhone. Brugeren gennemgår, retter og bekræfter, før opgaverne sendes. |
| 23 | OpenInterpreter | **Delvis i koden.** Code Bot viser ændringerne med Godkend og Afvis. Godkendelse kræver telefonens biometrik. Frie kodescripts er en separat åben opgave. |
| 24 | babyagi | **I koden.** Chief sender de godkendte opgaver til agenternes eksisterende PC-kø i prioritetsrækkefølge. Modtagne opgaver får kvitteringer, og genforsøg bruger samme opgave-id. Code Bot har separat prioritet og venteretfærdighed. |
| 25 | voxelcraft | **Delvis i koden.** Fritstående Godot-projekt bruger fBm til et terræn med bjerge og floder og kan indlæse en Office-eksport. |
| 26 | Matrix-Game | **Udskudt efter brugerens valg.** Den officielle 2.0-opsætning er testet under Linux med mindst 24 GB på grafikkortet. Denne Windows-PC har 8 GB. Kontorets lokale Godot-visning kan bruges separat. [Matrix-Game 2.0](https://github.com/SkyworkAI/Matrix-Game/tree/main/Matrix-Game-2#requirements) |
| 27 | Oasis | **Udskudt efter brugerens valg.** De officielle vægte kræver brugerlogin og accept af adgangsvilkår. En reel interaktiv forbindelse til FadedAI skal stadig bygges og måles på en kompatibel PC. [Oasis-modellen](https://huggingface.co/Etched/oasis-500m) |
| 28 | Wan2.1 | **Alle tre Studio-valg prøvet på PC.** Wan VACE 1,3B bruges på denne PC, når de større 14B-modeller mangler. Tekst, ét billede og start/slut gav hver en H.264-MP4 på 512 × 288 med 17 billeder, som FFmpeg kunne afkode. Begge endebilleder var genkendelige. Midt i overgangen var der en synlig dobbelteffekt. Lumis tidligere model og de store opskrifter er bevaret. Prøve fra iPhone afventer. |
| 29 | AnimateDiff | **Prøvet på PC.** Kreativt Studio fandt den lokale AnimateDiff-motor og brugte et rigtigt referencebillede i den parrede rute. Jobstatus blev fulgt til færdig, og den hentede H.264-MP4 på 512 × 320 med 16 billeder kunne afkodes uden fejl. Prøve fra iPhone afventer. |
| 30 | LTX-Video | **Tekst og referencebillede prøvet på PC.** De lokale LTX-filer bestod SHA-256-kontrol. Begge prøver gav en H.264-MP4 på 512 × 320 med 25 billeder via den parrede Studio-rute. FFmpeg afkodede alle billederne, og referencens lampe var synlig i første, midterste og sidste billede. Den kørende Windows-installation melder begge valg klar. Prøve fra iPhone afventer. |
| 31 | LiteReality-Agent | **Delvis i koden.** Vælg møbler og bots i den lokale 3D-visning, flyt og drej dem, og behold ændringerne i samme layout som plantegningen. Prøves på en iPhone med et scannet rum. |
| 32 | HexEngine | **Delvis i koden.** Office har eget hex-kort med papirkort, hårde skygger og genveje til profiler, computere og kirkegård. Prøv iPhone-navigation og kontrol med zoom. |
| 33 | [Life](https://github.com/zntfdr/Life/) | **I koden og prøvet lokalt.** Livshaven under Kontoret bruger Conways regler med eget gemt bræt, næste trin, start og pause. De to Swift-tests af spilleregler og genindlæsning bestod på PC’en. Landsbyens tidsmotor styrer fortsat behov og jobs. iPhone-prøven afventer. |
| 34 | isowords | **Delvis i koden.** Landsbyens pause gemmes med den eksisterende tilstand. En lokal Swift-prøve dækkede genåbning, tid i pause og ældre gemt data. Almindelig agentchat viser aktivitet i landsbyen og registrerer det sociale samvær ved et gennemført svar. Samling af visningstilstanden og iPhone-prøve afventer. |
| 35 | moonshine-mlx | **Dansk diktering forbedret med Whisper.** Vælg den dansktilpassede model og hent den én gang på 264 MB. Den kører derefter lokalt. På otte danske FLEURS-klip gav modellen 12 ordafvigelser mod 65 for tidligere Small, målt på 174 ord. På fire syntetiske kommandoer gav den 0 mod 7, målt på 29 ord. Modellen bruges til dansk tekst, og de flersprogede modeller er stadig tilgængelige. Mikrofontest på iPhone afventer. [Modellen](https://huggingface.co/thorhojhus/whisper-small-danish) · [FLEURS](https://huggingface.co/datasets/google/fleurs) |
| 36 | swift-parakeet-mlx | **Delvis i koden.** Den eksisterende Whisper-motor viser segmenter med tidsmærker. Parakeet v3 har dansk og en Core ML-variant til iOS 18. Indlæsning, svartid og identifikation af talere afventer. [Parakeet v3](https://huggingface.co/nvidia/parakeet-tdt-0.6b-v3) · [Parakeet Redux](https://github.com/FluidInference/FluidAudio/blob/main/Documentation/ASR/ParakeetRedux.md) |
| 37 | ihunyuan | **Delvis i koden.** Dansk oversættelse bruger en valgt, installeret telefonmodel. Hunyuan angiver ikke dansk som understøttet. |

Videovalgene er afledt af [ComfyUI's LTX-opskrift](https://comfyanonymous.github.io/ComfyUI_examples/ltxv/), [Wan 2.1](https://comfyanonymous.github.io/ComfyUI_examples/wan/) og [AnimateDiff Evolved](https://github.com/Kosinkadink/ComfyUI-AnimateDiff-Evolved/blob/main/documentation/nodes/README.md). Appen viser manglende modeller, og PC’en afviser jobs, hvis de mangler. De valgte billeder sendes kun til den parrede PC og gemmes midlertidigt af ComfyUI. Resultatet kan hentes fra seneste job i appen og ligger i ComfyUI's outputmappe.

**Kontrolleret på arbejdsgrenen.** 146 automatiske PC-tests bestod. Godot bestod landsby- og kontorprøverne, og kontrollen af landsbyens grafik fandt alle 10 figurer. Tidligere lokale billed-, Lumi-Wan- og LTX-prøver gav rigtige mediefiler. De tre nye Wan-prøver gav hver en H.264-MP4, som FFmpeg kunne afkode. Efter genstart meldte den kørende PC-app alle seks videoindstillinger samt 3D, agenthold og Gmail klar. Xcode-projektkontrol og Swift-syntakskontrol bestod. IPA-kontrollen er prøvet på testpakker med og uden pakkefejl. Mac-kompilering, ContractTests, en signeret IPA og iPhone- og Chromecast-prøver afventer.

## MAX på iPhone 17 Pro Max

1. **Lokal AI.** Start med Apples lokale model til dansk chat og billedanalyse, hvor funktionen er tilgængelig på telefonen. Mål svarstart, varme og batteri før endnu en model tilføjes. MiniCPM5 er i kataloget, men dets nuværende pakke mangler en motor i appen. Flash‑MoE er et forsøg til senere, og store video- og 3D-opgaver bliver på PC.
2. **Kamera.** LiDAR til Office først. Derefter Log 2-farvebehandling med bevaret original, genkendelse af genstande, Manga fra referencefoto og Object Capture af stillestående genstande. Afprøv ProRes RAW og SSD på telefonen. Rumlig video kan afspilles i 3D. Et Office man kan gå rundt i kræver en 3D-scene.
3. **Knapper.** Vælg **Tal med Harper** på Action Button. Brug Camera Control i Faded Camera og et synligt agentvalg i appen. Afprøv lille vibration ved færdigt svar, færdig video og fejl.
4. **Skærm.** Video og Code Bot har allerede Live Activity. Byg videre med joblink, fremdrift, sidste opdatering og eventuelt StandBy, widget og Apple Watch. Brug senest kendte status ved ren lokal drift og mål jævn scrolling på telefonen.
5. **Forbindelse.** QR og privat Wi‑Fi/Tailscale er grundlaget. Test NFC som Office-genvej, SSD til store klip og lokalt lys via kompatibelt Apple Home-udstyr. UWB kræver kompatibelt udstyr. Satellit er en Apple-tjeneste.
6. **Sensorer.** LiDAR først, TrueDepth til Harper efter mundsynkronisering. Bevægelsesgenveje og ørelyd kan prøves som valg. Brug direkte låseknap til Privat Studio. Kompas kan orientere et AR-kort, og barometer giver ændring i højde.
7. **Lyd.** Dansk stemme og stemmeprøve på iPhone. Kokoro er tilføjet til agentchat med Heart og Michael som engelsk oplæsning på den parrede PC. Begge stemmer bestod en lokal prøve gennem chat-API’et med rigtig lyd. Afprøv afspilningen fra iPhone. Positioneret lyd og de alternative dikteringsmotorer står stadig åbne.
8. **Systemgenveje.** **Tal med Harper**, **Åbn Landsbyen**, **Lav videokladde** og **Åbn kamera** er i koden. Kameraets knap i Kontrolcenter åbner den samme lokale optagelsesside som Kreativt Studio. Prøv på iPhone. Morgenrutinen står stadig åben.

## Grænser på tværs

- Hold standardfunktioner brugbare lokalt uden AI-nøgle. PC-forbindelsen bruger privat net eller Tailscale. Claude er valgfri.
- Spotify-metadata vises kun i brugerfladen. Google Photos vælges via Picker. Hold private sessionsdata ude af fælles søgning, jobstatus og almindeligt galleri.
- Genbrug danske tekster, maskot, glas og de aftalte farver. Brug gradient på kort, knapper og HUD. Baggrunden får tekstur, og Office får hårde skygger.


## OpenRouter efter build 67, 17. november 2026

- Gemma 4 31B, North Mini Code og automatisk gratisvalg er tilføjet til normal chat og agenternes cloudvalg. Forbindelsen kan gemmes på iPhone via den parrede PC og bruges over internet med PC’en slukket.
- OpenRouter-nøglen er gemt krypteret på PC’en. Appen gemmer sin kopi i Keychain. Modelvalget begrænses til de tre gratis model-id’er, og API-kald har et prisloft på nul. Automatisk gratisvalg viser den faktiske model fra svaret.
- North Mini Code og automatisk gratisvalg svarede korrekt gennem Swift-klienten. OpenRouter rapporterede pris 0 i API-testen. Begge gratis Gemma 4-varianter blev afvist med midlertidig 429 hos udbyderen. Gemma 4 afventer en vellykket svartest.
- PC-opdateringen er installeret. OpenRouter-overførsel kræver parring og har Cache-Control no-store. 12 lokale regressionstests bestod. Xcode-projektkontrol og Swift-syntakskontrol bestod.
- Efter brugerens godkendelse er commit 2fa36b307cd292dd1e1729e0f04fd4c7feb304fe pushet til codex/ipa-fadedai-complete-20261117. GitHub-bygning 72 har bestået Release XCTest i simulatoren og bygger nu iPhone-appen. IPA og fysisk iPhone-test afventer. Limrun bruges ikke; kontoen har ingen credits.


## Musikvalg, bekræftet 17. november efter push til bygning 72

Spotube er valgt som grundlag for den næste Musik-ændring. Målet er afspilning inde i FadedAI, playlister, kø og lyd ved låst skærm. **Rettet kildekontrol:** Spotube 6.0 har en fuld iPhone-udgave med NewPipe KMP og MobileVLCKit; den findes i både koden og releases. Den skal bruges som grundlag for iPhone-tilpasningen. Prototypen, kilder, testresultater og resterende arbejde er samlet i integrations/spotube-prototype/README.md. Den tilpassede Swift-kø er prøvet lokalt. Native afspilning og integration af iOS-kilden afventer. Bygning 72 blev startet før dette valg og indeholder den eksisterende musikløsning. Kilde: https://github.com/team-spotube/spotube/releases/tag/v6.0.0


## Nemotron-opgaver, næste gren efter bygning 72

- Nemotron Ultra og Lightning er tilføjet som eksplicitte gratisvalg via OpenRouter til agentchat og botcomputernes opgaver. Lokal PC er fortsat standard. Begge gratis-id’er svarede korrekt med rapporteret pris 0; Lightning gennemførte også den rigtige opgavekø. Ultras opgavetest fik efterfølgende HTTP 503 fra udbyderen; genprøves senere. Ingen betalt NVIDIA-test er udført.
- Valgt model gemmes med opgaven, vises på resultatet og indgår i kontrollen mod dobbeltopgaver. Ældre lokale opgaver bevarer deres adfærd. Ingen automatisk overgang til en betalt model. Cloudvalg viser, at opgave og eventuelle vedhæftninger sendes til OpenRouter.
- Cloudagenters svar bruger nu samme lokale værktøjsforløb som telefon- og PC-modellerne, inklusive verificeret værktøjsresultat og faktisk OpenRouter-modelnavn.
- 21 lokale Python-tests bestod, én eksisterende Docker-integrationstest blev sprunget over. Swift-test med selve AgentReplyDriver bestod værktøjsrunde, historik, instruktioner, modelnavn og fallback til verificeret værktøjsresultat. Swift-syntaks og Xcode-projektreferencer er kontrolleret. Ændringerne er ikke i den allerede startede bygning 72.

- PC-opdateringen til Nemotron-opgaver er installeret med sikkerhedskopi og genstart uden aktive jobs. Sundhedstjek bestod. Opgavemodellisten kræver parring (401 uden, 200 med), svarer no-store og afviser betalte model-id’er med 422. Appens nye modelvælger afventer næste IPA; den allerede startede bygning 72 ændres ikke.
