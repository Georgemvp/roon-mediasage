# Stations — functionele audit en plan

> Opgesteld 2026-08-22, op vraag van de user: *"Doe nog een audit van de stations
> view. Controleer alle functies, kijk of de functies wel slim zijn of slimmer
> moeten worden of kunnen opgaan in andere functies. Kijk of de UX verbeterd kan
> worden, kijk of alles duidelijk is, kijk of alles snel is. Oftewel maak een plan
> om deze view veel professioneler te maken."*
>
> De vorige ronde ([STATIONS_AUDIT.md](STATIONS_AUDIT.md)) ging over **vorm** —
> volgorde, koppen, kaartvormen, overlappende schakelaars. Dit gaat over
> **functie**: wat doet elk ding, overlapt het met iets anders, is het snel, en
> begrijpt iemand het.
>
> **Methode.** Code geteld in `RoonSageCore` (5.458 regels radio-gerelateerd) en
> `RoonSageUI`. Tijden gemeten met `curl` tegen de draaiende analyzer op deze mini
> (**87.820 tracks**, 66.378 geanalyseerd) — geen schattingen. Waar iets niet
> gemeten kon worden staat dat er expliciet bij.

---

## 1. Oordeel in één alinea

Onder Stations zit **één motor** — `startRadio → buildRadioCandidates → top-up` —
en daar staan **vier verschillende deuren** naartoe die elkaar niet kennen. Een
DJ-persona is per eigen documentatie "a thin preset, not a new engine": hij zet
drie knoppen (dial, arc, gate) op diezelfde motor. Een categorie-radio zet
dezelfde knoppen vanuit een bucket. Een opgeslagen "Mijn radio" zet ze vanuit een
`RadioConfig` — en dát datamodel is precies de **superset van alle andere drie**.
Het gevolg is dat één instelling, de avontuurlijkheidsdial, op **vijf plekken**
bestaat met vijf verschillende bedieningen, dat dezelfde artiesten in twee
lijsten met verschillende namen op hetzelfde scherm staan, en dat de motor
combinaties aankan die de UI niet aanbiedt (een genre-station mét een persona kan
gewoon — `startRadio(djMode:)` — maar je kunt het nergens kiezen). Daarbovenop
kost het openen van Radio's een netwerkcall van **6,1 s koud / 0,91 s warm** voor
een sectie die onderaan staat, en wordt de complete stationsberekening bij élke
segmentwissel opnieuw gedaan terwijl het resultaat per rotatiebucket constant is.

## 2. Feature-inventaris — alles wat in deze tab zit

| # | Feature | Waar | Wat het doet | Waar het draait |
|---|---|---|---|---|
| F1 | Categorie-stations | Radio's | 7 categorieën (artiest, genre, sfeer, activiteit, decennium, buurten, recent) → eindeloze stations | client, over de hele geanalyseerde bibliotheek |
| F2 | Avontuurlijkheidsdial | Radio's | 0…1 globaal; bepaalt hoe ver de motor van de seed afdwaalt | `radioAdventurousness`, UserDefaults |
| F3 | "Verberg duim-omlaag" | Radio's | harde ban i.p.v. down-sampling | `radioHardBanDisliked` |
| F4 | Mijn radio's | Radio's → push | CRUD op `RadioConfig`: artiesten + tracks + genres + sferen + activiteiten + decennia + **eigen dial** | server-of-record |
| F5 | AI-radio's op Qobuz | Radio's, onderaan | ~6 artiest-stations → 20-30 tracks, AI-titel, elke 3 u ververst, als Qobuz-playlist | analyzer, `/ai-radios` |
| F6 | Radio-sync-selectie | Instellingen | allow-list van welke stations naar Qobuz gespiegeld worden | `radiosync.selection` |
| F7 | Sturen in gewone taal | Radio's, actieve banner | "verras me" / "veiliger" → ±0,2 op **dezelfde dial als F2** | `RadioSteerParser` |
| F8 | DJ-persona's (6) | DJ-modi | preset van dial + arc + gate op de nu spelende track | dezelfde `startRadio` |
| F9 | Guest-DJ autoplay | DJ-modi | vult de wachtrij aan als hij leegloopt; optioneel persona-per-tijdstip | `djAutoplayEnabled` |
| F10 | Album Radio | Journeys | eindeloos station rond één album | `startAlbumRadio` → `startRadio` |
| F11 | Time Machine | Journeys | **eindige** chronologische lijst oud → nieuw | `buildTimeMachine` → `curateTracks` |
| F12 | The Bridge | Journeys | **eindig** A→B-pad tussen twee nummers | `SongPaths` |
| F13 | Genereer | Genereer | LLM-prompt + seeds + doelaantal → **eindige** playlist | server `/generate`, valt lokaal terug |
| F14 | 63 playlist-sjablonen | Genereer | voorgekookte prompts in 8 categorieën | statisch |

