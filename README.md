# AI Sweat-Caster til iPhone

SwiftUI-app til iOS 18 og nyere. Første gang kan du vælge **Prøv demo** og bruge appen uden PC, internet eller adgangskode. Demotilstand står øverst på skærmen, og den delbare testvideo er mærket **DEMO** inde i selve billedet. Demojob nulstilles, når appen lukkes helt.

## Åbn på en Mac

1. Kopiér hele mappen til din Mac. Åbn **SweatCaster.xcodeproj** i Xcode 26 eller nyere.
2. Til en hurtig prøve: vælg **SweatCaster** øverst i Xcode, vælg en iPhone-simulator, og tryk **⌘R**. Tryk **⌘U** for at køre testene.
3. Til din iPhone: forbind telefonen med USB, lås den op, og godkend Mac'en på telefonen. Vælg telefonen øverst i Xcode.
4. Vælg projektet **SweatCaster** i venstre side, derefter appmålet **SweatCaster → Signing & Capabilities**. Behold **Automatically manage signing**, og vælg dit team (eller dit Personal Team). Tilføj dit Apple ID under **Xcode → Settings → Accounts**, hvis teamet mangler. Skift Bundle Identifier til et unikt navn, hvis Xcode siger, at det allerede bruges.
5. Tryk **⌘R**. Følg telefonens anvisninger, hvis den beder om Udviklertilstand eller tillid til udvikleren. Brug en Xcode-version, som understøtter iOS-versionen på din telefon.

## Prøv appen

1. Vælg **Prøv demo**, og vælg et eller flere klip.
2. Tryk **Roast**, **Hype**, **Sweaty** eller **Funny NPC**. Demojob behandles ét ad gangen. Du kan stoppe et job, mens det arbejder.
3. Når et job står som **Klar**, tryk **Se testvideo** og derefter **Del video**, hvis du vil prøve iOS' delemenu.

Når Groks server er klar, skal telefon og PC være på samme lokale netværk. Åbn **Forbindelse til PC**, indsæt adressen fra PC’en, fx `http://192.168.1.20:8765/api/v1`. Du kan også skrive den private IPv4-adresse alene, indsæt koden fra PC’en, og vælg **Test forbindelse**. Appen bruger port **8765**. Ved en godkendt forbindelse husker den adressen og gemmer koden i iPhones nøglering.

Vælg **Tillad**, hvis iPhone spørger om adgang til det lokale netværk. Hvis adgangen blev afvist, slå den til under **Indstillinger → Anonymitet og sikkerhed → Lokalt netværk**. iOS kan vise samme forbindelsesfejl ved afvist adgang og ved en utilgængelig PC. Gæstenet kan blokere trafik mellem enheder. Brug et betroet netværk: HTTP krypterer ikke adgangskoden eller videoen på netværket. Appen bruger lokale ATS-undtagelser, private IPv4-adresser og følger ingen HTTP-omdirigeringer. Test LAN-adgang på selve telefonen; en simulatortest bekræfter ikke tilladelsesforløbet.

Appen uploader ingen klip. Den bruger den faktiske jobgrænse, de tilgængelige stilarter og serverens flag for at stoppe job. Kun ffmpeg, ffprobe, Ollama og Piper kan blokere jobstart. Jobstatus vises med den danske titel og serverens engelske besked. Ved stop venter appen på den endelige status. Videoafspilning bruger kontraktens godkendte MP4-download, også hvis serveren tilbyder den valgfrie byte-range-funktion. Appen henter joblisten, når den åbnes, og cirka hvert andet sekund, mens den er i forgrunden med aktive job. Efter et uklart startsvar henter den joblisten uden at gentage POST. Læs listen, før du trykker **Jeg har tjekket listen** og eventuelt vælger klip igen.

## Verifikation

Projektet blev skrevet på Windows. Projektets filreferencer og den delte Xcode-ordning samt Info.plist er kontrolleret med et lokalt script. Swift-koden er ikke kompileret her. XCTest, Simulator, fysisk iPhone, VoiceOver, videodeling og den rigtige PC-server er ikke afprøvet her. Der er ingen signeret app eller IPA.

Testmålet dækker JSON-dekodning, tidsstempler, malformed JSON, API-version, HTTP-fejlsvar, autorisationsheader, batchvalidering, videosøgesti og oprindelse, jobforløb og annullering i demoen samt afstemning uden nyt POST ved timeout. Kør med **⌘U** eller:

```sh
xcodebuild -project SweatCaster.xcodeproj -scheme SweatCaster -showdestinations
xcodebuild -project SweatCaster.xcodeproj -scheme SweatCaster \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro Max' test
```

Vælg en destination fra første kommando, hvis modellen ikke er installeret. Afprøv også på telefonen med **VoiceOver** og største skriftstørrelse: vælg klip, start, følg status, stop et job og del demovideoen.

## Frossen API v1

Chat bruger den foreslåede `POST /api/v1/chat` med `message` og en valgfri klientgenereret `session_id`. ID'et gælder, mens chatvisningen er åben. Appen bruger SSE til status og svar og kræver en `done`-hændelse for at afslutte normalt. Stop lukker modtagelsen på telefonen. Backendens eksisterende jobstop bruges til videokøen. Chatdemoen simulerer svar lokalt.

Afstem den endelige OpenAPI og ios-handoff før livegodkendelse. Bekræft især, om serveren accepterer `session_id`, hvilke HTTP-svar betyder at agenterne ikke er klar, og om værktøjsfejl sendes som `tool_status` eller som en særskilt hændelse. Klienten understøtter foreløbigt `tool_error` som en kort, generisk status. Den sender aldrig chatbeskeden igen automatisk.

GitHub Actions forsøger at køre XCTest i en tilgængelig iPhone-simulator før kompilering og pakning af den usignerede IPA. På en fysisk iPhone skal både preview og den delte fil afprøves med en kendt MP4 med tale fra starten. Preview kan spoles tilbage med **Afspil fra starten**.

Klienten følger handoff fra 6. november 2026. Standardområdet til tekstlæsning er nederst i midten, beskæring står på Automatisk, og støjfjernelse er slået fra. Appen forventer 200 med et opdateret job ved stop og 200 med `video/mp4` ved fuld download.
