# Botternes computere i FadedAI

Hver bot får et selvstændigt AIO Linux-skrivebord på Windows-PC’en. Docker gemmer botternes data i hver sin permanente plads. FadedAI bruger den eksisterende parrede PC-forbindelse til jobstatus, filer og visning af skrivebordet. De lokale AI-modeller bliver på PC’en og deles mellem botterne.

## Klargør PC’en

1. Åbn **Docker Desktop** og vent, til Linux-motoren er klar.
2. Dobbeltklik på **`backend/setup_aio_windows.pyw`** i den kompatible FadedAI-version. **Tjek Docker** viser, om motoren svarer, om Windows-brugeren har adgang, og om AIO-skrivebordet er hentet.
3. Tryk **Hent AIO-skrivebord** én gang. Vinduet henter den faste AIO Computer-version fra projektets officielle register. De enkelte bots bruger den samme kopi af imaget.
4. Vælg mappen til din eksisterende FadedAI-installation, hvis vinduet ikke allerede har fundet den. Lad igangværende FadedAI-opgaver afslutte, og tryk **Opdatér FadedAI**. Genstart PC’en, og åbn den sædvanlige FadedAI-genvej.

Opsætningen bruger den eksisterende PC-installation og ændrer først den valgte mappe, når du trykker **Opdatér FadedAI**. Hvis Docker er lukket eller mangler adgang, viser vinduet det og lader dig prøve igen.

## Tjek PC-delen først

Kør backendens tests, og prøv derefter to botmiljøer på den faktiske Windows-installation. `backend/smoke_aio_pc.py` kan afprøve to midlertidige Docker-skriveborde, visning og input, adskilte filer og genstart med syntetiske rapporter. Brug derefter den lokale Ollama-model til en rigtig rapportopgave, og notér RAM og CPU med begge miljøer aktive.

## Tjek på iPhone i den fælles IPA

1. Start Adam og Eva, og åbn begge skriveborde. Følg Adams skrivebord, overtag kort styringen, og skift tilbage til visning.
2. Importér en ufølsom testfil til Adam og en anden til Eva. Kør en rigtig rapportopgave på hver, og se status gå fra kø til færdig med hver sin fil.
3. Prøv at åbne Adams rapport fra Eva. Del derefter rapporten udtrykkeligt, og bekræft, at Eva kan åbne den delte kopi.
4. Stop og start begge miljøer. Bekræft, at testfilerne stadig er der. Genstart også PC-programmet, og kontrollér, at afsluttede opgaver kan findes igen.
5. Afbryd en opgave, og prøv igen. Kontrollér, at gentagen afsendelse af samme opgave ikke laver dobbeltarbejde. Afbryd PC-forbindelsen, og kontrollér, at iPhone viser en forståelig status ved ny forbindelse.
6. Afprøv visning, berøring og tastatur på den fysiske iPhone.

Livevisning bruger opdaterede billeder af Linux-skrivebordet og input via FadedAI. Botmiljøerne er lokale og adskilt fra netværket. Første udgave tager tekstfiler og genererer rapporter med den delte Ollama-model.

De lokale backendtests kan køres uden Xcode. Kørsel med det faktiske Docker-image og test på en fysisk iPhone skal bekræftes særskilt.

[AIO Computer-udgaven](https://sandbox.agent-infra.com/daemon/start/quick-start) · [AIO-skrivebord og visning](https://sandbox.agent-infra.com/daemon/basic/display) · [Docker-volumener](https://docs.docker.com/engine/storage/volumes/)
