# Plan: lydreference til ACE-Step på iPhone

Status: **modelklargøring er kodet separat, men ikke testet på iPhone**.
Lydreferencegenerering er ikke klar til brug. Dette er ikke en build- eller
pushordre. Klargøringen ændrer ikke den nuværende tekst-til-sang-vej. Gennemfør
kun et iPhone-build, når det er godkendt særskilt.

Den nye `PhoneSongReferenceModels` i `OfflineSongRuntime` tilbyder særskilt
status, klargøring, annullering, sletning og et kontrolleret resultatbibliotek.
Den kalder en afgrænset downloader, rekonstruktion, strømmet encoderkonverter
og genopretning af egne forældreløse mapper. Eksisterende modelstatus og
installation er fortsat separate. API'et har ikke en generel lease, der
forhindrer sletning, mens andre direkte API-kald bruger resultatmappen; den
aktuelle app skal derfor fortsat blokere sletning under generering.

## Hvad skal de to typer lyd gøre?

- **Inspiration/stemmeprøve:** En lydfil giver modellen oplysninger om klang
  og stil. Det garanterer ikke, at sangstemmen bliver en genkendelig klon.
- **Remix:** En kildefil giver en guide til en ny version. Den skal følge
  kildens faktiske længde og behandles separat fra en kort stemmeprøve.

## Foreslået afskærmning

1. Den separate modelklargører er implementeret, men er endnu ikke verificeret
   ende til ende. Et deaktiveret referencevalg skal fortsat følge præcis den
   eksisterende `PhoneSongEngine.generate`-vej.
2. Modelstatus og ekstra filer er adskilt fra `PhoneSongAsset.all` og
   `PhoneSongEngine.installed`. Vis ikke referencegenerering som klar, før de
   nedenstående enheds- og lydtests er gennemført.
3. Under det afslåede eksperiment kan en filvælger senere tilføjes i
   `App/SongStudioView.swift`; tilgængelige lokale favoritter skal behandles
   som filer, mens en streamingfavorit uden lokal lyd ikke er en lydreference.
   `App/PhoneSongStudio.swift` og `PhoneSongInput` skal først derefter kunne
   føre filens kontrollerede, midlertidige URL videre. Undgå at gemme store
   lydfiler som `Data` i `SongDraft`.

## Ekstra modeldata

Kilde og kontrollerede byteintervaller står i `official-range-manifest.json`;
komplette kilder matcher SHA-256 for den fastlåste officielle revision.
`locally-derived-header-digests.json` indeholder header-hashes, og manifestet
indeholder udsnitshashes: **begge typer udsnitshash er beregnet lokalt**, ikke
officielt udgivne selvstændige hashes. Beskyt og versionslås begge filer før
brug; en hash hentet fra samme ubeskyttede svar som data er ikke tilstrækkelig.

| Del | Råt BF16-udsnit | Efter konvertering | Anvendes til |
| --- | ---: | ---: | --- |
| VAE encoder | 168.562.688 byte | 168.544.912 byte FP16 | Lyd til 25 Hz-latenter; også nødvendig til en lydreference. |
| FSQ tokenizer | 210.064.396 byte | 210.068.484 byte FP16 | Standard-remix: 25 Hz-latenter til 5 Hz-koder. |

De nødvendige nye rå udsnit og konverterede filer kan midlertidigt kræve ca.
758 MB tilsammen, plus headers, arbejdsfiler og plads til den eksisterende
model. Mål det faktiske pladskrav og ryd kun forsøgets egne filer op. `ACEHints`
og de eksisterende hints-vægte er allerede detokenizeren, ikke tokenizeren.

`RangeFileDownload.swift` kan i researchudgaven anmode om absolut start/slut
inde i den større kildefil og validere kildens fulde `Content-Range`. Lokale
fixtures har testet korrekte og forkerte ranges og genoptagelse fra ikke-nul
offset. En Swift-prøve på PC har desuden hentet 64 KiB fra hver rigtig, fastlåst
model-URL gennem én redirect med det forventede interval og ETag; begge
matchede de verificerede lokale filer. Annullering videresendes nu til
URLSession og er testet på en langsom lokal fixture; en færdig blok blev
bevaret, og genoptagelse lykkedes. Hele udsnit, iPhone, ændrede ETags,
annullering mod en rigtig server og alle mulige timingløb er ikke testet.

