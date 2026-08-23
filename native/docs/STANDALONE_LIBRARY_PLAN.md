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

### Fase 3 — Stabiele track-identiteit 🔴 L — *herzien, zie 5d*
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

## 5d. Hoe de buren het doen — en wat RoonSage daarvan overneemt (2026-08-23)

> Op vraag van de user: *"kijk ook naar dropped needle en soulsync hoe zij
> bibliotheek inscannen etc. Volgens mij gaat dat met metabrainz en accousticID"*.
> Dat klopt voor DroppedNeedle, half voor SoulSync — en de meting bracht iets
> anders naar boven dan verwacht.

### DroppedNeedle — identiteit in drie lagen, AcoustID als laatste redmiddel

DN scant zelf (`local_tracks`: `file_path`, `path_hash`, `file_mtime_ns`,
`stat_revision`) en hangt daar een identiteit aan in
`local_track_external_identities` (`recording_mbid`, `release_mbid`,
`release_track_mbid`). Het veld dat het interessant maakt is `decision_source`:

| bron | tracks | wat het is |
|---|---|---|
| `automatic` | 12.270 | de MusicBrainz-matcher |
| `embedded` | 9.296 | **MB-tags die al in het bestand zaten** |
| `manual` | 7.148 | door een mens bevestigd |

AcoustID (`fpcalc` + acoustid.org, `audio_fingerprint_outcomes`) is er wél, maar
is de kléinste laag: 4.239 pogingen, waarvan **2.655 `matched`** en 1.509
`no_match`. Het is het laatste redmiddel, niet de eerste stap. Elke poging houdt
bewijs bij (`library_identification_attempts` / `_evidence`) en wat niet
overtuigt gaat naar een reviewwachtrij. Dekking vandaag: 28.714 van 67.110
tracks (43%), 4.457 van 8.955 albums.

### SoulSync — AcoustID als verificatie, niet als scanner

SoulSync heeft geen bibliotheekscanner in deze zin. AcoustID zit in
`core/library_reorganize.py` als **controle ná een download**: klopt het bestand
dat binnenkwam met het nummer dat gevraagd werd, anders quarantaine. MusicBrainz
is er één van ~12 metadata-providers (`core/source_ids.py`). Wat SoulSync wél
doet en wat hier telt: het **schrijft identiteit terug in de tags** — 78% van de
bemonsterde bestanden draagt een `soulsync_verification`-tag, en 80% een ISRC.

### Wat er daadwerkelijk in de bestanden zit (steekproef 385, mutagen)

| tag | dekking |
|---|---|
| **ISRC** | **80%** |
| `musicbrainz_artistid` | 28% |
| MusicBrainz recording/release-track id | 24% |
| `deezer_track_id` | 27% |
| AcoustID-fingerprint | 0% |

Dus: de identiteit die hier op schijf ligt is overwegend **ISRC**, gezet door
SoulSync's downloadpijplijn — niet MBID. En RoonSage las géén van beide: de
36.962 ISRC's in `analyzer.db` kwamen uit de offline dataset-sidecar (een fuzzy
metadata-match), niet uit de tags. **156 van 385 bemonsterde bestanden (41%)
droegen een ISRC die nergens werd opgepikt.** Waar beide bronnen een waarde
hadden waren ze het 89% eens; de 11% verschil zijn sidecar-missers, want de tag
zit in het bestand.

### En één echte bug, gevonden door daar te kijken

`MetadataReader` matchte rauwe tagnamen met `contains("ARTIST")` — en
`MUSICBRAINZ_ARTISTID` bevat "ARTIST", `MUSICBRAINZ_ALBUMID` bevat "ALBUM". In
bestanden waar de MB-tag vóór de gewone tag werd opgesomd belandde de **UUID als
artiestnaam en albumnaam**: 412 rijen, gesleuteld op een UUID, onvindbaar voor
elke join en in de app zichtbaar als een artiest die `300c4c73-33ac-…` heet.
Gerepareerd, met een regressietest die bewezen rood werd op de oude routering.
Bij het herstel bleek bovendien dat **352 van die 412 duplicaten waren** van een
correcte rij — dezelfde track stond twee keer in de bibliotheek.

### Gemeten na de ingreep (kopie van de echte `analyzer.db`)

