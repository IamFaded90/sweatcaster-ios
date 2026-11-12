# FadedAI PC backend extensions

## Fælles opdatering på Windows

Lad igangværende FadedAI-opgaver afslutte. Dobbeltklik på `setup_aio_windows.pyw`, vælg den eksisterende FadedAI-mappe, og tryk **Opdatér FadedAI**. Vinduet opdaterer botopgaver, forbindelser, FPS-kommentarer og stemmer samlet. Det tjekker kompatibiliteten, før det skriver til den eksisterende installation. Åbn derefter den sædvanlige FadedAI-genvej efter genstart. Du kan åbne **Forbind Emby** og **Forbind YouTube** fra samme vindue.

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

## Emby & bibliotek

Installer modulopdateringen med `install_module_tabs.py` som beskrevet ovenfor. Åbn derefter `setup_emby_windows.pyw` på PC’en, og gem opsætningen under samme Windows-bruger som PC-serveren. Tokenet krypteres med Windows' brugerbeskyttelse. Ved manuel opsætning kan PC-serveren også få følgende miljøvariabler. Miljøvariablerne for adresse, bruger og token går forud for den gemte Windows-opsætning.

Indtast Emby-adressen, og vælg **Find sikker adresse**. For en HTTP-adresse prøver vinduet HTTPS på samme vært på port 443 og 8920. Det bruger Embys offentlige serveroplysninger og sender først brugernavn og adgangskode, når du selv trykker **Forbind**. Hvis din Emby-server bruger en anden HTTPS-port, skal du indtaste den fulde adresse. På en Synology kan serverens administrator aktivere [HTTPS i Emby](https://emby.media/support/articles/Hosting-Settings.html) eller bruge [DSM’s reverse proxy](https://kb.synology.com/en-my/DSM/help/DSM/AdminCenter/system_login_portal_advanced).

| Variabel | Værdi |
| --- | --- |
| `FADEDAI_EMBY_URL` | Emby-serverens basisadresse. Brug HTTPS eller en lokal HTTP-adresse som `http://192.168.1.50:8096`. Et eventuelt `/emby`-suffiks accepteres. |
| `FADEDAI_EMBY_USER_ID` | Emby-brugerens id. Vælg en bruger med adgang til de biblioteker, der skal vises på den parrede iPhone. |
| `FADEDAI_EMBY_TOKEN` | Brugerens Emby-adgangstoken. Det bliver på PC’en. |
| `FADEDAI_EMBY_WEB_URL` | Valgfri HTTPS-adresse til samme Emby-servers webapp, fx `https://emby.example.org/web/index.html`. Aktiverer åbning af titler i Emby, når serveren giver det nødvendige id. Webappen bruger sit eget login. |

Åbn **Mere → Emby & bibliotek** i den kompatible iOS-app. Den parrede forbindelse bruges til at gennemse og søge i biblioteket. En server uden opsætning vises som ikke konfigureret. Afspilning åbnes i Emby, når en webadresse er sat op. Se Embys [brugergodkendelse](https://dev.emby.media/doc/restapi/User-Authentication.html) og [biblioteksopslag](https://dev.emby.media/doc/restapi/Browsing-the-Library.html).

## Opslag til botopgaver

I en bots **Opgaver** kan du gennemse et opslag fra **Brug Vault** eller **Brug en PC-forbindelse**. Et vedhæftet opslag bruges i den næste opgave. PC’en fjerner det vedhæftede opslag fra køen, når opgaven afsluttes eller annulleres. Den færdige rapport kan indeholde oplysninger fra opslaget.

- **SearXNG** bruger den lokale container på `127.0.0.1:8080`. JSON skal være aktiveret i containerens `search.formats`. SearXNG sender søgningen videre til sine konfigurerede søgemaskiner. [SearXNG Search API](https://docs.searxng.org/dev/search_api.html)
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

Åbn en interaktiv Windows Terminal i projektmappen. QR-værktøjet kræver Python-pakken `qrcode`.

```powershell
python -m pip install qrcode
python backend/show_pairing_qr.py 192.168.1.50
```

Brug PC’ens egen LAN- eller Tailscale-adresse. Indsæt det eksisterende token i den skjulte prompt, eller tilføj `--token-file 'D:\FadedAIData\PAIRING_TOKEN.txt'` med stien til tokenfilen. Vælg **Scan QR fra PC’en** på iPhonen, og tryk derefter **Test og Forbind**.

QR-koden indeholder tokenet. Vis den kun på din egen skærm, og luk visningen med Enter efter scanning. Forstør terminalvinduet, hvis QR-koden ikke kan være der.
