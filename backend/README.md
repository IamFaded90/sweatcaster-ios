# FadedAI PC backend extensions

## Composio

Åbn **Forbind Composio** i Windows-opdateringsvinduet, og gem din projektnøgle fra Composio Dashboard. FadedAI finder eller opretter loginopsætningen til Google Drive og GitHub, når du vælger **Log ind**. Dine egne login-id’er er valgfrie. Windows krypterer nøglen under den bruger, der kører FadedAI. Miljøvariablerne `COMPOSIO_API_KEY`, `FADEDAI_COMPOSIO_GOOGLEDRIVE_AUTH_CONFIG` og `FADEDAI_COMPOSIO_GITHUB_AUTH_CONFIG` går forud for den gemte opsætning.

Åbn **Forbindelser → Tjenester på PC’en → Composio** på iPhone. Log ind hos hver tjeneste. På en agentcomputer bruges **Brug en PC-forbindelse** til at vælge ét opslag, der kun sendes til den aktuelle opgave. FadedAI fjerner opslaget fra køen, hvis opgaven ikke starter inden for 30 minutter.

På en agentcomputer kan du åbne **Gmail-aftaler**, logge ind og slå aftalesøgning til for den valgte agent. PC’en søger i de sidste 30 dages mail efter aftalebekræftelser via Composio og udtrækker forslag med den lokale tekstmodel. FadedAI gemmer forslagene, mens mailteksten bruges til analysen. Du godkender kalender, alarm og påmindelse på iPhone. Aftalesøgning kræver, at FadedAI kører på PC’en.

## Christel

Åbn **Forbind Christel** i Windows-opdateringsvinduet. Med Azure CLI installeret og logget ind skal du vælge din eksisterende Speech-ressource. Opdateringen henter nøglen, og Windows gemmer den krypteret. Hvis PC-programmet allerede har `SPEECH_KEY` og `SPEECH_REGION` eller de tilsvarende `AZURE_SPEECH_*`-variabler, læser FadedAI dem automatisk. På Lumi sender **Læs med Christel** det valgte svar til Microsoft.

## Tilføjelser fra GitHub

Åbn **Code Bot → Tilføjelser → Fra GitHub**, indsæt linket til et offentligt projekt, og gennemgå forslaget. En godkendt tilføjelse kan bruges og slettes fra biblioteket. Offentlige opslag kræver ingen GitHub-nøgle.

- En FadedAI-pakke bruger filen `fadedai-addon.json` i repoets rod. Den indeholder `version: 1`, `title`, `text` og `actions`. Hver handling har `type`, `label` og `value`. Typerne er `tool`, `prompt` og `link`. Værktøjer er `checklist`, `stats`, `sum`, `average`, `percent`, `discount`, `split` og `days`.
- Udgivne GitHub Pages-projekter åbnes i appens browser. Vælg **Hent en lokal webpakke** for at gemme en bestemt GitHub-version på PC’en, hvis projektet har `index.html` i roden, `dist` eller `docs`, relative filer og en samlet størrelse på højst 6 MB. Den lokale kørsel bruger en midlertidig kopi på iPhone og er til webfiler, der fungerer uden internet og en server.

## Fælles opdatering på Windows

Lad igangværende FadedAI-opgaver afslutte. Dobbeltklik på `setup_aio_windows.pyw`, vælg den eksisterende FadedAI-mappe, og tryk **Opdatér FadedAI**. Vinduet opdaterer botopgaver, forbindelser, FPS-kommentarer og stemmer samlet. Det tjekker kompatibiliteten, før det skriver til den eksisterende installation. Åbn derefter den sædvanlige FadedAI-genvej efter genstart. Du kan åbne **Forbind YouTube** fra samme vindue.

`repository_library.py` is an additive PC module. Copy it into the existing Python installation's `sweatcaster` package. The current HTTP contracts stay as shipped. Use the PC's existing Git credential helper for private GitHub access, configured under the same Windows account that runs this command. The module never accepts a token or an arbitrary clone URL.

From the PC backend directory, replace the two example paths with the configured Agent Workspace and the existing local ONNX embedding directory:

```powershell
$repoArgs = @('--workspace', 'D:\AgentWorkspace', '--database', 'D:\FadedAIData\code-index.sqlite', '--embedding-dir', 'F:\FadedAIModels\embedding')
.\.venv\Scripts\python.exe -m sweatcaster.repository_library @repoArgs clone owner/project
.\.venv\Scripts\python.exe -m sweatcaster.repository_library @repoArgs index owner/project
```

The optional `mcp` subcommand requires the official Python `mcp` SDK. Configure it as a local stdio server in the agent host, passing the same paths. It exposes `read_repository_file` and `search_repository`. It reads regular tracked source blobs from a local Git snapshot. Keep the workspace and index private, especially for private projects. Existing PDF ingest and scheduling remain available through the installed backend.

