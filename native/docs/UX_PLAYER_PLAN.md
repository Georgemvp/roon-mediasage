# RoonSage als speler — UX-plan

> Opgesteld 2026-08-22, op vraag van de user: *"Kijk hoe je de UX van RoonSage
> kan verbeteren zodat het als een lokale player net als Plexamp of Roon ARC kan
> functioneren, en het niet te ingewikkeld is qua UI."*
>
> **Afbakening.** Dit gaat over *vorm*, niet over motor. De motorkant is al
> afgelopen in [LOCAL_PLAYER_READINESS](LOCAL_PLAYER_READINESS.md) (P1–P9, batch
> 1 t/m 5 afgevinkt): één speelpad, gapless, downloads, loudness, één
> zoek-API. Wat overblijft is dat je dat allemaal *niet ziet*, omdat de app zich
> nog presenteert als een sonisch laboratorium met een speler ernaast.
>
> **Methode.** Alle getallen hieronder zijn geteld in de broncode van commit
> `2c50e34`, niet geschat. Wat een toestel vereist staat expliciet als ongemeten
> gemarkeerd.

---

## 1. Oordeel in één alinea

De speler is af; de *app eromheen* is dat niet. Op de telefoon staan vijf tabs,
waarvan er drie geen bestemming zijn maar een kastje: **Create** en **Explore**
zijn lijsten die naar hubs wijzen die op hun beurt een segmented control tonen,
en **Instellingen** is een tab met 21 secties die grotendeels de server
configureren. Het eerste wat je bij een koude start ziet is een *lege speler*.
Tik je op de mini-balk, dan spring je van tab en ben je je plek in de
bibliotheek kwijt — precies het tegenovergestelde van wat Plexamp en ARC doen,
waar de speler als blad over je context schuift. En onder de motorkap bestaan
er nog altijd **twee volledige Nu-speelt-schermen** (lokaal en zone, samen 1.421
regels) die met de hand gelijk worden gehouden. Dit plan haalt de tabbalk terug
naar vier echte bestemmingen, maakt van de speler een overlay, en vouwt de
duplicatie op tot één scherm — zonder één feature weg te gooien.

## 2. Wat er precies mis is — geteld

| Bevinding | Bewijs |
|---|---|
| 72 view-bestanden, 29 `SidebarItem`-cases | `ls RoonSageUI/*.swift`, `enum SidebarItem` |
| … maar `detailView(for:)` kent er maar **13** bestemmingen | `RootView.swift:651-665` — 16 sidebaritems landen op een gedeeld scherm |
| Twee tabs zijn kastjes | `iOSCreateHub` (`RootView.swift:589`) en `iOSExploreHub` (`:614`) zijn `List`s met `NavigationLink`s |
| Zoeken heet nergens "zoeken" | het pad is Ontdek → Sonic Lab → segment; het woord *zoek* staat pas in het derde label (`iOSExploreHub` → `SonicLabView.Mode.search`) |
| Twee volledige spelers | `LocalNowPlaying.swift` 579 r. + `NowPlayingView.swift` 842 r.; handmatig gelijkgetrokken op 2026-08-11 (v1.10.260) |
| Speler is een tab, geen overlay | `NowPlayingBar.onOpen` roept `navigateTo(.nowPlaying)` — je verliest je scrollpositie |
| Wachtrij is een onzichtbare veeg | `RootView.swift:514-524`, `.page(indexDisplayMode: .never)` — de puntjes zijn bewust weg omdat ze taps opslokten |
| Koude start = leeg scherm | `@State private var selection: SidebarItem = .nowPlaying` (`RootView.swift:363`) |
| Instellingen = tab met 21 secties | `grep -c "Section(" SettingsView.swift` |
| Twee outputknoppen naast elkaar | `OutputSelector` + `AirPlayRouteButton` in beide spelers |

**De rode draad:** de navigatie is gebouwd rond *engines* (radio, sonic, DJ, AI)
in plaats van rond *intenties* (luisteren, vinden, laten spelen). De hub-views
zeggen dat zelf al in hun doc-comments — ze zijn stuk voor stuk ontstaan om
losse sidebaritems te bundelen. Dat was de goede beweging; hij is alleen halverwege
blijven staan, want de kastjes kregen een tab in plaats van te verdwijnen.

## 3. Wat we bewust NIET doen

