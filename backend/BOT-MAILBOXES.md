# Opret en botpostkasse i Google Workspace

Opsætningen opretter en Workspace-bruger på dit eget domæne og bruger bottens ID til at genkende kontoen ved senere opslag. Gmail-postkassen bliver klar, når Workspace har givet kontoen en licens og slået Gmail til. Det er en separat postkasse med eget login. Botjob kan endnu ikke læse eller sende mail fra den.

1. Brug et domæne med Google Workspace og en admin, der må oprette brugere. Tjek licensprisen i Workspace, før du opretter en konto.
2. Aktivér Admin SDK API i organisationens Google Cloud-projekt. Opret en OAuth-klient af typen **Desktop-app** og hent dens JSON-fil. Brug organisationens OAuth-konfiguration.
3. Installér Googles OAuth-bibliotek med `python -m pip install "google-auth-oauthlib>=1.4.1"` i PC’ens Python-miljø.
4. Brug bottens UUID og navn til at se adressen. Forhåndsvisningen åbner ingen forbindelse.

```powershell
python backend/setup_bot_mailbox.py --bot-id 20b18c14-c0ea-4eaa-ac70-747a7129d727 --bot-name Adam --domain example.org
```

Tilføj `--oauth-client C:\sti\desktop-client.json --apply` for at oprette kontoen. Google åbner sit login i browseren. Indtast den midlertidige adgangskode til den nye botpostkasse i terminalen, når kommandoen beder om den. Workspace beder om at skifte adgangskoden ved første login. Opsætningen gemmer hverken admin-token eller adgangskode på disk.

Brug `--status` i stedet for `--apply` for kun at tjekke, om Google har gjort postkassen klar. Hvis en oprettelse blev afbrudt, kan du gentage den samme kommando. Opsætningen ændrer ingen eksisterende konti. Workspace kan være lidt tid om at klargøre en ny postkasse.

[Google Workspace-brugere og licenser](https://developers.google.com/workspace/admin/directory/v1/guides/manage-users) · [Directory API](https://developers.google.com/workspace/admin/directory/reference/rest/v1/users/insert) · [Google OAuth for Desktop-apps](https://developers.google.com/identity/protocols/oauth2/native-app)
