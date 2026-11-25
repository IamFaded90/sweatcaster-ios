# FadedAI · De næste fem oplevelser

Godkendt 24. november 2026. Arbejdes igennem i denne rækkefølge.
Alle aftalte kodepunkter skal være færdige, før den samlede fejlgennemgang
og de lokale test køres. Først når de fundne fejl er rettet og prøvet igen,
må et push starte et IPA-build. En fejl i et tidligere GitHub-build ændrer
ikke rækkefølgen. Brugeren følger selv kørslen på GitHub.
Nedenstående tidsstemplede noter er historiske. Build 94 blev startet efter
kodegennemgangen og fejlede under Apple-kompilering; rettelserne og den nye
faktiske PC-prøve er beskrevet i starten af SONG-STUDIO.md. En efterfølgende
Apple-kompilering og de fysiske iPhone-/TV-prøver er stadig nødvendige.

1. **Kodet, afventer lytteprøve på iPhone.** Egne sange, favorit som inspiration, remix fra lydfil og
   særskilt prøve med brugerens egen optagede stemme. Apple Personlig stemme
   er en oplæsningsstemme, ikke en dokumenteret eksportérbar sangmodel.
   Kræver også ægte lokal generation på iPhone med PC’en slukket.
   Korte genreønsker udvides med musikdetaljer, som kan ses og slås fra.
   ACE-Step 1.5 er beholdt, også som native 2B-kandidat. PC har lavet rigtig
   sang og remix. iPhone-vejen har modelhentning og valg af egen stemmeoptagelse.
   Reel lyd, lighed og RAM skal måles på telefonen. Se SONG-STUDIO.md.
2. **Kodet og lokalt kontrolleret:** Foto med markering, billedmodel/OCR-skelnen,
   netopslag fra telefon eller PC, mulige produktfund, Product/Offer-priser fra
   forhandleren, sammenligning pr. valuta og gemte favoritter pr. agent.
   Ingen modelopfundne priser eller automatisk køb. Fem nye Swift-prøver bestod.
   Markering, netværk og layout skal stadig prøves i den samlede iPhone-app.
3. **Kodet og lokalt kontrolleret:** Stemninger på landsbykortet, de fire
   bygningsrum og egne agentrum. Baggrund, lys, farver, lokal lyd, valgt musik,
   favoritter, 24 tidligere udgaver og gendannelse. Figurer og oprindeligt rum
   ændres ikke. Seks nye Swift-prøver bestod; rigtig lyd og layout afventer iPhone.
4. **Fravalgt af brugeren 25. november:** Personlige lydprogrammer udgår.
5. **Kodet og lokalt kontrolleret:** Sager pr. agent fra chatten og Fortsæt.
   Tilknyt en eksisterende, bekræftet Gmail-mail, læs faktiske svar i samme
   tråd, gem noter og vælg en frist med lokal påmindelse. Næste mail åbnes
   til gennemgang og dit Send-tryk. Afslutning kræver dit bekræftede resultat.
   PC-opfølgning overtager den allerede sendte mail uden at sende en kopi.
   Stop og slet gemmes til næste PC-forbindelse, også efter lokal sletning.
   Uden PC kontrolleres Gmail ved åbning eller manuelt, ikke uafbrudt i baggrunden.
   Seks nye Swift-prøver og 31 Python-prøver inklusive HTTP-ruter bestod.
   Rigtig kontotest, notifikationer og layout afventer iPhone.

Favoritvalg er ikke i sig selv adgang til en lydfil. Inspiration og remix
skal derfor være to særskilte valg. Et remix beholder originalen.
Egen sangstemme skal først høres i et kort prøveklip, før kvalitet vurderes.
Ingen personlige optagelser, mails, adgangsnøgler eller kontooplysninger
skal gemmes i Git.

## Kontrol 25. november

Punkt 2, 3 og 5 blev gennemgået i rækkefølge. 58 lokale Foundation/Swift-prøver
bestod samlet, og alle App/Tests-Swift-filer bestod syntakskontrol.
Xcode-projektets 808 objekter og nye kildefiler er kontrolleret.
Python-prøverne brugte falske Gmail-data; der er ikke sendt mail fra kontoen.
HTTP-prøven krævede adgang uden om Windows-sandboxens interne socketblokering.
Dette er ikke en fuld Apple-kompilering eller en fysisk iPhone-prøve.
PC-installationen er ikke opdateret, og der er ikke startet push eller IPA.
Musikpunktets native Apple-kompilering, enhedsprøve og egen sangstemme er
fortsat åbne som beskrevet i SONG-STUDIO.md.