- **Geen features verwijderen.** Music Map, Song Paths, Alchemy, Sonic DNA,
  Multitag, Journeys en Year in Review blijven bestaan en bereikbaar. Ze verhuizen
  naar één plek in plaats van vier.
- **Geen tweede "eenvoudige modus"-app.** Een modusschakelaar is zelf complexiteit
  en verdubbelt elke toekomstige beslissing. (Wel in de backlog als U12, mocht de
  Lab-ingang alsnog te druk voelen.)
- **Geen Plexamp-kopie.** Wat wij hebben en zij niet — Roon-zones als uitvoer,
  CLAP-stations, de analyzer — blijft de kern. Het gaat om de *drempel*, niet om
  de inhoud.
- **Geen visuele restyle.** `Theme`, `AmbientTheme`, `Spacing`, `Radius` en de
  goud-accenten blijven zoals ze zijn. Dit plan raakt structuur, niet smaak.

---

## 4. De doel-architectuur

### iPhone — vier tabs plus een overlay

```
┌──────────────────────────────────────────────┐
│  ⌂ Start   ♪ Bibliotheek   ⌕ Zoek   ((•)) Stations │
└──────────────────────────────────────────────┘
         ▲ mini-balk boven de tabbalk
         └── tik → speler schuift als blad omhoog (veeg omlaag = terug)
```

| Tab | Wat er in zit | Waar het vandaan komt |
|---|---|---|
| **Start** | het huidige `LibraryView`-overzicht: verder luisteren, recent toegevoegd, vergeten parels, blader-op-genre/sfeer/decennium, Ontdek Wekelijks, gedownload, Lab-kaart, tandwiel rechtsboven | `LibraryView.overviewContent` (bestaat al, en is al goed) |
| **Bibliotheek** | Nummers · Albums · Artiesten · Playlists · Gedownload | `LibraryView` modes + `PlaylistsView` + `DownloadsView` + `BookmarksView` |
| **Zoek** | één veld, drie modi: Bibliotheek (`UnifiedSearch`) · Sonisch (CLAP) · Vraag het (AI) | `SonicSearchView` + `AskView` + de bestaande unified search |
| **Stations** | Radio's · DJ-modi · Journeys · Genereer een playlist | `StationsHubView` + `CreateHubView` |
| *(overlay)* | **Speler** — art, transport, wachtrij, songtekst, route | de twee huidige spelers, samengevouwen |
| *(kaart op Start)* | **Lab** — Music Map, Sonic DNA, Song Paths, Alchemy, Multitag, Smaakprofiel, Jaaroverzicht | `SonicLabView` + `TasteHubView` + los |
| *(tandwiel op Start)* | **Instellingen** — twee schermen: "Dit apparaat" en "Server & diensten" | `SettingsView`, gesplitst |

### macOS / iPad — dezelfde vijf begrippen in de sidebar

De sidebar krimpt van 29 items naar **Start · Bibliotheek · Zoek · Stations ·
Lab · Instellingen**, precies de begrippen van de telefoon. Dat is geen verlies:
16 van de 29 items landen nu al op een gedeeld scherm, dus de sidebar belooft
granulariteit die hij niet levert. De ⌘K-palet (`CommandPalette.swift`) blijft de
snelweg voor wie de featurenamen kent, en wordt daarmee de plek waar de diepte
zit.

---

## 5. Werkpakketten

Severity: 🔴 draagt de belofte · 🟠 merkbaar · ⚪ afwerking.
Effort: S (<1 u) · M (uren) · L (dag+)

### U1 🔴 L — Eén speler, één codepad
`LocalNowPlaying.swift` (579 r.) en `NowPlayingHero` in `NowPlayingView.swift`
(842 r.) tekenen hetzelfde scherm met andere bindings. Ze zijn al twee keer met
de hand gelijkgetrokken (10-08 en 11-08); de derde keer komt.

**Aanpak:** een `protocol NowPlayingSurface` in Core — `@MainActor`, observable,
met titel/artiest/art, positie/duur, `isPlaying`, shuffle/repeat, `toggle()`,
`next()`, `previous()`, `seek(_:)`, volume, en **capability-vlaggen**
(`canReorderQueue`, `hasDeviceVolume`, `supportsAirPlay`). `LocalPlaybackController`
implementeert hem rechtstreeks; een dunne `ZoneSurface`-adapter vertaalt de
Roon-zone. Eén `PlayerScreen` rendert allebei en verbergt wat een surface niet
kan, in plaats van dat twee schermen dat elk apart beslissen.