Runtime-klargøreren genskaber originalt BF16-format og bruger en strømmet
encoderkonverter til weight-normalization og Conv1d-layout. Tokenizervægtene
bevares i BF16 med eksisterende matrixlayout. Filerne anbringes i et særskilt
versionsbibliotek, og en pointer skiftes først efter kontrol af begge filer.
Den samlede proces er testet ende til ende på PC med lokale, verificerede
modeludsnit og en simuleret URL-forbindelse, inkl. annullering, genoptagelse og
sletning uden at røre den eksisterende tekstmodel. Den er endnu ikke testet
ende til ende mod den rigtige server eller målt på iPhone.

## Lyd og modelkæde

1. Lav en **separat** iPhone-lydindlæser, der læser valgt fil med
   sikkerhedsscope, afviser tom/stille eller ulæselig lyd, og resampler til
   48 kHz stereo. Den eksisterende `App/SongReferenceAudio.swift` laver 24 kHz
   mono til PC-vejen og må ikke ændres, så den eksisterende funktion forringes.
2. For klangreference vælges 3 × 10 sekunder efter `ReferenceAudioPlan.swift`;
   korte klip gentages som PC-reference. Tilpas til 1.920 samples pr.
   latentframe. Test filformater, mono/stereo, korte/lange klip og afrunding.
3. Indlæs `ACEAudioEncoder.swift` separat og afvikl i vinduer. Sampel de
   64-dimensionelle 25 Hz-latenter med en kontrolleret seed; sammenlign mod
   PC-orakel. Slip modelvægte før næste trin via `GenerationSupport.swift` /
   `StageMemory.release`, og kontrollér faktisk hukommelse på enheden.
4. I `ACEPipeline.swift` bruger `ACEGenerator.generate` nu 750 stille frames
   til `ACEConditioning.encode(...timbre:)`. Under forsøgsflaget kan de
   verificerede reference-latenter i stedet gives til det eksisterende argument;
   uden flag/reference skal de 750 stille frames og hele tekstvejen være uændret.
5. Standard-remix kræver særskilt kildeindlæsning, 5-frame-patches gennem
   `ACEAudioTokenizer.swift`, FSQ-koder og den eksisterende `ACEHints`
   detokenizer, før `ACEPipeline.diffuse` får guiden. Afstem med PC-referencens
   instruction, kildevarighed, padding, masker, seed og cover strength. Den
   mulige `cover-nofsq`-variant er ikke ækvivalent og må ikke kaldes færdig
   eller erstatte standard-remix uden sammenlignings- og lytteprøver.

## Testporte før aktivering

- **PC:** Eksisterende test af 15 referenceudvælgelser, header/range-hashes,
  rekonstruktion af alle 183/32 tensorer, konvertering og fejl ved download.
  Tilføj tests for absolutte HTTP-ranges, redirect, afbrudt hentning, parallelle
  forsøg og at fejl ikke ødelægger en allerede installeret tekstmodel.
- **Apple-platform:** Kompilér isoleret, verificér CryptoKit-grenen og sammenlign
  encoder/tokenizer mod faste PC-fixtures, inkl. korruption og outputform. Mål
  faktisk peak-RAM, diskplads, afbrydelse og temperatur på den rigtige iPhone.
  Linux-testens ~645 MiB var containerens konvertering, ikke et iPhone-tal.
- **Lyt og regression:** Lav korte nye sange, en stilreference, en
  stemmereference og et remix. Kontroller faktisk varighed, at resultatet kan
  afspilles, og at eksisterende tekst-til-sang stadig virker både før og efter
  forsøget. Bedøm om stemme og stil faktisk er anvendelige, uden at love en
  bestemt kvalitet før prøven.

Ingen af disse punkter er dokumenteret som gennemført på iPhone endnu.
