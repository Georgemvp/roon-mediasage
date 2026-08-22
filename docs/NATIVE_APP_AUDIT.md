# RoonSage Native — 360°-audit (UX + volledige functionaliteit)

> Datum: 2026-08-22 · Scope: `native/RoonSage` (292 Swift-bestanden, ~65k regels), `native/RoonProtocol`, `native/iosapp`
> Methode: baseline-verificatie, gerichte diepte-lezing van de gebruikersketens (bibliotheek, speler,
> wachtrij, navigatie, verbinding) plus repo-brede sweeps op lokalisatie, a11y en Dynamic Type.
>
> **Eerlijk over de dekking:** de UI-laag en het Core-transport/remote-pad zijn regel voor regel gelezen
> (`LibraryView`, `RootView`, `PlayerScreen`, `QueueView`, `NowPlayingSurface`, `CommandPalette`,
> `RoonSageApp`, `RoonClient+Transport`, `RoonClient+Remote`, `PlaybackEventHub`, `LibraryShareServer`).
> De AI-/DSP-kant (`RoonClient+Generate`, `Sonic/*`, `AnalyzerCore`) is steekproefsgewijs gelezen op de
> vraag "kan dit iets voorstellen dat niet speelbaar is" — niet uitputtend. Alles hieronder is
> geverifieerd tegen file:line, niet vermoed.

## Baseline (vers gedraaid, 2026-08-22)

| check | uitkomst |
|---|---|
| `cd native/RoonProtocol && swift test` | 12 tests, 0 failures |
| `cd native/RoonSage && swift test` | **973 tests, 0 failures** |
| `swift build -c release --product RoonSage` | exit 0 |
| `swiftlint lint --config .swiftlint.yml` | 469 violations, **5 serious** (alle `empty_count`) |
| `native/scripts/check-localization.sh` | 1033 sleutels · 0 missend · 0 wees · **61 geïnterpoleerd** |

`swiftlint` stond niet lokaal geïnstalleerd (CI doet `brew install swiftlint`); nu wel.

---

## Eindoordeel in één alinea

De app is in ongewoon goede staat: de reconnect-logica, de zone-grace, de FTS5-zoekindex, de
paginering en de "library-first"-garantie zijn niet alleen aanwezig maar ook bewust ontworpen en in
commentaar verantwoord. Wat er nog fout gaat, gaat bijna allemaal fout op één plek: **toestand die in
Core correct wordt bijgehouden maar de UI nooit bereikt.** `zonesAreStale` wordt op drie plekken
berekend en door geen enkele view gelezen; de wachtrij wordt op de cliënt uit een snapshot gevoed maar
door een subscriptie-API leeggegooid die daar niet draait; de skeleton-loader van de bibliotheek is
onbereikbaar omdat de laad-vlag vóór de laadactie wordt gezet. Dat zijn geen cosmetische kwesties —
het zijn precies de gevallen waarin de app iets toont dat niet waar is. Daarnaast is de
iPhone-navigatie onvolledig: negen van de zeventien bestemmingen van het commandopalet komen stil op
het bibliotheek-tabblad uit.

---

## 🔴 Functionele gaten / bugs (broken flows & edge cases)

### F1 — De wachtrij is op de cliënt tot 15 s leeg na het openen
`RoonSageUI/QueueView.swift:84,353` · `RoonSageCore/RoonClient.swift:1041-1060`

De verzonden apps draaien in `.server`-modus (`RoonSageApp.swift:17` → `useServerMode()`), dus
`isRemote == true` en `queueItems` komt uit `applyPlaybackSnapshot` (`RoonClient+Remote.swift:428`).
Maar `QueueView.onAppear` roept `restart()` → `client.startQueue(zoneID:)`, en die doet
onvoorwaardelijk `queueItems = []` en abonneert daarna op een Roon-WebSocket die in remote-modus niet
bestaat (`try? await transport.subscribe(...)` → nil → `return`).

Gevolg, per pad:
- **Spelend:** de snapshot-digest verandert elke tick (seek-positie), dus de wachtrij vult zich na
  ~1,5 s. Zichtbare flits van "Niets in de wachtrij".
- **Gepauzeerd:** de snapshot is statisch, `PlaybackEventHub.tick()` pusht alleen bij een gewijzigde
  digest (`PlaybackEventHub.swift:99`), en de fallback-poll staat op **15 s** zolang de stream leeft
  (`RoonClient+Remote.swift:232`). De wachtrij blijft dus tot 15 seconden leeg.

`onDisappear { client.stopQueue() }` zet `queueItems = []` opnieuw, en `ZoneNowPlayingSurface.upNext`
+ `queueSummary` lezen datzelfde veld (`NowPlayingSurface.swift:298,309`) — dus na elk bezoek aan de
wachtrij verdwijnen ook de "hierna"-pil en de "nog N over"-teller van de speler voor hetzelfde venster.

### F2 — `zonesAreStale` wordt berekend en door niemand getoond
`RoonSageCore/RoonClient.swift:356,962,992,1137` · `RoonClient+Remote.swift:426`

Bij een wegvallende Roon-verbinding houdt de app de laatst bekende zones 45 s vast
(`zoneGraceSeconds`) en markeert ze als verouderd — bewust, om te voorkomen dat een blip de hele UI
leegt. Maar `zonesAreStale` heeft **nul lezers buiten Core**. De gebruiker ziet een volledig normale,
volledig ingeschakelde interface; pas na een druk op play komt er een foutmelding
("Afspelen/pauzeren mislukt — geen verbinding met Roon"). `ReconnectingBanner` dekt dit niet af: die
toont alleen `!isConnected && !hasLiveSession && !offlineMode`, en tijdens de grace is
`hasLiveSession` nog `true` (`RoonClient.swift:84`).

Dit is exact het scenario uit de opdracht — "duidelijke statusmelding i.p.v. bevroren UI" — en de
informatie ligt al klaar.

### F3 — Bibliotheek-overzicht toont "Nog geen bibliotheek" tijdens het laden
`RoonSageUI/LibraryView.swift:1157-1170` (weergave) en `:1378-1382` (`loadOverview`)

```
private func loadOverview() {
    guard !loadedModes.contains(.overview) else { return }
    loadedModes.insert(.overview)          // ← synchroon, vóór de Task
    Task { await performOverviewLoad() }
}
```
De weergave kiest `SkeletonRows()` alleen als `stats == nil && !loadedModes.contains(.overview)`. Die
combinatie bestaat nooit: de vlag staat er al in vóórdat de zeven queries beginnen. De hele laadtijd
lang toont het overzicht dus `overviewEmpty` — "Nog geen bibliotheek · synchroniseer je bibliotheek" —
op een apparaat dat een volle bibliotheek heeft. Advies om precies het verkeerde te doen, en de
skeleton-code die dit moest voorkomen is dode code.

### F4 — "Alleen favorieten" filtert over 120 albums na een tabwissel of zoekopdracht
`RoonSageUI/LibraryView.swift:274-277,872-878,890-895,935-968`

`fillAllPages()` bestaat precies om te voorkomen dat de sterfilter "de favorieten binnen de eerste
120 albums" betekent — het commentaar zegt dat ook met zoveel woorden. Maar hij wordt maar op één
plek aangeroepen: `onChange(of: favoritesOnly)` bij het **aanzetten**. Alle andere paden die de grid
terugzetten naar pagina 1 doen het niet:
- `onChange(of: viewMode)` → `loadContentIfNeeded()` → `loadAlbums()`/`loadArtists()`
- `onChange(of: searchText)` → `loadedModes.subtract(...)` → `reloadContent()`

En omdat `loadMoreAlbums`/`loadMoreArtists` paginering pauzeren zolang `favoritesOnly` aan staat
(`guard ... !favoritesOnly`), groeit de lijst daarna ook niet meer. Zet de filter aan bij Albums,
tik naar Artiesten: je ziet de favorieten onder de eerste 120 artiesten, zonder enig teken dat de rest
bestaat. Alleen `refresh()` (pull-to-refresh) doet het wél goed (`:986,990`) — wat bewijst dat de
bedoeling helder was.