**Waarom eerst:** elk volgend pakket (overlay, wachtrijknop, routeknop) zou
anders twee keer gebouwd moeten worden.

**Risico:** dit is de grootste ingreep in het plan. Doe hem strikt refactorend —
eerst het protocol + de adapters mét tests, dán pas het scherm samenvoegen, en
geen enkele gedragswijziging in dezelfde commit.

### U2 🔴 M — De speler wordt een blad, geen tab
Mini-balk tikken presenteert `PlayerScreen` als `fullScreenCover` (iOS) /
sheet (mac) met veeg-omlaag om te sluiten. De tab **Nu speelt** vervalt; je
bladercontext blijft staan. Dit is *hét* verschil met Plexamp en ARC, en het
verklaart waarom de app "als een dashboard voelt" en niet als een speler.

~~Let op: de mini-balk hoort één keer om de `TabView` heen, met
`safeAreaInset`.~~ **Dat advies was fout, en de code wist het al beter.**
`nowPlayingBarDocked` staat bewust *per tab* en is een `VStack`-broer, geen
inset: een bodem-`safeAreaInset` op een `NavigationStack` inset de scrollinhoud
van een `List` met grote titel niet betrouwbaar, dus rijen schuiven ónder de
balk door (`NowPlayingBar.swift:190-198` legt dat uit). Bij de uitvoering
gelaten zoals hij stond.

### U3 🔴 M — Vier tabs in plaats van vijf, en geen kastjes
`iOSCreateHub` en `iOSExploreHub` verdwijnen als tab. Hun inhoud verdeelt zich
zoals in §4. `iOSTabSelection` — de mapping die 27 sidebaritems terugvouwt op
twee tabs (`RootView.swift:576-587`) — vervalt daarmee ook.

### U4 🟠 M — Eén routeknop in plaats van twee outputknoppen
`OutputSelector` en `AirPlayRouteButton` staan naast elkaar bovenin beide
spelers. Samenvoegen tot één luidsprekerknop die één lijst toont: **Dit apparaat ·
AirPlay-doelen · Roon-zones**. Daarmee verdwijnt "lokaal versus zone" als
begrip uit het hoofd van de gebruiker — het is gewoon een uitvoerkeuze, zoals
in ARC.

### U5 🟠 S/M — De wachtrij krijgt een handvat
Nu alleen een onaangekondigde horizontale veeg. Voeg in de speler een
wachtrijknop toe (`list.bullet`, rechtsonder in de voetrij) die `QueueView`
als sheet opent, plus een regel "3 van 24" onder de titel. De veeg blijft
werken voor wie hem kent.

### U6 🟠 S — Landen op Start, en terugkeren waar je was
`selection` begint op `.nowPlaying`; bij een koude start is dat een leeg scherm.
Standaard `.library` (het overzicht), en de laatst gebruikte tab onthouden in
`@AppStorage`. ~~Uitzondering: als er al muziek speelt bij het openen, opent de
speler-overlay meteen.~~ **Bewust niet gedaan.** Bij het starten is er nog niets
verbonden, dus dat blad zou een halve seconde ná de tabbalk uit het niets
omhoog schuiven — een scherm dat je niet vroeg. De mini-balk toont al wat er
speelt en is één tik van de volledige speler; die tik is de gebruiker's keuze,
niet die van de app. Plexamp noch ARC doet dit.

### U7 🟠 M — Instellingen uit de tabbalk, en in tweeën
Tandwiel rechtsboven op Start. Daarachter twee schermen:
**Dit apparaat** (uiterlijk, taal, downloads, audio-cache, loudness, transcode,
Qobuz lokaal streamen) en **Server & diensten** (Roon, analyzer, LLM, Discogs,
Last.fm, Qobuz-account, bibliotheeksync). Dat is dezelfde scheidslijn die op
11-08 al één keer bloed heeft gekost — vier afspeelsecties zaten achter
`if role == .server` en waren op de telefoon onzichtbaar (STATE.md, v1.10.257).
Die les hoort in de *structuur* te zitten, niet in een `if`.

### U8 🟠 M — Speler-ergonomie voor een duim
- Transport in de onderste derde; niets tikbaars in de bovenste 40% behalve
  sluiten en route.
