# FadedAI Landsbyen · Del B · Livsdesign v1

Til Cursor. Fase 1 låser bottilstanden, rækkefølgen for valg af aktivitet, reglerne for behov, eventkataloget og accepttestene nedenfor. [JSON-skemaet](UNIVERSIM-LIFE-SCHEMA.json) beskriver bottilstand og eventforekomster. Skærmkomposition, animation og grafikkens placering er Del A. Fase 2 er forslag.

## 1. Oplevelsen

Inden for ti sekunder skal brugeren kunne se, hvor Adam og Eva er, hvad de laver, og at de kan finde på at skifte aktivitet. Adam kan gå til Research Lab, mens Eva passerer torvet på vej til Video Studio. En kort samtale på caféen eller lyset i sovekrogen fortæller, hvad der sker, uden at brugeren skal åbne et dashboard. Filmtilstand giver plads til at observere. Når brugeren vil deltage, kan et tryk på en bot åbne dens eksisterende profil eller computer.

Filmtilstand er standard. Landsbyen skal fungere i demo og med en afbrudt PC-forbindelse. Lokale aktiviteter er en del af landsbylivet. Appen viser kun en rigtig PC-opgave, filoverførsel eller samtale, når den har en bekræftelse fra den eksisterende funktion. Simulationen styrer visningen. Faktisk arbejde, fildeling og computerstyring starter gennem brugerens eksisterende handlinger.

## 2. Data og kompatibilitet

| Enhed | Felter og betydning |
| --- | --- |
| Bot | `id` er et stabilt ID. Brug den eksisterende `VillageBot.id` til gemte bots og de reserverede id'er `adam` og `eva` til de indbyggede demofigurer. `display_name` kommer fra profilen. `archetype` angiver adfærden. `sprite_id` angiver en grafiknøgle med plads til eksisterende brugerfigurer. En ukendt nøgle giver en standardfigur. |
| Zone | `research`, `video`, `cafe`, `sleep`. Research Lab, Video Studio, Café og Sovekrog. Torvet og stierne er rutenet, ikke destinationszoner. Brug ruteankre fra aktivpakken og et fast slot pr. bot, ordnet efter stabilt ID. |
| Aktivitet og positur | `idle`, `walk`, `work`, `talk`, `rest`, `sleep`. `activity` styrer adfærden, og `pose` styrer billedet. De følges som standard. En manglende animation bruger et stillbillede for den samme aktivitet. |
| Behov | `energy`, `social`, `fulfillment` og `mood` er tal mellem 0 og 1. `fulfillment` er arbejdsglæde. `mood` er beregnet. |
| Bevægelse | `zone_id` er den senest nåede zone. `destination_zone_id` er kun udfyldt under en tur. `path_progress` er 0 ved afgang og stiger til 1, hvorefter zonen og aktiviteten opdateres samlet, destinationen fjernes, og fremdriften sættes til 0. En afbrudt tur starter den nye rute fra figurens viste position. |
| CarryItem | `carrying` er `null` eller et objekt med `kind: file_share`, `label_key`, `from_bot_id` og `to_bot_id`. Brug `shared_file` eller `shared_clip` som label. Afstand og animationsretning beregnes i visningen. |
| Event | `id` er den unikke forekomst, `event_id` en af de 14 katalognøgler, `bot_ids` de berørte bots, `zone_id` en zone eller `null`, `speech_hint` en dansk tekstnøgle eller `null`, `started_at` UTC, og `duration_seconds` antal aktive sekunder. For en fildeling kommer afsender før modtager i `bot_ids`. |
| Tid og henvisninger | `updated_at` er tidspunktet i UTC for seneste tilstandsændring. `last_event_id` peger på seneste synlige events **forekomst-id**, ikke katalogkoden. `speech_hint` er en nøgle til aktivt kort hint. Alle krævede felter, også nullable felter, er altid til stede. |

