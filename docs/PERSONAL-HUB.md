# FadedAI · Det personlige univers

Brugerens rækkefølge, 24. november 2026. Hvert punkt kodes og kontrolleres
færdigt før næste punkt påbegyndes. Ingen push eller nyt build er bestilt.

1. **Kodet og lokalt kontrolleret:** Tid, stemning, reelle gemte filmkilder,
   musikkatalog/bibliotek, offlinefilter og tre valg. Tre Swift-tests bestået.
   Filmkilder er mærket som kilder; der foregives ikke adgang til bestemte film.
   Det endelige valg åbner eksisterende afspiller eller landsby. iPhone afventer.
2. **Kodet og lokalt kontrolleret:** Fortsæt åbner konkrete agentchats,
   arbejdsrum, projektkladder, musik og filmsider. Ny Hjem-hero, færre
   samtidig synlige genveje, søgning i indstillinger og direkte telefonvalg.
   Ingen eksisterende indstillinger eller nøgler fjernet. iPhone-layout afventer.
3. **Kodet og lokalt kontrolleret:** Musik gemmer kø og afspilningssted,
   genåbner uden automatisk lyd og har betjening over fanehjulet. Lokal film og
   musik tager lydfokus fra hinanden; TV-afspilning stoppes ikke af musikvalg.
   Fortsæt kan åbne TV-betjeningen uden nyt LOAD. Tre nye Swift-tests bestået.
   Cinejoy, iOS-afbrydelser og fysisk Cast er fortsat særskilte releasechecks.
4. **Kodet og lokalt kontrolleret efter brugerrettelse:** Filmhjælp om handling, jokes og opsamling,
   ikke automatisk oversættelse. Tilgængelige replikker og egne scenenoter kan
   bruges, mikrofonen er en valgfri ekstra kilde. Tidligere roller slås op på
   nettet ud fra et valgt skuespillernavn; rollelisten kan findes fra filmtitlen.
   Kun navne fra indhentede kilder tilbydes; der gættes ikke på ansigter.
   Biografi og tidligere film/serier har kildelinks, også til en separat
   filmografi. Den aktuelle film holdes ude af listen over andre film.
   Resuméer bruger kun modtagne uddrag frem til tidspunktet. Ti filmtests
   bestået. Offentlige opslag efter rolleliste og skuespillerbiografi svarede
   på PC uden en API-nøgle. Fysisk TV/iPhone afventer.
5. **Kodet og lokalt kontrolleret:** Miks fra faktisk katalog/bibliotek,
   stemning, valgfri stigende energi, hentet musik, læring fra favoritter og
   tidlige manuelle spring. Valgfri hentet stemme præsenterer starten og skiftet
   i energi. Tre nye Swift-tests bestået; lyd og fysisk iPhone afventer.
6. **Kodet og lokalt kontrolleret:** Spilbar lokal krimi med tre botroller,
   rum, spor, afhøringer, anklage og en konsekvent forklaring. Tre variationsfrø
   og dine valgte botnavne; ingen påstand om ubegrænset AI-genererede historier.
   Gem/fortsæt/slet, valgte hentede stemmer og adgang fra Hjem, agentmenu,
   landsbyens rumgenvej og Fortsæt. Tre nye Swift-tests bestået. iPhone afventer.
7. **Kodet og lokalt kontrolleret:** Gemte personligheder/træk bruges i
   almindelig agentchat. Individuel tone, egne ønsker og valgfri genvej til
   sidste emne. Relevant ældre brugerhistorik hentes kun fra samme agent;
   opgavehandlinger, billeder og dokumentkontekst blandes ikke ind som nye
   tilladelser. Eksisterende valgte stemmer bevares. Tre Swift-tests bestået.
8. **Kodet og lokalt kontrolleret:** Konkret retursag på iPhone med valgt
   Gmail-ordre, returvejledning, lokalt skrevet kladde, eksisterende verificeret
   Gmail-afsendelse og EventKit-påmindelse. Stabil mailopgave-ID og gemt forløb
   på Fortsæt. Oversigten meldes kun færdig efter kvitteringer/aktivt fravalg af
   påmindelse; butikkens svar og fysisk returforsendelse meldes stadig åbne.
   To nye Swift-tests bestået. Ingen rigtig mail sendt. Kontotest afventer.
9. **Kodet og lokalt kontrolleret:** Gemte kreative forløb med valgt tekst- og
   billedagent, redigerbare forslag, eksisterende lokale billedmotor, gemt
   lydhilsen, PDF med sideskift og deling/sletning. Illustrerede agentrum kan
   gemmes lokalt i den eksisterende rumafspiller, også med figurjustering og
   versioner. Ingen påstand om nye 3D-meshes. Hjem/Fortsæt/agentchat er koblet på.
   To Swift-tests bestået; en fundet slettefejl er rettet. PDF-rendering, lyd og
   rumvisning kræver stadig iPhone/Xcode-kontrol.
10. **Kodet og lokalt kontrolleret:** Søg i almindelige chats, billeder,
    projekter, agentfiler, noter, gemte filmsider og musik. Et billede kan
    findes sammen med det nummer, der faktisk spillede, da det blev lavet.
    Resultater åbner den konkrete fil eller det gemte forløb. Agentafgrænsning
    er standard; fælles søgning kan vælges. Gmail-opslag vælges særskilt og
    læser først den mail, brugeren åbner. Privat Studio og Lumis private ID
    indgår ikke. Fire nye Swift-tests bestået. Konto- og iPhone-prøve afventer.

## Samlet lokal kontrol

Alle ti punkter er kodet lokalt. 33 Swift-tests for det nye univers og 39
regressionstests for telefonværktøjer, Gmail og agentarbejde bestod med
prøvedata. Testene sender ingen rigtige mails. Swift-syntaks og registrering
af kilder i Xcode-projektet er kontrolleret på PC.

Der er ikke kørt en fuld Xcode-kompilering eller ContractTests på Mac.
Layout, tastatur, PDF-visning, mikrofon, offline-modeller, stemmelyd og
rumvisning skal prøves på iPhone. Cinejoy på Chromecast med låst telefon
kræver stadig den konkrete TV-prøve. Ingen ny IPA eller push er startet.

Alle eksisterende navne, nøgler og kontrakter bevares. Ændrede Swift-filer højst 600
linjer. Telefonfunktioner og netfunktioner beskrives hver for sig. Ingen
opfundne katalogtitler, opgaver der foregiver at være udført, eller garanteret
Cast på en kilde, der ikke er testet. Xcode og fysisk iPhone/TV er releasechecks.