- Veeg links/rechts over de hoes = vorige/volgende.
- Veeg omhoog = songtekst (`LyricsView` bestaat al), veeg omlaag = sluiten.
- Marquee voor lange titels (`KOEL_AUDIT` K7, nog open).
- Lang indrukken op de hoes = volledig scherm (bestaat al als `FullArtworkView`,
  maar is nu een gewone tik en dus makkelijk per ongeluk).

### U9 🟠 M — Offline zichtbaar in de bibliotheek zelf
Downloads bestaan (`DownloadsView`, batch 4), maar leven als aparte lijst. Een
draagbare speler laat het *in* de bibliotheek zien: een downloadknop in het
contextmenu van elk album/nummer, een pijltje-badge op wat gedownload is, en één
filter "alleen gedownload" in de bibliotheektab. Zonder dat blijft het een
instelling in plaats van een gewoonte.

### U10 ⚪ S — Zoek als tab in plaats van als scherm-eigenschap
`UnifiedSearch` is er al (v1.10.255) maar zit in de zoekbalk van het
bibliotheekoverzicht. Als tab is het één tik vanaf elk scherm — de reden dat
zowel Plexamp als ARC zoeken een vaste plek in de tabbalk geven.

### U11 ⚪ M — Sidebar en tabs vertellen hetzelfde verhaal
`SidebarSection.items` terugbrengen tot de zes begrippen van §4, en de 16
sidebaritems die op een gedeeld scherm landen laten vallen als navigatie-item
(ze blijven bestaan als `SidebarItem` voor deeplinks, palet en `navigateTo`).

### U12 ⚪ S — Backlog: "Toon geavanceerde tools"
Alleen bouwen als de Lab-kaart ná U1–U11 nog te druk voelt. Eén `@AppStorage`,
één plek, standaard aan op macOS en uit op iOS.

---

## 6. Volgorde

| Batch | Inhoud | Effort | Waarom hier |
|---|---|---|---|
| **1** | U1 — één speler, één codepad | L | fundament; alles daarna zou anders dubbel gebouwd worden |
| **2** | U2 + U6 — speler als blad, landen op Start | M | dit is waar het "als Plexamp voelt" vandaan komt |
| **3** | U3 + U10 + U11 — vier tabs, zoek-tab, sidebar gelijk | M | de kastjes weg; grootste zichtbare vereenvoudiging |
| **4** | U4 + U5 — routeknop, wachtrijknop | M | maakt de speler compleet zonder hem voller te maken |
| **5** | U7 — instellingen gesplitst en uit de tabbalk | M | kan los; raakt geen speelpad |
| **6** | U8 + U9 — ergonomie en offline in de bibliotheek | M | afwerking die het draagbaar maakt |
| Backlog | U12 | S | alleen op bewijs |

Per batch de huisregel: bewerken → `swift build && swift test` →
iOS-simulatorbuild → `check-localization.sh --strict` → commit + push + tag
(`vX.Y.Z`, `ios-vX.Y.Z`) → STATE.md bijwerken.

---

## 7. Hoe we weten dat het gelukt is

Meetbaar, vóór en ná, op de simulator (de enige GUI die op deze machine te
automatiseren is — het bureaublad heeft geen Screen-Recording-TCC):

| Maat | Nu | Doel |
|---|---|---|
| Tikken van koude start tot muziek | 3 (Bibliotheek-tab → item → play) vanaf een leeg spelerscherm | **≤ 2**, en het eerste scherm toont al speelbare rijen |
| Tikken van bladeren naar de speler en terug | 2 + verloren scrollpositie | **2, context behouden** |
| Tikken naar de wachtrij | onbekend (blinde veeg) | **1 vanuit de speler** |
| Verzonnen eigennamen in het navigatiepad | 9 (Sonic Lab, Music Map, Sonic DNA, Song Paths, Alchemy, Multitag, Journeys, DJ-modi, Ontdek Wekelijks) | **0 in de tabbalk** (Bibliotheek · Zoek · Ontdek · Stations); Lab is één kaart, en daarbinnen krijgt elk gereedschap een regel gewone taal — gehaald (U3) |
| Bestemmingen in de tabbalk | 5, waarvan 3 kastjes | **4 echte** — gehaald (U3) |
| Regels Nu-speelt-code | 1.421 in 2 bestanden | **< 900 in 1** — gehaald: 704 (U1) |
| Secties in het eerste instellingenscherm | 21 | **≤ 10 per scherm, 2 schermen** |