## Dynamic tabs and Kortscanner

Run `python backend/install_module_tabs.py <checkpoint-directory>` and restart the PC server. The installer validates the existing hook locations and keeps copies of the two original files. The separate `/api/modules/v1` endpoints use the existing pairing authentication. The first compatible iOS build is required once.

Export JSON from Kortscanner, open Kortsamling on the phone and choose the file. Import replaces the previous collection on this PC. In v2 chat, type `Kortsamling: Hvilke kort har jeg dubletter af?` or `Kortsamling: Hvilke kort mangler en pris?`. These answers use a local lookup.

Add more native information tabs by placing `module-tabs.json` in the configured output directory, for example `[{"id":"status","title":"Status","text":"Alle rutiner er klar."}]`. The phone refreshes the manifest on foreground and pull-to-refresh. Other renderers and actions require a new app build.


## Opslag til botopgaver

I en bots **Opgaver** kan du gennemse et opslag fra **Brug Vault** eller **Brug en PC-forbindelse**. Et vedhæftet opslag bruges i den næste opgave. PC’en fjerner det vedhæftede opslag fra køen, når opgaven afsluttes eller annulleres. Den færdige rapport kan indeholde oplysninger fra opslaget.

- **SearXNG** bruger den lokale container på `127.0.0.1:8080`. JSON skal være aktiveret i containerens `search.formats`. SearXNG sender søgningen videre til sine konfigurerede søgemaskiner. [SearXNG Search API](https://docs.searxng.org/dev/search_api.html)

Vælg **Brug nettet** på en almindelig agentopgave for at lade PC-modellen formulere en søgning. FadedAI henter op til tre offentlige kilder og viser, hvor agenten har læst selve siden eller brugt søgeuddraget. Det separate AIO-skrivebord bruger sin eksisterende netværksopsætning. [SearXNG](https://github.com/searxng/searxng) · [lxml](https://github.com/lxml/lxml)
- **Tradera** bruger et app-id og en appnøgle fra Tradera Developer Program. Gem dem under **Mere → Vault → Tradera-adgang**. FadedAI søger i aktive annoncer. [Tradera API](https://api.tradera.com/documentation/rest-getting-started)
- **YouTube** bruger en Google OAuth-klient af typen Desktop-app fra et projekt med YouTube Data API v3 slået til. Installér `google-auth-oauthlib` i Python-miljøet til opsætning. Åbn `setup_youtube_windows.pyw`, vælg klientfilen, og godkend læseadgang hos Google. PC’en gemmer adgangen under den nuværende Windows-bruger. Brug **Forbindelser → Tjenester på PC’en → YouTube** for at teste. [Google Desktop OAuth](https://developers.google.com/identity/protocols/oauth2/native-app) · [YouTube Data API](https://developers.google.com/youtube/data/guides/authentication)

[Botpostkasser med Google Workspace](BOT-MAILBOXES.md)

## Local Code Bot batch queue

Copy `sweatcaster/code_batch.py` into the same installed Python package as `repository_library.py`. Run from the checkpoint directory:

```powershell
.\.venv\Scripts\python.exe -m sweatcaster.code_batch enqueue owner/project 'Describe a usable change' path/first.py path/second.py
.\.venv\Scripts\python.exe -m sweatcaster.code_batch worker
.\.venv\Scripts\python.exe -m sweatcaster.code_batch show <job-id>
```

The queue persists under the PC output directory. The worker starts with the PC HTTP server after installing the module hooks. It serializes jobs and acquires the existing Ollama model lease shared with chat and rendering. A job produces a unified diff for up to five selected tracked files and a test plan. In the compatible iOS app, open **Code Bot → Forslag til flere filer** to submit and review jobs. Approval creates a local `fadedai/review-*` branch in the bare repository snapshot. The source branch remains unchanged. `worker --once` is also available for standalone diagnostics.

## Forbindelse med QR

Brug **FadedAI – Scan QR** på skrivebordet, hvis genvejen er installeret. Som alternativ kan du åbne Windows Terminal i projektmappen og køre QR-værktøjet med Python-pakken `qrcode`.

```powershell
python -m pip install qrcode
python backend/show_pairing_qr.py 192.168.1.50
```

Brug PC’ens egen LAN- eller Tailscale-adresse. Indsæt det eksisterende token i den skjulte prompt, eller tilføj `--token-file 'D:\FadedAIData\PAIRING_TOKEN.txt'` med stien til tokenfilen. Vælg **Scan QR fra PC’en** på iPhonen, og tryk derefter **Test og Forbind**.

Åbn en ny QR-kode, hvis de fem minutter er gået. Vis koden på din egen skærm, og luk terminalvisningen med Enter efter scanning. Forstør vinduet, hvis koden ikke kan være der.
