# Native Spotube-lydkilde til FadedAI

Dette er en afprøvet fælles lydbro, endnu ikke koblet til appens aktive Musik-fane.

FadedMusicClient tilpasser den konkrete søge- og lydstrømskode fra Spotubes NewPipeService.ios.kt. Den anvender samme Maven-bibliotek som Spotube 6.0: `io.github.yushosei:newpipe-extractor-kmp:1.3.0`. Maven Central er kontrolleret for JVM, iosArm64, iosSimulatorArm64 og iosX64. Initialisering er asynkron og låst, så første kald ikke blokerer Swift-UI'et.

## Resultat af den lokale prøve

Den 17. november 2026 kompilerede Gradle 8.14.3, JDK 21 og Kotlin 2.2.21 denne kode. Den fandt 20 musiknumre og hentede 4096 bytes rigtig `audio/mp4` med HTTP 200 fra et af resultaterne. Ingen API-nøgle, brugerkonto eller FadedAI-PC-tjeneste blev brugt af selve biblioteket. JVM-prøven bruger samme commonMain-kode som iOS.

Kommando: `gradle --no-daemon smoke` i denne mappe. Den lokale testcontainer var begrænset til to CPU'er og 3 GB RAM og er afsluttet. Gradle-cachen er under repoets ignorerede build-mappe.

## Det som stadig skal forbindes og prøves

- Byg den deklarerede FadedMusicCore XCFramework på Mac til de tre iOS-varianter. Den er statisk; byggekæden skal linke den korrekt og kontrollere alle native afhængigheder. Denne native bygning er endnu ikke kørt.
- Brug Swift-importen FadedMusicCore og FadedMusicClient. `searchJson` og `streamJson` returnerer de JSON-felter, som den afprøvede Swift-prototype forventer. Flyt ikke PC-omvejen ind i den færdige app.
- Genbrug kø, playlister, Now Playing og sovetimer fra den bevarede Swift-prototype. Behold danske tekster, glas og Faded-farver.
- Test på rigtig iPhone, at lyd fortsætter ved faneskift, anden app og låst skærm. Test to numre, pause, seek, næste, headset-afbrydelse, nettab, sletning og gem/genåbn playliste. Ingen musik eller sangtekster må sendes til AI.
- Chromecast kræver separat kontrol af receiver og filmkilde. Genbrug lydlivscyklus, hvor det passer, men lad TV'et hente filmen selv. PC-relay skal fortsætte, når telefonen låses; telefon-relay har andre baggrundsbegrænsninger. Den faktiske TV-prøve afventer.

Kilder: https://github.com/team-spotube/spotube/releases/tag/v6.0.0 · https://github.com/yushosei/NewPipeExtractor-KMP

Wrapperen er tilpasset fra Spotube under AGPL-3.0-or-later. Spotubes licens findes ved den bevarede prototype. NewPipeExtractor-KMP deklarerer GPL-3.0-or-later; dens kilde og licens skal følge den native integration ved distribution.