Demo og den gemte landsby har separate tilstande. I en eksisterende landsby bevares UUID, profil, sprite og lokale samtaler. Ved tilpasning af den eksisterende `SimulationEngine` deles energien, det sociale behov og `workJoy` med 100 ved visning. `working/idle/resting/sleeping` oversættes til de tilsvarende kontraktværdier. `walk` og `talk` hører til visningen. Den eksisterende gemte enum, jobhistorik og samtalehistorik bevares. Adam og Eva oprettes efter den eksisterende regel om førstegangsoprettelse. Genåbning eller en ulæselig fil giver ingen nye dubletter.

Integrationskoden og Cursor-grenen er ikke på samme revision. Erstat de midlertidige livsregler i Del A med kontrakten her. Ved samling genbruges den eksisterende Runde 6-motor, joblog og samtalekroge fra integrationsgrenen. Kun én motor må opdatere gemte behov; kortets beslutninger, animationer og events er en visning ovenpå. På den samlede app forbinder QR iPhone til Windows over lokalnettet. Lokale modeller køres via Ollama, og PC-delen håndterer de isolerede skriveborde.

Fase 1 tilføjer ingen krævede felter til minimumsskemaet. Sessionsdata såsom turstart, næste beslutning, nedkøling, relation og observationskilde kan ligge i simulatoren ved siden af bottilstanden. En senere udvidelse af den udvekslede kontrakt skal versionsangives, så gamle klienter kan læse v1.

## 3. Ur, bevægelse og balance

| Mekanik | Låst regel |
| --- | --- |
| Beslutning | Evaluer hvert **8. aktive sekund** og straks ved bekræftet ændring af job eller samtale. Bevægelse bruger samme monotone ur og tegnes løbende. Dag/nat og stille figurer kan opdateres én gang pr. sekund. |
| Virkelig landsby | Følg telefonens lokale klokkeslæt og brug aktiv forgrundstid til behovsændringer. Begynd med aktuelle værdier. |
| Demo | Start ved virtuelt kl. 09.00. Ét aktivt sekund svarer til to virtuelle minutter, altså ét virtuelt døgn pr. 12 aktive minutter. Brug denne virtuelle tid til dagsrytme og de timebaserede rater. Bevar den almindelige hastighed for gang, events og pauser. |
| Første demo | Adam starter ved Research Lab med energi 0,80, social 0,52 og arbejdsglæde 0,48. Eva starter i Video Studio med 0,76 / 0,38 / 0,55. Adam og Eva vurderes i stabil id-rækkefølge. Første beslutning må sende Eva mod caféen, mens Adam bliver på Research Lab. En frivillig caféaftale, som bruger den samme matchregel som senere, kan derefter sende Adam af sted. |
| Bevægelse | En tur mellem zoner varer 4 aktive sekunder og følger stierne. Efter ankomst må en frivillig ny tur tidligst starte efter 24 aktive sekunder. Behovskrise og bekræftet PC-arbejde kan afbryde en almindelig tur. Brug centralt torv som rute ved manglende direkte sti. Behold kortets eksisterende zoomspænd. Ved 1× er kortet centreret og kan ikke trækkes. Ved zoom begrænses forskydningen for hver akse til ±maks(0, (kortets skalerede længde − rammens længde) / 2). Begræns igen ved zoom og størrelsesændring; tryk på figurer skal stadig ramme rigtigt. |
| Pause og baggrund | Stop lokale ture, events, nedkøling og behovsdrift. Ved genoptagelse fortsætter den lokale simulation fra sin aktive tid, uden at efterregne baggrunden. Ved tilbagekomst kan faktiske PC-resultater fra den eksisterende historik vises én gang. PC-opgaver følger PC’ens egen kø. |
| Mindre bevægelse | Med Reduce Motion flyttes figuren direkte til næste zone. Bevar samme opgave og opholdstid samt tekstlig feedback. Korte ikke-bevægende positurskift er tilstrækkelige. |

Lokale tilstandsændringer behandles i fast rækkefølge pr. tick. Først bekræftelser fra bruger og PC, derefter behovsdrift, derefter ankomst/afslutning af lokale sessioner, til sidst nye destinationer. Sæt alle ændringer for en tur eller et event samlet. En tilfældighedskilde er ikke nødvendig i fase 1.

