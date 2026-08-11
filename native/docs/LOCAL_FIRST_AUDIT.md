# Local-first-audit — waar RoonSage "dit apparaat" nog als uitzondering behandelt

> Gegenereerd: 2026-08-11. Aanleiding: user wil "een professionele lokale music
> player met ondersteuning voor zone play via Roon in plaats van andersom", en
> liep in twee dagen tegen twee losse symptomen aan (de mini-speler die een zone
> aanprees, en een stopknop die zijn uitvoer wegzette). Beide bleken hetzelfde
> onderliggende patroon. Dit is de systematische versie van die twee meldingen.
>
> Reikwijdte: `RoonSageCore` + `RoonSageUI`. Geen externe bronnen, dus geen
> licentie-hek — dit gaat puur over onze eigen code.
>
> Verwant: [JELLYFIN_AUDIT](JELLYFIN_AUDIT.md) gaat over *ontbrekende* features
> (offline, crossfade, AirPlay). Dit document gaat over features die er **wél**
> zijn maar alleen werken als je naar Roon speelt.

---

## 1. Oordeel in één alinea

De omslag van vorige week is half af. De *fundering* klopt al:
`playToActiveOutput` en `queueToActiveOutput` bestaan, 27 plekken gaten op
`hasActiveOutput`, en de wachtrij is lokaal bewerkbaar. Maar de **stations —
Sonic Radio, Song Radio, Custom Radio, DJ-modi, Sonic Adventure — werken
uitsluitend op een Roon-zone.** Dat is de duurste vondst van deze audit: het is
precies wat RoonSage onderscheidt van elke andere speler, en het is niet
beschikbaar in de modus die sinds v1.10.228 de standaard is. Daaromheen zit een
staart van 62 zone-gates in de UI en een handvol verbs die één regel van
output-agnostisch af staan.

## 2. Wat al goed staat (niet aan sleutelen)

`playToActiveOutput` / `queueToActiveOutput` (`RoonClient+LocalPlayback.swift`),
`hasActiveOutput` als gate (27 plekken), de bewerkbare lokale wachtrij, de
afspeel-cache, gapless, en `NowPlayingView` + `NowPlayingBar` die sinds
v1.10.231 allebei op `localOutputSelected` beslissen.

## 3. Gap-analyse

Severity: 🔴 breekt de belofte "lokale speler eerst" · 🟠 merkbaar scheef · ⚪ kosmetisch.
Effort: S (<1u) · M (uren) · L (dag+)

### L1 🔴 M/L — De stations werken niet op dit apparaat
**Wat:** `startRadio`, `startTrackRadio`, `startCustomRadio`, `playSonicRadio`,
`playSonicAdventure` en de DJ-modi nemen allemaal een verplichte `zoneID`.

**Waarom het structureel is, niet alleen een parameter:** een station is geen
eenmalige actie maar een doorlopend proces. `startRadioMonitor()` polst elke 3
seconden en `topUpRadioIfNeeded()` (`RoonClient+Radio.swift:301`) doet twee
dingen die allebei Roon-specifiek zijn:

```swift
guard let state = radioState, queueZoneID == state.zoneID else { return }
guard queueItems.count <= Self.radioLowWater else { return }
```

`queueItems` is de **zone**-wachtrij (via `startQueue(zoneID:)`); de lokale motor
heeft zijn eigen array die de radio nooit ziet. En `RadioStatus`
(`RoonClient+Radio.swift:44`) draagt een `zoneID: String` als niet-optioneel veld.

**Voorstel:** geef de radio een uitvoer-notie in plaats van een zone-id.
Concreet drie plekken: (a) `RadioStatus.zoneID` → een `Output`-enum (`.zone(String)`
/ `.device`); (b) de low-water-lezing → bij `.device` het aantal resterende
tracks in `localPlayback.queue` na `index`; (c) het aanvullen → `enqueueLocally`
in plaats van `queueTracks(zoneID:)`. De pool-generatie, de scoring en het
her-sturen blijven ongemoeid — die weten niets van uitvoer.

**Dit is de belangrijkste van het hele document.** Zonder dit is "lokale speler
eerst" een speler zonder de reden waarom je RoonSage zou gebruiken.

### L2 🟠 S — Zeven verbs staan één regel van output-agnostisch af
Deze assembleren een tracklijst en eindigen in `curateTracks(_:zoneID:)`. Ze
hebben geen doorlopende staat, dus ze zijn te converteren door die laatste regel
te vervangen:

| Verb | Bestand |
|---|---|
| `playDJSet` | `RoonClient+Features.swift:406` |
| `playShuffledMix` | `RoonClient+Features.swift:486` |
| `playPlaylist` | `RoonClient+Playlists.swift:120` |
| `playRecommendation` | `RoonClient+Discovery.swift:239` |
| `playAlbum` / `playAlbums` | `RoonClient+Features.swift:497/521` |
| `playArtist` | `RoonClient+Features.swift:508` |
| `playTrack` | `RoonClient+Library.swift:390` |

**Voorstel:** een `…ToActiveOutput`-variant per verb (of `zoneID` optioneel maken
en bij nil naar `playToActiveOutput` routeren), daarna de call-sites ontgaten.
Let op: `playAlbumLocally` en `playArtistLocally` bestaan al als losse tweeling —
die moeten opgaan in de geroute versie, anders houden we het tweede pad in stand
dat we vorige week juist hebben opgeruimd.

