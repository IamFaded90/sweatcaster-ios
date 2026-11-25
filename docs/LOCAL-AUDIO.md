# Dansk lyd og optagelser

Den eksisterende danske Whisper-kode/model og stemmevalg er bevaret.
Taleskift bruger den eksisterende sproguafhængige lydmåler; ugyldige
målinger og tilbagegående ur kan ikke udløse en falsk afslutning.
FluidAudios engelske Parakeet EOU erstatter ikke dansk diktering.

Agentværktøjet Optagelser kan importere eller optage op til 30 minutter.
Import konverteres til mono 16 kHz med små buffere og en beskyttet lydkopi
på disk. Whisper får højst 25 sekunder ad gangen. Hvert færdigt stykke
gemmes med behandlingsposition, så stop eller fejl kan fortsættes.
Den danske tekstmodel har tidskoder pr. lydstykke, ikke påstået ordjustering.

Tekst og talernavne kan rettes, afspilles fra tidspunktet, deles og sendes
til Fang og følg op. Slet lyd og tekst fjerner appens egne kopier.
Skift til baggrunden stopper en aktiv mikrofon og forsøger at gemme den
optagne del; ubegrænset arbejde med lukket app er ikke lovet.

FluidAudio tilføjes gennem et fastlåst Swift 6.2-diarieseringsmodul med
TTS/Nemo slået fra. Den valgfrie offline VBx-model hentes først ved tryk.
En komplet filstørrelsesliste kontrolleres før brug, og SDK-netadgang
slås fra under inferens. Modeller frigives efter hver kørsel.
En tekstbid med mere end én mulig taler markeres Flere talere frem for
at blive tilskrevet én person. Talermærker er forslag, ikke identifikation.

Portable prøver dækker bufferintervaller, kildebevarelse, flere talere,
delvise optagelser, sletning og taleskift. Pakker kan opløses på PC;
AVAudio-konvertering, Apple-kompilering, dansk kvalitet, taleropdeling og
faktisk RAM/tid skal prøves på iPhone.

Kilde: FluidInference/FluidAudio, commit e2ea498dafd6db9b3f18f0f644bc35312b3a7679,
MIT. WhisperBoard/Argmax-arbejdsgange er reference; der importeres ingen
parallel Whisper-/TTS-app.
