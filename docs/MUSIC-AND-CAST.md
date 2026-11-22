# Musik og Cast

## 22. november 2026

I Musik kan du sætte en sang på pause, mens den åbner. Fjerner du sangen fra en pauset kø, står den næste klar, til du selv trykker afspil. Spoler du tilbage på Chromecast, bruger FadedAI det nye tidspunkt ved næste forsøg på at genoptage filmen.

PC-relæet afviste det første filmstykke i en prøvefilm med fragmenteret MP4. Efter rettelsen kunne en særskilt testmodtager hente alle tre stykker, efter afsenderen var lukket. FFprobe afkodede alle 30 billeder og AAC-lyden. Otte relæprøver og fem lokale Swift-prøver bestod. Ændringerne i køen og Cast-betjeningen skal prøves på iPhone. Filmstykkerne i prøven havde den medietype, Apple anbefaler til formatet. [Apples HLS-specifikation](https://developer.apple.com/documentation/http-live-streaming/hls-authoring-specification-for-apple-devices/)

Musikafspilleren beder iOS om at fortsætte ved låst skærm. Efter en lydafbrydelse genoptager den kun et nummer, der var sat til at spille, hvis iOS tillader det. Pause fra låseskærmen, sovetimeren eller frakobling af hovedtelefoner annullerer genoptagelsen. Swift-prøven dækkede både genoptagelse og de tilfælde, hvor musikken skal forblive på pause.

Cast giver TV’et tid til at melde tilbage, når iPhone kommer tilbage i appen. Tiden med låst skærm udløser dermed ikke straks et nyt forsøg på at indlæse filmen. En separat testmodtager hentede næste filmstykke fra PC’en med afsenderen lukket efter ti minutters simuleret tid. Låseskærmens lyd og kontrolknapper på iPhone samt Cinejoy på brugerens Chromecast afventer fysisk prøve.

## 19. november 2026

Ændringerne ligger lokalt på `codex/spotube-musik-next-20261117`. Ingen push eller IPA er startet i denne omgang. Denne status erstatter de ældre Eevee- og ByTune-beskrivelser.

## Musik inde i FadedAI

`App/MusicView.swift` er nu en intern afspiller. Spotubes kø- og mediesessionsadfærd er adapteret til Swift med AVPlayer; hele Spotube-appen er ikke indlejret. YouTubeKit 0.4.10 leverer lydudtræk, og den offentlige YouTube-søgning leverer kataloget. Ingen Spotify-login, udviklernøgle eller PC kræves af musikklienten. Spotify-indhold sendes ikke til AI.

Der er søgning, favoritter, playlister, kø, blanding, gentagelse, sovetimer, hentning, annullering og sletning af hentet musik. Afspilleren lever på tværs af faner. Låseskærmens betjening og iOS-baggrundslyd er koblet til AVAudioSession og MPRemoteCommandCenter.

Faktisk katalogsøgning gav 20 resultater gennem den rigtige Swift-parser. Vedvarende favoritter, playlister, genåbning og fjernelse er prøvet lokalt. Udtræk af en aktuel lydadresse, faktisk lyd, låst skærm, afbrydelse ved opkald og hentning på iPhone er **ikke** verificeret. Kildeændringer og utilgængelige numre kan give fejl, som vises i appen med genforsøg.

Kilder og licenser ligger i `Dependencies/Spotube/NOTICE.md` og `LICENSE`. Den ældre Kotlin/NewPipe-prototype er gemt, men den aktive Musik-side bruger Swift-klienten.

## Cinejoy og Chromecast

Brugeren ser engelske film fra [Cinejoy](https://cinejoy.pk/) og bekræftede fysisk, at den nuværende app starter filmen på Chromecast. Filmen stopper, når appen forlades. Hurtig genkomst kan få den til at fortsætte. Dette er en reproduktion af fejlen i den gamle build.

Den nye kode vælger disse ruter for Cinejoy:

1. **PC til TV.** Den parrede PC leverer mediefilen eller de omskrevne HLS-lister og filmstykker til Chromecast. Afspillerens Referer-sti og faktiske browseridentitet bevares. PC’en skal være tændt og kunne nås fra TV’et.
2. **Direkte på TV.** Hvis PC-ruten fejler, prøver Chromecast selv kilden. Denne rute opretter ikke en iPhone-streamserver.
3. **Via iPhone.** Sidste mulighed for kilder med særlige krav. Appen forklarer, at denne rute kræver telefonen vågen. Den er ikke en garanti for baggrundsafspilning.

Underholdning kan bruge en gemt lokal hjemmepairing, selv om chat er forbundet gennem Tailscale. Tailscale-adresser sendes ikke som lokale TV-adresser. Genkomst til appen kontrollerer receiverens aktuelle film før et eventuelt genforsøg, så en film i gang ikke genindlæses.

En lokal HTTP-test lod en særskilt receiver hente hovedliste, underliste og filmstykke med den krævede Referer-sti og browseridentitet, uden telefonens server eller pairing-token. Range, underressourcer, fejlsvar og redirects er kontrolleret. Der er ikke sendt LOAD, pause eller stop til brugerens TV under testen. Den nye rute er **ikke** fysisk testet mod Cinejoy på brugerens Chromecast.

## Filmven uden synlige undertekster

Underholdning → TV → Spørg filmvennen. Skjulte engelske tekstspor bruges, hvor de findes. Ellers kan PC’en hente et afgrænset stykke engelsk lyd og transskribere med lokal Whisper. Tidligere billeder kan beskrives med en installeret lokal visionsmodel. Ingen dialog eller billeder efter TV’ets tidspunkt må bruges.

Filmvennen kan forklare scenen på dansk og vise eller læse den originale engelske replik. Faktisk engelsk lyd fra både mediefil og HLS gav “We met at school.”; den lokale Qwen svarede “De mødte hinanden på skolen.” med den rigtige kilde. Tidsafgrænsede billeder blev også læst korrekt af den installerede Gemma-model. Danskkvaliteten afhænger af den valgte lokale model. Spoling og filmskift rydder svar og stopper igangværende oplæsning.

## Før frigivelse

- [x] PC-relæets rettelse til fragmenteret MP4 blev installeret 22. november. Chromecast viste pauseskærmen, køerne var tomme, og PC-tjenesten svarede efter genstarten.
- [ ] Kør Xcode-kompilering, ContractTests og kontrol af den samlede IPA. Windows-testene erstatter ikke dette.
- [ ] Start Cinejoy på iPhone, cast, skift til Landsbyen, åbn en anden app, og lås skærmen i mindst to minutter. Kontrollér ruten i TV-siden.
- [ ] Åbn appen igen uden, at filmen starter forfra. Prøv pause, søgning og Stop.
- [ ] Spørg filmvennen om en engelsk replik og scenen. Spol tilbage og skift film; tidligere svar må ikke hænge ved.
- [ ] Søg og afspil musik, skift fane, lås skærmen, skift sang og prøv sovetimer. Hent én sang og slet den igen.
