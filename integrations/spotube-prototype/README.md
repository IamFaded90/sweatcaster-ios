# Spotube: arbejde til næste omgang

Dette er en bevaret prototype, ikke appens aktive Musik-fane. Bygning 72 indeholder den hidtidige afspiller. Filerne her skal ikke flyttes til App eller sættes i en IPA, før lydkilden og Mac-kompileringen er prøvet.

Den valgte løsning er en iPhone-tilpasning af Spotube inde i FadedAI. Korrigeret kildekontrol: Spotube 6.0 har en rigtig iPhone-udgave. Brug dens iOS-integration som udgangspunkt, så musik ikke unødigt kræver PC’en. Den indbyggede lydkilde er YouTube. Spotify-indhold og musiktekster må aldrig sendes til AI.

## Konkrete kilder

- Spotube, undersøgt ved commit `5768ad7568665130bdbc057348bc2b9e1cf8cc38`.
- `composeApp/src/commonMain/kotlin/org/spotube/spotube/core/audioplayer/DeviceAudioPlayerQueue.kt`: kø, valg af nummer, flytning, fjernelse og genåbning. De tilpassede Swift-køfunktioner i MusicQueue.swift er prøvet lokalt.
- `composeApp/src/iosMain/kotlin/org/spotube/spotube/core/newpipe/NewPipeService.ios.kt`: søgning og lyd med `io.github.yushosei:newpipe-extractor-kmp:1.3.0`. Der findes fuld iOS-kode; en tidligere vurdering om manglende iOS-understøttelse var forkert.
- `iosApp/iosApp/VlcPlayerEngine.swift` og `NativePlayerEngine.kt`: Spotubes afspillerkontrakt og MobileVLCKit. Afspilning og events skal køre på hovedtråden. Aktivér AVAudioSession playback, og behold afspilleren ved faneskift.
- https://github.com/team-spotube/spotube/releases/tag/v6.0.0 har en iOS-IPA og beskriver baggrundsafspilning.
- https://github.com/yushosei/NewPipeExtractor-KMP har init, søgning, stream extraction, desktop-test og iOS-eksempel. Initialisering er `NewPipe.init(DefaultDownloaderImpl.initDefault())`.

## Afprøvning

- MusicQueue.swift bestod en rigtig Swift-test af indeksgrænser, aktuelt nummer efter flytning/sletning, indsæt som næste, gem/genåbn playliste og tøm kø.
- AVPlayer-, Now Playing-, fjernbetjening- og sovetimerprototypen er syntakskontrolleret, men ikke typekontrolleret på Mac eller prøvet på iPhone. Den er derfor ikke klar til release.
- Den alternative Python/PC-kilde fandt 12 søgeresultater. En opdateret yt-dlp-læser fik én gang HTTP 200 og 4096 bytes, men efterfølgende prøver fik 403, også med en lokal token-hjælper. Det er ikke en bestået afspilningstest. Dette spor er ikke installeret i den kørende PC-app.
- Testpakken ligger isoleret under build/music-test-env. Den midlertidige Docker-container fadedai-music-proof-test er stoppet. Ingen brugerlogin eller adgangskoder blev brugt i musiktæstene.

## Før release

1. Genbrug NewPipe-iOS-kilden via en lille Kotlin/Native-bro eller en dokumenteret tilsvarende iOS-løsning. Undersøg de nødvendige JVM- og iOS-artifacts før byggeopsætningen ændres. Behold Faded-UI'et.
2. Test faktisk lyd fra mindst to numre, søgning, næste/forrige, kø, gem/genåbn playliste, slet og sovetimer. Ingen model skal have adgang til lyd eller sangtekster.
3. Test faneskift, anden app, låst skærm, hovedtelefoner, afbrudt net og lyd fra chat/video. Timerstatus og kø må ikke skrive til disk hvert sekund.
4. Kør Mac-typekontrol og eksisterende ContractTests. Ingen udskiftning af den aktive afspiller før dette består.

AGPL-licensen og kildehenvisningerne skal følge den tilpassede Spotube-kode. LICENSE er Spotubes licens.