## Valgt fra de efterfølgende forslag

Brugeren har valgt disse fire retninger og 25. november bestilt de anbefalede
integrationer nedenfor i rækkefølge. Ingen build eller push er bestilt.

- **Kamerahjælp med markeringer:** Agenten viser pile/cirkler på det billede,
  brugeren ser, og kan fortsætte efter næste foto.
- **Gemte værker i landsbyen:** Sang på anlægget, cover på væggen og projekt
  i værkstedet. Genstanden genåbner det konkrete gemte arbejde.
- **Agentbrowser på iPhone:** Arbejde i en indbygget browser over telefonens
  internet, uden PC. Undersøg [Gepetto](https://github.com/haplollc/Gepetto).
- **Egne stemmer fra optagelse:** Undersøg
  [ChatterboxCoreML](https://github.com/iliasaz/chatterbox-coreml) med dansk,
  lokal syntese og agentens eget stemmevalg. Kvalitet/RAM skal prøves på iPhone.

Serie, holdopkald, producerbord, genererede minispil, lærte arbejdsmetoder,
sanggenkendelse, agentopkald, fotoatelier og visuel hukommelse er ikke valgt
fra disse forslagsrunder. Lokal 3D fra foto blev undersøgt, men er ikke valgt.
FLUX-prøven med æblet lykkedes allerede på brugerens iPhone: 1024 × 1024,
70,3 sekunder. Den eksisterende lokale billedmotor skal bevares.

## Gennemgang af brugerens 40 projektforslag · 25. november

A henviser til første liste på 20, B til anden liste. Seks projekter gentages,
så der er 34 forskellige navne. Dette er en vurdering af kilder og udvalgte
pakke-/kodegrænser, ikke 34 kompilerede eller enhedstestede integrationer.
Projekternes egne hastigheds- og kvalitetsmålinger er ikke FadedAI-målinger.

| Projekt / listepunkt | Værdi for FadedAI | Valg og begrænsning |
| --- | --- | --- |
| [PhoneClaw](https://github.com/kellyvv/PhoneClaw) · A1/B9 | Sammenhængende native værktøjer, flertrinsopgaver, relevant Skill-kontekst og tydelige resultater. | Høj værdi. Kalender/påmindelser findes allerede; udbyg med kontakter og relevante telefonværktøjer. Aktuel README bruger LiteRT til Gemma, ikke MLX. Genbrug ikke hele modelstakken ukritisk. |
| [OnDevice LLM](https://github.com/Mesutcydev/ios-local-llm/blob/main/Docs/REUSABLE_COMPONENTS.md) · A2/B18 | Modelvalidering, afbrudte downloads, serialiseret inferens, stop, RAM/temperatur og fejlgendannelse. | Høj teknisk værdi. Projektet angiver konkrete dele, der kan udtrækkes; behold FadedAIs chat og motorer. |
| [CoreML-LLM](https://github.com/john-rocky/CoreML-LLM) · A3 | ANE-inferens, billedforståelse, små specialister til funktioner og embeddings. | Allerede afhængighed, version 1.9.0, og brugt i telefoninferensen. Udbyg og mål; installér ikke en parallel kopi. ANE og GPU deler stadig RAM. |
| [MLX Swift Examples](https://github.com/ml-explore/mlx-swift-examples) · A4 | Reference til modelindlæsning, streaming, billed-/tekstmodeller og målinger. | God reference til eksisterende MLX-kode; ingen grund til at overtage endnu en chat-app. |
| [AnyLanguageModel](https://github.com/huggingface/AnyLanguageModel) · A5 | Fælles modelkontrakt og mere ens værktøjsforløb på tværs af lokale/cloudmodeller. | God kandidat. Modelunderstøttelse er ikke garanti for korrekt værktøjsbrug. Aktuel pakke kræver mindst Xcode 26.4/Swift 6.3, mod FadedAIs nuværende Xcode 26.3; vælg version og overgang særskilt. Private Cloud Compute er ikke offline. |
| [Localight](https://github.com/timokoethe/Localight) · A6 | Lille demonstration af Apple Foundation Models og modeltilstande. | Lav ekstra værdi; FadedAI har allerede denne type chat. Udgiveren betegner den som demo. |
| [ANEMLL](https://github.com/Anemll/Anemll) · A7 | Konvertering, vægtdeduplikering og stabil ANE-inferens. | Teknisk reserve/reference. CoreML-LLM er allerede i appen; vælg kun en ny motor efter en reel fordel i målinger. |
| [iOS Agent Harness](https://github.com/a178960320/ios-agent-harness) · A8/B17 | Før/efter-kontrol og opdeling i planlægning, udførelse og vurdering. | Arkitekturidéer alene. Den beskrevne daemon og styring af andre apps kræver jailbreak, ZXTouch/Activator og et modelendpoint. Ikke en almindelig AltStore-funktion. |
| [NOBS](https://github.com/acburgess25/NOBS) · A9/B10 | Realistisk dagsplan, lokal funktion ved tab af computerforbindelse og tydelig behandlingsstatus. | Nyttig inspiration til eksisterende dagsoversigt. Tidlig prototype med separat Tank-backend og planlagte funktioner; ikke et færdigt offline assistantsystem. |
| [Osaurus](https://github.com/osaurus-ai/osaurus) · A10/B20 | Agentidentitet, hukommelse og værktøjer uafhængigt af valgt model. | God arkitekturinspiration, men Mac-app, ikke iPhone-modul. |
| [SELF-OS](https://github.com/selflabs/SELF-OS) · A11 | Modulopdeling og et register over agentfunktioner. | Lav direkte gevinst. Community Edition indeholder deterministiske eksempelagenter og mock-services; en rigtig model skal forbindes særskilt. |
| [Wax](https://github.com/christopherkarani/Wax) · A12/B19 | Lokal, modeluafhængig søgning/hukommelse med dokumentkilder. | Høj værdi ved udbygning. Allerede vendoreret og brugt gennem FadedAIPrivateWax i privat søgning. Almindelig, vedvarende agenthukommelse er et andet, eksplicit afgrænset formål. Sub-millisekundtal er ikke garanti for en hel AI-besvarelse. |
| [Railtracks Swift / RAG](https://github.com/RailtownAI/Railtracks-swift) · A13 | PDF/CSV/JSON/tekst-loadere, opdeling af dokumenter, genfinding og sporbare agenttrin. | Relevant til dokumentbibliotek oven på eksisterende hukommelse. RAG er et separat produkt i Package.swift. Aktuel Swift 6.3-grænse kræver også byggeplan; Spotlight/Siri følger ikke automatisk med en RAG-motor. |
| [WhisperKit](https://github.com/argmaxinc/argmax-oss-swift) · A14 | Core ML-baseret lokal transskription. | Sammenlign dansk, latenstid og RAM med nuværende Whisper-runtime; behold den bedste danske model. Samme SDK-familie som A16. |
| [FluidAudio](https://github.com/FluidInference/FluidAudio) · A15 | Taleaktivitet, taleslut, transskription og opdeling i talere. | Høj værdi til stemmeforløb og optagelser. Sprog og kvalitet varierer pr. model; dansk og afbrydelse skal prøves særskilt. |
| [Argmax OSS Swift](https://github.com/argmaxinc/argmax-oss-swift) · A16 | WhisperKit, SpeakerKit og TTSKit som valgbare produkter. | Relevant alternativ/sammenligning til FluidAudio. OSS- og Pro-funktioner er forskellige; hent ikke begge fulde lydstakke uden målt gevinst. Qwen-TTS er ikke i sig selv et bevis på dansk kvalitet. |
| [DeviceAI](https://github.com/deviceai-labs/deviceai-runtime-sdks) · A17 | Fælles grænseflade til flere lokale motorer på iOS/Android. | Lav ekstra værdi til den nuværende native iPhone-app; endnu en model-/lydstak giver overlap. Cloudstyring er valgfri, ikke nødvendig for det lokale SDK. |
| [DiffusionKit](https://github.com/argmaxinc/DiffusionKit) · A18 | Konvertering og alternative diffusion-pipelines på Apple Silicon. | Teknisk reference/reserve. Python-konvertering og native iPhone-inferens er forskellige dele. Ikke dokumentation for, at alle FLUX-varianter passer på telefonen. |
| [SD_POC](https://github.com/ccqqder/SD_POC) · A19 | En lille MLX-billedprototype med model- og fremdriftsvisning. | Lav ekstra værdi over fungerende FLUX. Roden har PRD og kildekode, men ingen klar licensfil ved gennemgangen; PRD'ets mål er ikke en iPhone-benchmark. |
| [Swift Core ML Diffusers](https://github.com/huggingface/swift-coreml-diffusers) · A20 | Native eksempel på Apples Stable Diffusion-pipeline. | Reference ved fejlsøgning. Ikke en nødvendig erstatning for den fungerende FLUX-motor. |
| [Memex](https://github.com/memex-lab/memex) · B1 | Fang tekst/foto/lyd én gang, udled konkrete fakta og bind opfølgning til kilden. | Stor værdi i arbejdsgangen, indbygget i chat/Fortsæt. Flutter-app; local-first lagring betyder ikke lokal AI: README bruger en konfigureret modelservice. Brug FadedAIs telefonmodel til en lokal tilpasning. Ingen ny Kortsamling-fane. |
| [Notiary](https://makerportal.ai/) · B2 | Idéen om løfter/beslutninger med præcis kilde og mulighed for at rette dem. | God adfærd at overveje. Det angivne GitHub-repo gav 404; producentens nuværende side beskriver semantiske noter. Den beskrevne åbne kode til løfter er ikke verificeret. |
| [WhisperBoard](https://github.com/Saik0s/WhisperBoard) · B3 | Enkel optagelse, import, transskription, historik og eksport. | Brugbar brugerflade/reference til FadedAIs eksisterende danske diktering. Ikke nødvendigt med endnu en Whisper-motor alene af den grund. |
| [Whisper Notes](https://github.com/mazzzystar/whispernotes-mcp) · B4 | Optagelser med tekst, tidskoder og talere. | Funktionen er nyttig. Den identificerede officielle GitHub-kilde er MCP-dokumentation; selve appen er kommerciel, ikke et frit Swift-modul, vi kan overtage. |
| [ORIX Scan](https://git.spboucher.ai/orix-scan) · B5 | Perspektivrettet scanning, søgbar PDF og lokale dokumenthandlinger. | God funktionsinspiration. Udgiverens licens er All rights reserved; offentlig kilde er ikke en fri genbrugslicens. Enhedskamera er ikke fysisk testet af udgiveren ifølge README. |
| [Auto Receipts Studio](https://github.com/drowzeys/keys-Auto-Receipts-Studio) · B6 | Beløb/butik/dato med en gennemgang før lagring. | Idéen kan bruges, men denne implementering er ikke on-device iPhone: Gemma 4 12B kører på en GPU-boks, iPhonen er Safari-kamera/klient. |
| [SmartSqan](https://smartsqan.stone9.app/support/) · B7 | Foreslå titel, type og arkivering af et scannet dokument. | Nyttig arbejdsgang til lokale dokumenter. Produktet er verificeret, men ikke en åben kodepakke ved det angivne link. |
| [6pm Scan](https://github.com/at6pm/6pm) · B8 | Automatisk kvitteringsfoto, perspektivretning, QR og lokal udlæsning. | Konkrete native kameradele er relevante. Det rigtige repo er at6pm/6pm. Udgiveren beskriver valgfri serverhjælp ved usikker læsning; brug lokaltilstanden til offline-kravet. |
| [Cadeo](https://www.cadeo.app/changelog) · B11 | Dagsplan med luft, flyt/kort ned/spring over og kontekst fra seneste aftale. | Gode idéer til eksisterende dagsoversigt. Produktfunktioner er dokumenteret, men appens åbne kildekode er ikke verificeret ved brugerens link. |
| [DeftTask](https://defttask.com/privacy) · B12 | Sammenhæng mellem opgaver, noter og kalender med lokal lagring. | Produkt-/flowinspiration. SQLite/CloudKit kan bygges nativt; en tilsvarende åben kodebase er ikke verificeret ved det angivne link. |
| [Patchwork](https://github.com/tashifkhan/Patchwork) · B13 | Samle konkrete opgaver fra forskellige konti og vise den rigtige kilde. | Relevant hvis disse tjenester bruges. Korrekt repo er tashifkhan/Patchwork; API-opslag kræver net. Undgå en ny separat opgaveapp oven i FadedAI. |
| [Open Walnut](https://github.com/EvanZhang008/open-walnut) · B14 | Gemte forløb, genoptagelse og gennemgang af ændringer pr. agentopgave. | Nyttig arkitekturinspiration til PC-arbejde/Fortsæt. Node/Claude Code-host; iPhone-appen er ledsager, ikke et selvstændigt offline iPhone-system. |
| [OpenMinis](https://github.com/OpenMinis/OpenMinis) · B15 | En lokal Alpine/iSH-sandkasse, scripts, filer, browser og native telefonværktøjer. | Størst potentiel ny agentkapacitet. Stor native integration med iSH/FFmpeg/rootfs og GPL-komponenter; modelvalg er separat. Tilslut FadedAIs lokale model for offline ræsonnement. Ikke Windows, ikke løfte om fri baggrundskørsel. |
| [Spectrion](https://us.spectrion.app/docs/en) · B16 | Færdige dokumenter/diagrammer, synlige opgavetrin og dokumentation for handlinger. | God produktinspiration til chatresultater. Produktdokumentation er fundet; tilsvarende åben iOS-kildekode ved brugerens link er ikke verificeret. |

### Størst praktisk gevinst

- Et rigtigt arbejdsrum på iPhone, der kan behandle filer, korte scripts og
  dokumenter, koblet til vores lokale model og den valgte browser.
- Native telefonværktøjer med sammenhæng mellem flere trin og faktiske resultater.
- Modeluafhængig, vedvarende almindelig agenthukommelse samt dokumentgenfinding
  med præcise kilder. Bevar den private sessions livscyklus særskilt.
- Bedre taleskift og danske optagelser med tidskoder/talere, sammenlignet med den
  nuværende danske Whisper-model. Egne agentstemmer er allerede valgt særskilt.
- Fang tekst/foto/lyd fra chat og deling; gennemgå udledte aftaler, beslutninger
  og opgaver uden at genindføre den fravalgte Kortsamling.
- Scan til søgbar PDF, kvitteringsdata og praktisk opfølgning, samlet i samme flow.
- Planlæg med realistiske pauser og mulighed for at flytte valgte opgaver.
- Bedre runtime-genopretning, tydelig fremdrift og verificering af hvert værktøjstrin.

### Afgrænsning før integration

Ingen af de 34 vurderinger er en beslutning om at udskifte eksisterende motorer.
FLUX bevares. AnyLanguageModel/Railtracks kræver en kompatibel, fastlåst pakke-
og Xcode-plan; appen bruger i øjeblikket Xcode 26.3 i sin primære workflow.
WhisperKit og Argmax OSS overlapper. Vælg et fælles lydforløb frem for flere
parallelle download-, mikrofon- og afspillerstakke. Funktioner fra offentlige
produkter uden genbrugslicens kan inspirere en selvstændig implementering.

Offline værktøjer, internet over telefonen og fjernarbejde på en computer er tre
forskellige driftsmåder. Importerede Skills kan instruere eksisterende værktøjer;
de giver ikke automatisk nye iOS-rettigheder. En lokal Linux-sandkasse fjerner
ikke iOS' begrænsninger ved lukning/låsning. Mål hele opgaven på den faktiske
iPhone, inklusive modelindlæsning, dansk kvalitet, RAM og genoptagelse.

Denne gennemgang ændrer kun listen/statusnoterne. Ingen kode er importeret,
ingen motor skiftet, og ingen build, push eller kontohandling er startet.

## Bestilt gennemgang · ét punkt færdigkodes og prøves lokalt før næste

Godkendelsen omfatter de fire valgte oplevelser og de dele, der blev anbefalet
til videre arbejde. Overlappende projekter løses i samme forløb. Fungerende
FLUX, dansk diktering, stemmevalg, modeller og eksisterende kontrakter bevares.
Apple-kompilering og fysisk iPhone/TV-kontrol markeres særskilt og foregives
ikke udført af PC-prøver. Ingen nye builds/push startes automatisk.

| Rækkefølge | Arbejde | Status |
| --- | --- | --- |
| C1 | Kamerahjælp: foto, konkrete markeringer, rettelse og næste billede | Kodet. 66 lokale Swift-logikprøver bestået inkl. kameraets koordinater, format og fotoskift. Rigtigt lokalt Gemma-billedsvar afprøvet med kendte tekstpositioner; rå modelkoordinater var fejlformede og blev ikke brugt. Native kamera/OCR og iPhone-model samt PC-API-flow afventer fysisk/Apple-prøve. |
| C2 | Gemte sange, billeder og projekter som brugbare genstande i landsbyens rum | Kodet i landsbyrum og gemte agentrum. Egne gemte sange, billeder og projekter, flyt/fjern/fortryd, deling og håndtering af slettet original. 70 lokale Swift-logikprøver bestået; native tryk/zoom/afspilning afventer iPhone. |
| C3 | Agentbrowser på iPhone, Gepetto-adapter og faktisk resultatkontrol | Kodet med fastlåst kompatibel Gepetto, eksisterende telefonmodeller, pause/overtag/stop, særskilt kontrol og kilde. 74 lokale logikprøver og projektkoblingen består. Apple-kompilering og fuldt WKWebView-/modelforløb afventer iPhone. Se AGENT-BROWSER.md. |
| C4 | Egne lokale stemmer fra optagelse, ChatterboxCoreML og individuelle valg | Kodet med særskilt modelhentning, mikrofon/lydfil, prøvestemme, individuelle valg og eksisterende afspillere. Swift 6.2.1 afhængighedsopløsning og 77 lokale Swift-logikprøver bestået. Dansk kvalitet/lighed/RAM og Apple-kompilering afventer fysisk prøve. Se CLONED-VOICES.md. |
| C5 | Sammenhængende native telefonværktøjer og importérbare Skills, PhoneClaw-inspiration | Kodet: native kontaktopslag, valgt kilde til næste opgave, agentafgrænsning/udløb, SKILL.md-import/aktivering/relevans. Kalender/Påmindelser beholdt. 80 lokale logikprøver bestået; native kontakter/tilladelser afventer iPhone. Se PHONE-SKILLS.md. |
| C6 | Agentens lokale computer | JavaScript og valgfri Linux med BusyBox og Lua. Valgte filer, gemt resultat, Stop og genoptagelse pr. agent. Seks browserprøver kørte den faktiske Linux-motor på PC’en. WebKit og hastighed afventer iPhone. Se LOCAL-CODE.md. |
| C7 | Udbyg eksisterende Wax til almindelig, kildebundet agenthukommelse | Kodet: egne noter/gemte brugerbeskeder, kildekopier, modeluafhængighed, valg/sletning og separat vedvarende Wax. 84 logikprøver og ni rigtige Wax-prøver bestået inkl. manglende indeks og privat oprydning. Fælles pakkeversioner opløst. Native chat/filbeskyttelse afventer iPhone. Se AGENT-MEMORY.md. |
| C8 | Lokalt dokumentbibliotek og relevante RAG-dele fra Railtracks | Kodet: JSON/CSV-loadere, række-/stikilder, lokal søgning på tværs af filer. 88 portable logikprøver består; native PDF/OCR og to native kildeprøver afventer Apple. Eksisterende læser/embeddings beholdt. Se DOCUMENT-LIBRARY.md. |
| C9 | Tekst/foto/lyd til gennemgåelige fakta, noter og opfølgning, Memex-arbejdsgang | Kodet i hjem/chat/deling: citatkontrollerede forslag, danske optagelser, foto-OCR, notehukommelse og native handlingsgennemgang. 92 lokale logikprøver består. Native model-/lyd-/EventKit-flow afventer iPhone. Se CAPTURE-AND-FOLLOWUP.md. |
| C10 | Fælles dansk lydforløb, taleskift/talere og længere optagelser, FluidAudio/Argmax/WhisperBoard | Kodet: 30-minutters optagelser/import, små buffere, tidskoder, stop/genoptagelse, rettelser/deling og valgfrie lokale VBx-talermodeller fra fastlåst FluidAudio. 98 portable logikprøver og syntaks består; talerpakke opløst. Native lyd/dansk kvalitet/RAM og Apple-kompilering afventer iPhone. Se LOCAL-AUDIO.md. |
| C11 | Runtime-stop, indlæsning, downloads og genoptagelse, OnDevice LLM-komponenter | Kodet: generationsafgrænset inferenskø, eksplicit stop/køstatus og GGUF-pause/genoptagelse/friske links. 103 portable logikprøver og syntaks består. Fungerende FLUX bevaret; native prediction-/URLSession-forløb afventer Apple. Se LOCAL-RUNTIME.md. |
| C12 | Fælles modelkontrakt og vurdering af kompatibel AnyLanguageModel-adapter | Kodet: prioriterede hele instruktioner/kilder, nyeste spørgsmål, afgrænset historik og bevis for medtaget hukommelse. 107 portable logikprøver og syntaks består. Eksisterende adaptere bevaret frem for Xcode-opgradering; native providerforløb afventer prøve. Se MODEL-CONTRACT.md. |
| C13 | Lokal scanning, QR, søgbar PDF og kvitteringsopfølgning, 6pm/native Apple og produktidéer | Kodet: native papir/QR/foto, PDF med kontrolleret tekstlag, beløbscitater, del/slet og agentbibliotek/opfølgning. 110 portable logikprøver og syntaks består; kamera/OCR/PDF-tekstlag afventer Apple. Se SCAN-AND-SAVE.md. |
| C14 | Realistisk dagsplan med flyt/kort ned/spring over, NOBS/Cadeo/DeftTask-idéer | Kodet: kalenderhuller/pauser, varighed/prioritet, flyt/kort ned/spring over, gemte kladder og gennemgået booking. 114 portable logikprøver og syntaks består. Native tilladelser/EventKit/booking afventer iPhone. Se REALISTIC-DAY-PLAN.md. |
| C15 | Gennemgå opgavekilder, artefakter, trin/resultater og genoptagelse med inspiration fra Patchwork/Spectrion/Open Walnut | Kodet: faktiske inputkopier/jobstatus, resultatfilkontrol, citatbundet lokal modelvurdering/forældelse, genoptagelse og lokale forløb i Fortsæt/personlig søgning. 118 portable logikprøver og syntaks består. Native navigation/modelkvalitet afventer Apple. Se WORK-REVIEW.md. |

En projektreference er ikke en ordre om at erstatte hele FadedAI eller tilføje
endnu en parallel motor. En eksisterende bedre løsning beholdes og kontrolleres.

### Slutkontrol af denne kodningsrunde

C1–C15 er færdigkodet i rækkefølge med lokale prøver mellem punkterne.
118 portable Swift-logikprøver består på Swift 6.2.1. De ni rigtige Wax-prøver
bestod ved C7. C6's Worker- og Chromium-prøver bestod ved C6. Swift-syntaks,
projektkobling og pakkeopløsning er kontrolleret. Ændrede/nye Swift-filer er
højst 600 linjer. Ingen push, build, Limrun-kørsel eller kontohandling er startet.

Apple-kompilering og fysisk kvalitet/RAM/lyd/kamera/kalender/browser er stadig
åbne kontroller. Se NATIVE-TOOLS-DEVICE-CHECK.md for en konkret tjekliste.
Afgrænset kodekørsel beholdes som iPhone-arbejdsrum; fuld iSH/Alpine er ikke
tilføjet. AnyLanguageModel/Railtracks erstatter ikke de fungerende adaptere.


## Opfølgning · 25. november, samlet kodegennemgang

Sangstudiets iPhone-kode er nu koblet til separat modelhentning, lydvalg,
reference og remix. Tekst-til-sang bruger fortsat den hidtidige vej.
PC-remix er prøvet med korrekt længde og bevaret original; de ekstra modeldele
blev klargjort, afbrudt, genoptaget og slettet i en isoleret PC-prøve.
Apple-kompilering, faktisk iPhone-RAM, reference-/remixlyd og stemmelighed er
stadig åbne; se SONG-STUDIO.md. PC-serverens nye sangkode er lagt på disk,
men den kørende server er ikke genstartet.

Kodegennemgangen rettede desuden gammelt svar i kamerahjælp (C1), retfærdig
kontrol af ventende PC-opgaver (C6), senere korte dokumentuddrag (C8),
forskellige opfølgninger fra samme citat og genforsøg af kildearkivering
uden gentaget handling (C9), samt gendannelse af optagelser ved afbrydelse
(C10). Eksterne originalfiler bevares; en afbrudt import kan kræve nyt valg.
142 portable Swift-tests bestod i den samlede lokale regression, herunder en
separat udtrukket dokumentlogiktest; Apples dokument- og lydbiblioteker er
ikke kørt på Linux. 27 lokale sangbackendtests og særskilte PC-modelprøver
bestod. Fysisk iPhone-/TV-test og Xcode-kompilering er stadig ikke udført.

AltStore-/RAM-pakkens inspektion og pakning bestod desuden 16 lokale
Python-tests med simuleret signering. Den endelige Apple-signering, iPhone-
RAM og brugerens lyd-/kameraforløb skal fortsat kontrolleres på enheden.
