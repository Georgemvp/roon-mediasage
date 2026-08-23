# Van monoliet naar Plex-client — gefaseerd migratieplan

> Opgesteld 2026-08-23. Alle getallen zijn gemeten tegen de draaiende Plex- en
> analyzer-installaties op de mini, niet geschat.
>
> **Beslissing van de user (2026-08-23):** Alchemy, Song Paths en Sonic DNA
> blijven. Dus CLAPEngine blijft, en de analyzer krimpt tot batchjob — hij wordt
> niet geschrapt.

## 1. Wat Plex bewezen wél doet

| | gemeten |
|---|---|
| Muzieksectie | `/Volumes/4tbdrive/Muziek` — dezelfde map die de analyzer walkt |
| Tracks | 65.738 geïndexeerd, 65.719 via de API met bestandspad |
| Sonic Analysis | 65.699 tracks · 8.521 albums · 3.413 artiesten (99,94%) |
| `GET /library/metadata/<rk>/nearest` | **HTTP 200 vanuit een gewone client**, alleen `X-Plex-Token`; echte distance-gradiënt; werkt op track, album én artiest |
| Identiteit | `ratingKey` is stabiel (Roon's `item_key` is sessie-vluchtig) |
| Bestandspad ↔ analyzer | 58.308 exacte joins ná NFC-normalisatie |

De veelgehoorde kanttekening "sonic-data is Plexamp-only, ongedocumenteerd" is
getoetst en klopt niet in de praktijk: `curl` met alleen het token krijgt 200.
Ongedocumenteerd blijft het wel — het kan bij een Plex-update breken, dus de
aanroep hoort achter één client te zitten die je in één plek kunt repareren.

## 2. Wat Plex bewezen níét doet

Gecontroleerd op een volledige metadata-payload met `includeLoudnessRamps=1`:
de enige feature-achtige velden zijn `Mood` en `musicAnalysisVersion`.

- **Geen BPM, geen toonsoort/Camelot, geen loudness.**
- **Geen ruwe vectoren via de API.** Die zitten in `Track.tree` (55 MB,
  ongedocumenteerd binair). `/nearest` geeft k-NN vanaf een bestaande track —
  geen `seed − X + Y`.
- **Geen near-duplicate-hygiëne.** Rauwe `/nearest` op "I'm Mandy Fly Me" gaf
  vijf andere kopieën van hetzelfde nummer plus 3× "Lazy Ways" terug.
  `SonicSelection.dropNearDuplicates` blijft dus nodig, ook als de k-NN van Plex
  komt.

Daarom blijven Camelot/DJ Set/Live DJ, Song Paths, Alchemy, Sonic DNA en de
discovery sonic-fit op eigen embeddings draaien.

## 3. Doelplaatje

```
Plex Media Server (mini)   catalogus · streaming · transcode · remote · offline · artwork
  + Sonic Analysis         vergelijkbaar / radio / mixes        → vervangt de kNN-paden
Analyzer (batchjob)        BPM · toonsoort · loudness · CLAP-embeddings → sidecar
                           GEEN HTTP-server meer, geen token, geen ZeroTier
Roon (RoonProtocol)        uitvoer: zone-casting
App                        Plex-client + DJ/curatie + Roon-casting
```

## 4. Fases

Elke fase eindigt groen en laat de app werkend achter.

### Fase 1 — Plex als bibliotheekbron ✅ AF EN LIVE (`7ad4a0b`, `eda751a`)
`PlexClient` + `ingestPlexTracks` + `PlexSyncService`. Eerst geverifieerd op een
kopie van `library.db` (65.719/65.719, 16,4 s), daarna **echt gedraaid op de mini**
onder `analyzer-v1.1.215`:

```
tracks                    89.752 → 96.644   (plex 65.719, roon 30.925)
analyses zonder trackrij  19.537 →  8.959
```

Backup vóór de import: `backups/library-pre-plex-20260823-161349.db`.

### Fase 2 — vergelijkbaar/radio via Plex ✅ AF (`5edb9a2`)
`PlexClient.nearest` achter `plex_sonic_enabled`, met
`SonicSelection.dropNearDuplicates` erachter en `RadioEngine` als terugval.
*Raakt niet:* Alchemy, Song Paths, Sonic DNA — die hebben ruwe vectoren nodig.

### Fase 3 — Roon degradeert tot de laag zonder bestanden ✅ AF (`bc4c514`)
`fileBackedOwnedKeys` filtert bij het **schrijven**, op trackniveau: de walk maakt
geen rij meer aan voor wat Plex bezit, en een half gedekt album krijgt de rest
gewoon van Roon. Wat overblijft is de Qobuz/streaminglaag — gemeten 30.925 rijen.

### Fase 4a — inloggen + rechtstreeks afspelen ✅ AF (`f01977a`, `13ed12c`)
De blokkade was niet de stream-URL maar de auth: `PlexClient.localToken()` leest
het **admin**-token uit `Preferences.xml` en dat bestaat alleen op de
servermachine. Dat naar een iPhone sturen zou een volledig-toegang-credential over
het netwerk zetten. Dus `PlexAuth`: plex.tv PIN-flow → eigen token per apparaat →
Keychain. Daarna is afspelen klein: `plexStreamURLs` → `streamURLOverride`.

Geverifieerd tegen de echte server: `HTTP 206 audio/flac`, dus range-support en
dus seeken. **Nog niet op een echt toestel gespeeld** — het bewijs is HTTP plus
unit-tests, niet AVPlayer op een iPhone.

### Fase 4b — artwork, offline en transcode van Plex (OPEN)
Wat nu nog via de analyzer loopt en naar Plex kan:
`AudioStreaming` (101) · `AudioTranscoder` (315) · `LocalTranscode` (129) ·
`LocalAudioCache` (364) · `RoonClient+Downloads` (202) ·
`DatabaseManager+Offline` (130) · `ArtworkProvider` (141).
De `thumb` wordt al bij de sync opgeslagen. **Vereist Plex Pass** voor
transcode-sessies en de sync/download-API.

### Fase 5 — de analyzer krimpt tot een kleine server (OPEN)

> **Correctie (2026-08-23).** Een eerdere versie zei "de analyzer stopt met server
> zijn". Dat klopt niet: een iPhone kan de 66.239 embeddings niet zinnig lokaal
> houden (~135 MB) en het CLAP-tekstmodel al helemaal niet. Hij wordt geen
> batchjob — hij wordt een **kleine** server.

```
nu:      :5767  44 endpoints  +  :5766  8 endpoints   = 52
straks:  :5766  ~4 endpoints  (/features, /embeddings, /text-embed, /health)
```

Wat vervalt: de bibliotheek-mirror (`LibraryShareServer`, 1.172 regels), de
playback-proxy, de offline-wachtrij, `/audio`, `/artwork`, en de
apparaatgoedkeuring voor audio.

Het tokenprobleem verdwijnt niet volledig — de resterende endpoints hebben nog
auth — maar wel waar het pijn doet: bij een auth-storing valt dan een aanbeveling
weg in plaats van dat de muziek stopt.

### Openstaand vóór fase 5: waar gaat de gebruikersdata heen?

`listening_history` (44.157 rijen), `track_feedback` en `playlists` staan alleen in
`library.db` op de mini. Wordt de analyzer optioneel, dan verdampt dat.
**Aanname nu:** de client houdt ze zelf en de analyzer wordt sync-peer — Plex
accepteert geen teruggedateerde historie-import, dus verhuizen zou die data
vernietigen. Dit is Caspers beslissing en nog niet bevestigd.

**Geschatte omvang die vervalt in fase 4b–5:** ~2.800 regels, plus de
ZeroTier-afhankelijkheid en één van de twee poorten. Wat blijft: `RoonProtocol`,
`Theme`/`NowPlaying`, `Camelot.swift`, `SonicSimilarity`/`SonicSelection`,
CLAPEngine en een afgeslankte embedding-API.

## 5. Bekende risico's

1. **`/nearest` is ongedocumenteerd.** Isoleer hem in één client; houd
   `RadioEngine` als terugval (fase 2 doet dat).
2. **Plex Pass is een vereiste** vanaf fase 4 (transcode-sessies, sync/download).
3. **Qobuz blijft buiten Plex.** Losse aankopen landen als bestanden in de
   Plex-map en worden vanzelf meegeïndexeerd; de streaminglaag blijft een tweede
   bron.
4. **8.038 analyzer-rijen wijzen naar bestanden die niet meer bestaan**
   (steekproef 300/300 weg; 1.638 in `MuziekDown`). Opruimen vóór fase 5, anders
   verhuist die rommel mee naar de sidecar.
