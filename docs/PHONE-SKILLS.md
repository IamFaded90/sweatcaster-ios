# Telefonværktøjer og Skills

FadedAI beholder de eksisterende native Kalender/Påmindelser/alarmforløb.
Kontakter og Skills ligger i agentchattens værktøjsmenu. “Find kontakten Lars”
åbner et rigtigt lokalt kontaktopslag efter iOS-tilladelse. Ingen PC kræves.
Valgt kontakt gemmes som kilde til den pågældende agents næste opgave, i højst
otte timer. Kontekst kan ryddes fra færdighedssiden og deles ikke med andre
agenter. Ved flere adresser/numre skal modtageren afklares.

Import er en UTF-8 SKILL.md, højst 24 KB, med enkel frontmatter:

```markdown
---
name: mail-opfølgning
description: Følg beskeder og kalenderaftaler op
allowed-tools: [mail, calendar]
---
Læs den valgte kilde. Gennemgå svaret før afsendelse.
```

Import aktiverer intet automatisk. Brugeren gennemgår teksten og vælger agent.
Højst to relevante, aktiverede færdigheder følger med en opgave. Ukendte
værktøjer vises som manglende og indgår ikke i modelkonteksten. En tekstfil
installerer ikke scripts eller giver adgang til andre apps. Importerede filer
og kontaktoplysninger ligger i appens data, ikke i Git.

Brug af udklipsholder sker kun ved systemets Indsæt-knap. Der læses ikke
automatisk i udklipsholderen. Native kontakter og systemtilladelser skal prøves
på iPhone; lokale prøver dækker import, relevans, agentadskillelse og udløb.