```
in scope gezet             : 1.931   (alle 412 UUID-rijen + 1.500 willekeurige)
ISRC binnen die scope      : 841 -> 1.410
MusicBrainz-ids gevonden   : 361
artiest = UUID             : 412 -> 0
rijen hersteld             : 412     (waarvan 352 duplicaten verwijderd)
rijen totaal               : 66.378 -> 66.026
```

Kosten: ~48 ms per bestand op de externe schijf, dus de volledige backfill over
66.378 rijen duurt ongeveer **een uur** — eenmalig, hervatbaar, en zonder audio
te decoderen.

### Wat dit met fase 3 doet

Het plan zei: *verzin een stabiele synthetische sleutel*. Dat is nu de tweede
keus. De eerste is **de identiteit gebruiken die er al ligt**, in deze volgorde:

1. `release_track_mbid` — edition-specifiek, onderscheidt precies de dubbele
   edities waar `match_key` op stukloopt.
2. `recording_mbid` / `isrc` — recording-identiteit.
3. pas daarna een deterministische synthetische sleutel voor de rest.

Twee dingen om niet te vergeten. **Roon zelf heeft geen enkele identifier** — de
Browse-API geeft er geen, dus dit repareert de Roon↔bestand-join *niet*, alleen
de bestandskant. En de dekking is geen 100%: ná de backfill draagt naar
verwachting ~80% een ISRC en ~24% een MB-id, dus een synthetische terugval blijft
nodig. Een sleutel die voor de ene helft een ISRC is en voor de andere een hash
is prima — zolang het schema in de sleutel zelf staat (`isrc::…`, `mb::…`,
`k::…`), net zoals `local::` en `import::` dat nu al doen.

**Wat we bewust níét overnemen van DroppedNeedle:** de MusicBrainz-matcher en de
reviewwachtrij. DN heeft daar maanden en negen matcher-bugs in zitten, haalt er
43% mee, en RoonSage heeft het niet nodig om zijn bibliotheek te tonen. Als
RoonSage ooit MB-identiteit wil die niet in de tags staat, is DN's
`local_track_external_identities` per `file_path` te lezen — 60.174 van de 66.378
paden zijn bij allebei bekend, en 25.470 daarvan hebben er al een. Dat is een
koppeling tussen twee projecten, dus een beslissing voor Casper, geen
implementatiedetail.

## 5e. De sleutel moest de album meenemen — gemeten (2026-08-23)

Om te weten wat fase 3 écht moet oplossen is de bibliotheek op een kopie
**volledig herbouwd uit alleen de bestanden** — Roon-rijen weg, alles opnieuw uit
de analyzer. Dat legde meteen een fout in fase 1 bloot: de lokale rij-id was
`local::<match_key>`, en `match_key` is bewust albumvrij (edities en boxsets
lopen uiteen). Dus **dezelfde opname op twee albums viel samen op één primaire
sleutel**: 66.377 geanalyseerde bestanden werden 59.517 rijen — 6.860 tracks
verdwenen zonder een spoor.

De id is nu `local::<album>|<artiest>::<match_key>`. De `image_key` blijft
bewust op `match_key` alleen: `/artwork` zoekt een bestand op inhoud, en twee
rijen van dezelfde opname mogen dezelfde hoes én dezelfde cache delen.

Daar hing één gevolg aan: met het album in de sleutel landt een gecorrigeerde
albumtag op een **nieuwe** rij, en bleef de oude achter voor een album zonder
bestanden. De ingest ruimt die nu op — met dezelfde rem als de Roon-walk
(`finishSyncRun(pruneStale:)`): een payload die met meer dan de helft kromp is
een afgebroken lezing, geen bibliotheek die halveerde, en dan wordt er niets
gewist.

### De bibliotheek zonder Roon, gemeten

| | met Roon | alleen bestanden |
|---|---|---|
| tracks | 89.752 | **65.759** (van 66.377 aangeboden) |
| albums | 13.153 | 9.908 |
| artiesten | 6.563 | 4.886 |
| met albumhoes | 89.680 | **65.759 — 100%** |
| **met jaartal** | **1.071** | **59.136** |
| sonisch bereikbaar | 49.166 | **60.621** |
| MB-genres (los van Roon) | — | 177.756 rijen |

