# Stations — UX-audit

> Opgesteld 2026-08-22, op vraag van de user: *"Kan je de UX van de Stations-view
> verbeteren? Doe een uitgebreide audit en maak het beter, overzichtelijker en
> professioneler."*
>
> **Methode.** Alles hieronder is geteld in de broncode of afgelezen van de
> schermafdrukken die `native/scripts/ui-verify.sh` maakt (iPhone 17, 402×874 pt,
> offlinemodus). Waar een getal een schatting is, staat dat erbij.

---

## 1. Oordeel in één alinea

Stations is geen scherm maar vier schermen die in dezelfde tab zijn gezet. Ze
delen geen kop, geen kaartvorm, geen plek voor de primaire actie en zelfs geen
begrip van "waar speelt dit af": twee van de vier eisen nog een Roon-zone en doen
op dit apparaat niets. Elk segment opent met een eigen kop die letterlijk
herhaalt wat de segmentkiezer er één regel boven al zegt, waarna nog twee blokken
volgen die *geen* station zijn — een link naar een ander scherm en een instelling.
Het gevolg is te meten: op het Radio's-segment begint de eerste stationstegel pas
rond **600 pt** in een venster van 794 bruikbare punten, dus je ziet geen enkel
station zonder te scrollen. En één scherm is domweg stuk: op DJ-modi liggen twee
schakelaars boven op elkaar.

## 2. Wat er precies mis is — geteld

| Bevinding | Bewijs |
|---|---|
| Drie titelniveaus boven elke inhoud | tab "Stations" → segment "Radios" → kop "Sonic radios" |
| Chrome vóór de eerste inhoud | banner 100 pt + navbalk 49 + kiezer 54 + kop 112 = **315 pt** (36% van 874) |
| Eerste stationstegel | ~600 pt — ná "Mijn radio's" (81 pt) en de avontuurlijkheidskaart (146 pt) |
| Twee schakelaars overlappen | `DJModesView.swift:40-47` — twee `Toggle`s met een `.caption`-label in een `VStack(spacing: .xs)`; de switch is 31 pt hoog, de rij niet |
| Drie interactiemodellen op één scherm | `SonicJourneysView`: Album Radio = **alleen tekst, geen actie** · Time Machine = stepper + 2 knoppen · The Bridge = `NavigationLink` |
| Dubbele chevron | `SonicJourneysView.swift:152` — handmatige `chevron.right` in een `NavigationLink` in een `List` |
| Time Machine werkt niet op dit toestel | `.disabled(building \|\| client.selectedZone == nil)` + `curateTracks(_:zoneID:)` |
| "Genereer" queuet zone-only | `GenerateView.swift:151` — `guard let z = client.selectedZone?.id` |
| Twee visuele talen in één tab | Radio's/DJ/Journeys = `List` + `.plainCardRow()` + `.cardStyle()`; Genereer = `List` + `Section` (systeemformulier) |
| Nederlands op een Engelse telefoon | `LS("Lengte: \(count) tracks")`, `LS("Tijdreis gestart — …")`, `LS("Op Qobuz gezet als …")` — interpolaties in de sleutel, kunnen nooit oplossen |
| Uitgeschakelde knop zonder reden | "Start journey" staat grijs zonder één woord uitleg |

**De rode draad:** de volgorde op elk segment is *chrome → navigatie → instelling
→ inhoud*, terwijl het omgekeerde hoort. Wat je wilt (een station starten) staat
onder de vouw; wat je zelden aanraakt (een schuifregelaar die pas geldt bij het
vólgende station) staat er bovenop.

## 3. Wat we bewust NIET doen

- **Geen feature weghalen.** Mijn radio's, de avontuurlijkheidsdial, de
  Qobuz-spiegel, de autoplay-persona en de sjablonen blijven allemaal bestaan en
  bereikbaar. Ze verhuizen binnen hun eigen segment.
- **Genereer niet omschrijven naar kaarten.** Dat scherm ís een formulier
  (prompt, seeds, aantal) en `List`+`Section` is daar de juiste vorm; het hoort
  alleen niet als enige een grijze systeemkop te dragen waar de rest kaarten
  gebruikt. We trekken de *kop* gelijk, niet het hele scherm.
- **De segmentkiezer blijft.** Vier bestemmingen in één tab is precies waar hij
  voor is; het probleem zit onder de kiezer, niet in de kiezer.

## 4. Wat er verandert

