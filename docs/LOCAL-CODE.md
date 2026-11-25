# Lokal kode i agentens arbejdsrum

## Linux på telefonen

Skriv “Åbn terminalen” i agentchatten, eller vælg **Arbejd i Linux på iPhone**
i agentens arbejdsrum. Hent de 12,6 MB én gang. Hver kørsel starter en ny
Buildroot Linux med BusyBox og Lua 5.4. Kør det viste eksempel eller beskriv
opgaven, og lad din lokale chatmodel skrive scriptet.

Hovedteksten er tilgængelig som standardinput og som `input.txt`. Op til fem
ekstra valgte tekstfiler hedder `file-1.txt` til `file-5.txt`. I `files.json`
står de oprindelige navne. Standardoutput gemmes som en ny fil hos agenten.
Script og kopier af de valgte input følger opgaven, også hvis originalerne
senere ændres. Øvrige filer i Linux slettes, når kørslen afsluttes.

Pakken hentes fra [v86](https://github.com/copy/v86), med firmware fra en
fast revision og udgiverens Buildroot-image. Appen kontrollerer fem SHA-256-
summer ved installation og før start. Den isolerede Worker kan stoppes under
opstart eller under en kommando. Telefonens almindelige agentbrowser håndterer
webopgaver. XFCE-skrivebordet og Windows-programmerne kræver den parrede PC.

De seks offline-browserprøver dækker Unix-værktøjer og Lua, exitkode og stderr,
en for stor resultatfil, timeout, Stop og behandling af flere kildefiler efter
en afbrydelse. Enhedsprøven skal kontrollere opstart, kørsel og filoverførsel
til chatten i iOS WebKit.

## JavaScript

Arbejdsrummet bevares. “Lav et lokalt værktøj” åbner en rigtig JavaScript-motor
på iPhone til tekst, JSON, CSV og beregninger. Den valgte telefonmodel kan skrive
koden; brugeren kan gennemgå/rette den og køre den på en kopi af valgt input.
Resultatet bliver en ny fil. Kode/input/opgavetype bevares til genoptagelse.
Genkørsel af et færdigt værktøj opretter en ny opgave, ikke en overskrivning.

Valget erstatter ikke native telefonværktøjer eller PC-arbejdsrum. Det er en
afgrænset udbygning inspireret af OpenMinis' lokale arbejdsrum, ikke en indbygget
iSH/Alpine-installation. Fuld iSH kræver særskilt native emulator/rootfs-build
og er ikke medtaget eller foregivet installeret.

Hvert script kører i en ny Web Worker i en ikke-vedvarende WKWebView. Worker-
miljøet har ikke native fil-, mail- eller telefonadgang. CSP blokerer netadgang.
Input overføres som data gennem WebKits argumentgrænseflade, ikke indsat som
eksekverbar tekst. Kode højst 8 KB, input 160 KB, resultat 80 KB. Tre sekunders
deadline eller Stop terminerer selve Workeren, også ved `while(true){}`.
Et blokeret, afbrudt eller fejlet script bliver ikke et færdigt resultat.

Lokale prøver: Swift-kontrakter/arbejdsrum; syv reelle Node Worker/forældreside-
prøver; separat tom Chromium-profil med rigtig beregning, CSP-connect-src-
blokering, uendelig løkke og et nyt script efter timeout. Chromium er ikke
WKWebView. Den native iPhone-host og modelgenereret kode afventer Apple-prøve.
Ingen IPA, push eller ændring af brugerens eksisterende browserprofil.