Twee dingen springen eruit. **Roon levert vrijwel geen jaartallen** — 1.071 van
89.752, omdat de Browse-API het jaar alleen in een subtitle-string zet die lang
niet altijd te parsen is; de bestandstags geven er 59.136. En de standalone
bibliotheek is **sonisch groter** dan de Roon-bibliotheek: 60.621 tegen 49.166
bereikbare tracks, want elk geanalyseerd bestand heeft nu een rij.

Het verschil in aantallen (89.752 → 65.759) is geen verlies: de Roon-kant telt
~13.175 Qobuz-only tracks mee én dubbele edities van hetzelfde album. De 618 die
nog wegvallen zijn dezelfde opname twee keer op één album.

**Conclusie voor fase 3.** De bibliotheek kán al zonder Roon, en is op twee punten
beter. Wat er nog aan vast zit is de identiteit van de Roon-rijen zelf
(`tracks.id` = een sessie-sleutel) en de Qobuz-laag (fase 4).

## 5f. De omslag — de analyzer is nu de primaire bak (2026-08-23)

> User, halverwege de uitvoering: *"Ja bak 2 moet dus de belangrijkste bak zijn.
> De Roon bak is enkel voor als ik via zone wat wil afspelen. Maar RoonSage moet
> dus een zelfstandige speler worden die zijn eigen muziek indentificatie heeft
> en zelfstandig is. Zelfs als Roon wegvalt moet alles gewoon werken. Roon
> control is dan iets ernaast."*

Tot hier vulde de ingest alleen de gaten: elke Roon-rij won. Dat is omgedraaid.

**De ingest neemt élk geanalyseerd bestand op**, niet alleen wat Roon miste, en
verdringt daarna de Roon-rijen die de analyzer nu bezit. Voordat zo'n rij
verdwijnt geeft hij zijn genres over: Roon's genrehiërarchie hangt aan de rij
(`track_genres.track_id`, `ON DELETE CASCADE`), en 1,2% van de geanalyseerde
tracks heeft alleen een Roon-tag als genre.

**De walk schrijft niet meer wat de analyzer al bezit.** Zonder dat zou elke
Roon-walk ~51.000 rijen schrijven die de eerstvolgende feature-sync weer
verdringt. Op een machine waarvan de analyzer nog niets heeft gelopen is die set
leeg en gedraagt de walk zich exact zoals altijd — een verse installatie blijft
dus werken.

**Wat er van Roon overblijft** is precies wat de analyzer níét kan hebben: geen
bestand op schijf. Dat is de Qobuz/streaming-laag, plus de rijen die Roon anders
spelt dan de tags (klassiek, vooral).

### Gemeten op de echte bibliotheek

```
tracks                     : 89.752 -> 90.759
  waarvan van de analyzer  : 65.759   (élk geanalyseerd bestand)
  waarvan van Roon         : ~25.000  (Qobuz + anders gespeld)
analyzedTrackIdentities    : 49.166 -> 60.658
```

**Wat hier nog niet af is.** De ~25.000 resterende Roon-rijen bevatten naast de
13.175 echte Qobuz-tracks ook ~10.700 die wél op schijf staan maar onder een
andere spelling — dubbelingen die de fuzzy matcher niet pakt. Harde identiteit
(ISRC, sinds vandaag gelezen) is daar het gereedschap voor, maar Roon levert zelf
geen identifier, dus die kant blijft matchen op naam.

## 6. Maten om achteraf te toetsen

| maat | vóór | nu | doel |
|---|---|---|---|
| rijen uit `analyzedTrackIdentities()` | 49.166 | **64.219** | ✅ fase 1 |
| feature-rijen zonder `tracks`-rij | 19.537 | **4.484** (verweesd, zie 5b) | ✅ fase 1 |
| lokale rijen met een vindbare hoes | — | **99%** (198/200 steekproef) | ✅ fase 2 |
| tracks in een bibliotheek zonder Roon | — | **65.759** van 66.377 bestanden | ✅ |
| bestanden met een harde identiteit gelezen uit de tags | 52% (sidecar) | **73%** binnen de gemeten scope | ~80% na de volle backfill |
| rijen met een UUID als artiestnaam | 412 | **0** | ✅ |
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