### W1 — Eén kop, niet drie
De vier interne `header`-blokken verdwijnen. De segmentkiezer krijgt er één
regel uitleg onder die met het segment meebeweegt. **Winst: 112 → 22 pt** per
segment, en de naam van het segment staat nog maar één keer op het scherm.

### W2 — Inhoud eerst (Radio's)
Nieuwe volgorde: actieve radio → categoriepillen → **de stations** → Mijn radio's
→ avontuurlijkheid → Qobuz. De filterpillen blijven direct boven wat ze filteren;
alles wat geen station is, zakt eronder. **Eerste tegel: ~600 → ~260 pt.**

### W3 — Actie eerst (DJ-modi)
Persona-grid naar boven, het autoplay-instellingenblok naar onderen. De regel
"start eerst een nummer" komt direct boven het grid te staan in plaats van boven
een instelling.

### W4 — Eén schakelaarvorm
`SettingToggle`: één rij met een fatsoenlijke minimumhoogte, gebruikt op beide
plekken. Dit repareert de overlapping bij de bron in plaats van er padding
tegenaan te duwen.

### W5 — Drie gelijke reiskaarten (Journeys)
Eén `journeyCard`-vorm: icoon, naam, één regel uitleg, en **precies één primaire
actie**. Album Radio krijgt er een — een knop die je naar je albums brengt, want
daar start je hem — in plaats van een kaart die niets doet.

### W6 — Alles speelt op de actieve uitvoer
Time Machine, de Qobuz-sync eromheen en `GenerateModel.queueOne` gaan van
`selectedZone` naar `playToActiveOutput` / `queueToActiveOutput` / `hasActiveOutput`,
zoals de rest van de app sinds v1.10.228.

### W7 — De laatste Nederlandse literals
De drie interpolatie-sleutels in `SonicJourneysView` worden `String(format:)` met
een echte sleutel.

## 5. Maten — vóór, doel, gehaald

Afgelezen van `native/scripts/ui-verify.sh` op dezelfde simulator, vóór en na.

| Maat | Vóór | Doel | Na |
|---|---|---|---|
| Titelniveaus boven de inhoud | 3 | 2 | **2** |
| Chrome vóór de eerste inhoud | 315 pt | ≤ 225 pt | **223 pt** |
| Eerste stationstegel (Radio's) | ~600 pt | ≤ 300 pt | **~288 pt** |
| Overlappende bedieningselementen | 2 | 0 | **0** |
| Interactiemodellen op Journeys | 3 | 1 | **1** |
| Zone-only acties in deze tab | 3 | 0 | **0** |
| Interpolatie-sleutels in deze tab | 3 | 0 | **0** |
| Persona's zichtbaar zonder scrollen | 2 | — | **6** |

## 6. Wat er onderweg bijkwam

Drie dingen die pas zichtbaar werden toen de rest opgeruimd was:

- **Een gat van 54 pt onder elke kop.** `List` reserveert ruimte boven zijn
  eerste rij voor een sectiekop die een kaartenfeed niet heeft. Met de oude,
  hoge koppen viel dat niet op; eronder werd het een zichtbaar gat. Opgelost met
  `cardFeedList()`, toegepast op alle vier de segmenten.
- **De Bridge-knop zag er anders uit dan de twee erboven.** Een `NavigationLink`
  in een `List` tekent zijn eigen disclosure-chevron en negeert
  `.buttonStyle(.bordered)` op zijn label, dus die actie werd kale tekst met een
  losse "›" ernaast. Nu een `Button` + `navigationDestination(isPresented:)`, wat
  de enige manier is om de drie kaarten op één scherm te laten lijken.
- **"Wat voor playlist?" stond er drie keer.** Op Genereer zei de segmentregel,
  de sectiekop én de placeholder van het tekstveld hetzelfde. De sectiekop is
  weg; de andere twee blijven, want die staan er om verschillende redenen.

## 7. Bewust niet gedaan

- **De per-categorie uitleg op Radio's** ("Eindeloze stations per genre uit je
  bibliotheek", enz., 7 varianten) is vervallen met de kop. De pillen zeggen
  Artist/Genre/Mood/Activity/Decade — dat is dezelfde informatie in één woord in
  plaats van twee regels, en het staat direct boven wat het filtert.
- **De actieve-radiobanner is niet aangeraakt.** Die is offline niet te
  fotograferen, dus elk oordeel erover zou ongemeten zijn.
- **Genereer blijft een `Form`.** Dat scherm ís een formulier; alleen zijn kop en
  bovenmarge zijn gelijkgetrokken met de andere drie.
