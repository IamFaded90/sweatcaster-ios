# Privat Studio: billedmodeller på PC

Koden tilføjer valg på PC'en. Den kørende installation og iPhone-appen skal opdateres før valgene vises. Modellerne er lokale filer i ComfyUI og følger ikke med IPA'en.

- **RealVisXL** er bevaret som tidligere valg og bruges fortsat af Lumis eksisterende billedrute.
- **FLUX 2 · redigering** bruger [FLUX.2 Klein 4B FP8](https://huggingface.co/black-forest-labs/FLUX.2-klein-4b-fp8), tekstencoder og VAE fra [Comfy-Org](https://huggingface.co/Comfy-Org/Flux-2-Klein-4B). Alle tre filer er hentet på F: og SHA-256-kontrolleret mod deres udgivere. Modellen er udgivet under Apache 2.0.
- **FLUX 2 · voksen** bruger den samme base med [Party Time v2.1 Klein 4B](https://civitai.com/models/2458332) fra whoforscuba. Den downloadede SafeTensors-fil blev kontrolleret mod udgiverens SHA-256. Udgiverens side tillader billeder og viderebearbejdning; kontrollér separate vilkår før distribution af selve modelvægtene. Tilføjelsen er primært trænet til kvindelig nøgenhed.
- **CyberRealistic Pony · voksen** bruger [skaberens checkpoint](https://huggingface.co/cyberdelia/CyberRealisticPony), udgivet som CreativeML OpenRAIL-M. Filen er SHA-256-kontrolleret.

Appen undersøger PC'ens ComfyUI før FLUX- og Pony-valgene bliver tilgængelige. Ved maskeret redigering bruges hele referencen til billedmodellen, og resultatet lægges ind i markeringen på originalen. FLUX bruger ikke negativ prompt eller styrkeskyderen. Eksisterende RealVisXL og andre jobs skiftes ikke automatisk.

## Lokale prøver

- FLUX 2 ændrede en syntetisk rød firkant til blå. En separat prøve via den nye PC-rute bevarede området uden for masken.
- FLUX 2 redigerede et syntetisk billede af en voksen mand, så den markerede t-shirt blev til en bar overkrop. Alle pixels uden for markeringen var identiske med originalen. Der var synlige kanter ved masken.
- FLUX 2 voksen gav nøgenhed i en syntetisk voksenprompt og fjernede overdel fra en syntetisk voksenkvinde. Stropper uden for masken blev bevaret.
- CyberRealistic Pony skabte i én prøve to nøgne voksne, men anatomi og handling var ikke pålidelige. I en redigering erstattede modellen en trøje med en anden trøje.
- Standard-FLUX og RealVisXL viste heller ikke den ønskede sexscene i samme konkrete prøve. Resultaterne viser ikke, at andre beskrivelser nødvendigvis fejler.
- RealCore Pony og StableYogi inpaint blev hentet, SHA-256-kontrolleret og prøvet; de to testfiler blev fjernet igen efter svage resultater og brugerens ønske om oprydning.

Alle prøvemotiver var syntetiske, og ingen brugerfotos blev sendt på nettet. Billedkvalitet på et rigtigt foto, mere komplekse sexscener og afprøvning af alle valg fra iPhone står åbne. Modellerne konkurrerer med andre lokale funktioner om PC'ens 8 GB grafikhukommelse.