### Døgnrytme og behov

| Lokal eller virtuel tid | Grundrytme | Energi pr. time |
| --- | --- | ---: |
| 00.00–07.00 og 22.00–24.00 | Sovevindue | +0,04 |
| 07.00–08.00 og 12.00–13.00 | Pause og café | −0,01 |
| 08.00–12.00 og 13.00–18.00 | Arbejdsvindue | −0,04 |
| 18.00–22.00 | Ro og hvile | +0,02 |

`delta = satsPrTime × forløbneTimer`. Hvis et tick krydser et tidsvindue, fordel tiden ved grænsen. Klamp hvert behov til 0…1. Behold raterne fra den eksisterende motor som grundrytme. Ved en synlig, behovsstyret hvile eller søvn med aktivt ophold bruges henholdsvis +0,02 eller +0,04 pr. time for opholdet, med samme regelsæt i demo og online. Ventetid i en PC-kø er en status og giver ingen jobbonus.

| Behov | Ændringer | Tærskler og synligt resultat |
| --- | --- | --- |
| Energi | Tidsraterne ovenfor. Et fuldført lokalt hvileophold på 24 sekunder giver +0,08. Behovssøvn giver +0,12 efter 24 sekunder, højst én gang pr. søvnsession. De to bonusser har hver 120 sekunders nedkøling pr. bot. | Under 0,30 er lavt. Ved 0,22 eller lavere vælger botten behovssøvn, hvis der ikke kører et PC-job eller en samtale. Søvnen varer mindst 24 sekunder og hænger ved, indtil energien er mindst 0,34. Ved 0,70 og derover er energien høj. |
| Socialt | −0,01 pr. time i pausevinduer. Et bekræftet brugersvar giver +0,05, og en bekræftet interaktion i holdchat giver +0,03 pr. deltagende bot gennem de eksisterende hooks. En lokal caféaftale giver +0,03 pr. deltager ved fuldførelse. | Under 0,20 er meget lavt og kan give ensomt udtryk. Ved 0,40 eller lavere kan botten søge caféen. Fra 0,70 kan et socialt overskud vises med glad positur, hvis de andre behov tillader det. |
| Arbejdsglæde | −0,02 pr. time uden for arbejdsvinduet. Et nyt bekræftet jobresultat giver +0,10 ved succes eller −0,05 ved fejl. En fuldført lokal øvesession på 24 sekunder giver +0,04 med 120 sekunders nedkøling pr. bot. | Under 0,20 er meget lavt og kan give frustreret udtryk. Ved 0,50 eller lavere kan botten vælge en øvesession. Over 0,80 kan botten vise stolt positur. |
| Humør | Beregn `clamp(0.4 × energy + 0.3 × social + 0.3 × fulfillment)` ved ændringer. Giv ingen særskilt humørbonus. | Under 0,35 er lavt, 0,35–0,70 er middel, og over 0,70 er højt. Brug de eksisterende udtryk i rækkefølgen frustreret, træt, ensom, stolt, glad, neutral. Prioritér behovsudtrykket, når det forklarer aktiviteten bedre end tallet alene. |

En lokal session skal være fuldført for at give bonus. Afbrydelse giver ingen bonus. En caféaftale varer 16 aktive sekunder. Begge deltagere får gevinsten ved slutning. Når det samme PC-job vises i flere skærme, bruges motorens eksisterende deduplikering med PC, bot og job-id. Det visuelle event ændrer ikke behov en ekstra gang.

## 4. Valg af destination

Vælg første gældende række. Hvis aktiviteten allerede kører eller destinationen allerede er sat, fortsæt den samme handling uden at starte timeren forfra. Frivillige ture følger opholdstiden ovenfor. Ved ens prioritet vælger du det sted, hvor botten allerede er, hvis det er egnet. Vælg ellers bottypens arbejdszone eller den laveste id-sorterede partner.

