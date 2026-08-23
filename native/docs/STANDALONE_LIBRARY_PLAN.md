# De bibliotheek los van Roon — audit en plan

> Opgesteld 2026-08-23, op vraag van de user: *"Ga daar in werken en begin maak
> een duidelijk plan en voer die uit"*, na een analyse van hoe `tracks` gevuld
> wordt en wat er nodig is om de bibliotheek standalone te maken.
>
> **Verwant, maar niet hetzelfde.** [LOCAL_FIRST_AUDIT](LOCAL_FIRST_AUDIT.md) en
> [LOCAL_PLAYER_READINESS](LOCAL_PLAYER_READINESS.md) gaan over de **uitvoer** —
> "speelt dit ding ook zonder Roon-zone?" Die vier batches zijn geshipt op
> 2026-08-11. Dit document gaat over de **bron**: waar de bibliotheek zelf
> vandaan komt. Dat is nog onaangeroerd.
>
> **Methode.** Alle getallen hieronder zijn gemeten op 2026-08-23 tegen kopieën
> van de echte databases (`library.db` 511 MB, `analyzer.db` 407 MB), niet
> geschat. Codeverwijzingen zijn gecontroleerd op regelnummer.

---

## 1. Oordeel in één alinea

De app heeft **twee identiteitssystemen** die met een fuzzy matcher aan elkaar
geknoopt zijn, en die knoop lekt. `tracks` is een afdruk van Roon's Browse-boom
met Roon's `item_key` als primaire sleutel; `track_features` is een afdruk van de
schijf met een genormaliseerde `match_key` als primaire sleutel. De brug ertussen
is `TrackIdentity.matchKey` plus `reconcileFeatureMatches`, en die brug haalt
64.789 van de 89.752 trackrijen — waardoor **19.537 volledig geanalyseerde
tracks in `track_audio_features` staan zonder bijbehorende `tracks`-rij**. Die
analyses zijn al gesynchroniseerd, kosten al schijf en geheugen, en zijn
onbereikbaar voor élke functie in de app, want `analyzedTrackIdentities()` doet
`FROM tracks t JOIN track_audio_features f`. Er is dus een complete tweede
bibliotheek aanwezig waar niets bij kan. Tegelijk erkent de code zélf al dat de
Roon-sleutel niet houdbaar is (`LibrarySyncService.swift:245`: *"item_keys are
session-scoped and can't key anything persistent"*), en heeft `playByBrowse` al
een zoek-terugval voor verlopen sleutels. De weg naar standalone is daarom niet
"Roon eruit slopen", maar: **`tracks` een tweede bron geven, de identiteit
losmaken van Roon, en Roon degraderen tot uitvoer.**

## 2. Hoe het nu werkt — twee bronnen, één knoop

| | catalogus | analyse |
|---|---|---|
| bron | Roon Browse (Root→Library→Albums→tracks) | `LibraryWalker` over `/Volumes/4tbdrive/Muziek` |
| code | `RoonSageCore/Sync/LibrarySyncService.swift` | `AnalyzerCore/LibraryWalker.swift` + `AudioAnalysis/MetadataReader.swift` |
| opslag | `library.db` → `tracks` | `analyzer.db` → `track_features` |
| sleutel | `tracks.id` = **Roon `item_key`** (`TrackRecord.swift:8`) | `match_key` = `TrackIdentity.matchKey(artist, album, title)` |
| overdracht | :5767 library share | :5766 `/features`, `/embeddings`, `/audio` |
| knoop | `reconcileFeatureMatches` (exact + fuzzy) rewrite `tracks.match_key` | |

## 3. De meting (2026-08-23)

| | |
|---|---|
| `track_features` (schijf) | **66.378** — allemaal met `file_path`, 66.239 met CLAP-embedding (99,8%), één root |
| `tracks` (Roon) | **89.752** rijen, 67.262 unieke `match_key`s |
| rauwe `match_key`-overlap | **44.357** (66%) |
| trackrijen die ná reconcile een feature-rij vinden | **64.789** |
| `track_audio_features` in `library.db` | 64.038 rijen — **waarvan 19.537 zonder `tracks`-rij** |
| `tracks` zonder analyse | 22.761 unieke `match_key`s |
| daarvan op een albumtitel die nérgens op schijf staat | **13.175** — de Qobuz-laag in Roon |
| bestanden op schijf zonder Roon-rij | 22.021 — vooral klassieke boxsets (London Philharmonic, Solti, Menuhin) |

Twee dingen springen eruit. **Ten eerste**: die 19.537 zijn geen ontbrekende
data maar onbereikbare data — de analyse is al binnengehaald. **Ten tweede**: de
13.175 Qobuz-tracks zijn het enige echte verlies bij standalone gaan; de rest
staat gewoon op schijf.

## 4. Bevindingen

Severity: 🔴 blokkeert standalone · 🟠 kost nu al functionaliteit · ⚪ opruimwerk.

### S1 🟠 — 19.537 geanalyseerde tracks zijn onzichtbaar
`analyzedTrackIdentities()` (`DatabaseManager+AudioFeatures.swift:578`) joint op
`tracks`. Geen bibliotheekrij = niet in de bibliotheek, niet in radio, niet in
DJ, niet in Music Map, niet in Sonic Search. De features zijn er wél. Kosten om
dat te repareren zijn laag, want `/features` exporteert al `match_key, artist,
title, album, year` (`FeatureStore.swift:1131`).

### S2 🔴 — `tracks.id` is een sessie-sleutel
`TrackRecord.id` is Roon's `item_key`. Die verloopt per Browse-sessie; de code
weet dat en vangt het op met een zoek-terugval in `playByBrowse`
(`BrowseService.swift:143`). Zolang de identiteit van een track een Roon-artefact
is, kan de bibliotheek per definitie niet zonder Roon.

### S3 🔴 — Er is nul lokale albumhoes-code
Geen enkele hit op `folder.jpg`, `cover.jpg` of embedded-artwork-extractie in
`Sources/`. Alle zeven weergaveplekken gaan via `client.imageURL(forKey:)`, dus
via Roon's image-API: `AlbumArtView:20`, `PlayerScreen:92,119,218,237`,
`ShareCardView:111`, `WallDisplayView:39`.

### S4 🟠 — De Qobuz-laag heeft geen eigen route
`QobuzClient` kan `streamURLs`, zoeken en playlists, maar heeft **geen**
favorieten/bibliotheek-ophaal. De 13.175 streaming-tracks bestaan alleen doordat
Roon ze in zijn bibliotheek toont.

### S5 ⚪ — De prune kent maar één bron
`finishSyncRun(pruneStale:)` (`DatabaseManager+Sync.swift:113`) doet
`DELETE FROM tracks WHERE album_fp IS NULL OR album_fp NOT IN (checkpoints)`.
Elke rij die niet uit de Roon-walk komt wordt daarmee bij de eerstvolgende
volledige sync weggegooid. Een tweede bron kan dus niet bestaan zonder dat de
prune weet wie waar vandaan komt.

## 5. Het plan — vier fasen, los te shippen

### Fase 1 — De bibliotheek krijgt een tweede bron 🟠 M — ✅ af, zie 5b
Kolom `tracks.source` (`roon` | `local`, default `roon`), de prune beperkt tot
`source = 'roon'`, en een ingest die van elke feature-rij zonder `tracks`-rij een
lokale bibliotheekrij maakt: `id = "local::<match_key>"`, artiest/titel/album/jaar
uit de bestandstags. Draait in `syncAudioFeatures`, direct ná `reconcileFeatureMatches`
— dus alleen wat de fuzzy matcher óók niet thuis kon brengen.

Waarom dit als eerste kan: `LocalPlayability.matchKey(for:)` herberekent de
sleutel uit artiest/album/titel, dus een rij die uit diezelfde tags gebouwd is
komt op exact dezelfde `match_key` uit en is **meteen streambaar via `/audio`**.
Geen nieuwe afspeelcode nodig. Op een Roon-zone gaat `local::` door dezelfde
synthetische-sleutel-tak als `import::`: verse zoekopdracht op afspeelmoment.

Let op de trigger `trg_tracks_first_seen`: 19.537 verse inserts zouden allemaal
als "vandaag nieuw" gestempeld worden en "op deze dag"/nieuw-in-bibliotheek
overspoelen. De ingest zaait `track_first_seen` daarom vooraf, met de oudste
bekende datum uit die tabel.

**Klaar wanneer:** `swift test` groen met nieuwe tests op de ingest en op de
prune-grens, en `analyzedTrackIdentities()` levert meetbaar meer rijen.

### Fase 2 — Lokale albumhoezen 🔴 M — ✅ af, zie 5c
Zonder dit heeft fase 1 duizenden albums zonder hoes. Embedded artwork via
`MetadataReader` (AVFoundation `commonKeyArtwork`), anders `cover.jpg`/`folder.jpg`
naast het bestand; uitserveren als `/artwork?match_key=…` op :5766 naar analogie
van `/audio` (Range-loos, wél cache), en de weergaveplekken via één resolver die
op de sleutel beslist: Roon-sleutel → Roon-API, `local::` → `/artwork`.

### Fase 3 — Stabiele track-identiteit 🔴 L
`tracks.id` los van `item_key`: Roon's sleutel naar een eigen kolom
`roon_item_key` die per sync ververst wordt, en `id` naar iets duurzaams. Let op:
`match_key` alléén kan niet — hij is niet uniek in `tracks` (67.262 unieke
sleutels op 89.752 rijen, dus 22.490 botsingen door dubbele edities). De sleutel
moet dus album-fingerprint + match_key + volgnummer worden. Migratie raakt
`track_genres.track_id` (FK, cascade) en `playlist_tracks.track_id`. Pas ná fase
1-2, en met een gemeten migratie op een kopie van de echte database.

### Fase 4 — Qobuz-favorieten direct 🟠 M
`favorite/getUserFavorites` in `QobuzClient`, weggeschreven als `source = 'qobuz'`.
Pas hierna is "Roon uitzetten" een echte optie in plaats van 13.175 tracks
verliezen.

## 5b. Uitvoering — fase 1 (2026-08-23)

**Af en gemeten.** Migratie `v49_track_source` (kolom `tracks.source`), alle drie
de deletes van de Roon-walk begrensd tot `source='roon'`,
`DatabaseManager+LocalLibrary.swift` met `ingestLocalTracks`, aangeroepen in
`syncAudioFeatures` direct ná `reconcileFeatureMatches` en alleen in
`.direct`-modus (de server bezit de bibliotheek; een thin client krijgt hem
compleet via :5767). `local::` erkend in `playByBrowse`. `source` reist mee in de
share-payload als `"s"`, alleen als hij niet de standaard is.

Onderweg opgeruimd: de live-heuristiek stond alleen in `LibrarySyncService` en
had nu een tweede kopie gekregen — nu één definitie,
`TrackIdentity.looksLive(title:context:)`, gebruikt door beide bronnen. Anders
kon dezelfde track live zijn via de ene route en studio via de andere, en
`excludeLive` filtert álle stations op precies die vlag.

**De meting** (`swift test --filter testMeasureAgainstTheRealLibrary`, tegen
kopieën van de echte databases — de test staat in de suite en slaat zichzelf over
zonder de twee omgevingsvariabelen):

```
feature-rijen aangeboden   : 66.377
tracks vóór                : 89.752
tracks ná                  : 104.805
lokale rijen               : 15.053 (allemaal nieuw)
features zonder tracks-rij : 19.537 -> 4.484
analyzedTrackIdentities    : 49.166 -> 64.219
```

**Dat laatste is de opbrengst: +15.053 tracks (31%) voor de stations, DJ-sets,
Music Map en Sonic Search** — die lezen allemaal `analyzedTrackIdentities()`, en
die stond op 49.166 van de 66.378 geanalyseerde bestanden.

**De 4.484 die overblijven zijn geen tekort van deze fase.** Het zijn rijen in
`track_audio_features` waarvan de sleutel in de huidige `/features`-export niet
meer voorkomt: historische sleutels van vóór een normaliser-wijziging, plus rijen
zonder BPM (`exportJSON` filtert op `bpm IS NOT NULL`). Er bestaat geen analyse
meer die ze onderbouwt. Opruimen hoort bij een aparte onderhoudsronde, niet hier.

## 5c. Uitvoering — fase 2 (2026-08-23)

**Af en gemeten.** `MetadataReader.artwork(url:)` haalt ingebedde cover art uit
het bestand (ID3 `APIC`, FLAC `METADATA_BLOCK_PICTURE`);
`AnalyzerCore/ArtworkProvider` valt terug op een sidecar
(`cover`/`folder`/`front`/`album`/`artwork` × jpg/jpeg/png/webp, in die volgorde,
hoofdletter-ongevoelig gematcht tegen de échte mapinhoud), schaalt met ImageIO
naar de gevraagde maat en cachet 512 uitkomsten — misser inbegrepen, anders
wordt een map zonder hoes bij elke scrollbeweging opnieuw gelijst.
`GET /artwork?match_key=…&size=…` op :5766, met dezelfde auth als `/audio`
(header óf `token`-queryparameter, want een image loader kan net zomin een eigen
header meesturen als AVPlayer) en `size` geklemd op 32…1200.

**De UI hoefde niet aangeraakt.** Een lokale rij krijgt als `image_key` dezelfde
`local::<match_key>`-markering die zijn id draagt, en
`RoonClient.imageURL(forKey:)` kiest daarop: Roon-sleutel → de image-API van de
Core, `local::` → `/artwork` van de analyzer. Alle zeven weergaveplekken
(`AlbumArtView`, `PlayerScreen` ×4, `ShareCardView`, `WallDisplayView`) namen al
een image key aan en zijn ongewijzigd.

**De meting** (zelfde opt-in test, tegen echte bestanden):

```
steekproef van 200 lokale rijen
  ingebed in het bestand : 182
  cover.jpg ernaast      :  16
  geen hoes te vinden    :   2      → 99% dekking

/artwork end-to-end (echt bestand, over HTTP)
  200 OK · image/jpeg · 199x200 px · 14.143 bytes
```

Die 14 kB is het punt van het schalen: dezelfde hoes zit als ~1 MB in het
bestand, en de uplink hier is 39 Mbps.

**Eén verwachting stond verkeerd om** en de test ving het:
`kCGImageSourceThumbnailMaxPixelSize` begrenst de **langste** zijde, dus een
niet-vierkante hoes komt op 199×200 uit. De toets kijkt nu naar die afspraak in
plaats van naar de breedte.

## 6. Maten om achteraf te toetsen

| maat | vóór | nu | doel |
|---|---|---|---|
| rijen uit `analyzedTrackIdentities()` | 49.166 | **64.219** | ✅ fase 1 |
| feature-rijen zonder `tracks`-rij | 19.537 | **4.484** (verweesd, zie 5b) | ✅ fase 1 |
| lokale rijen met een vindbare hoes | — | **99%** (198/200 steekproef) | ✅ fase 2 |
| bibliotheekrijen met een Roon-sleutel als identiteit | 100% | 86% | 0% na fase 3 |
| tracks die verdwijnen als Roon uitgaat | 13.175 | 13.175 | 0 na fase 4 |

## 7. Wat we bewust niet doen

- **Geen `tracks`-vervanging.** De Roon-walk blijft de bron voor alles wat Roon
  wél goed weet (genres, compilatie-detectie, de Qobuz-laag). De tweede bron
  vult aan; hij vervangt pas iets als fase 3-4 af zijn.
- **De fuzzy matcher blijft.** Exact matchen dekt 44.357 sleutels; ná reconcile
  joinen 64.789 trackrijen. Dat verschil is precies zijn opbrengst. Fase 1 draait
  ná hem, niet in plaats van hem.
- **Geen tweede scan.** De ingest leest de bestaande `/features`-payload; er komt
  geen extra schijfwandeling en geen nieuwe module-afhankelijkheid
  (`RoonSageCore` mag `AnalyzerCore` niet importeren).
