# Landsbyfigurer og tale · 16. november 2026

Brugeren valgte punkt 1 og 5 fra listen over landsbyforbedringer. Denne lokale ændring bygger videre på de eksisterende figurer og talevalg. Ingen push, modeldownload, IPA eller ændring af den kørende PC-tjeneste er foretaget.

## Med i koden

- De indbyggede landsbyfigurer blinker forskudt. Ansigtsankrene følger de originale FadedAI-sprites i `docs/village-art/export_fadedai.py`. Profilbilleder og gemt landsbytilstand ændres ikke.
- Den talende agents figur får mundbevægelse. Apples oplæsning bruger ordgrænser som tidsmarkører; bevægelserne er en enkel animation, ikke præcis fonemgenkendelse. Christel bruger lydstyrken fra den lyd, der faktisk afspilles.
- Pause, stop og afslutning lukker munden. Ejerskab pr. oplæsning forhindrer, at en gammel afslutning eller et forsinket ord påvirker næste agent. Stemmeprøver uden agent tilknyttet animerer ingen figur.
- Figurer ses i agentchat, Lumis samtalefane, landsbykortet og botlisten på Kontorkort. Harper bruger sin eksisterende landsbyfigur. Systemets Reducer bevægelse, appens bevægelsesindstilling og baggrundstilstand stopper bevægelserne. Sovende figurer blinker ikke.
- Agentchat gemmer særskilt valg af dansk eller engelsk diktering. Stemmevalget bevares. Apples lokale diktering får agentens navn og FadedAI som hjælpeord. Whisper er stadig et eksplicit valg, med de eksisterende tidsmærker.
- Håndfri afsendelse kan vente 1,4, 2,5 eller 4 sekunder efter sidste tekstændring. Standard er 2,5. Afbrydelse, baggrund og lukning annullerer den ventende afsendelse. Manglende stemme afslutter håndfri tilstand med en forklaring.
- Dikteringsfejl vises efter opstart, og en tom afsluttet håndfri optagelse efterlader ikke mikrofonen som tilsyneladende aktiv. En igangværende Whisper-transskription overskriver ikke tekst, brugeren har redigeret imens.
- Tilladelsesforespørgsler kan annulleres uden efterfølgende mikrofonstart. Apples optagelse stoppes efter højst 55 sekunder. Ingen tale sendes til en ny tjeneste.

## Stadig åbent

- Live2D- og VRM-figurer, herunder Harpers egne model-/rigfiler, er ikke leveret eller indbygget. De to oprindelige repo-punkter er derfor stadig delvist åbne. Denne udgave er animation af de eksisterende figurer.
- Moonshine, Parakeet, identifikation af forskellige talere og nye stemmemodeller er ikke indbygget. Vi har forbedret styringen af den eksisterende Apple-/Whisper-diktering. Dansk nøjagtighed, lydkvalitet og hastighed kræver prøver på telefonen.
- Den gamle [Parakeet MLX-udgave](https://github.com/FluidInference/swift-parakeet-mlx) er arkiveret; vedligeholderne henviser til FluidAudio og beskriver højt ressourceforbrug. [Moonshine MLX](https://github.com/kylehowells/moonshine-mlx) dokumenterer streaming, men vi har ikke målt dansk eller valideret dens modelpakke i denne app. Ingen af dem erstatter stiltiende den eksisterende motor.

## Kontrol og prøve på iPhone

Xcode-projektets filreferencer og Swift-syntaks er kontrolleret på Windows. Alle Swift-filer ændret i denne omgang holder sig under 600 linjer. Fire nye XCTest-tilfælde dækker ejerskifte, pause, udløbet mundbevægelse og lydstilhed. De er skrevet, men kan ikke køres her uden Xcode. Hverken faktisk iPhone-afspilning eller billedhastighed er verificeret.

1. Åbn Harper og derefter en anden agent. Figurerne skal stemme med landsbyen. Et ændret profilfoto må ikke skifte figuren.
2. Læs et langt svar op. Kun den valgte agents mund bevæger sig. Stop, skift svar hurtigt, luk chatten og lås skærmen. Der må ikke være efterfølgende tale eller mikrofonstart.
3. Prøv Lumi med hendes valgte telefonstemme og, hvis konfigureret, Christel. Stemmeprøver må ikke starte andre agenters mundbevægelser.
4. Vælg dansk diktering, tal en sætning med agentens navn, og gentag på engelsk. Afvis mikrofontilladelsen én gang. Afslut under en tilladelsesdialog.
5. Prøv håndfri med alle tre pauser, et tomt lydklip og et telefonopkald under samtalen. Én sætning må kun sendes én gang. Stop under ventepausen må ikke sende.
6. Diktér med Whisper og skriv manuelt, mens den transskriberer. Manuel tekst skal bevares. Åbn seneste diktering for resultatet med tider.
7. Slå Reducer bevægelse til. Figurerne skal stå stille, mens oplæsning og tekst fortsat virker. Gå i baggrunden og vend tilbage.

Apple-kilder for implementeringen er [ordgrænser under oplæsning](https://developer.apple.com/documentation/avfaudio/avspeechsynthesizerdelegate/speechsynthesizer(_:willspeakrangeofspeechstring:utterance:)), [hjælpeord til diktering](https://developer.apple.com/documentation/speech/sfspeechrecognitionrequest/contextualstrings) og [lokal talegenkendelse](https://developer.apple.com/documentation/speech/sfspeechrecognitionrequest/requiresondevicerecognition).