| Prioritet | Situation | Handling |
| ---: | --- | --- |
| 1 | Tilknyttet, bekræftet PC-job kører | Gå til jobtypen: kendt video → `video`, kendt kode/research → `research`, ellers profilens arbejdszone. Vis `walk` på vej og `work` ved ankomst. Vis samtidig live arbejdsmærke. Jobbet får lov at slutte, og et lavt energiniveau kan vise et diskret pausehint. |
| 2 | Bekræftet samtale med brugeren eller holdet | Vis `talk` på nuværende sted, hvis botten ikke har aktivt PC-job. Når samtalen slutter, vælges en ny lokal aktivitet. |
| 3 | Sovevindue med energi under 0,80, energi ≤0,22 eller en søvnsession, der ikke er afsluttet | Gå til `sleep`. Efter mindst 24 sekunders ophold må botten vågne ved energi ≥0,80 i sovevinduet, ved ≥0,34 uden for vinduet ved behovssøvn, og ellers når vinduet slutter. En bot med energi ≥0,80 i sovevinduet vælger rolig hvile frem for en ny aktivitet. |
| 4 | En bekræftet fildeling kan vises uden at afbryde række 1–3 | Vis pakken på afsenderen og spil den korte håndtering i samme zone eller på ruten til modtageren. Se §6 for visning under arbejde eller søvn. |
| 5 | Energi ≤0,36 eller roligt tidsvindue og energi under 0,65 | Tag én hvilesession i `sleep` eller `cafe`. Brug den eksisterende zone, hvis den er egnet. Ved nedkøling hviler figuren roligt uden en ny sessionsbonus. |
| 6 | Socialt behov ≤0,40, eller der er allerede en aktiv caféreservation | Reservér begge i én caféaftale. Partneren skal have social ≤0,60, energi >0,36, ingen anden reservation og ingen aktivitet fra række 1–5. En caféaftale kan afløse lokal øvning, når opholdstiden er opfyldt. Hvis ingen partner er ledig, behold det almindelige lokale valg og prøv igen ved næste beslutning. |
| 7 | PC-job ligger i kø, men er endnu ikke startet | Vis ventestatus med `idle`. Vis den ved arbejdszonen, hvis botten allerede er der. En kø hindrer ikke pause, søvn eller lokal samtale. |
| 8 | Arbejdsvindue, eller arbejdsglæde ≤0,50 og botten er vågen | Gå til profilens arbejdszone. Tag en lokal øvesession, hvis nedkølingen er udløbet. Vis `work` med lokal aktivitetslabel. Der oprettes intet PC-job. |
| 9 | Øvrige tilstande | Vis `idle` på nuværende sted, eller `rest` i café/sovekrog i et roligt tidsvindue. Ingen ny tur. |

## 5. Personlighed og hukommelse

| Type | Arbejdszone og vane | Udtryk |
| --- | --- | --- |
| `logic` · Adam | Research Lab. Vælger bordet længst fra caféen, hvis flere lige gode researchpladser er ledige. | Rolig, præcis, tør humor. Blå figur. |
| `creative` · Eva | Video Studio. Vælger plads tæt på torvet, hvis flere lige gode videopladser er ledige. | Nysgerrig og levende. Lilla figur. |
| `care` | Research Lab. Prioritér den ledige cafépartner med lavest socialt behov, hvis to er lige egnede. | Varmt og imødekommende. |
| `playful` | Video Studio. Vælger caféen ved lige gode hvilepladser. | Kort og legende. |

En tilføjet bot får en type fra et eksplicit valg eller standarden `logic`. Alle bruger samme regler for opgaveprioritet og behov. Zonepladser fordeles deterministisk efter bot-id og kan bruges af op til 10 bots. Kontoret har otte synlige pladser og en botliste, så alle ti kan findes. Åbn den valgte bots egen profil eller computer med dens stabile id, også hvis den deler kørende skrivebordskapacitet med andre. Den eksisterende grænse er to aktive skriveborde ad gangen.

