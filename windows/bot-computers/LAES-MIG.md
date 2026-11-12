# FadedAI-computere

Adam og Eva får hver sin computer på din Windows-pc. Telefonen åbner skrivebordet fra Landsbyen. Den kørende installation i `C:\Users\LydonVanBeek\AppData\Local\SweatCaster\app\fadedai-checkpoint-20261107` bliver ikke ændret.

## Sådan lægger du genvejen

1. Installer Docker Desktop, og lad det køre.
2. Dobbeltklik `Start-BotComputere.vbs` i denne mappe. Der åbner et vindue, ikke et konsolvindue.
3. Tryk **Læg genvej på skrivebordet**. Genvejen hedder FadedAI-computere. Data ligger i `D:\FadedAIData\bot-computers`, ikke i den kørende FadedAI-mappe.
4. Skriv det modelnavn, Ollama allerede viser. Der hentes ikke en ny model. Modellerne bliver på `F:\FadedAI`.
5. Parr telefonen som du plejer, med den QR-kode FadedAI allerede viser.

Først når du selv vil lægge modulet ind i en kopi af PC-programmet, kører du `backend/install_bot_computers.py` mod kopien. Scriptet nægter stien til den kørende installation.

## Daglig brug

Åbn genvejen.

- **Start Adam**, **Start Eva** eller **Start begge** starter kun den computer, du beder om.
- **Åbn skrivebord** viser noVNC på din egen pc. Telefonen bruger ikke det link. Den bruger den parrede forbindelse.
- **Mål RAM og CPU** kører `docker stats --no-stream`, mens begge computere kører, og gemmer `D:\FadedAIData\bot-computers\maaling.txt`.
- **Kør bevis** lader Adam skrive en rapport ud fra `kilde.txt` og Eva ud fra `noter.txt`. Derefter genstarter det computerne, tjekker at filerne er der, og tjekker at Eva først kan åbne Adams rapport efter en godkendt deling. Resultatet ligger i `bevis.txt`.

Ollama skal køre på pc'en, som den allerede gør. Containerne kalder `http://host.docker.internal:11434`. De monterer ikke `F:\FadedAI`.

## Hvad telefonen gør

I Landsbyen trykker du på Adam eller Eva. Du lander på deres skrivebord med **Se live**, **Overtag styring**, **Opgaver** og **Filer** ovenpå. Live-billedet og klik går gennem den parrede server. Overtagelse og deling kræver et ja. En opgave har ét id, så et dobbelttryk eller en genforbindelse ikke starter den igen.

## Måling

Denne cloud-maskine har ikke Docker Desktop, Ollama eller de to skriveborde. `maaling.txt` bliver derfor ikke lavet her. På pc'en er målingen tallene fra `docker stats --no-stream` for `fadedai-bot-adam` og `fadedai-bot-eva`. Hver computer beder om 4 GB shared memory, fordi det er det, AIO Computer selv kræver til Chromium. Det rigtige forbrug står i målefilen.

## Licens

Skrivebordet er image `aio-computer:1.0.1` fra [agent-infra/sandbox](https://github.com/agent-infra/sandbox), Apache-2.0. Koden her er ikke en kopi af det repo. noVNC følger med imaget. GrokBot-clone er ikke kopieret ind. Pocket God er ikke brugt som grafik, navne eller spil.