**Eén maat is bij de uitvoering geschrapt: "tikken naar Sonic Search".** Dat was
2 en werd 2 — de winst zat nooit in het aantal tikken maar in wat je onderweg
moest wéten. Een tabbalk waarin twee van de vijf knoppen een lijst openen die
naar een hub linkt is furniture, geen navigatie; dát is wat weg is. De maat is
vervangen door "verzonnen eigennamen in het navigatiepad".

Plus wat alleen op een toestel kan en dus expliciet openblijft: of de
blad-overgang soepel is met de art-crossfade eronder, of de veeggebaren botsen
met de systeem-terugveeg, en of de mini-balk boven de tabbalk blijft staan met
een geopende sheet.

## 7b. Wat de simulator wél en niet kon bewijzen (2026-08-22)

Er stond geen simulator op deze machine; er is er één aangemaakt (iPhone 17,
iOS 26.5), de app op geïnstalleerd en gestart. Dat leverde één echte bevinding op
en liep daarna vast op een grens die het vastleggen waard is.

**Wél bewezen:** de app bouwt, installeert en start op een schoon toestel, en het
verbindscherm mengde Nederlands en Engels (screenshot). Dat is gerepareerd.

**Niet bewezen — en niet te forceren:** `simctl` kan schermafdrukken maken maar
géén tikken versturen, en GUI-automatisering van het bureaublad is op deze
machine geblokkeerd (geen Accessibility-TCC). Zonder een tik kom je niet voorbij
het verbindscherm, dus de tabbalk en het spelerblad zijn **niet visueel
geverifieerd**. Wie dat wél wil: een XCUITest-target is de enige route.

**Vermoeden, onbewezen:** met een gevulde `client-library.db` (12 rijen) en een
onbereikbare `lastRoonHost` bleef de app op het verbindscherm staan in plaats van
zelf naar de offlinemodus te glijden, terwijl `RoonClient.swift:88-92` dat belooft
zodra een poging faalt én er een lokale bibliotheek is. Waarschijnlijk bereikt
`connectionState` nooit `.failed` maar blijft hij `.disconnected` tussen pogingen
door. Los uit te zoeken; het raakt P9 (half-offline zichtbaar maken).

## 8. Risico's

- **U1 is een hartoperatie.** De speler is het enige scherm dat élke sessie
  gebruikt. Strikt refactorend, protocol + adapters eerst mét tests, en geen
  gedragswijziging in dezelfde commit.
- **`fullScreenCover` en de mini-balk vechten om de safe area.** De val staat al
  beschreven in `NowPlayingBar.swift:9-12`; niet opnieuw inlopen.
- **`.nowPlaying` heeft precies vier aanroepers** — de mini-balk (`NowPlayingBar.swift:44`
  en `:67`), de navigatielijst van het palet (`CommandPalette.swift:329`) en de
  tab-tag zelf. Geteld, niet aangenomen: die vier moeten allemaal de overlay
  openen, anders wijst er iets naar een tab die niet meer bestaat.
- **Er zijn géén deeplinks** (`onOpenURL` en `widgetURL` komen nergens voor), dus
  het weghalen van sidebaritems breekt niets buiten de app. Dat is meteen een
  gemis op zich: een widget of Live Activity kan nu alleen de app openen, niet
  een scherm. Buiten de reikwijdte hier, maar het hoort in de ROADMAP.
- **De lokalisatiepoort straft elke gemiste sleutel af**, maar niet de kale
  literals — er staan er nog ~82 buiten `SettingsView`. Nieuwe schermen mogen er
  geen bij maken.

## 9. Status