Hukommelse kan fremhæve kendte forbindelser uden at vise indhold. `bestFriendID` kan bryde en ellers lige cafématch, hvis personen findes og opfylder reglerne. En godkendt fildeling giver eventnøglen `file_handoff`. Fuldført holdchat kan tælle som seneste samtale og afgøre, hvilken lige egnet partner der har ventet længst. Gem kun lokal hændelsestype, bot-id, tidspunkt og event-id i landsbyens hukommelse. Ved manglende samtykke eller data bruges neutrale standardhint. Teksten fra eksisterende `dailyMemory`, private chats og backendets `agent-memory` vises kun i deres egne eksisterende visninger.

## 6. Samtale, fildeling og events

En caféaftale oprettes med begge id'er i samme lokale handling, når begge må afgå. Ved caféankomst placeres figurerne på to ledige pladser. Når begge er fremme, vises ét fælles `cafe_chat`-event i 16 sekunder. Samme par kan først mødes igen efter 120 aktive sekunder, og hver bot har 60 sekunders nedkøling efter en gennemført caféaftale. Hvis en højere prioritet afbryder aftalen, eller begge ikke er fremme inden 12 aktive sekunder, frigives pladserne, og ingen får en bonus. En almindelig caféaftale bruger korte danske standardreplikker, uden AI- eller netkald.

Eksempel på lokal replik, hvis den vises i detaljevisningen: Adam: «Skal vi tage en kort pause?» Eva: «Ja, jeg har en idé til bagefter.» Den korte tekst på selve kortet er «En snak over kaffen».

En rigtig fildeling animeres, når den eksisterende godkendte delefunktion returnerer succes. Deduplikér på den delte kopis stabile id, hvis det er tilgængeligt. Brug ellers PC-id, kildefil-id, afsender-id og modtager-id, så samme deling kun vises én gang. Afsender får pakken i op til 10 sekunder, modtageren får ankomsthint, og `carrying` nulstilles. Hvis en bot arbejder, taler eller sover, vises pakken ved dens zone. Appens eksisterende funktion ejer selve overførslen. Demo kan vise en tydeligt mærket eksempelpakke én gang ved den første gennemførte cafésamtale. Den opretter ingen fil.

| Event-id | Udløsning og nedkøling | Sek. | Tekstnøgle og dansk tekst | Brugerhandling |
| --- | --- | ---: | --- | --- |
| `morning_startup` | Første tick over 07.00 pr. lokalt eller virtuelt døgn | 8 | `morning_startup` · Godmorgen, Landsby | Åbn bot |
| `night_wind_down` | Første tick over 22.00 pr. døgn | 8 | `night_wind_down` · Der falder ro over Landsbyen | Ingen |
| `needs_break` | Energi krydser under 0,30. Mindst 120 sek. mellem hints pr. bot | 8 | `needs_break` · Trænger til en pause | Åbn bot |
| `rested` | En lokal hvilesession fuldføres | 6 | `rested` · Klar igen efter en pause | Ingen |
| `cafe_chat` | Begge deltagere når caféen | 16 | `cafe_chat` · En snak over kaffen | Åbn deltager |
| `file_handoff` | Bekræftet deling eller første caféaftale i demo. Én gang pr. dele-id | 10 | `shared_file` · En fil er delt. `shared_clip` · Et klip er delt. `demo_file` · Sådan ser en deling ud i demo | Åbn modtager |
| `inspired` | Fuldført lokal øvesession. Følger sessionens nedkøling | 8 | `inspired` · Fik en ny idé | Åbn bot |
| `stuck_on_task` | Nyt bekræftet job med status fejl. Én gang pr. job | 12 | `stuck_on_task` · Opgaven kunne ikke gennemføres | Åbn opgave |
| `offline_rest` | Tidligere tilgængelig PC-forbindelse afbrydes. Én gang pr. overgang | 8 | `offline_rest` · PC’en er afbrudt. Landsbyen fortsætter | Åbn Forbindelser |
| `pc_reconnected` | Et gyldigt svar modtages efter afbrydelse. Én gang pr. overgang | 6 | `pc_reconnected` · PC’en er tilbage | Åbn bot |
| `work_started` | Bekræftet job går til kørende. Én gang pr. job | 6 | `work_started` · Er gået i gang med opgaven | Åbn opgave |
| `work_finished` | Bekræftet job afsluttes med succes. Én gang pr. job | 10 | `work_finished` · Opgaven er færdig | Åbn resultat |
| `sleep_started` | Ankomst til sovekrog ved søvn. Én gang pr. søvnsession | 6 | `sleep_started` · Er gået til ro | Ingen |
| `awake` | Søvnsession slutter | 6 | `awake` · Er vågen igen | Åbn bot |

