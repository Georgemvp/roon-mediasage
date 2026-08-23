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

### Fase 1 — Plex als bibliotheekbron ✅ AF (`7ad4a0b`, `eda751a`)
`PlexClient` + `ingestPlexTracks` + `PlexSyncService`. Staat **default uit**.
Geverifieerd op een kopie van de echte `library.db`: 65.719/65.719 ingevoerd,
58.827 Roon-rijen verdrongen, 16,4 s.

**Volgende concrete stap:** `plex_sync_enabled` aanzetten op de mini en één run
op de échte database laten draaien.

### Fase 2 — vergelijkbaar/radio delegeren aan Plex
Eén `PlexSonicClient` rond `/nearest`, met `SonicSelection.dropNearDuplicates`
erachter. Vervangt de kNN-paden in `RoonClient+Features` (SimilarTracks) en de
station-opbouw. Achter een schakelaar, zodat de eigen `RadioEngine` de terugval
blijft als Plex een endpoint wijzigt.
*Raakt niet:* Alchemy, Song Paths, Sonic DNA — die hebben vectoren nodig.

### Fase 3 — de Roon Browse-walk uitzetten als catalogus
`LibrarySyncService` (268 regels) van "bron" naar "alleen de Qobuz/streaminglaag".
Plex dekt de bestanden; Roon levert nog wat er geen bestand voor is
(~13.175 Qobuz-only tracks).

### Fase 4 — audio van Plex in plaats van :5766
`AudioStreaming` (101) + `AudioTranscoder` (315) + `LocalTranscode` (129) +
`LocalAudioCache` (364) + `RoonClient+Downloads` (202) +
`DatabaseManager+Offline` (130) vervangen door Plex' stream-/transcode-/sync-API.
**Vereist Plex Pass** — dat heeft de user.

### Fase 5 — de analyzer krimpt tot een kleine server

> **Correctie (2026-08-23).** Een eerdere versie van dit plan zei "de analyzer
> stopt met server zijn". Dat klopt niet: een iPhone kan de 66.239 embeddings
> niet zinnig lokaal houden (~135 MB) en het CLAP-tekstmodel al helemaal niet,
> dus er moet iets blijven serveren. Hij wordt geen batchjob — hij wordt een
> **kleine** server.

```
nu:      :5767  44 endpoints  +  :5766  8 endpoints   = 52
straks:  :5766  ~4 endpoints  (/features, /embeddings, /text-embed, /health)
```

Wat vervalt: de hele bibliotheek-mirror (`LibraryShareServer`, 1.172 regels), de
playback-proxy, de offline-wachtrij, `/audio`, `/artwork`, en de
apparaatgoedkeuring voor audio. Wat blijft is een klein ding dat vectoren en
scalars uitdeelt.

Het tokenprobleem verdwijnt daarmee niet volledig — de resterende endpoints
hebben nog steeds auth — maar wel op de plek waar het pijn doet. Volgens de eigen
memory is een verlopen client-token de #1 oorzaak van "wil niet verbinden"; na
deze fase valt bij een auth-storing een aanbeveling weg in plaats van dat de
muziek stopt, want het audio-pad ligt dan bij Plex.

**Geschatte omvang die vervalt:** ~2.800 regels in fase 3–5, plus de ZeroTier-
afhankelijkheid en de twee poorten. Wat blijft: `RoonProtocol`, `Theme`/
`NowPlaying`, `Camelot.swift`, `SonicSimilarity`/`SonicSelection`, CLAPEngine en
een afgeslankte embedding-API.

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
