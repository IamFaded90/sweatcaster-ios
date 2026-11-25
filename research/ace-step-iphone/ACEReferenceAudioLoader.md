# Isoleret lydforberedelse til ACE-Step

`ACEReferenceAudioLoader.swift` er en forsøgsimplementering uden for appens
byggeproces. Den er ikke koblet til sangstudiet og ændrer ikke PC'ens
eksisterende 24 kHz mono-sti.

Den foreslåede Apple-sti læser en valgt fil med security scope, konverterer i
små blokke til 48 kHz stereo float-PCM og skriver en separat midlertidig WAV.
Kaldet returnerer filens URL, faktisk indlæste/alignment-frames og lydniveau;
den fremtidige kalder skal slette den returnerede fil efter brug. Fejl eller
annullering forsøger at fjerne den fil, som dette kald selv har oprettet.
Indlæsning i blokke begrænser arbejdsstørrelsen, men der er ikke målt faktisk
iPhone-RAM. Filen bliver nul-udfyldt til 1.920-samples-grænsen; det indlæste
indhold ændres ikke. Varigheden er begrænset til højst 180 sekunder, og tom,
ikke-endelig eller næsten lydløs indgang afvises.

`ACEReferencePCM.swift` er platformuafhængig. `ACEReferencePCMChecks.swift` er
kørt med Swift 5-sprogniveau på Linux og dækker to kanaler, bevaring af data,
blokopdeling, længdegrænse, padding, tom/stille lyd, NaN, ugyldig varighed,
gentagen afslutning og cancellation. Der bruges kun syntetiske lydværdier.

**Begrænsninger:** AVFAudio-indlæseren er alene syntakskontrolleret på PC,
ikke Apple-typekontrolleret eller kørt på en iPhone. Mono-til-stereo, reel
resampling, WAV/M4A/MP3, iCloud-filer, filbeskyttelse, disk fuld, håndtering af
afbrydelse under en blokerende læsning og WAV-afspilning er ikke verificeret.
Filnavnets UUID- og eksistenskontrol er ikke en fuldstændig løsning på
samtidige filskrivere. Den genererede lyd er endnu ikke koblet til ACE-encoder,
referenceudvælgelse, MLX, sang eller UI. Ingen kvalitet eller iPhone-kompatibilitet
er dermed bevist.
