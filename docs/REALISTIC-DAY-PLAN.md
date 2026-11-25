# En realistisk dagsplan

Planlæg min dag åbner fra chatværktøjerne, naturlig chatkommando eller
Dagens overblik. Kalenderaftaler og åbne påmindelser med frist læses på
telefonen efter native tilladelse; opgaver kan også skrives manuelt.
Varighed, prioritet og ønsket dag/tidsrum er gennemgåelige.

Den lokale planlægger reserverer eksisterende aftaler og pauser, fordeler
opgaver i de reelle huller og viser dem, der ikke fik plads. Kort ned,
Flyt (tidligst) og Spring over/Medtag ændrer forslaget. På dagens dato bruges
tidligst næste femminutsgrænse. Ingen model kan opfinde ledig kalendertid.

Kladden og kilde-ID'er gemmes pr. agent. Kalenderen genlæses før fordeling,
og hver konkret booking går gennem den eksisterende native gennemgang med
ny kontrol af ledig tid. Job-ID følger opgaven ved gentagne forsøg.
Faktiske kvitteringer gemmes; allerede bookede opgaver foreslås ikke igen.
At slette en kladde fjerner kladden, ikke en kalenderaftale i Kalender.

NOBS/Cadeo/DeftTask inspirerer arbejdsgangen. Ingen parallel opgaveapp eller
usikret ekstern backend tilføjes. Fire portable prøver dækker møder/pauser,
flyt/kort ned/spring over, prioritet, ugyldige input og gemte kilde-ID'er.
Native tilladelser, EventKit-læsning, booking og lokale tidszoner/DST i
brugerfladen kræver fysisk Apple-kontrol.