## 3. De architectuur eronder — één motor, vier deuren

```
                     ┌──────────────────────────────────────────┐
   F1 bucket  ──────►│                                          │
   F8 persona ──────►│  startRadio(seedIds, dial, arc, gate)    │──► eindeloos
   F10 album  ──────►│  → buildRadioCandidates → top-up         │
   F4 config  ──────►│                                          │
                     └──────────────────────────────────────────┘

   F11 Time Machine ─► buildTimeMachine ─► curateTracks   ──► eindig
   F12 The Bridge   ─► SongPaths                          ──► eindig
   F13 Genereer     ─► LLM + curatie                      ──► eindig
```

Twee soorten dingen dus — **eindeloze stations** (F1, F4, F8, F10) en **eindige
lijsten** (F11, F12, F13) — en de vier segmenten snijden daar dwars doorheen:
Journeys bevat één station (Album Radio) en twee lijsten, Radio's bevat stations
én een lijstenspiegel (F5).

## 4. Bevindingen

### 4.1 Overlap — wat kan opgaan in wat

**B1 · `RadioConfig` is het algemene geval; drie features zijn er bijzondere
gevallen van.** `RadioConfig` draagt artiesten, tracks, genres, sferen,
activiteiten, decennia én een eigen dial. Daarmee is:
- `genre:house` (F1) = `RadioConfig(genres: ["house"])`
- een DJ-persona (F8) = `RadioConfig(trackKeys: [seed])` + dial/arc/gate-preset
- Album Radio (F10) = `RadioConfig(trackKeys: albumtracks)`

Drie features met eigen schermen, eigen tuning en eigen opslag, die één datamodel
delen dat al bestaat. **Dit is de kern van het plan.**

**B2 · De dial bestaat vijf keer.** `radioAdventurousness` (F2, schuif) ·
`DJMode.adventurousness` (F8, voorgekookt) · `RadioConfig.adventurousness` (F4,
per radio — de code zegt zelf "mirrors RoonClient.radioAdventurousness") ·
`RadioSteerParser` (F7, ±0,2 op F2) · `generatePlaylist(adventurousness:)` (F13).
Vijf bedieningen voor één begrip, en niets op het scherm vertelt je welke er nu
geldt.

**B3 · Twee radiosystemen naast elkaar, op hetzelfde scherm.** F1 bouwt live
stations client-side; F5 bouwt van *dezelfde seeds* 20-30-track-playlists met een
AI-titel op de server. Op Radio's staan ze onder elkaar — dezelfde artiesten,
andere namen, ander gedrag. Nergens staat dat de tweede lijst dezelfde muziek is,
alleen bevroren en met een andere naam.

**B4 · De motor kan meer dan de UI aanbiedt.** `startRadio(_:zoneID:djMode:)` en
`startAlbumRadio(…djMode:)` accepteren allebei een persona. Je kunt dus
technisch "genre house, maar dan als The Daredevil" of "dit album, als The
Superfan" starten — maar de UI biedt persona's uitsluitend aan op de nu spelende
track. Een bestaande, gratis capaciteit die niemand kan bereiken.

**B5 · Genereer en Mijn radio's vragen hetzelfde.** `generatePlaylist` neemt
`seedArtists`, `seedTrackKeys`, `adventurousness`, `arc` — precies de facetten van
een `RadioConfig`. Het verschil is dat de een eindigt en de ander niet, en dat de
een een LLM-prompt heeft. Twee schermen die dezelfde vraag anders stellen.

### 4.2 Snelheid — gemeten

| Wat | Meting | Gevolg |
|---|---|---|
| `/ai-radios` koud (na herstart analyzer) | **6,08 s** | Radio's toont een spinner onderaan bij de eerste opening van de dag |
| `/ai-radios` warm | **0,91 s** | draait bij **élke** opening van het segment |
| `/taste-analysis` | 0,37 s | ok |
| `/history`, `/playback`, `/radio-configs` | 0,01–0,03 s | ok |

**B6 · `loadQobuz` draait bij elke segmentwissel.** `SonicRadioView` heeft
`@State private var loaded = false` en twee `.task`-blokken. Wissel je naar
DJ-modi en terug, dan wordt de view opnieuw opgebouwd, staat `loaded` weer op
false en draaien beide loads opnieuw — inclusief die 0,91 s netwerkcall voor een
sectie die je zelden bereikt.

