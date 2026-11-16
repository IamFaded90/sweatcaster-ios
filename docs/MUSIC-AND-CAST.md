# Musik og cast — lokalt arbejde, endnu ikke frigivet

## Musik: Eevee-valget erstatter Spotify/Composio

Brugeren har afvist den tidligere Spotify Web API/Composio-musikside på grund af opsætningen og valgt EeveeSpotifyReincarnated. Den nye Musik-fane er en enkel genvej via `spotify:` til den installerede Spotify-kompatible app. Den kræver ingen PC, Premium-kontrol eller udviklernøgle i FadedAI. Login og musikafspilning sker i den separate app.

Det er ikke indlejret Eevee eller en ny musikmotor. Ingen Eevee-kode eller IPA er hentet/installeret. Hvis både Spotify og Eevee registrerer samme URL-skema, bestemmer iOS, hvilken app der åbner. Hvis åbning afvises, viser FadedAI en forklaring og et link til det valgte projekt. Der er ingen automatisk browser-fallback eller falsk melding om vellykket afspilning.

`MusicAPI.swift`, PC-musiktjenesten, dens installations-/lifecyclekoblinger og de tilhørende mock-tests er fjernet. De tidligere otte musiktests er derfor ikke validering af den nye genvej. Andre Composio-forbindelser er uændrede. API-filopdelingen er beholdt med uændrede metodekroppe og højst 600 linjer pr. berørt Swift-fil.

Eevees README beskriver et tweak til Spotify; deres IPA-workflow kræver en separat Spotify-IPA som input. Der foreligger ingen sådan inputfil i denne opgave, og installation på iPhone er ikke bekræftet. Der er ikke startet builds eller signering. Almindeligt login inde i en installeret Eevee er noget andet end automatisk installation eller indbygning i FadedAI. Projektet angiver også, at Spotify Connect stadig har kontoens serverbegrænsninger.

## Gemt til senere

[ByTune](https://github.com/rishiteja21/ByTune) er gemt som et muligt udgangspunkt for kø, miniafspiller og sovetimer. Brugeren prøver Eevee på sin iPhone først. Musik-fanen bruger den eksisterende genvej, og ByTune er ude af denne samlepakke.

## Cast

Normal cast prøver nu originalkilden direkte på TV’et. HLS-format inspiceres som før, men video og eksterne undertekster får direkte adresser ved direkte cast. Hvis direkte indlæsning fejler eller ikke starter, bruges eksisterende cookie-/headerbevidste iPhone-proxy med de tidligere begrænsede genforsøg. Hvert LOAD har sit eget forsøgs-id og sin egen delegate, så gamle svar ikke afslutter et nyt forsøg.

Fjernbetjeningen viser **Direkte på TV**, når receiveren bekræfter aktiv direkte afspilning. Denne rute behøver ikke iPhone-streamen. **Via iPhone** forklarer, at app og skærm fortsat skal være åbne. Cast SDK er sat til ikke automatisk at stoppe receiveren, når sender-sessionen afsluttes; Stop-knappen stopper stadig filmen. Den lokale kø starter ikke automatisk næste film, når iPhone er lukket.

Der er **ingen PC-videoproxy** i denne ændring. Derfor kan vi ikke love slukket skærm for alle websites. DRM, cookies, kildens IP-/headerkrav og TV’ets codec-understøttelse gælder fortsat. Direkte cast, genforbindelse, undertekster og fallback er **ikke prøvet på fysisk TV/iPhone** her.

## Kilder og kontrol

- [EeveeSpotifyReincarnated](https://github.com/SideloadLabs/EeveeSpotifyReincarnated) og `.github/workflows/build-and-release-yourself.yml`: undersøgt; ikke installeret eller indlejret.
- [ClickAppz](https://github.com/ClickAppz/Spotify-Premium-IPA): træet indeholder kun README og LICENSE. Ingen genbrugelig afspillerkode. README modsiger sig selv om downloads; påstandene er ikke afprøvet.
- [Square](https://github.com/Lelonio/Square): Android-projektet er ikke længere valgt til musikdelen.
- [Google Cast iOS](https://developers.google.com/cast/docs/ios_sender/integrate): eksisterende CastBrowser og SDK genbruges.
- Streaming-topiclinks undersøgt: ingen ny filmapp installeret.

Xcode-filreferencer kontrolleret: 342 objekter. Swift-syntaks kontrolleres med tree-sitter, ikke Xcode. Før frigivelse mangler Mac-kompilering/ContractTests samt iPhone-test: Musik åbner den ønskede Eevee-installation; login, skift tilbage til FadedAI, låst skærm, ingen installeret handler og både Spotify/Eevee installeret. Cast mangler fortsat fysisk TV-test af direkte MP4/HLS, fallback, undertekster, genforbindelse og Stop.

Ingen push, merge eller IPA startet.
