# Ny landsbygrafik · lokal integration 16. november 2026

Status: implementeret lokalt. Ingen push eller ny IPA i denne omgang. Grafikfiler, projektregistrering og syntaks er kontrolleret på Windows. Xcode-kompilering, ContractTests og iPhone-prøven er endnu ikke kørt for disse ændringer.

## Med i appkoden

| Design | Integration |
| --- | --- |
| 5 mænd | Adam, Atlas, Milo, Noah og Theo i en separat figurvælger. |
| 5 kvinder | Eva, Luna, Iris, Nova og Saga i samme figurvælger. |
| Stabil identitet | `VillageBot.villageFigure` gemmes i eksisterende profil-JSON. Ældre profiler får samme navn/UUID-baserede figur som før. Profilfoto, navn, stemme og landsbyfigur er adskilte. Skabeloner og backup tager figurvalget med. |
| Dag og nat | To rene kort uden fastmalede personer. Forskellige bygninger til forskningsværksted, café, mediestudie og sovekrog. |
| Vindueslys og dybde | Native lyslag om natten; bygningernes oprindelige pixels tegnes som forgrund over figurer, der går bag dem. Samme kortkoordinater til grafik og tryk. |
| Kortstyring | Låst som standard. Zoomskyderen virker fortsat. Brugeren kan låse panorering op og nulstille kortet. |
| Alle fire rum | De leverede indendørsbilleder bruges på hver sin bygningsside. Botprofil og computer får rum efter valgt figur. |
| Kirkegård | Det fejlnavngivne `building-workshop.png` er i virkeligheden kirkegården og bruges dér. Eksisterende mindeliste og slet/fortryd-flow bevares. |
| Kontorer | `memory-garden.png` er i virkeligheden det personlige kontor. `office-slice.png` bruges i Skaberværkstedet. |
| Harper og Lumi | Store portrætter, blink og to mundåbninger. Samme ejerskab og ord-/lydniveau-signaler som eksisterende oplæsning. Separat portrætside; ingen ekstra lydafspiller. |
| Bevægelse | Gang bruger forskellige billedceller. Arbejde, tale, hvile og søvn får native bevægelse/rekvisitter. Reducer bevægelse og baggrund stopper animationen. |
| Glas | Figurkort, valgmarkering, rumrammer og kortets låseknap bruger appens eksisterende glas-komponenter. |

## Bevidste afgrænsninger og resterende kvalitetskontrol

- Den oprindelige leverance var en prøvepakke. Dens gamle Adam/Eva-prøveark gentog samme celle; de bruges ikke som nye ganganimationer.
- De nye atlasfiler har **14–16 målte rækker og 7–8 billeder pr. række**, i alt 1.225 forskellige celler. Runtime understøtter 16 gangretninger og vælger nærmeste tilgængelige række. Dette er **ikke** 16 håndtegnede, ensartede vinkler × seks komplette animationsark pr. figur. Rytme, kanter og retningsskift skal ses på en telefon, især ved høj zoom.
- Native portrætanimation erstatter det manglende Live2D-materiale i denne integration. En lagdelt Harper-PSD, `.moc3`/`.model3.json`-rig og VRM er ikke leveret eller oprettet. De tidligere Live2D-/VRM-ønsker er stadig særskilte åbne opgaver; de blokerer ikke disse portrætter.
- De mørknede `CODE-PREVIEW`-billeder og dubletter er ikke kopieret som nye selvstændige rum. Vinterpreviewet er ikke en færdig sæsonfunktion.
- Telefonens hukommelsesforbrug, billedhastighed, VoiceOver og tekst ved stor skrift skal verificeres på fysisk iPhone. Ingen påstand om fuldt beståede iOS-tests endnu.

## Filer og oprindelse

23 PNG-filer, ca. 51 MB, ligger i `App/Assets/Village/final`. Xcode inkluderer dem gennem den eksisterende `Village`-folderreference. SHA-256 og dimensioner står i `final-package-manifest.json`. Originalpakken i Downloads er uændret.

Map, figurer og portrætudtryk er genereret/redigeret med imagegen med brugerens leverede billeder som reference. De øvrige rum/portrætter er byteidentiske kopier fra leverancen. Den tidligere CC0-erklæring for proceduretegnede billeder i `new/` udvides ikke til disse brugerleverede eller genererede filer.

## Kontrol

- `python verify_project.py`: projekt, sources, tests, scheme og plist.
- `python tools/verify_village_art.py`: alle PNG-hashes/dimensioner, ti figurer, gennemsigtighed, gyldige billedudsnit, ingen identiske celler i samme gangrække og fire forskellige portrætudtryk.
- `Tests/VillageDesignTests.swift`: seks XCTest-tilfælde for figurvalg, gammel JSON, rename/foto, skabelon, bundling og koordinater. Afventer Xcode.
- `python tools/preview_village_art.py`: skriver `build/village-preview.html`, en lokal grafikprøve. Dette er ikke en kørende iPhone-app. Browserens filadgang var blokeret under denne gennemgang; PNG-filer er inspiceret direkte.

## Prøve på næste iPhone-build

1. Opret én mand og én kvinde, vælg andre figurer end deres navne. Gem, luk og åbn appen. Valget skal være bevaret.
2. Skift navn og profilfoto. Landsbyfiguren skal forblive den valgte. Eksportér/importér en skabelon og kontrollér samme figur.
3. Åbn alle fire bygninger, en bots profil/computer, Skaberværkstedet og kirkegården. Gå tilbage fra hver side.
4. Brug zoomskyderen med låst kort; lås op, panorér, nulstil og prøv dag/nat. Tryk på huse og bots tæt ved hinanden.
5. Se gang og skift mellem arbejde, tale, hvile og søvn. Kontrollér fødder, størrelse, overlap og farvede kanter ved høj zoom.
6. Læs op med Harper og Lumi. Kun den aktive taler skal bevæge munden; stop og skærmlås stopper bevægelsen. Prøv Reducer bevægelse.
7. Kør eksisterende ContractTests og VillageDesignTests, før en IPA kaldes klar til installation.