For flere samtidige hints får jobfejl, jobafslutning og godkendt fildeling forrang, i den rækkefølge. Derefter følger caféaftale og behov, til sidst rutine og forbindelse. Ved samme prioritet vises det nyeste event, og ved samme tidspunkt sorteres på forekomst-id. Vis højst ét hint pr. bot og to på hele kortet. Resten er tilgængelige i en evt. lokal hændelsesliste. Bind aldrig en ny hændelse til hvert gentaget snapshot. For globale forbindelseshændelser bruges et banner og en tom liste i `bot_ids`.

## 7. PC-status og afbrydelse

| Kilde | Visning og betydning |
| --- | --- |
| Joboversigt `running` | Bekræftet PC-arbejde. Vinder over lokalt café-, hvile- eller øvevalg for den samme bot. |
| Joboversigt `queued` | Venter. Vis ved siden af den lokale aktivitet. |
| Joboversigt `completed` / `failed` | Ændrer behov og viser event én gang gennem den eksisterende joblogik. Første hentning for en PC registrerer gamle jobs uden bonus eller event. |
| Joboversigt `cancelled` | Fjern jobmærket. Næste lokale valg tager over. |
| Hub `working` | Vis arbejde for den agent, som snapshottet identificerer. Knyt det kun til Adam/Eva, når det matcher det eksisterende stabile bot-id. |
| Hub `thinking` | Vis `talk` ved kendt samtale eller `work` med mærket «Tænker» ved kendt job. Ellers vises mærket «Tænker» med `idle` på nuværende sted. |
| Hub `ready` | Vis den lokale plan. |
| Hub `offline` eller mistet forbindelse | Fjern live-mærket, vis forbindelsesstatus særskilt, og fortsæt lokalt. En afbrydelse er ingen bekræftet jobfejl. |

Læs de eksisterende hub- og botjobdata, så længe den aktuelle PC-forbindelse og den observerede bot stadig matcher. Ved ændring af forbindelsen ryddes tidligere live-signaler. Brug bot-id og tilhørende PC-identitet til at skelne resultater. Lokal demo og beslutningsregler har ingen netværksafhængighed.

## 8. Dansk tekst og tilgængelighed

| Nøgle | Tekst |
| --- | --- |
| `idle` | Klar |
| `walk` | På vej til {sted} |
| `work` · PC | Arbejder på PC’en |
| `work` · lokal | Øver sig i {sted} |
| `queued` | Venter på en opgave |
| `talk` | Taler |
| `rest` | Holder pause |
| `sleep` | Sover |
| `demo_empty` | Åbn demoen for at møde Adam og Eva. |
| `village_empty` | Landsbyen er tom. Tilføj en bot for at komme i gang. |
| `pc_unavailable` | PC’en er afbrudt. Landsbyen fortsætter. |
| `paused` | Landsbyen er sat på pause. |
| `camera_reset` | Nulstil kortets udsnit |

VoiceOver læser navn, aktivitet og sted som én enhed, fx «Eva, holder pause på caféen». Ved live-aktivitet tilføjes «PC-opgave i gang» eller «Venter på en opgave». Navn og aktivitet må ikke afhænge af figurens farve. Oplæs kritiske ændringer som jobfejl én gang. Dag/nat, højere zoom og animationer skal kunne ændres uden at flytte VoiceOver-fokus.

## 9. Accepttest for fase 1