- [x] Batch 1 — U1 · v1.10.263 / ios-v1.7.230.
      `NowPlayingModel` (Core, puur, 20 tests) + `NowPlayingSurface` (het verschil
      tussen de uitvoeren als data) + één `PlayerScreen`. `LocalNowPlaying.swift`
      weg. **De vondst zat niet in de layout maar in wat de splitsing verborg:**
      Sonic Radio ontbrak in het menu van de lokale speler terwijl de motor het
      al volledig kon — `startRadio(zoneID: nil)` levert aan de actieve uitvoer
      en `topUpRadioIfNeeded` heeft een lokale tak. Eén regel, aparte commit.
      Verder samengevoegd naar de béste van de twee, niet naar het gemiddelde:
      haptics op ⏮ (had alleen lokaal), de toegankelijke scrub-actie (alleen de
      zone), en de uitweg onder "niets aan het spelen" (alleen de zone — een
      stille telefoon zag er daardoor kapot uit). Catalogus 860 → 844: de héle
      `localNowPlaying.*`-familie was een duplicaat van `nowPlaying.*`, wat
      precies is wat de twee schermen zélf waren. Wees-sleutels 1 → 0.
      **Regels spelerscherm: ~1.219 in twee kopieën → 704 in één** (plus 304 r.
      adapter en 103 r. getoetste rekenkunde in Core).
- [x] Batch 2 — U2 + U6 · v1.10.265 / ios-v1.7.231.
      De tab "Nu speelt" is weg; de speler komt als blad (`.sheet`, detent
      `.large`, zichtbare grijper) over waar je was, en de wachtrij reist met hem
      mee als tweede pagina. Alle navigatie loopt nu door één trechter,
      `RootView.go(to:)`: `.nowPlaying` is op een compacte iPhone geen selectie
      meer maar een presentatie, dus de mini-balk, het ⌘K-palet en elke
      lege-staat-knop blijven werken zonder te weten in welke schil ze zitten.
      Landen op Bibliotheek, laatste tab onthouden (`lastTab`), met een grendel
      tegen een `.nowPlaying` die een oudere build heeft weggeschreven — een
      `TabView`-selectie zonder bijbehorende tag rendert een blanco tab.
      **Bijvangst uit de simulator: het verbindscherm was half Nederlands op een
      Engelse telefoon.** `LS("Opnieuw verbinden met \(saved)")` interpoleerde de
      host ín de sleutel, dus die kon nooit oplossen en viel terug op de
      Nederlandse literal. Twee sleutels erbij, catalogus 844 → 846.
- [x] Batch 3 — U3 + U10 + U11 · v1.10.266 / ios-v1.7.232.
      **Vier tabs, en ze landen alle vier op inhoud:** Bibliotheek · Zoek ·
      Ontdek · Stations. `iOSCreateHub` en `iOSExploreHub` — de twee `List`s die
      alleen naar een hub linkten — zijn weg; hun hubs zijn nu zélf de tab.
      Instellingen verhuist naar een tandwiel op Bibliotheek en een blad, net als
      de speler; `go(to:)` vangt `.settings` op dezelfde plek af als
      `.nowPlaying`. **Zoek is een eigen tab** met drie manieren: Bibliotheek ·
      Sonisch · Vraag het.
      **Geen tweede zoekimplementatie:** de gecombineerde artiest/album/track-zoek
      (P7) staat in `LibraryView`, inclusief de "toon alles"-doorstap en de
      sonische doorgeefrij. `LibraryView(searchOnly:)` hergebruikt dat en verbergt
      alleen de moduskiezer tot een doorstap hem nodig maakt — een eigen kopie
      zou precies de fout van de twee spelers herhalen.
      **Genereer** zit bij Stations (alle vier beantwoorden "zet iets op", ze
      verschillen alleen in eindeloos versus eindig). **Lab** (Sonic Lab, Music
      Map, Multitag, DJ, smaak) is één kaart op het bibliotheekoverzicht, met
      een regel gewone taal per gereedschap. Playlists en Bewaard staan daar nu
      ook, in dezelfde kaartvorm als Gedownload.
      Sidebar 29 items → **11**, met dezelfde vijf woorden als de telefoon.
      Catalogus 846 → 854 (14 nieuw, 6 wezen van de gesloopte kastjes weg).
- [ ] Batch 4 — U4 + U5
- [ ] Batch 5 — U7
- [ ] Batch 6 — U8 + U9
- [ ] Backlog — U12

## 10. Herhaalbare metingen

```bash
cd ~/roonsage/native/RoonSage/Sources/RoonSageUI
ls *.swift | wc -l                                   # aantal view-bestanden
grep -c "case " ../RoonSageUI/RootView.swift         # sidebar-cases (grof)
grep -c "Section(" SettingsView.swift                # instellingen-secties
wc -l LocalNowPlaying.swift NowPlayingView.swift     # duplicatie in de speler
grep -rn "navigateTo(.nowPlaying)" ..                # aanroepers van de tab-sprong
```
