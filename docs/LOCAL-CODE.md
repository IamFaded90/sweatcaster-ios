# Lokal kode i agentens arbejdsrum

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