| Nr. | Givet | Når | Så |
| ---: | --- | --- | --- |
| 1 | Frisk installation uden PC | Åbn demoen | Adam er ved Research Lab og Eva ved Video Studio. Inden ti sekunder er en lokal aktivitet eller tur synlig. |
| 2 | Adam og Eva har ledig kapacitet, og Eva er under 0,40 i socialt behov | Næste beslutning træffes | De kan reservere én caféaftale. Begge når frem, og der vises én samtale. |
| 3 | En caféaftale varer 16 aktive sekunder | Begge bots er fremme, og tiden udløber | Begge får +0,03 socialt én gang, og parrets nedkøling starter. |
| 4 | En bot har energi 0,20, social 0,15 og et job i kø | Næste beslutning træffes | Botten går til sovekrogen og beholder ventemærket. |
| 5 | En bot har energi 0,20 og et bekræftet videojob i gang | Jobstatus hentes | Botten går til Video Studio med live arbejdsmærke. Lav energi kan vises som pausehint. |
| 6 | Et bekræftet job er afsluttet efter første synkronisering | Joblisten opdateres igen eller åbnes i en anden visning | Arbejdsglæde får +0,10 én gang, og hændelsen vises én gang. |
| 7 | Første synkronisering indeholder gamle jobs og ét afbrudt job | Listen indlæses | Gamle resultater registreres uden bonus, og afbrydelsen vises ikke som fejl. |
| 8 | PC-forbindelsen forsvinder under arbejdet | Appen opdager afbrydelsen | Live-mærket fjernes, ét forbindelseshint vises, og botten genoptager sin lokale rytme. |
| 9 | To bots er i gang med en tur, og et PC-job kører | Brugeren pauser Landsbyen eller sender appen i baggrunden | Lokal tur og behov stopper, PC-jobbet fortsætter, og ved genoptagelse foretages ingen lokal indhentning af tiden. |
| 10 | En godkendt fil er delt | Det samme resultat vises to gange | Præcis én pakke vises, og den fjernes fra `carrying` efter højst 10 sekunder. |
| 11 | Demo bruger sin første eksempelpakke | Brugeren ser fildelingen på kortet | Hintet siger, at det er demo. Der oprettes ingen fil på telefon eller PC. |
| 12 | Reduce Motion er aktiveret | En bot skifter zone | Den vises straks på destinationspladsen med aktivitetstekst. VoiceOver kan stadig vælge den. |
| 13 | Kortet er zoomet ind 2× | Træk hårdt mod alle fire hjørner, og zoom ud til 1× | Rammen er hele tiden dækket. Ved 1× sidder kortet centreret uden forskydning. |
| 14 | Der findes 10 profiler og to aktive skriveborde | Åbn Landsbyen og derefter Kontoret | Alle bots findes på kort eller i liste. Brug af et tredje skrivebord følger den eksisterende PC-grænse. |
| 15 | En tidligere installeret app har egne profiler, jobhistorik og tilpassede figurer | Opdater og åbn Landsbyen | Bot-id, profiler, figurer og historik bevares. Ingen grundlæggerdubletter. |
| 16 | Adam har eksisterende privat hukommelse og Eva har et andet bot-id | De mødes på caféen | Hintet bruger lokaliseret standardtekst uden at vise private noter eller blande bot-identiteter. |
| 17 | Demoens virtuelle ur når 22.00 og senere 07.00 | Døgnet skifter | Natlys, aftenhint og morgenhint vises på de rette overgange. Hvert hint vises én gang pr. døgn. |
| 18 | En bot går til behovssøvn kl. 14.00 ved energi 0,22 og har ingen nedkøling | Botten er fremme, og der går mindst 24 aktive sekunder | Søvnen bevares trods stigning over 0,22. Ved fuldførelse udløses +0,12 én gang, og botten vågner, når energien når 0,34. |

## 10. Fase 2

Mulige udvidelser er et udtrykkeligt tilvalg til at vise bestemte hukommelsesnoter, lokal historik for relationer, valgfri pushbesked når et job bliver færdigt og synkronisering mellem enheder. Disse kræver særskilte beslutninger om data og tilladelser. Fase 1 kan implementeres og afprøves med det eksisterende klient- og PC-setup.