**B7 · De stationslijst wordt telkens herberekend en nergens gecachet.**
`dailyRadios()` groepeert de hele bibliotheek per artiest, scoort alle kandidaten
en sorteert — per opening. Het resultaat is per `rotationStamp()` (dag + uurbucket)
**per definitie constant**. Er is geen cache op dat niveau; wel op de laag
eronder (`SonicLibraryCache`).

**B8 · Een stationslijstje kost de hele bibliotheek in RAM.** `radioLibrary()` →
`sonicCache.tracks(from:)` laadt élke geanalyseerde track mét een 512-dimensionale
CLAP-embedding (2 KB) plus moods/attributes/tags/genres — ruwweg 2,5 KB per track,
dus **~165 MB bij 66.378 tracks**. Dat is de reden dat de analyzer vandaag
"Geheugendruk — sonische caches vrijgegeven" logde. Voor het *tonen* van een lijst
stations is geen enkele embedding nodig; die zijn pas nodig zodra je er één start.

### 4.3 Duidelijkheid

**B9 · Vier namen voor hetzelfde.** "Sonic radios" (F1), "My radios" (F4), "AI
radios on Qobuz" (F5), "DJ modes" (F8) — het zijn alle vier eindeloze stations uit
je eigen bibliotheek. Niets legt het verband uit.

**B10 · "Buurten" is een technisch woord.** De categorierij is Artiest · Genre ·
Sfeer · Activiteit · Decennium · **Buurten** · Recent. Zes daarvan zijn
gebruikersbegrippen; "Buurten" (k-means-clusters over CLAP-embeddings) is de
implementatie die naar buiten lekt.

**B11 · De dial belooft iets wat pas later gebeurt.** De schuif geldt voor "het
volgende station dat je start" — dat staat nergens. Wie hem tijdens het luisteren
verschuift, verwacht dat het nú verandert. (F7, het stuurveld, doet dat wél — maar
alleen zichtbaar als er een station loopt.)

**B12 · Journeys mengt eindig en eindeloos.** Album Radio stopt nooit, Time
Machine en The Bridge hebben een einde. Ze staan als drie gelijke kaarten onder
elkaar, wat suggereert dat ze hetzelfde soort ding zijn.

## 5. Het plan

Vier fasen, oplopend in ingrijpendheid. Elke fase staat op zichzelf en is los te
shippen.

### Fase 1 — Snelheid en zichtbare rust (klein, meetbaar)

**W1 · Cache de stationslijst per rotatiebucket.** Een `[categorie ×
rotationStamp] → [SonicRadio]`-cache op `RoonClient`, geïnvalideerd door dezelfde
twee gebeurtenissen als `SonicLibraryCache` (features-sync, library-sync) plus een
nieuwe bucket. *Doel: tweede opening van een categorie < 50 ms.*

**W2 · Laad de Qobuz-spiegel pas als hij in beeld komt.** Nu een `.task` bij het
verschijnen van het scherm; wordt een `.task` op de sectie zelf (of een knop
"toon"). *Doel: 0,91 s netwerk per segmentopening → 0.*

**W3 · Een lijst stations tonen zonder embeddings te laden.** `dailyRadios` heeft
per station alleen naam, hoes, aantal en seed-ids nodig — dat is een SQL-query, geen
165 MB. De embeddings pas laden bij `startRadio`. *Doel: het openen van Radio's
raakt `sonicCache` niet meer.* (Grootste technische klus van deze fase; te doen als
`radioLibraryLight()` naast de bestaande.)

**W4 · Zeg wat de dial doet.** Eén regel onder de schuif: "geldt vanaf het
volgende station" — en als er een station loopt, de bestaande stuurzin tonen.

### Fase 2 — Eén taal voor stations (UX, geen architectuur)

**W5 · Noem alles wat eindeloos is een station.** "Sonic radios" → **Stations**,
"My radios" → **Eigen stations**, "AI radios on Qobuz" → **Op Qobuz gezet**, "DJ
modes" → **Gast-DJ**. Eén woord voor één concept.

**W6 · Vouw de Qobuz-spiegel in de stationskaarten.** In plaats van een tweede
lijst onderaan: een klein Qobuz-merkje op de stations die gespiegeld zijn, en één
regel "12 van je stations staan op Qobuz · beheren". *Doel: twee lijsten van
dezelfde artiesten → één.*

**W7 · "Buurten" hernoemen** naar iets wat een luisteraar herkent — bijvoorbeeld
**Klankgroepen**, met één regel uitleg. (Naamkeuze aan Casper.)

**W8 · Journeys splitsen op wat het ís.** Album Radio verhuist naar de stations
(het is er een); Time Machine en The Bridge blijven samen als **eindige reizen**.
Daarmee bevat elk segment één soort ding.