### L3 🟠 M — 62 zone-gates in de UI
28× een `disabled(…)` die op `selectedZone == nil` gate't (27 kaal, 1 samengesteld:
`SonicJourneysView.swift:78`) en 34× `if/guard let zone = client.selectedZone`. Een deel is terecht (de zone-hero in `NowPlayingView`, de
Roon-tak van `QueueView`, de zonekiezer zelf). De rest schakelt gewoon
functionaliteit uit terwijl er een prima uitvoer klaarstaat:

| Bestand | Gates | Oordeel |
|---|---|---|
| `LibraryView.swift` | 11 | grootste concentratie; speelknoppen in lijsten en grids |
| `DiscoveryView.swift` | 5 | album-plays op de kaarten |
| `MusicMapView.swift` | 4 | tikken op een punt speelt niet lokaal |
| `LibraryDetailViews.swift` | 4 | album-/artiestradio nog zone-only |
| `QueueView.swift` | 4 | **terecht** — dit is de Roon-tak |
| `SonicRadioView` · `SonicFingerprintView` · `GenerateView` · `AskView` | 3 elk | mix van L1 (radio) en L2 (play) |
| overige 11 bestanden | 1–2 elk | |

**Voorstel:** na L1 en L2 zijn de meeste gates vanzelf `hasActiveOutput`. Doe ze
per bestand, grootste eerst, en gebruik `hasActiveOutput` als enige gate-vorm
zodat er één patroon overblijft.

### L4 🟠 S — Teksten die nog uitgaan van een zone
- `playlists.chooseZoneFirst` = "Kies eerst een zone" — noemt dit apparaat niet,
  terwijl de zusterteksten (`library.chooseZoneFirst`, `root.chooseZoneHelp`,
  `generate.noZone`) dat inmiddels wél doen.
- `queue.noZoneTitle` = "Geen zone gekozen" — de titel boven een scherm dat sinds
  v1.10.228 ook een lokale wachtrij kan tonen.
- `PlaylistsView.swift:245-246` hardcodeert "speelt op **deze iPhone**" in het
  Nederlands, in een app die in het Engels kan draaien. Zelfde klasse als de
  "Stop afspelen op this device" van v1.10.230.

### L5 ⚪ S — Instellingen framen lokaal als een modus
Drie secties heten "(lokaal afspelen)": loudness-normalisatie
(`SettingsView.swift:866`), onderweg streamen (`:901`) en "Muziek bewaren op dit
apparaat" (`:833`). Dat was juiste taal toen lokaal de uitzondering was. Nu is
het de standaard, en lezen die haakjes als een niche-instelling.
**Voorstel:** laat de haakjes weg; noem alleen expliciet "Roon-zone" waar iets
juist níét voor dit apparaat geldt. Omgekeerde default in de taal.

### L6 ⚪ S — `localOutputName` is hardgecodeerd Nederlands
`RoonClient+LocalPlayback.swift` geeft letterlijk `"Dit apparaat"` / `"Deze Mac"`
terug. Core kan `LS` niet gebruiken (dat leeft in `RoonSageUI`), dus dit ontsnapt
aan de localisatie-poort — het is geen sleutel, dus `check-localization.sh` ziet
het niet. Zichtbaar in de uitvoerkiezer van een Engelstalige app.
**Voorstel:** de naam in de UI-laag bepalen en Core alleen de identiteit
(`localOutputID`) laten leveren.

### Bewust NIET veranderen
- **`playFromHere` en `startQueue`** — dat is Roons queue-browsing, per definitie
  zone-gebonden. De lokale kant heeft z'n eigen (rijkere) equivalent.
- **De transport-verbs met `zoneID`** (`playPause`, `next`, `seek`, `setShuffle`,
  `setRepeat`) — die horen bij de zone-hero; de lokale motor heeft z'n eigen set.
  Twee paden is hier correct, want het zijn twee verschillende apparaten.
- **`QueueView`'s zone-tak** — terecht gegate.

## 4. Aanbevolen batches

| Batch | Inhoud | Effort | Waarom in deze volgorde |
|---|---|---|---|
| 1 | L2 zeven verbs output-agnostisch + de tweelingen opheffen | S | mechanisch, en het maakt de meeste L3-gates vanzelf overbodig |
| 2 | L3 gates opruimen, grootste bestand eerst | M | volgt uit batch 1; één gate-vorm overhouden |
| 3 | **L1 stations op dit apparaat** | M/L | de eigenlijke belofte; verdient een eigen ronde met tests |
| 4 | L4 + L5 + L6 teksten en framing | S | kosmetisch maar zichtbaar; L6 sluit een gat in de localisatie-poort |

Batch 3 staat bewust ná 1 en 2: de radio's leunen op `enqueueLocally`, en die
route wil je bewezen hebben vóór je er een doorlopend proces op zet.

## 5. Status

- [ ] Batch 1 — L2
- [ ] Batch 2 — L3
- [ ] Batch 3 — L1
- [ ] Batch 4 — L4/L5/L6

## 6. Hoe dit gevonden is (herhaalbaar)

```bash
# zone-gates in de UI
grep -rnE 'disabled\(client\.selectedZone == nil|if let zone = client\.selectedZone' \
  --include='*.swift' native/RoonSage/Sources/RoonSageUI

# verbs die een zone eisen
grep -rhoE 'client\.[a-zA-Z]+\([^)]*zoneID:' --include='*.swift' \
  native/RoonSage/Sources/RoonSageUI | sort | uniq -c | sort -rn

# hardgecodeerde apparaat-teksten (ontsnappen aan check-localization.sh)
grep -rniE '"[^"]*(dit apparaat|deze iPhone|deze Mac|lokaal afspelen)[^"]*"' \
  --include='*.swift' native/RoonSage/Sources
```
