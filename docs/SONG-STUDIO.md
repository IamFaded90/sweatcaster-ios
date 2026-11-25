# Sangstudie · lokal status

25. november 2026. Ingen push, IPA eller cloudbygning bestilt.

ACE-Step 1.5 beholdes. Windows bruger den officielle API; iPhone-koden bruger
den åbne 2B-konvertering fra [WhisperKit](https://github.com/yu314-coder/WhisperKit).
Nativepakken er ikke Argmaxs talegenkendelsespakke.

## På telefonen

Musik → Skab en sang eller et remix → Skab på denne iPhone. Modellen hentes
én gang (cirka 10 GB), derefter er ny sang/instrumental
lokal uden PC og internet. Filer indlæses i adskilte stadier. Der er stop- og
sletknapper; ingen automatisk modelindlæsning efter hentning eller appstart.
En kort stil som “hiphop” udvides med synlige musikdetaljer. Udvidelsen kan
slås fra og respekterer f.eks. ingen trommer, intet omkvæd og angivet tempo.
En tom sangtekst får et originalt forslag fra den valgte telefonmodel.

Denne native vej er **kodet, men endnu ikke Apple-kompileret eller kørt på
brugerens iPhone**. MLX 0.31.4 er valgt for den aktuelle værktøjskæde, mens
upstream bruger 0.31.6. Første Core ML-klargøring, RAM-top, korrekt lyd og
afbrydelse skal prøves på rigtig enhed. Foreløbig kræver generation forgrund.

Favorittens navn kan give stilinspiration efter research. Navnet er ikke
adgang til musikken. Et faktisk lydremix og egen optagelse som stemmereference
bruger foreløbig PC-valget. Ingen skjult netværksfallback fra iPhone-valget.
Apple Personlig stemme er til tale og er ikke dokumenteret som sangstemme.
Der er endnu ingen prøve, der beviser brugerens egen sangstemme.

## På PC

Isoleret runtime: `F:/FadedAI/song-studio`, officiel ACE-Step v0.1.8,
revision `dce621408bee8c31b4fcf4811682eb9359e1bc94`, eget Python-miljø,
Torch 2.7.1 CUDA 12.8 og egne model/cache/tmp-mapper. Ingen eksisterende
FadedAI-service er genstartet eller udskiftet. API bindes kun til 127.0.0.1:8001.
Testopsætningen kørte uden LM-planner (`thinking=false`); højere kvalitet med
planlægger og egen stemme skal stadig vurderes med lytteprøver.

Backendtilføjelsen giver parrede, idempotente job, vedvarende status,
genoptagelse af kendt job uden genafsendelse samt hentning/sletning af lyd.
Usikker afsendelse bliver ikke automatisk gentaget. Midlertidig afbrydelse ved
polling beholder det kendte job. Kilden ændres aldrig.

Reelle lokale prøver lykkedes:

- Ny 30,0 sek. instrumental: 48 kHz stereo PCM16, RMS 0,1279, peak 0,8912.
- Remix af samme originale prøve: færdig WAV, trimmet med kort fade til de
  valgte 20,0 sek. Ingen løkke eller stilhed bruges til at forlænge korte svar.
- ACEs float-WAV konverteres til PCM16. Den første rigtige prøve fandt denne
  inkompatibilitet; rettelsen er dækket af en regressionstest.
- 13 Python-prøver for kø, lyd, afbrydelser, idempotens og sletning bestod.
- HTTP-rutetest med det eksisterende backendgrundlag bestod: parring,
  cachebeskyttelse, fejlagtigt input, samme anmodning og sletning.
- Swift-kontroller køres særskilt fra den manglende fulde Apple-kompilering.
  Derudover kontrolleres det præcise modelmanifest mod GitHubs udgivelsesfiler.
  41 app-modelprøver og 3 særskilte manifestprøver bestod efter rettelserne.
  App, tests og native kernel passerer Swift-syntakskontrollen. Projektet har
  780 konsistente Xcode-objekter. Disse kontroller validerer ikke Apple-kernen
  eller MLX 0.31.4 numerisk på iPhone.

Lokale lydprøver og logfiler ligger under ignoreret `build/phone-song-research`.
Ingen personlige optagelser, mails eller nøgler bruges i prøverne.

## Mangler før frigivelse

Apple-kompilering og reel native generation; lytteprøver, inklusive vokal;
eksakt kvalitet ved referencesang og egen optagelse; konfliktfri, gentagelig
start af PC-runtime via den eksisterende genvej; integrationstjek i den samlede
app. Den native tekst-til-musik-vej gør ikke native lydremix/voice conversion
færdig. Ingen påstand om fuld funktionslighed mellem iPhone og PC.

## Opfølgning · 25. november

Genoptagelse af en afbrudt modelhentning prøver nu et nyt downloadlink én gang,
hvis det gemte link er ugyldigt eller ikke længere kan genoptages. Kun HTTP
200/206 og den forventede filstørrelse accepteres. Filstørrelseskontrollen er
ikke en kryptografisk kontrolsum. Downloadkoden er typekontrolleret med en
lokal shim for Apples genoptagelses-API; selve iPhone-netværksflowet mangler.

Den færdige sang kopieres på disk uden først at indlæse hele WAV-filen i RAM.
En ny prøve kontrollerer indhold, at originalen bevares, og at en eksisterende
sang ikke overskrives. Ved skift mellem iPhone og PC beholdes valgte musik- og
stemmereferencer til PC-forløbet, indtil brugeren selv fjerner dem. De bruges
ikke fejlagtigt som reference i den nuværende telefonmotor. 119 portable Swift-
prøver består; appens native Apple-kompilering og iPhone-prøve mangler stadig.

Det nuværende Swift-port mangler både VAE-encoder og audio-tokenisering til
lydreferencer. Den undersøgte MIT-kandidat xocialize/mlx-ace-step-swift har
referencefunktioner til macOS, men dens dokumenterede cover-forbrug ligger på
cirka 15–18 GB på en Mac. Det er ikke en iPhone-måling og kan ikke antages at
passe i telefonens målte RAM-råderum. En reel iPhone-implementering kræver
separat port/konvertering, numerisk sammenligning og fysisk RAM-/lydprøve.

PC'ens eksisterende FadedAI-genvej er nu koblet til `tools/Start-SongEngine.ps1`.
Motoren starter uden at indlæse selve modellen, før en sang bestilles. Ved
prøven tog kold start længere end 45 sekunder; scriptet opdager den allerede
startende proces og starter ikke en ekstra. ACE-Step-sundhedssvaret blev læst,
og to gentagne startforsøg fandt den samme proces. Den installerede scriptskopi
og genvejens kald er kontrolleret; en fuld genstart via hele genvejen og ny
lydgenerering er ikke prøvet i denne opfølgning. En backup af den tidligere
startfil ligger ved siden af scriptskopien. Første egentlige bestilling afslørede,
at en kold modelindlæsning kan tage mere end den tidligere 60-sekunders
HTTP-grænse; backendkoden venter nu op til seks minutter på at få job-ID'et,
mens andre forespørgsler fortsat har deres hidtidige grænse. Usikker afsendelse
bliver stadig ikke automatisk gentaget. Fjorten Python-prøver består.
En ny 10,0 sekunders instrumental blev genereret gennem den lokale motor og
downloadet som 48 kHz stereo WAV. Eksisterende jobprøver kontrollerer, at et
midlertidigt forbindelsesbrud ved polling genoptager det kendte job frem for
ny afsendelse. Sangrutens kode er nu også lagt i den installerede PC-server. Serverprocessen
er endnu ikke genstartet, så den kørende server har ikke indlæst opdateringen.

Native remix, stemmelighed og reel Apple-kompilering er fortsat åbne. Ingen
push eller build er startet i opfølgningen.


## Yderligere PC-integration · 25. november

Den installerede PC-kode er kontrolleret mod den eksisterende version, før
sangruterne blev tilføjet. Femten Python-prøver bestod med en isoleret kopi af
den installerede backend. En separat ende-til-ende-prøve sendte et job gennem
samme ruter til den rigtige lokale motor og kontrollerede den færdige 10 sekunders
WAV. Prøven brugte en midlertidig mappe; den installerede server er ikke blevet
genstartet og den nye rute er derfor endnu ikke aktiv for telefonen.

## Lokal rettelse · fortsættelse

En afbrudt download forsøges højst én gang forfra, hvis det gemte resume ikke
kan bruges. Fejl og afbrydelse bevarer tilgængelige resume-data. Lokalt færdige
sange kan gendannes i sanglisten ud fra de gemte joboplysninger. Manglende cover
forhindrer ikke længere, at en færdig sang registreres i musikbiblioteket.
120 portable Swift-prøver og 15 Python-prøver består. Downloadens faktiske
genoptagelse og sangafspilning mangler fortsat at blive prøvet på iPhone.

Et eksperimentelt første trin til lokal lydreference findes nu under
`research/ace-step-iphone`, uden for appens byggeproces. Encodervægtene er
konverteret fra PC'ens eksisterende model uden at ændre originalen; PC-prøver
sammenlignede resultatet med originalen. Det er ikke et færdigt remix: den
manglende lydtokenisering, sammenkobling, iPhone-kompilering, RAM-måling og
lytteprøve mangler. Se forskningsmappens README for målte afvigelser.

Et andet eksperimentelt trin til lydtokenisering ligger også uden for appens
byggeproces. En separat PC-prøve med de originale og de eksporterede vægte
gav samme koder; en uafhængig prøve af kvantiseringen sammenlignede 2.048
syntetiske vektorer. Swift-filerne passerer syntakskontrol, men er hverken
typekontrolleret mod Apple/MLX eller kørt på iPhone. Ingen funktion er slået
til på dette grundlag.

ACE-Step-serveren har ingen dokumenteret annullering af et enkelt aktivt
job i den installerede udgave. Den opdaterede sletterute rapporterer derfor,
om motoren kan fortsætte efter sletning, så appen kan fortælle det. Resultatet
betyder ikke, at motorens egen midlertidige outputfil er fjernet. Tyve
backendprøver består; den seneste kode er endnu ikke aktiveret i PC-processen.

Mens sangstudiets PC-visning er åben, opdateres aktive job nu automatisk,
og netværksfejl beholder seneste kendte status frem for at genstarte jobbet.
Den nye slettebesked og statusopdateringen er kodekontrolleret; selve
SwiftUI-visningen er endnu ikke afprøvet på iPhone. De seneste lokale
kontroller omfattede 121 portable Swift-prøver og 20 backendprøver.

Hvis Windows holder en fil fra et slettet sangjob åben, markerer serveren
oprydningen som afventende og prøver igen, også efter genstart. Oprydningen
rammer kun sangjobbets kendte lyd- og referencefiler samt den afgrænsede klippekopi. 23 lokale
backendprøver består, herunder en reel Windows-fillås. Denne udgave er lagt
på den installerede PC-server, men den kørende proces er ikke genstartet.


## Remixlængde · 25. november

ACE-Step bestemmer et remix' varighed ud fra kildelyden. En virkelig prøve med
en 10-sekunders kilde og et ønske om 20 sekunder gav kun 10 sekunder. Appen
forbereder nu op til tre minutter af en musikreference, mens stemmeprøven
fortsat er kort. Backend afviser et remix, som er længere end kilden, og
viser en konkret forklaring. Til kortere remix bruges en separat trimmet
kopi, så motoren ikke behøver behandle resten og originalen forbliver intakt.
En faktisk ACE-prøve lavede et 10 sekunders remix af en 20 sekunders kilde
og bekræftede byte-identisk original og oprydning af klippekopien. Prøven
beviser ikke musikalsk kvalitet eller iPhone-forløbet. 27 backendprøver og
121 portable Swift-prøver består. Den opdaterede PC-kode ligger på disk,
men den kørende server er ikke genstartet.

Til iPhone-remix er der nu et eksperimentelt manifest med fastlåst kilde og
integritetskontrol i `research/ace-step-iphone/official-range-manifest.json`.
Begge nødvendige udsnit blev streamet direkte fra den officielle kilde og
kontrolleret for byteantal og SHA-256 på PC’en; der blev ikke gemt modelkopier
under denne prøve. Den officielle tjeneste angiver hash for hele filer;
udsnittenes hashes er udledt lokalt fra filer, der matcher de officielle hashes.
En Swift-plan for valg af lydudsnit har bestået PC-fixtures. Modelhentning og
konvertering er endnu ikke indbygget i appen, og ingen iPhone-prøve er udført.

En separat Swift 5-prototype henter modeldata i kontrollerede blokke. En lokal
HTTP-prøve viste genoptagelse efter afbrydelse og afvisning af forkert status,
interval, ETag, blokstørrelse og fejlet slutkontrol. Den er ikke integreret:
betroet manifest, streaming-SHA-256, samtidig hentning, diskfejl og realistisk
iPhone-/servertest mangler før produktionsbrug. Lydimportens afbrydelse er
forbedret i appkoden, men selve AVFoundation-stien er ikke kørt på iPhone.

Foreløbigt afviser prototypehentningen en servers forkerte svar for sent:
en server, der ignorerer Range, kan nå at sende hele modelkilden først.
Dette er fundet ved kodegennemgang og skal rettes og prøves, før prototypen
kan bruges til andet end research. Den kører ikke i appen.

Efterfølgende blev prototypen ændret til at annullere anmodningen eksplicit
ved forkert HTTP-svar. I den lokale Linux-prøve stoppede forbindelsen efter
32.768 byte af et forkert svar på 67.108.864 byte; genoptagelsesprøverne
bestod igen. Dette er ikke en iPhone-test eller en test mod modelserveren,
så hentekoden forbliver uden for appens byggeproces.

En isoleret rekonstruktionsprøve har nu genskabt modeldele fra de originale
filheaders og de verificerede byteudsnit. Otte syntetiske tests bestod, og alle
183 encoder- og 32 tokenizer-tensorer blev sammenlignet med PC-originalerne.
Midlertidige testfiler blev fjernet. Resultatet er fortsat et forskningsstadie
i originalt BF16-layout; det er ikke konverteret eller kørt på iPhone.

En eksperimentel Swift 5-konverter har på en lille kunstig testfil givet
bit-identiske resultater med Python-konverteren og afvist bl.a. ugyldige
vægtpar og overskrivning. Det er ikke en test af den fulde model eller af
iPhonens RAM og MLX. Alt ligger fortsat uden for appens byggeproces.

En fuldmodelprøve af Swift-konverteren blev efterfølgende kørt isoleret på
PC: 183 indgangs- og 146 udgangstensorer, uden GPU eller netværk. Alle navne,
former og datatyper matchede Python-eksporten; 109.542 af 84.264.832 værdier
afvigede, højst 0,0001220703125 absolut. Containerens målte hukommelsestop
var cirka 645 MiB inklusive containerens øvrige hukommelse og cache; det er
ikke en iPhone-måling. Forskellens lydmæssige betydning er ikke afprøvet.

En isoleret Swift 5-rekonstruktion af den rigtige encoder blev sammenlignet
med Python-resultatet: alle 183 tensorer havde identiske BF16-bitmønstre.
Syntetiske prøver afviste korrupt header, korrupt data og overskrivning.
PC-testen bruger OpenSSL; Apples CryptoKit-sti og iPhone er ikke testet.

Den samme Swift-prøve blev også kørt på den rigtige tokenizer: alle 32
tensorer matchede Python-rekonstruktionens BF16-bitmønstre. Kun midlertidige
prøvefiler blev brugt og fjernet; iPhone-/CryptoKit-prøve mangler stadig.

Forsøgshenteren understøtter nu absolutte offsets inde i en større fil.
PC-fixtures viste korrekt genoptagelse og afvisning af forkerte intervaller.
En separat Swift-prøve hentede 64 KiB fra hver af de to officielle modeldele,
fulgte redirects og kontrollerede ETag, Content-Range og identisk indhold.
Task-annullering videresendes endnu ikke til URLSession; iPhone og store
gyldige overførsler er fortsat ikke afprøvet. Henteren er ikke i appen.

Den eksperimentelle modelhentning kan nu annullere en langsom overførsel og
genoptage fra sidste hele blok i en lokal Swift 5-prøve. Der er også skrevet
separat iPhone-lydforbehandling og remixrouting under research. Rene Swift-
prøver dækkede lydgrænser, padding, ugyldige værdier og annullering; 120
remix-fixtures matchede beregninger fra den installerede PC-motor. AVFAudio,
MLX, hukommelsesforbrug og faktisk lyd på Apple-hardware er stadig uafprøvet,
og funktionerne er ikke sat til i produktionsappen.

## Arbejde med sammenkobling

Efter forskningsprøverne er separate lydforberedelses- og runtimefiler nu
lagt i appens kildekode, sammen med valg af musik- og stemmefil på iPhone.
Tekst-til-sang bevarer den tidligere rute, når der ikke vælges reference.
Den særskilte modelklargører og den sidste sammenkobling er stadig under
udvikling. Disse nye runtimefiler er kun lokalt syntakskontrolleret; Apple-
typekontrol, iPhone-RAM, lydkvalitet og hele remixforløbet er ikke verificeret.
Ældre afsnit om, at samtlige runtimefiler kun ligger i research, beskriver
status før denne sammenkobling. Ingen IPA/build eller push er lavet.

Appkoden rydder nu også sine egne efterladte midlertidige reference-WAV'er
ved sangstudiestart og før en ny reference. En lokal Swift-prøve bekræftede,
at andre filer, mapper og symbolske links i testmappen blev bevaret.

Modelklargøreren er nu koblet på iPhone-koden med separat status, hentning,
annullering og sletning. En samlet Linux/Swift-prøve brugte faktiske,
verificerede modeludsnit over simuleret HTTPS og dækkede afbrydelse,
genoptagelse, integritet, genbrug og separat sletning; en kontrolfil for den
eksisterende sangmodel blev bevaret. Filerne er koblet til sangmotorens
referencevej. Dette beviser ikke Apple-kompilering, Filer-scope, MLX-inference,
iPhone-RAM eller hørbar kvalitet; det er åbent til den samlede iPhone-prøve.