### Fase 3 — De persona overal beschikbaar maken (kleine ingreep, groot effect)

**W9 · Een persona is een *manier van spelen*, geen aparte lijst.** De motor
accepteert `djMode` al op élke station-start (B4). Voorstel: één persona-kiezer die
bij het starten van welk station dan ook meegaat — als optie in het
lang-indrukken-menu van een stationskaart, en als "speelt nu als …" op de speler.
Het DJ-modi-segment wordt dan wat het eigenlijk is: **de persona-kiezer plus
autoplay**, en niet een tweede stationslijst die alleen op de huidige track werkt.

**W10 · Eén dial, één plek.** De globale schuif blijft de standaard; een persona
of een eigen station overschrijft hem tijdelijk en dat wordt zichtbaar gemaakt
("The Daredevil stuurt nu — avontuurlijk"). `RadioConfig.adventurousness` blijft
bestaan als override, maar krijgt in de editor de tekst "wijkt af van je
standaard". *Doel: vijf bedieningen → één zichtbare waarheid met expliciete
overrides.*

### Fase 4 — Eén stationsmodel (architectuur; alleen als fase 1-3 bevallen)

**W11 · Maak `RadioConfig` het enige stationsmodel.** De automatische categorieën
worden voorgebakken configs (niet-bewerkbaar, wel "bewaar als eigen station"),
Album Radio wordt een config met albumtracks als seeds, en een persona wordt een
`presetOverride` op een config. Eén CRUD, één gate-berekening, één sync-selectie.
*Winst: `RoonClient+RadioCategories` (560 r.) en delen van `RoonClient+Radio`
(612 r.) vallen samen met `RoonClient+CustomRadio` (560 r.); drie tuning-sets
worden er één.*

**W12 · "Bewaar dit als station" overal.** Zodra alles één model is, kan elk
station dat je nu hoort — een categorie, een album, een persona-sessie — met één
tik een eigen station worden. Dat is de functie die de app al kán en nergens
aanbiedt.

**W13 · Genereer wordt "een station met een einde".** Zelfde seed-facetten,
zelfde dial, plus een prompt en een doelaantal. Eén formulier in plaats van twee
schermen die dezelfde vraag anders stellen. (Grootste stap; alleen zinvol ná W11.)

## 6. Maten om achteraf te toetsen

| Maat | Nu | Doel |
|---|---|---|
| Netwerk bij openen Radio's (warm) | 0,91 s | 0 s |
| Tweede opening van een categorie | volledige herberekening | < 50 ms |
| Geheugen voor het *tonen* van stations | ~165 MB (hele bibliotheek + embeddings) | alleen de lijst |
| Bedieningen voor de avontuurlijkheid | 5 | 1 zichtbaar + expliciete overrides |
| Woorden voor "eindeloos station" | 4 | 1 |
| Lijsten met dezelfde artiesten op één scherm | 2 | 1 |
| Plekken waar een persona te kiezen is | 1 (nu-spelend) | overal waar een station start |
| Regels radio-code in Core | 5.458 | na fase 4 meetbaar minder (W11) |

## 7. Wat we bewust niet doen

- **Geen feature schrappen.** Alle 14 blijven bestaan; het plan verplaatst en
  verenigt ze.
- **Geen tweede "eenvoudige modus".** Dezelfde reden als in het UX-speler-plan: een
  modusschakelaar is zelf complexiteit.
- **Fase 4 niet vóór fase 1-3.** De architectuur samenvoegen is pas verantwoord als
  de goedkope winst binnen is en de nieuwe woordenschat bevalt — anders herschrijf
  je een model dat je daarna alsnog anders wilt noemen.
- **De motor zelf niet aanraken.** `buildRadioCandidates`, de gates en de
  sequencer doen aantoonbaar hun werk; dit plan gaat over hoeveel deuren er naar
  toe leiden, niet over wat erachter gebeurt.

## 8. Wat niet gemeten kon worden

- **De client-side kant op een echt toestel.** De metingen hierboven zijn tegen de
  analyzer op de mini. Hoeveel `dailyRadios` op een iPhone kost met een volledig
  gesynchroniseerde bibliotheek is onbekend — B8 zegt dat het geheugen daar het
  knelpunt wordt, maar dat is beredeneerd, niet gemeten.
- **GUI-doorloop met echte data.** De simulator kon deze sessie niet met een
  venster starten (LaunchServices `-1712`), nadat zwaar simulator- en buildwerk op
  deze mini de analyzer had uitgeswapt — zie STATE.md. De UI-observaties komen uit
  de XCUITest-schermafdrukken van de vorige ronde.
