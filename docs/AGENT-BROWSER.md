# Agentbrowser på iPhone

FadedAI bruger Gepettos rigtige WKWebView/observe/decide/act-forløb, ikke demoens
scriptede svar. Adgang fra agentchattens værktøjer eller “Brug browseren …”.
Telefonens data/Wi-Fi bruges til siderne. Modellen er den valgte telefonmodel.
Ingen PC- eller cloudmodel faldes ind som skjult reserve.

Gepetto er fastlåst til revision
`1759f5c9ab5f1207939360d3e8091a37e205de68`, MIT, Haplo LLC:
[kilde](https://github.com/haplollc/Gepetto/tree/1759f5c9ab5f1207939360d3e8091a37e205de68).
Den efterfølgende FoundationModelsEngine bruger SDK-symboler fra 26.4.
Den valgte revision indeholder ikke den fil; vores adapter bruger allerede
eksisterende PhoneModels og LocalCompute. Xcode 26.3 ændres ikke.

Hver opgave har højst 18 trin. Der vises 14 sideelementer ad gangen; resten nås
ved at rulle. For store modelprompts giver en synlig fejl i stedet for at klippe
handlingsregler eller siden vilkårligt. Browserens standardregler for følsomme
handlinger og manuel overtagelse er beholdt. Automatisk samtykke til cookies og
den gamle, mindre kontrollerede scripted-flow er slået fra.

Agenten genlæser siden efter hvert trin. Ved afslutning læses sideteksten igen,
og en særskilt modelkontrol skal citere faktisk læst tekst, før resultatet kaldes
kontrolleret. Et manglende/falsk citat markeres som uafklaret. Kildelinks mister
query/fragment, så engangsnøgler ikke følger med i chatkvitteringen.

Pause ved baggrundsskift; stop og afbryd modelkald ved lukning. Der loves ikke
baggrundsautomatisering, mens iOS har suspenderet appen. Resultater gemmes i
chatten ved brugerens tryk; browserlogin og personlige sider følger ikke med Git.

Lokale Foundation-prøver dækker kilder, beviskrav og kommandorouting. Apple-
kompilering, rigtig WKWebView, pause/overtagelse og et komplet modelforløb på
iPhone er fortsat separate acceptprøver. Ingen build/push er startet.