### F5 — Negen van de zeventien palet-bestemmingen zijn dood op de iPhone
`RoonSageUI/CommandPalette.swift:333-344` · `RoonSageUI/RootView.swift:733-751`

Het commandopalet biedt 17 "Ga naar …"-commando's. `go(to:)` vangt op compact-iOS alleen
`.nowPlaying` en `.settings` af (als sheet); de rest zet `selection`, en `iOSTabSelection` mapt dat op
één van vier tabs. Alles wat niet in `searchItems`/`exploreItems`/`stationItems` zit, valt in de
`default`-tak → `.library`.

Dood op de iPhone: **`.queue`, `.playlists`, `.bookmarks`, `.dj`, `.lab`, `.sonicLab`, `.musicMap`,
`.multitag`, `.tasteHub`**. Je tikt "Ga naar Wachtrij" en belandt op de bibliotheek. Dat is dezelfde
klasse fout die elders in dit bestand juist zorgvuldig is opgelost ("otherwise you tap them and
nothing appears to happen", `RootView.swift:707`).

---

## 🟠 UX-knelpunten & frictie

### U1 — Geen optimistic UI op transport en volume
`RoonSageCore/RoonClient+Transport.swift` (hele bestand) · `RoonSageUI/PlayerScreen.swift:506-546,577`

Elke transport-actie (`playPause`, `next`, `previous`, `setShuffle`, `setRepeat`, `toggleMute`) stuurt
het commando en wacht op de volgende snapshot voor de UI-verandering. Er is geen enkele optimistische
mutatie. Over ZeroTier is dat een merkbare stilte tussen tik en respons op de grootste knop van het
scherm. De architectuur ondersteunt het prima — `zoneMap` is lokaal en `applyPlaybackSnapshot`
overschrijft toch — maar niemand doet het.

De volumeschuif is een tweede geval: `Slider(...) { editing in ...; if !editing { vol.set(...) } }`
stuurt pas bij **loslaten**. De knop beweegt, het geluid niet. Voor een afstandsbediening is dat het
verkeerde model.

### U2 — 61 gebruikersstrings negeren de taalinstelling
Repo-breed, script-geverifieerd (`check-localization.sh`, en `grep -rn 'L[ST]("[^"]*\\('`)

Sleutels met string-interpolatie erin kunnen per definitie nooit oplossen en vallen terug op het
Nederlandse literal. Het bestand `RootView.swift:595` waarschuwt hier expliciet voor — en twee
regels verderop staan er zelf twee (`:791` `LS("Verbinding: \(...)")`, `:824` de slaaptimer-tooltip).
Verspreid over 24 bestanden; de meest zichtbare zijn `QueueView:30` (de lege wachtrij),
`CommandPalette:340` (élk navigatie-commando), `DJSetView` (7×) en `DiscoverWeeklyView` (4×).

### U3 — Het macOS-menu is ongelokaliseerd Nederlands
`RoonSage/RoonSageApp.swift:38-57,110-115`

`CommandMenu("Bediening")`, "Speel / pauzeer", "Volgende track", "Volume omhoog", "Zoek naar
updates…", "Je bent up-to-date" — allemaal harde literals, geen `LS()`. `check-localization.sh` mist
dit omdat het alleen op `LS("…")` grept. Op een Engelse Mac blijft de menubalk dus Nederlands terwijl
het venster eronder vertaalt.

### U4 — ⌘1…9 wijst naar een andere lijst dan de zijbalk
`RoonSageUI/RootView.swift:795-802`

`SidebarItem.allCases.prefix(9)` = nowPlaying, queue, library, ask, generate, recommend, playlists,
bookmarks, djSet. De zijbalk toont (`SidebarSection.items`) nowPlaying, queue, library, playlists,
bookmarks, sonicSearch, stationsHub, discovery, lab, tasteHub, settings. ⌘4/5/6/9 springen dus naar
bestemmingen die niet in de zijbalk staan, waardoor de selectie nergens oplicht; ⌘7/⌘8 wijzen naar
rij 4 en 5. De volgorde van een `CaseIterable` is een implementatiedetail, geen menu.

### U5 — Geen ⌘F, geen spatiebalk op macOS
`grep -rn keyboardShortcut native/RoonSage/Sources` — de enige globale bindingen zijn ⌘K, ⌘1-9,
⌘P, ⌘[, ⌘], ⌘↑, ⌘↓.

Twee conventies die een Mac-gebruiker zonder nadenken probeert ontbreken: **⌘F** zet de focus niet in
het zoekveld van de bibliotheek, en de **spatiebalk** doet niets (play/pause zit op ⌘P). De
spatiebalk is legitiem lastig — hij mag niet vuren terwijl er een tekstveld focus heeft — maar ⌘F is
recht toe recht aan.

### U6 — De speler belooft een "wis de wachtrij" die voor een Roon-zone niet bestaat
`RoonSageUI/PlayerScreen.swift:741-744` (commentaar) · `QueueView.swift:270-300`

"Stopping is still reachable from the mini-player, and the queue screen can clear what's upcoming."
`clearUpcoming` zit alleen in `localQueueOptions` — de on-device wachtrij. Voor een Roon-zone heeft
`queueOptions` alleen bewaren/shuffle/repeat. De belofte klopt voor één van de twee outputs.

### U7 — Dedup verbergt nummers zonder dat te zeggen
`RoonSageUI/LibraryView.swift:141-149`

`sortAndDedupe` houdt per `artiest|titel` alleen de eerste rij. Bedoeld voor remasters en
deluxe-edities, maar het geldt ook voor een studio- en een liveversie (`isLive` wordt wél
bijgehouden en hier genegeerd) en voor covers op verzamelalbums. `selectedRecords()` filtert
`displayTracks`, dus "selecteer alles → bewaar als playlist" laat de verborgen kopieën stil vallen.
Er is geen teller en geen "toon duplicaten".

### U8 — Zeven icon-only knoppen zonder VoiceOver-label
Script-geverifieerd (label-body bevat alleen een `Image(systemName:)`, geen `accessibilityLabel`
binnen 8 regels):

| bestand:regel | icoon | betekenis |
|---|---|---|
| `SonicRadioView.swift:87` | `arrow.clockwise` | ververs |
| `SonicFingerprintView.swift:49` | `arrow.clockwise` | ververs |
| `CustomRadioView.swift:256` | `eye`/`eye.slash` | verberg/toon |
| `CustomRadioView.swift:266` | `square.and.pencil` | bewerk |
| `SongAlchemyView.swift:132,157` | `xmark.circle.fill` | verwijder |
| `SonicSearchView.swift:83` | `xmark.circle.fill` | wis zoekopdracht |

Daarnaast twee harde Engelse labels op een verder Nederlands scherm:
`PlayerScreen.swift:511` `.accessibilityLabel("Shuffle")` en `:587` `.accessibilityLabel("Volume")`.

---

## 🟡 Performance, geheugen & batterij

### P1 — De hele speler hertekent één keer per seconde, ook als er niets speelt
`RoonSageUI/PlayerScreen.swift:213-218`

```
.onReceive(Timer.publish(every: 1, on: .main, in: .common).autoconnect()) { _ in
    guard !surface.positionIsContinuous, !isSeeking else { return }
    displayPosition = NowPlayingModel.interpolatedPosition(...)
}
```
Drie dingen tegelijk:
1. `displayPosition` is `@State` van `PlayerHero`, gelezen door `scrubber` → de **hele** hero (art,
   trackinfo, feature-badges, visualizer, scrubber, transport, volume, footer) hertekent op 1 Hz.
   De opdracht noemt dit expliciet: "geen onnodige body re-evaluaties bij elke tick".
2. De guard sluit een gepauzeerde speler niet uit. `interpolatedPosition` geeft dan het anker terug,
   maar de toewijzing aan een `Double`-`@State` invalideert alsnog — een gepauzeerde iPhone hertekent
   dus eeuwig op 1 Hz.
3. `Timer.publish(...).autoconnect()` staat *in* `body`, dus elke evaluatie maakt een nieuwe
   publisher aan die `onReceive` opnieuw moet abonneren. Zelf-versterkend met punt 1.

De remedie is bekend en klein: de scrubber (plus de twee tijdlabels) in een eigen subview die
`displayPosition` bezit.

### P2 — `curateTracks` doet één round-trip per nummer, sequentieel
`RoonSageCore/RoonClient+Transport.swift:85-99`

Een playlist van 50 nummers = 50 opeenvolgende `playByBrowse`-aanroepen over ZeroTier. De volgorde
móet behouden blijven, dus parallelliseren kan niet zomaar — maar de remote-timeout staat er niet
voor niets op 180 s (`RoonClient+Remote.swift:541`). Waard om te meten voordat je eraan begint.

### P3 — `fillAllPages()` kan 24.000 albums in het geheugen trekken
`RoonSageUI/LibraryView.swift:947-968` — 200 iteraties × `gridPageSize` 120. Voor de doelbibliotheek
prima; voor de >100k-tracks-vraag uit de opdracht is dit het enige punt waar de paginering bewust
wordt opgeheven. Begrensd en gedocumenteerd, dus geen bug — wel het plafond.

### P4 — `ForEach(Array(client.queueItems.enumerated()), id: \.element.id)`
`RoonSageUI/QueueView.swift:39` — precies de constructie die in `LibraryView` is weggehaald omdat hij
een volledige tuple-kopie per body-evaluatie kost. Begrensd op 200 items (`max_item_count`), dus
klein bier, maar inconsistent met de rest.

---

## 🟢 Codekwaliteit, concurrency & architectuur

### C1 — 5 "serious" lintfouten, allemaal `empty_count`
`SettingsView.swift:933` plus vier in andere bestanden. CI draait `--lenient` dus ze breken niets,
maar het zijn de enige violations boven waarschuwingsniveau. De overige 464 zijn opmaak
(`comma` 132, `colon` 93, `statement_position` 70) — een `swiftlint --fix` zou het leeuwendeel
oplossen, maar dat is een diff van honderden regels en hoort niet in een auditbatch.

### C2 — `docs/STATE.md` is 1188 regels
De eigen guardrail (`docs/guardrails/SESSION.md` S2) zegt "Keep it under 80 lines by deleting old
Done entries". `## Now` beslaat in z'n eentje de regels 21–1008. Het bestand is daarmee precies wat
S2 wil voorkomen: een toestandsbestand dat je moet doorzoeken in plaats van lezen. Niet gevaarlijk,
wel zelfondermijnend.

### C3 — `Package.swift` staat bewust ongecommit
`.process("Resources")` → `.copy("Resources")` voor het `AudioAnalysis`-target: een lokale
werkomgeving-fix, omdat de gitignored `Resources/CLAP/`-map twee `.mlpackage`-mappen met dezelfde
bestandsnamen bevat en `.process` daarop weigert te bouwen. Volledig uitgelegd in STATE.md `## Done`.

**Caveat die daar nog niet stond, gemeten in deze sessie:** met `.copy` faalt een lokale iOS-build op
het codesignen van de resourcebundle —
`RoonSage_AudioAnalysis.bundle: bundle format unrecognized, invalid, or unsuitable`. Dat is dezelfde
gewijzigde bundle-indeling die de reden is om hem niet te committen; het is dus geen bug, maar het
betekent wel dat een iOS-typecheck op deze machine `CODE_SIGNING_ALLOWED=NO` nodig heeft:

```
cd native/RoonSage && xcodebuild -scheme RoonSageUI \
  -destination 'generic/platform=iOS Simulator' CODE_SIGNING_ALLOWED=NO build
```
Zonder die vlag leest de fout als "de iOS-build is stuk", en dat is hij niet.

### C4 — Twee instellingenschermen op macOS
`RoonSageApp.swift:59-63` opent de ⌘,-scene met `SettingsView()` (scope `.all`), terwijl de
zijbalk-ingang `.settings` naar `SettingsHomeView()` gaat (twee deuren: apparaat/server). Bewust —
het is in `SettingsHomeView` gedocumenteerd — maar het betekent wel dat dezelfde Mac twee verschillende
indelingen van dezelfde instellingen toont, afhankelijk van hoe je binnenkomt.

---

## Wat gecontroleerd is en góed bleek (niet aankomen)

- **Library-first is architectonisch afgedwongen, niet geprompt.** `generatePlaylist` bouwt de
  kandidatenpool uit `radioLibrary()` (`RoonClient+Generate.swift:164-190`); het LLM rangschikt en
  ordent, het verzint geen titels. `TitleGrounding.violations` doet een tweede pas op de titel/
  beschrijving met één retry (`:901-907`).
- **Reconnect + zone-grace.** Exponentiële backoff, flap-detectie met een diagnose in de log,
  45 s zone-grace, `expectingFullZoneList` zodat een verse subscriptie de grace-lijst vervangt,
  en een 10 s watchdog op een subscriptie waarvan de initiële state nooit aankomt. Grondig.
- **`zonesAfterSnapshot` / `resolvedCoreHost`** — beide "nooit degraderen naar niets op een blip",
  beide `nonisolated static` en dus getest.
- **Paginering + FTS5** in de bibliotheek, inclusief het afvangen van een pagina die volledig
  wegdedupliceert (`loadTracksPage` recurseert dan) en het verwerpen van een pagina waarvan de
  query intussen veranderde.
- **`PlaybackEventHub`** — één ticker voor alle cliënten, push alleen bij gewijzigde digest,
  snapshot-then-deltas bij verbinden, keepalive per 30 s.
- **Lege staten met een uitweg.** `gridEmptyState` onderscheidt drie oorzaken (niet verbonden /
  geen favorieten / niets gevonden); de speler biedt "Ontdek muziek" en "Maak een playlist" in
  plaats van dood te lopen; een mislukte zoekopdracht biedt de sonische zoektocht aan.

---

## Status — alle drie de batches uitgevoerd (2026-08-23)

Batch A, B en C zijn geïmplementeerd en geverifieerd. Verse uitkomsten:

| check | vóór | na |
|---|---|---|
| RoonProtocol tests | 12 / 0 fouten | 12 / 0 fouten |
| RoonSage tests | 973 / 0 fouten | **984 / 0 fouten** (+11 nieuw) |
| `swift build -c release` | exit 0 | exit 0 |
| iOS-typecheck `RoonSageUI` | — | BUILD SUCCEEDED |
| lokalisatiesleutels | 1033 | **1134** |
| geïnterpoleerde sleutels | **61** | **0** — en nu een harde CI-gate |
| wees-sleutels | 0 | 0 |
| swiftlint serious | 5 | **2** (beide een Codable wire-veld, zie C1) |

Twee dingen die tijdens het uitvoeren groter bleken dan de audit ze inschatte:

- **B3 was niet "het menu" maar het hele macOS-app-target.** `Sources/RoonSage`
  (3 bestanden) had **nul** `LS()`-aanroepen en 25+ harde Nederlandse literals:
  de menubalk, de menubar-extra én de complete updater-dialoog. Allemaal
  gelokaliseerd.
- **`check-localization.sh` keek daar nooit.** De checker scande alleen
  `RoonSageUI` + `RoonSageCore`, dus hij meldde al die tijd "0 missing" over een
  target dat de catalogus niet eens gebruikte. Nu scant hij ook `RoonSage`,
  `RoonSageAnalyzerApp` en `native/iosapp` — en omdat de achterstand op nul staat,
  faalt `--strict` (die in CI draait) voortaan óók op een nieuwe geïnterpoleerde
  sleutel. Negatief getest: een opzettelijk toegevoegde `LS("Test \(1) regressie")`
  geeft exit 1, na terugdraaien weer exit 0.

Wat bewust **niet** is gedaan, met reden:

- **De overige 464 lintwaarschuwingen** zijn opmaak (`comma` 132, `colon` 93,
  `statement_position` 70). `swiftlint --fix` zou het leeuwendeel oplossen, maar
  dat is een diff van honderden regels over 306 bestanden die de inhoudelijke
  wijzigingen onleesbaar maakt. Eén commando, apart te draaien wanneer je 'm wilt.
- **De laatste 2 `empty_count`-violations.** Beide lezen
  `DiscoveryDigestStatus.count`, een **Codable wire-veld** tussen server en
  clients. Hernoemen breekt dat contract voor een regel die hier een false
  positive is (het is een Int, geen collectie). De andere drie zijn wél opgelost,
  en eerlijk: `VectorIndex` kreeg een echte `isEmpty` (daar hád de regel gelijk),
  de MusicBrainz-tuple heet nu `votes` (het is een stemmenteller) en de
  downloadteller in Settings heet `downloadedCount`.
- **"Wis de wachtrij" voor een Roon-zone (B5).** Roon's Extension-API heeft er
  geen verb voor — `TransportService` biedt control, play-from-here, volume, mute,
  seek, shuffle en repeat, en dat is de hele lijst. In plaats van iets nep te
  bouwen is de belofte in `PlayerScreen` ingetrokken en legt de zone-wachtrij nu
  in één regel uit waarom herschikken/wissen op "dit apparaat" zit.

---

## Batchplan

### Batch A — kritieke fixes & UX-blockers
| # | bevinding | bestand | |
|---|---|---|---|
| A1 | F1 — wachtrij-abonnement alleen in `.direct`-modus | `QueueView.swift`, `RoonClient.swift` | ✅ |
| A2 | F3 — skeleton bereikbaar maken tijdens het overzicht-laden | `LibraryView.swift` | ✅ |
| A3 | F4 — `fillAllPages` ook na tabwissel en zoekopdracht | `LibraryView.swift` | ✅ |
| A4 | F2 — `zonesAreStale` tonen | `RootView.swift` | ✅ |
| A5 | F5 — palet-bestemmingen bereikbaar maken op de iPhone | `RootView.swift` | ✅ |

### Batch B — functionele verfijning
| # | bevinding | geleverd |
|---|---|---|
| B1 | U1 — optimistic UI op play/pause, shuffle, repeat, mute + live volume | ✅ `TransportIntent` (pure, 9 tests) + throttled live volume |
| B2 | U2 — de 61 geïnterpoleerde sleutels naar `String(format:)` | ✅ 61 → 0, plus een CI-gate |
| B3 | U3 — macOS-menu door de stringcatalogus | ✅ hele app-target, 33 sleutels |
| B4 | U4 — ⌘1…9 op de werkelijke zijbalkvolgorde | ✅ `SidebarSection.items` |
| B5 | U6 — "wis wat komt" voor een Roon-zone, of de belofte intrekken | ✅ ingetrokken + uitgelegd (API kan het niet) |
| B6 | U7 — dedup-teller / "toon duplicaten" | ✅ chip in `browseBar` |

### Batch C — polish & a11y
| # | bevinding | geleverd |
|---|---|---|
| C1 | U8 — zeven VoiceOver-labels + twee Engelse labels | ✅ |
| C2 | P1 — scrubber als eigen subview, timer buiten `body`, pauze-guard | ✅ `PlayerScrubber`; een gepauzeerde speler tikt niet meer |
| C3 | U5 — ⌘F naar het zoekveld | ✅ via AppKit (`.searchFocused` is macOS 15+) |
| C4 | P4 — `enumerated()` uit de wachtrij-`ForEach` | ✅ |
| C5 | C1 — de vijf `empty_count`-violations | ✅ 3 van 5; 2 zijn een wire-veld — zie boven |

---
---

# Historie — eerdere audits

# RoonSage Native (macOS + iOS) — Volledige Code-, Performance-, Design- & Feature-audit

> Datum: 2026-06-12 · Scope: `native/RoonSage`, `native/RoonProtocol`, `native/iosapp` (~108 Swift-bestanden, ~14k regels)
> Methode: 5 parallelle diepte-audits (architectuur, UI/UX, performance, iOS-platform, feature-parity).

## ✅ Voortgang (2026-06-13) — afspeel-bug opgelost

Nieuwe audit naar aanleiding van "niet alles speelt af bij de play-knopjes". **Geverifieerde hoofdoorzaak:** library-tracks worden afgespeeld via hun opgeslagen Roon `item_key`, maar die zijn sessie-vluchtig (verlopen bij Core-herstart / reconnect / album-rewalk). `BrowseService.playByBrowse` browsede direct naar de sleutel en deed bij een verlopen sleutel **stil niets** (geen throw → `curateTracks` telde 0 fouten → geen toast). De Python-zoek-fallback (`playViaSearch`) bestond al maar was alleen op synthetische Qobuz/import-sleutels aangesloten. Alle play-methodes (`playTrack`/`playAlbum`/`playShuffledMix`/`playSonicRadio`/`playDJSet`/`playPlaylist`/`queueTracks`) lopen via deze ene trechter.

**Geleverd (commit `3c71ad9`, 58 tests groen, macOS release + iOS sim-build groen):**
- `playByBrowse` krijgt title/artist; bij lege lijst → fallback naar `playViaSearch`, anders `BrowseError.playbackFailed` (i.p.v. stille `return`). `curateTracks`/`queueTracks` geven title/artist door en surfacen falen als `ActionError`-toast.
- `handleOpen`: resync forceren bij Core-wissel (vreemde coreID = stale keys); same-Core restart leunt op de goedkopere play-time zoek-fallback.
- iOS: `reconnectOnForeground()` bij `scenePhase → .active` (geen backoff afwachten); intent-timeout 6s→12s voor cold-reconnect over ZeroTier.
- Fase B: ListenBrainz `submit(listenedAt:)` = starttijd (consistent met Last.fm); queue-remove slaat index-loze changes over.

**Geverifieerde false positives uit de brede sweep (NIET aanpassen):** seek-positie-nil (`now_playing.seek_position` is correct), scrobble-gate bij lengte 0 (30s-vloer aanwezig), zonesWatchdog-flicker (her-subscribet alleen bij lege zoneMap na 10s).

**Nog open:** iOS multicast-discovery (SOOD vereist Apple's multicast-entitlement; iOS gebruikt nu ZeroTier+saved host — caveat, geen bug); Control Center vanuit suspend (architectuur: geen lokale audiosessie). Versies bij start van deze ronde: macOS v1.5.48 · iOS ios-v1.6.18.

## ✅ Voortgang (2026-06-12, zelfde dag)

**Fase 0 volledig geïmplementeerd + quick wins + eerste Fase 1-hero (alle 57 tests groen):**
- A2/A4/C2: per-request timeout (15s), receive-loop guard op socket-identiteit, registration-send-failure fix (`RoonTransport.swift`)
- A5: sync prune-guard — `finishSyncRun(pruneStale:)`, prune alleen bij 0 mislukte albums
- A3: `RoonClient.ActionError` + `runAction` helper; alle transport-acties + `curateTracks` + `transferZone` rapporteren falen → `ActionErrorToast` in `RootView.swift`
- A1/B5/B9: `libraryStats`/`recentListens`/`topArtistsListened`/`totalListens`/`topTags`/`playlists`/`audioFeaturesStats`/`buildDJSet`/`buildRadio` async + `Task.detached`; `refreshTrackCount` fire-and-forget; DJSetView & SettingsView body-DB-reads → `@State` + `.task`; alle call-sites (UI + MCP) bijgewerkt
- B1: FTS5 external-content index (`v12_fts_search` migratie, triggers, `ftsQuery`-sanitizer) → `searchTracks`/`browseTracks`/`filterTracks` keywords; + unit test
- B2: `LibraryView.sortedTracks` → gecachte `displayTracks` (recompute alleen op tracks/sort-change, off-main)
- B4/F13: ImageCache `totalCostLimit` 96MB + cost per image, `CGImageSourceCreateThumbnailAtIndex`-downsampling (target uit URL-width), colorCache cap 256
- S1: Keychain `kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly`
- P2/P3: `busyMode .timeout(5)`, gedeelde `DatabaseManager.isoFormatter` (6 call-sites)
- Quick wins: goud+wit→zwart-op-goud contrast, `.accessibilityLabel` op icon-knoppen (Playlists/Library), `Motion.*` tokens toegepast (Library/MusicMap/NowPlaying/ContentView), Skeleton respecteert reduce-motion, `Motion.spring` token toegevoegd
- **Hero #1 — Immersive Now Playing geleverd**: full-bleed geblurde art-backdrop + materiaal + dominantColor-scrim, 420pt art met spring-pop (pauze-krimp, track-change transition), zone-switcher chips, grote gouden transport (56pt), royale scrubber met resterende-tijd, Badge-component hergebruikt, reduce-motion gerespecteerd
- N.B. `DiscoveredRoonCore` bleek **niet** dood (gebruikt door `protocol-check`) — laten staan.

**Fase 1-vervolg (zelfde dag, ronde 2):**
- `Card`/`.cardStyle()`-component + `Haptics`-helper (tap/success/error, no-op op macOS) in Theme.swift; alle 7 Discovery-kaarten + StatCard geünificeerd
- "Deal-out" reveal in GenerateView: rijen dealen met 30ms stagger + spring, gouden `wand.and.stars`-bounce, success-haptic, reduce-motion-pad; haptics op Play again/Save
- A8 ✅: `ScrobbleCoordinator`-actor — per zone één gegate commit (min(length/2, 240s), ≥30s vloer), cancel bij trackwissel/zone-weg, LF now-playing direct, scrobble-timestamp = starttijd; vervangt de ongeordende `Task.detached`
- N2 ✅: zones-subscribe retry (3s bij send-faal) + 10s-watchdog die her-subscribet als de initiële state nooit aankomt

**Ronde 3 (zelfde dag) — taal-unificatie ✅ + Fase 2 gestart:**
- **Taal-unificatie afgerond**: alle UI-views, Core-strings (ConnectionState, actie-fouten, sync-fases, transport-errors), menubar, macOS-menu's, updater-dialoog → consistent Nederlands. Featurenamen (DJ Set, Live DJ, Sonic DNA, Music Map, Sonic Radio) en LLM-prompts blijven Engels; MCP-output blijft Engels (voor de LLM). `SidebarItem.title` / `SortField.label` toegevoegd zodat rawValue-ID's stabiel blijven.
- **MPNowPlayingInfoCenter + MPRemoteCommandCenter** (`iosapp/Sources/NowPlayingCenter.swift`): Lock Screen/Control Center/AirPods/CarPlay-bediening, incl. artwork via ImageCache en seek via changePlaybackPosition. Beperking gedocumenteerd: zonder lokale audio-sessie kan iOS de controls bij suspensie aan een andere app geven.
- **Live Activity `staleDate`**: activity dimt nu na verwacht trackeinde i.p.v. bevroren verkeerde track.
- **Interactieve Live Activity + Siri/Shortcuts**: `RoonClient.shared` + `ensureConnected()` (auto-reconnect voor background-intents); `PlayPauseIntent`/`NextTrackIntent`/`PreviousTrackIntent` als `LiveActivityIntent` in `Shared/` (type in beide targets via `WIDGET_EXTENSION`-conditie, perform draait in app-proces); transport-knoppen in Dynamic Island expanded + Lock Screen-banner; `RoonSageShortcuts` met NL Siri-frases.
- Extra haptics: Library/Ask/Queue play- en queue-acties, DJ-set-build success.

**Ronde 4 — releases + widget:**
- **Uitgebracht**: macOS **v1.5.36** (DMG op GitHub Releases, in-app updater pikt hem op) en iOS **ios-v1.6.9** (TestFlight) — beide CI-runs groen.
- **App Group + home-screen widget** (ios-v1.6.10): `group.com.roonsage.ios` entitlements op app + widget-extensie; `SharedNowPlaying`-snapshot (app schrijft bij elke wissel + reloadTimelines); `ZoneControlWidget` (systemSmall/Medium + accessoryRectangular Lock Screen-complicatie) met interactieve play/pause/next via de LiveActivityIntents; `syncSystemSurfaces()` bundelt Live Activity + MPNowPlayingInfo + widget-snapshot.

**Ronde 5 — alle drie hero-redesigns (macOS v1.5.37):**
- **Hero #5 Sonic DNA living fingerprint**: radar springt uit centrum + ademt (TimelineView, reduce-motion-gated), radiale goud→amber fill + vertex-dots, "personality"-headline, gestaggerde tag-drift, deelbaar via ImageRenderer, ViewThatFits voor iPhone.
- **Hero #3 Live DJ mix-radar**: Camelot-wiel met huidige track in centrum, orbitende suggesties (A binnen/B buiten, grootte=tempo-match, kleur=hue), gloed+puls op compatibele keys, neon-gouden bogen, tap→snap-select + actiebalk; lijst blijft als detail.
- **Hero #4 Discovery editorial**: hero "Herontdek"-kaart, cover-forward shelves (horizontale scroll + play-overlay), Swift Charts (gouden area-chart decennia + balkgrafiek genres) met tappbare chips, sectiekoppen met SF Symbol.

**Hero-redesigns uit het audit-rapport: 5/5 geleverd** (Now Playing #1 + curatie deal-out #2 in eerdere rondes; #3/#4/#5 nu).

**Nog open (Fase 2-rest):** art in Live Activity/widget via App Group-bestand, APNs/ActivityKit-push, BGTaskScheduler, Handoff — plus de eenmalige **App Group-registratie** (taak #18) die ios-v1.6.10 deblokkeert.
**Ronde 6 — Fase 3 gestart + release-discipline:**
- **Templates-pariteit** (macOS v1.5.39): alle 63 backend-sjablonen geport naar `PlaylistTemplates.swift` (8 NL-categorieën, prompts blijven Engels), met featured-rij + gecategoriseerde "Alle sjablonen"-sheet in GenerateView.
- **Release-build-discipline**: v1.5.37 faalde op CI (release-modus is stricter: `ambiguous use of cos`); sindsdien `swift build -c release` lokaal vóór elke tag → v1.5.38 + v1.5.39 groen. Vastgelegd in geheugen.

**Uitgebrachte versies vandaag:** macOS v1.5.36 · v1.5.38 (heroes) · v1.5.39 (templates) — alle DMG-releases groen. iOS ios-v1.6.9 (TestFlight, groen). iOS ios-v1.6.10 geblokkeerd op App Group-registratie (taak Casper).

**Fase 3 features (nog te doen):** scrobble-import, taste LB/LF-merge, Song Paths/Alchemy, Year-in-Review.
**Perf-diepte (nog te doen):** B3 (sonic feature-vectors/bitsets), B6 (vDSP-analyzer), B7 (batch-sync).
**Tech-debt (nog te doen):** A10 (controllers extraheren), A11 (Codable responses), A12 (chunkedInsert-helper). **Fase 3:** features (templates-pariteit, Sonic Radio-knop bestaat al, scrobble-import, taste LB/LF-merge, Song Paths/Alchemy) + B3/B6/B7-perf + A10/A11/A12-techdebt + Discovery-editorial (Hero #4), Live DJ mix-radar (Hero #3), Sonic DNA living fingerprint (Hero #5).

---

## 0. Eindoordeel in één alinea

De fundering is **echt goed**: een actor-gebaseerde transportlaag, een serieel-gelockte Roon Browse-laag, hervatbare sync met checkpoints, een handgeschreven MOO/SOOD-protocolcodec, GRDB met WAL, een gevectoriseerde FFT, en — uniek — een **on-device Swift audio-analyzer** (BPM/Camelot/energy) die librosa/Docker volledig vervangt. Maar de app oogt vandaag als een *competente native tool*, niet als een Apple Design Award-kandidaat. De kloof zit in drie dingen: (1) het design-systeem bestaat maar wordt in ~60% van de views genegeerd, (2) er is **geen hero Now Playing-moment** — het paradepaardje van elke muziek-app ontbreekt, en (3) de iOS-app is een dunne shell zonder de native superkrachten (widgets, Lock Screen-bediening, Live Activity-knoppen, Shortcuts). Daarnaast lekt er functionaliteit weg vs. de Python-backend (113 → 26 MCP-tools) en zitten er een handvol echte correctheids-/dataverlies-randen in error-handling en sync.

**Drie hoogste hefbomen:** ① bouw een echte immersive Now Playing-ervaring, ② maak de iOS-app native (MPNowPlayingInfoCenter + interactieve widgets + Live Activity-knoppen + App Group), ③ haal de DB-reads van de main thread af en zet FTS5 op zoeken.

---

## DEEL A — Code & Architectuur

### Sterke punten
- Netwerk- en Roon-transport correct geïsoleerd in `actor`s (`RoonTransport`, `BrowseService`, `TransportService`, `LibrarySyncService`, `SonicLibraryCache`).
- `RoonClient` is `@MainActor @Observable`; zware reads worden via `Task.detached` van de main thread gehaald.
- Schone mixin-split van `RoonClient` en `DatabaseManager`. Pure, testbare cores (`SonicSimilarity`, `DJSetBuilder`, `Camelot`, `TrackIdentity`). Geen `try!`, `fatalError`, `as!` of TODO/FIXME. Uitstekende "waarom"-comments.

### Kritieke & hoge bevindingen
| # | Bestand:regel | Sev | Probleem | Fix |
|---|---|---|---|---|
| A1 | `RoonClient+Library.swift` (`libraryStats`, `recentListens`, `topArtistsListened`, `totalListens`, `topTags`) + `RoonClient+Playlists.playlists()` | High | `@MainActor` getters doen **blocking** `pool.read` met full-table aggregaten (`COUNT(DISTINCT …)`, GROUP BY) → zichtbare UI-hitch op 30k tracks | Maak `async` + `Task.detached` (patroon bestaat al), of cache stats en refresh op sync-einde |
| A2 | `Transport/RoonTransport.swift:133-142` (`request`) | High | Geen per-request timeout; enige backstop is de 20s connection-watchdog die *alle* pending requests tegelijk laat falen → één hangende browse stalt tot 20s | Per-request `Task.sleep`-timeout die de continuation met error hervat en uit `pendingRequests` haalt |
| A3 | `RoonClient+Transport/+Playlists/+Qobuz` (overal `_ = try? await …`) | High | Elke gebruikersactie (play/next/volume/seek/curate) slikt fouten stil; `curateTracks` no-opt als `browseService==nil` zonder feedback | Geef `Result`/throw terug óf zet observable `lastActionError` → toast in UI; log minimaal |
| A4 | `Transport/RoonTransport.swift:193-215` (`processReceived`) | High | Receive-loop wordt onvoorwaardelijk her-armed met de *oude* `wsTask`; na reconnect kan een stale socket continuations van een nieuwe verbinding resolven | `guard self.wsTask === wsTask, isConnected else { return }` vóór `startReceiving` |
| A5 | `LibrarySyncService.sync` (`:117-123`, `:209-211`) + `DatabaseManager+Sync.swift:103-116` (`finishSyncRun`) | High (dataverlies-rand) | Per-album browse-fouten worden stil geslikt; daarna **verwijdert** `finishSyncRun` rijen die deze generatie niet gecheckpoint zijn → flaky sync die tóch "voltooit" kan de library laten krimpen | Tel mislukte albums; prune alléén als failed-count == 0 |

### Medium / tech-debt
- **A6** `RoonClient.init` (`:103`): `database = try? …` → bij DB-faal draait de hele app stil met lege library. Voeg `databaseError` + herstelbare banner toe.
- **A7** `BrowseService.genreMapping` (`:190-208`): re-popt de genres-root één keer *per genre* (ephemeral keys) → O(genres²) browse-verkeer; correct maar traag.
- **A8** `RoonClient.applyZoneUpdate` (`:368-396`): scrobbles via ongeordende `Task.detached` per track-wissel; scrobblet élke now-playing-change op `timestamp=now` → korte plays scrobblen. Serialiseer via één actor met min-speelduur-gate + persisted last-scrobbled state.
- **A9** Subscriptions (`RoonTransport.subscribe` `:157-171`) timen nooit uit; een gemiste subscribe-COMPLETE = permanent lege Now Playing tot full reconnect. Detecteer & resubscribe.
- **A10** `RoonClient` groeit naar god-object (~10 verantwoordelijkheden). Extraheer `PlaybackController`/`LibraryController`/`ConnectionController` achter protocollen.
- **A11** `[String: Any]` JSON-dicts overal door transport→browse→models met ad-hoc `as? String ?? ""`. Decodeer Roon-responses één keer naar `Codable` structs in de transportlaag.
- **A12** Gedupliceerde chunked-insert-loop in 5+ plekken → generieke `chunkedInsert(table:columns:rows:)`.

### Security
- **S1 (Medium)** `Auth/KeychainStore.swift:13-22`: geen `kSecAttrAccessible` → Roon-token & Last.fm session-key synct via iCloud Keychain en zit in backups. Zet `kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly`.
- **S2 (Medium)** `QobuzClient.tryLogin` (`:66-82`): wachtwoord als GET-queryparam (belandt in logs/proxies). POST in body.
- **S3 (Medium)** `LibraryShareServer`: ongeauthenticeerd, bindt alle interfaces → volledige library leesbaar op poort 5767. Eis een shared secret of bind alléén op de ZeroTier-interface.
- **Positief:** DMG-updater doet echte codesign + Team-ID-verificatie vóór swap; quarantine-strip staat correct ná de signatuurcheck.

**Top-10 fixes (code):** A1 · A2 · A3+A5 · A4 · S1 · A8 · (FTS5, zie Deel B) · S3 · A9 · A11+A12.

---

## DEEL B — Performance & Snelheid

### Sterke punten (niet aankomen)
Gevectoriseerde `RealFFT` met hergebruikte scratch-buffers; `vDSP_svesq` RMS; batched multi-row upserts; zware reads off-main; resumable per-album checkpoints; `[weak self]` overal (geen retain cycles); zone seek-frame-filtering tegen observable-churn.

### Top-10 speedups
| # | Bestand:regel | Sev | Kost | Fix & impact |
|---|---|---|---|---|
| B1 | `DatabaseManager+Discovery.swift:108-111`, `+Tracks.swift:74-84`, `+Filter.swift:40` | High | `LIKE '%q%'` met leading wildcard → **full table scan** per toetsaanslag; `LOWER()` per rij verslaat indexen | **FTS5** virtual table over (title,artist,album) + `MATCH`. Grootste interactieve win op 10k+ |
| B2 | `LibraryView.swift:25-42` (`sortedTracks`) | High | Re-sort + re-dedupe (`localizedCaseInsensitiveCompare`) bij **elke** body-eval (selectie, keystroke, sync-tick); `.random` herschudt elke render | Cache in `@State`, herbereken alleen op `tracks`/`sort`-change; dedupe bij fetch |
| B3 | `Sonic/SonicEngine.swift:43-63` + `SonicSimilarity.distance` | High | Fingerprint = ~1.2M `distance()`-calls; elke call alloceert `Set<String>` tags + parse't Camelot-string | Precompute numerieke feature-vector + tag-bitset per track → branchless float-math + `popcount`. Seconden → sub-seconde |
| B4 | `RoonSageUI/ImageCache.swift:11-13` | High | NSCache `countLimit=400` zonder `totalCostLimit`, geen downsampling → 400 full-res bitmaps; kritiek op iOS | Zet `totalCostLimit` (64–128MB) + `cost:`; downsample via `CGImageSourceCreateThumbnailAtIndex` |
| B5 | `RoonClient+Library.swift:177` → `DatabaseManager+Discovery.swift:143-154` (`topTags`) | High | Full feature-table fetch + N JSON-decodes **op main**, bij elke Library-appear | Async/detached + precompute tag-counts tabel bij feature-sync |
| B6 | `AudioAnalysis/TempoAnalyzer.swift` (windowing/flux/autocorrelatie) | High | Scalar loops; O(L²) autocorrelatie per lag — heetste loop van de analyzer | `vDSP_vmul`/`vDSP_dotpr` of FFT-based autocorrelatie (Wiener–Khinchin) → 5–20× |
| B7 | `LibrarySyncService.swift:154` → `DatabaseManager+Sync.swift` | Medium | Eén transactie (WAL fsync) **per album** ~9.5k keer | Batch ~25 albums per transactie |
| B8 | `DatabaseManager+Discovery.swift:10-21,42-85` | Medium | Joins op `LOWER(title)=LOWER(artist)` (geen functionele index) + `ORDER BY RANDOM()` over alle albums | `title_lower`/`artist_lower` geïndexeerde kolommen; gesamplede random |
| B9 | `RoonClient+Library.swift:18-32`, `RoonClient+Features.swift:15,91` | Medium | `libraryStats`/`recentListens`/`audioFeaturesStats` synchroon op main | `Task.detached` |
| B10 | `Sonic/SonicLibraryCache.swift` | Medium | Houdt hele 30k-track array sessielang vast | Drop op `didReceiveMemoryWarning` (iOS) |

**Quick wins:** `KeyAnalyzer` windowing → één `vDSP_vmul`; hoist `ISO8601DateFormatter` naar `static let` (`+History.logListen`, fired elke track-wissel); cap unbounded `colorCache`; verhoog Roon browse `pageSize` boven 100.

---

## DEEL C — Design, UX & Animatie (de "100 designers"-as)

### Diagnose
Er ís een design-systeem (`Theme.swift`: 4-pt `Spacing`, `Radius`, `Typography`, `Motion`, semantische `Color.roon*`, `Badge`) — maar het wordt in slechts ~4 van de 20 views consequent gebruikt. `Motion.*` en `Typography.*` worden door **nul** views gebruikt. De componentbibliotheek is half af: `Badge` bestaat (en wordt 3× geforkt), maar `Card`, `SectionHeader`, `TrackRow`, `PromptComposer` worden gekopieerd.

### Visuele polish — Top 15 (geprioriteerd)
1. **Bouw een echte hero Now Playing** (`NowPlayingView.swift`) — nu een lijst zone-kaarten met 56pt thumbnail. *Hoogste impact.* (zie Hero #1)
2. **Unificeer de taal** — Nederlands en Engels staan dóór elkaar binnen views (`DJSetView`: "Build DJ Set" naast "Exporteer"/"Energie"; `SettingsView`; `LiveDJView` volledig NL, `GenerateView` volledig EN). *Meest amateuristisch ogende issue.* → één `String catalog`, kies Nederlands.
3. **Adopteer je eigen tokens** — vervang inline `Spacing`/`Radius`/`Motion`/`Typography`-literals (Generate `spacing:22`/`padding(24)`, NowPlaying, Discovery `cornerRadius:10`).
4. **Eén gedeelde `Card`-container** — 3 verschillende kaart-recepten coëxisteren (`.background.secondary` vs `platformCardBackground.opacity(0.5)` vs `cornerRadius:10`).
5. **Verwijder de 3 geforkte `badge`/`featBadge`-helpers** (`NowPlaying:224`, `Library:296`, `DJSet:150`) → route alles via `Badge`.
6. **Fix goud+wit contrast** (actieve tag-chip `LibraryView:191` ~2.3:1 — onder WCAG AA) → zwarte tekst op goud.
7. **44pt hit-targets** op alle iOS-rij-glyphknoppen (Library/Ask/LiveDJ/Playlists/NowPlaying ~22pt).
8. **Vervang `.help()`-only labels door `.accessibilityLabel`** — `.help()` is een no-op op iOS (`Compat.swift:17`) → iOS-knoppen hebben nu géén toegankelijke labels.
9. **Animeer resultaatlijsten** (Generate/Recommend/Ask/Discovery) met staggered `.transition` + `Motion.standard`.
10. **iOS-haptics** op play/queue/save/zone-select/DJ-build (nu nul `sensoryFeedback`).
11. **Respecteer reduce-motion** (Skeleton-pulse, repeating `symbolEffect`, art-crossfade).
12. **`.onHover` rij-highlighting op macOS** + maak hele library-rij speelbaar (nu alleen het kleine knopje).
13. **`.swipeActions`** (play/queue/delete) op iOS-lijsten.
14. **Discovery als cover-forward shelves** + Swift Charts i.p.v. handgetekende `GeometryReader`-bars.
15. **Herschrijf developer-speak empty states** (`PlaylistsView:24` "save_playlist via Claude Desktop").

### Vijf "wow-factor" hero-herontwerpen (art direction)
1. **Immersive Now Playing — het paradepaardje.** Full-bleed achtergrond = albumart zwaar geblurred (`.blur(60)`) + verticale scrim met de al-berekende `ImageCache.dominantColor` (de pipeline bestaat al, maar voedt nu enkel een 30%-rechthoekje). Albumart ~70% breed, `Radius.xl`, zachte schaduw, spring-scale 0.94→1.0 bij trackwissel (krimpt bij pauze — de "card pop"). Royale custom scrubber met groeiende thumb, monospaced elapsed/remaining; grote gouden `play.circle.fill` (44pt). Achtergrond-tint cross-fade met `Motion.ambient` (0.8s). iOS: swipe-down to dismiss.
2. **AI-curatie "deal-out" reveal.** Generate dumpt nu een lijst. In plaats daarvan: "Curated N tracks"-banner in-sliden, dan elke rij met 30ms stagger in-dealen (`.move(edge:.trailing)+.opacity`, spring), art die infade. Gouden `symbolEffect(.bounce)` op `wand.and.stars` + success-haptic. De payoff voor het LLM-wachten.
3. **Live DJ "mix radar".** Camelot-wiel als hero: huidige track in het centrum, harmonisch-compatibele suggesties orbiten op hun wielpositie, grootte = tempo-match, kleur = bestaande Camelot-hue (al in MusicMap). Compatibele keys gloeien goud & pulseren; clashes dimmen. Tap → queue-next met snap-to-center. Donkere-vilt achtergrond, neon-gouden harmonische bogen.
4. **Discovery als editorial "Listen Now".** Vervang 7 grijze stapelkaarten door een magazine: full-width hero "rediscover"-kaart (vergeten favoriet, grote art + gouden Play-overlay), dan horizontale cover-shelves met parallax, dan één Swift Charts area-chart (decade, gouden gradient). Sectiekoppen: SF Symbol + accent + chevron. Beeld doet het werk, niet tekstrijen.
5. **Sonic DNA "living fingerprint".** Radar van statische stroke → ademende identiteit: vertices spring-en uit het centrum, zachte undulatie (reduce-motion-gated), radiale goud→amber fill. Signature-tags driften één voor één in. "Personality"-headline ("High-energy, major-key, eclectic tempo"). Hele kaart deelbaar als afbeelding (Spotify-Wrapped-meets-readout).

### Toegankelijkheid (apart benoemd)
Dynamic Type genegeerd door veel vaste `Font.system(size:)` + vaste frames (`SettingsView width:440`, `statRow width:220`) die clippen; Canvas-viz (radar/curve/scatter/bars) volledig onzichtbaar voor VoiceOver — voeg `.accessibilityLabel`/`.accessibilityValue` toe ("Energy 72 procent").

---

## DEEL D — iOS-app, Widgets & Live Activity

**Verdict:** volledige *view*-pariteit (alle 14 views hergebruikt uit `RoonSageUI`), maar de iOS-eigen code is ~270 regels en bijna elke native iOS-superkracht ontbreekt.

### Top-10 iOS-gaten
1. **Geen `MPNowPlayingInfoCenter` + `MPRemoteCommandCenter`** → geen Lock Screen / Control Center / AirPods / CarPlay-bediening. *Hoogste hefboom* — bestaande `RoonClient+Transport`-API's zijn er al; alleen bedraden. (High)
2. **Geen home-screen / Lock Screen / StandBy widgets** — de bundle bevat enkel een Live Activity, geen `StaticConfiguration`/`AppIntentConfiguration`, geen `TimelineProvider`. (High)
3. **Geen App Group + geen entitlements-bestanden** (beide targets) → blokkeert gedeelde data, art-caching, interactieve bediening, push. (High)
4. **Live Activity heeft geen knoppen** — geen `Button(intent:)` play/pause/skip; iOS 17 `LiveActivityIntent` ongebruikt. (High)
5. **Geen App Intents / Shortcuts / Siri.** (High)
6. **Live Activity `staleDate: nil` + geen push-tokens** → bevroren verkeerde track op Lock Screen bij suspensie. Zet `staleDate` op trackeinde. (High)
7. **Geen APNs / push** (ook de echte fix voor #6). (Medium-high)
8. **Geen background audio session** — alleen 30s `beginBackgroundTask` tijdens sync. (Medium-high)
9. **Geen `BGTaskScheduler`** background-refresh voor cache/zone/widget-versheid. (Medium)
10. **Geen haptics, geen Handoff/`NSUserActivity`** continuïteit met macOS. (Medium/low)

### Zes iOS-flagship features
1. **Lock Screen now-playing + volledige bediening** (`MPNowPlayingInfoCenter`+`MPRemoteCommandCenter`) — hoogste leverage, gratis Lock Screen/Control Center/AirPods/CarPlay.
2. **Interactieve Live Activity / Dynamic Island** — `LiveActivityIntent`-knoppen + art via App Group-cache.
3. **"Zone Control" widgets** — `systemSmall` now-playing-per-zone + `accessoryRectangular/Circular` complicaties met interactieve play/pause; configureerbare zone.
4. **Siri/Shortcuts App Intents** — `PlayInZoneIntent`, `GeneratePlaylistIntent("chill avond mix in de woonkamer")` via `AppShortcutsProvider`.
5. **StandBy now-playing** — full-bleed art + zone + elapsed; gedockt iPhone = Roon-zonedisplay op het nachtkastje.
6. **Handoff + Live Activity push** — `NSUserActivity` voor iPhone↔Mac continuïteit + ActivityKit push-tokens.

*Goed gedaan al:* adaptieve `NavigationSplitView`/`TabView` met Create/Explore-hubs; `NSLocalNetworkUsageDescription` correct; ZeroTier auto-retry + scene-phase resume; CI naar TestFlight met `ios-v*` tag-namespace.

---

## DEEL E — Feature-pariteit & Nieuwe Features

### Pariteit met de Python-backend (samengevat)
**Aanwezig (✅):** library filter/curate, generate (2-staps native LLM — rijker dan backend), ask, recommend, sonic fingerprint, DJ sets, **Live DJ (native-only sterkte)**, playlists/Qobuz-save, scrobbling naar LB+Last.fm, on-device analyzer.
**Gedeeltelijk (⚠️):** discovery (mist smart/sonic radio, LB-aanbevelingen), taste profile (lokaal-only, geen LB/LF-merge), Music Map (scatter, geen UMAP/HDBSCAN-clustering), templates (~8 inline vs 63 built-ins).
**Afwezig (❌):** Song Paths, Song Alchemy, watchlist (new-release scanner), scheduler (cron-playlists), automations, enrichment, notifications, CLAP, semantische lyrics, scrobble-import, circadian/personas/mood/sonic-radio/queue-continuation.
**MCP-oppervlak:** native 26 tools vs backend ~113.

### Top-features om te porten (effort)
1. **Taste profile + LB/Last.fm-merge** (M) — je scrobblet al naar beide; haal de stats terug → echte cross-source profiel.
2. **Watchlist new-release scanner** (M) — met lokale notificaties (beter dan Discord op Apple).
3. **Scheduler (cron-playlists)** (M) — "verse maandag-mix" via `BGTaskScheduler` + bestaande generate-flow.
4. **Templates-pariteit** (S) — porteer de 63 JSON-templates + picker; goedkope polish.
5. **Song Paths** (M) + **Song Alchemy** (S–M) — feature-vector + `SonicSimilarity.distance` zijn er al.
6. **Sonic/Smart Radio + queue-continuation** (S–M) — `SonicEngine.nearest` bestaat; alleen een queue-feeder-loop.
7. **Vollere feature-vector** (L) — voeg danceability/valence/instrumentalness/acousticness toe aan de analyzer → ontgrendelt rijkere similarity/alchemy/mood.

### Twintig nieuwe premium-ideeën (selectie van de sterkste)
- **Gapless/crossfade DJ-transitions via `AVAudioEngine`** (L) — Roon biedt geen crossfade; native doen = echte differentiator.
- **On-device Apple Intelligence-curatie** (M) — route Generate/Ask via Apple Foundation Models (privacy/offline/geen API-key); `LLMClient` is al pluggable.
- **SharePlay luistersessies** (L) — vrienden stemmen op de volgende track.
- **Year-in-Review / "Sonic Wrapped"** (M) — geanimeerde recap uit `listening_history`; viraal.
- **Live audio-visualizer op Now Playing** (M) — Metal/Canvas gedreven door analyzer-energy.
- **ShazamKit "wat is dit?" → add to library/Qobuz** (M).
- **Apple Watch-remote + haptische BPM-tap** (M).
- **CarPlay now-playing + "speel iets zoals dit"** (M).
- **Interactieve Camelot-wiel harmonische mixer** (M) — tap een segment → filter library op compatibele tracks bij huidige BPM.
- **Hi-res signal-path badge** (S) — toon bit-depth/sample-rate/DSP uit de zone-payload; audiophile-feel.
- **Quick wins:** Templates-pariteit (S) · Sonic Radio (S–M) · Scrobble-import (S) · Hi-res badge (S) · Year-in-Review (M).

---

## ROADMAP — Gefaseerd plan

### Fase 0 — Fundering & correctheid (1 sprint, onzichtbaar maar essentieel)
- A1/B9/B5: alle DB-getters off-main (`Task.detached` / cache).
- A2: per-request timeout. A4: receive-loop guard. A5: prune-guard tegen dataverlies.
- A3: `lastActionError` → toast-infra (nodig voor alle volgende UI).
- S1: Keychain `…ThisDeviceOnly`.
- B1: FTS5 op zoeken. B4: image-cache cost-limit + downsampling.
> Resultaat: snappy, geen UI-hitches, geen stille faal, geen krimpende library.

### Fase 1 — Het paradepaardje (1–2 sprints, hoogste zichtbare impact)
- **Immersive Now Playing** (Hero #1) — grote art, ambient backdrop via bestaande `dominantColor`, custom scrubber, spring-transitions.
- Design-systeem afdwingen: `Card`-container, tokens overal, `Motion.*` overal, geforkte badges weg, **taal unificeren**.
- AI-curatie "deal-out" reveal (Hero #2) + iOS-haptics + reduce-motion.
> Resultaat: app voelt als award-kwaliteit op de twee meest-bekeken schermen.

### Fase 2 — iOS native maken (1–2 sprints)
- Entitlements + App Group toevoegen (deblokkeert de rest).
- `MPNowPlayingInfoCenter` + `MPRemoteCommandCenter` (Lock Screen/Control Center/CarPlay).
- Interactieve Live Activity-knoppen + `staleDate` + art via App Group.
- Home/Lock Screen "Zone Control"-widgets met `AppIntent`.
- App Intents/Shortcuts (PlayInZone, GeneratePlaylist).
> Resultaat: iPhone voelt als een flagship Roon-remote, niet als een shell.

### Fase 3 — Feature-diepte & differentiators (doorlopend)
- Quick wins eerst: Templates-pariteit, Sonic Radio, Scrobble-import, Hi-res badge, Taste-profile LB/LF-merge.
- Daarna premium: Song Paths/Alchemy, Year-in-Review, interactieve Camelot-wiel, Discovery-editorial-redesign (Hero #4), Live DJ mix-radar (Hero #3).
- Performance-diepte: B3 (sonic feature-vectors/bitsets), B6 (vDSP-analyzer), B7 (batch-sync).
- Tech-debt: A10 (controllers extraheren), A11 (`Codable` responses), A12 (chunkedInsert-helper).

---

## Snelle wins die je vandaag kunt doen (laag risico, direct merkbaar)
1. `ISO8601DateFormatter` → `static let` (fired elke track-wissel).
2. Goud+wit contrast-fix (`LibraryView:191`) → zwart op goud.
3. `.help()` → `.accessibilityLabel` (deblokkeert iOS-toegankelijkheid).
4. Vervang inline animatie-literals door `Motion.*`.
5. Cap de unbounded `colorCache` in `ImageCache`.
6. Verwijder dode `DiscoveredRoonCore` (`SOODMessage.swift:110-130`).
