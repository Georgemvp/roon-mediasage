# Benchmark: wat Lidarr en DroppedNeedle RoonSage kunnen leren

Opgesteld 2026-08-08. Bronnen bestudeerd via shallow clone:
`github.com/lidarr/Lidarr` (GPL-3.0) en `github.com/DroppedNeedle/DroppedNeedle` (AGPL-3.0).
Bevindingen over RoonSage zijn geverifieerd tegen de code in `native/` op die datum.

## Licentie-hek (bepalend, niet onderhandelbaar)

| Project | Licentie |
|---|---|
| Lidarr | GPL-3.0 |
| DroppedNeedle | AGPL-3.0 |
| **RoonSage** | **MIT** |

Beide bronnen zijn copyleft, RoonSage is MIT. Er wordt **geen regel code overgenomen** —
alleen mechanismen bestudeerd en zelfstandig opnieuw gebouwd. Dit is dezelfde regel die al
gold bij de vier discovery-verbeteringen van 2026-08-08 (zie `docs/STATE.md` ## Done).
Geen bestandsnamen, geen structuur-één-op-één, geen vertaalde functies.

---

## 1. Hoe de twee programma's werken en geschreven zijn

### Lidarr — C#/.NET 6 backend + React/Redux frontend, ±4400 bestanden

Volwassen server-app uit de \*arr-familie (fork-lijn van Sonarr/NzbDrone). De interessante
delen zitten niet in de muziekfunctionaliteit maar in het **applicatie-frame**:

- `src/NzbDrone.Core/Messaging/Commands/` — alle achtergrondwerk is een `Command` in een
  prioriteitswachtrij: dedupe via `CommandEqualityComparer`, `CommandStatus`, `CommandPriority`,
  voortgang via `ProgressMessaging/`. Eén plek waar werk in gaat, één plek waar status uit komt.
- `src/NzbDrone.Core/Jobs/` — `ScheduledTask` + `TaskManager`: interval per taak, `LastExecution`
  gepersisteerd in de DB, gecached. De scheduler kijkt wie er "pending" is; er is geen enkele
  `while(true){sleep}`-lus in de applicatiecode.
- `src/NzbDrone.Core/HealthCheck/` — ±30 losse checks (`Checks/*.cs`) achter één
  `HealthCheckService`, deels **event-gedreven** (een check draait als er iets gebeurt),
  deels gepland, met debounce en een opstart-grace-period. Resultaten zijn zichtbaar in de UI.
- `src/NzbDrone.Core/Backup/` + `Housekeeping/` — geplande DB-backup met retentie,
  `DatabaseRestorationService` bij corruptie, en periodieke opruiming van weesrijen.
- `src/NzbDrone.SignalR/` — de UI krijgt **push**, geen polling.
- `frontend/src/Styles/Themes/{dark,light}.js` — een thema is één plat JS-object met ±80
  benoemde tokens; `App/ApplyTheme.tsx` schrijft ze bij mount als CSS-custom-properties op
  `documentElement`. Een thema toevoegen = één bestand. Daarnaast
  `Styles/Variables/{dimensions,fonts,zIndexes,animations}.js`.
- Grote lijsten zijn gevirtualiseerd (`react-window`), en `Components/` is een bibliotheek van
  ±60 kleine primitieven die overal hergebruikt worden.

### DroppedNeedle — Python/FastAPI backend + Svelte 5/Tailwind frontend, ±267k regels Python

Modernere, strak gelaagde codebase (`api/` → `services/` → `repositories/` → `infrastructure/`):

- `backend/infrastructure/sse_publisher.py` — multi-channel pub/sub over SSE met
  **snapshot-dan-deltas**: een late abonnee krijgt eerst de laatste stand per event-type, daarna
  alleen wijzigingen, plus een keepalive-comment zodat reverse proxies de stream niet knippen.
- `backend/middleware.py` — token-bucket rate limiting op **elke** route met per-pad-overrides,
  een expliciete smalle `_PUBLIC_PATHS`-frozenset (met de opmerking dat de oude prefix-match
  per ongeluk admin-routes vrijgaf), en slow-request-logging.
- `backend/infrastructure/crypto.py` — provider-tokens en secrets **versleuteld at rest**
  (Fernet), sleutel in een `.env` met `chmod 0600`.
- `backend/infrastructure/{resilience/{rate_limiter,retry},degradation,service_health}.py` —
  gedegradeerde modus als expliciet begrip: de app blijft draaien met minder bronnen en zegt
  dat tegen de gebruiker (frontend `DegradedBanner.svelte`).
- `backend/api/compat/{subsonic,jellyfin}/` — compatibiliteits-API's zodat bestaande clients
  werken zonder dat DroppedNeedle die clients hoeft te bouwen.
- `backend/infrastructure/plugins/{host,manifest,protocols}.py` — providers als plugins.
- Frontend: ±200 kleine Svelte-componenten, **per kaarttype een eigen skeleton**
  (`AlbumCardSkeleton`, `ArtistHeaderSkeleton`, `CarouselSkeleton`), daisyUI-thema als
  tokenobject in `app.css`, en zelf-gehoste fonts (geen externe calls) met een bewuste
  drieslag: Space Grotesk (display) / Hanken Grotesk (body) / Space Mono (cijfers).

### De rode draad

Beide projecten hebben iets wat RoonSage nog niet heeft: **een applicatie-frame onder de
features**. Werk is een object met status, gezondheid is een dienst, en de client krijgt push
in plaats van te pollen. RoonSage heeft daarentegen sterkere *domein*-code dan beide
(sonic DNA, CLAP-embeddings, harmonische DJ-logica) — daar valt niets te halen.

---

## 2. Snelheid

### S1. Vervang de 1,5 s-poll door een push-kanaal — grootste winst

**Bewijs:** `RoonClient+Remote.swift:214-222` pollt `/playback` elke 1,5 s zolang een client
verbonden is. `LibraryShareServer.swift:335` zet `Connection: close`, dus élke poll is een
nieuwe TCP-handshake; er is nergens in de Swift-bron een `ETag`, `If-None-Match`,
`gzip` of `Accept-Encoding` (grep over `native/RoonSage/Sources` → 0 treffers). Per client:
40 volledige snapshots + 40 verbindingen per minuut, ook als er niets verandert.

**Zij:** Lidarr duwt via SignalR; DroppedNeedle via SSE met snapshot-dan-deltas en keepalive.

**Voorstel:** een `GET /events`-SSE-endpoint op de share-server dat de bestaande
`PlaybackSnapshot` publiceert zodra hij verandert, met dezelfde token-gate. Client houdt één
verbinding open; de 1,5 s-lus blijft als fallback bestaan maar zakt naar 15 s zodra de stream
staat (netwerken waar SSE sneuvelt blijven werken). Neem het snapshot-dan-deltas-idee over:
bij connect eerst de huidige stand, daarna alleen wijzigingen.

**Acceptatie:** met één client verbonden dalen de verbindingen op :5767 van ±40/min naar
<5/min, en een zone-wissel is zichtbaar binnen 500 ms in plaats van tot 1,5 s.

### S2. Conditionele GET's + compressie

**Bewijs:** `/library` bouwt de volledige export (tientallen MB bij 53k–76k tracks). Er is een
cache op `last_sync` (`LibraryShareServer.swift:578-588`), maar de body gaat er onverkort en
ongecomprimeerd uit — ook als de client hem al heeft. Zelfde voor `/history`,
`/taste-analysis`, `/feedback`, `/playlists`.

**Voorstel:** `ETag` = de `last_sync`-signatuur die er al is; `304 Not Modified` bij een
matchende `If-None-Match`; `Content-Encoding: gzip` als de client het vraagt. De cachesleutel
bestaat al, alleen de HTTP-semantiek eromheen ontbreekt.

**Acceptatie:** een tweede `/library`-pull zonder tussenliggende sync geeft 304 met lege body;
een verse pull is minstens 4× kleiner over de lijn.

### S3. Keep-alive

**Bewijs:** `LibraryShareServer.swift:331-340` sluit elke verbinding.

**Voorstel:** HTTP/1.1 persistent connections (de parser leest al `Content-Length` en kan een
tweede request in dezelfde buffer aan). Scheelt een handshake per request, vooral merkbaar
over ZeroTier waar de RTT hoog is.

### S4. Eén scheduler in plaats van dertien losse lussen

**Bewijs:** achtergrondwerk is nu per feature een eigen `Task { while true { … sleep } }`:
`RoonClient.swift:426,455,487,513`, `+Discovery.swift:862,888`, `+Features.swift:185`,
`+DiscoverWeekly.swift:211,217`, `+Lastfm/ListenBrainzPlaylists.swift:29`,
`+ArtistRadio.swift:1597`. Geen gedeelde status, geen "wanneer draaide dit voor het laatst",
geen annuleren, geen voortgang, en bij een herstart begint alles opnieuw aan zijn eigen
initiële slaap.

**Zij:** Lidarr's `ScheduledTask` + `TaskManager` + `CommandQueue`.

**Voorstel:** een `TaskScheduler`-actor in `RoonSageCore` met een GRDB-tabel
`scheduled_tasks(name, interval_sec, last_execution, last_duration, last_status)` en een
`TaskRun`-model (queued/running/completed/failed + voortgang 0…1). Bestaande lussen worden
taken; de scheduler beslist wie mag draaien. Nieuwe endpoints `GET /system/tasks` en
`POST /system/tasks/{name}/run` (token-gated), plus een "Systeem"-scherm dat dit toont.
Dedupe zoals Lidarr: eenzelfde taak twee keer aanvragen zet er geen tweede in de wachtrij.

**Waarom het ook snelheid is:** nu kunnen discovery-run, feature-sync en artist-radio-sync
tegelijk op de mini vallen (16 GB, deelt de machine met Docker/Roon/Plex/rclone — zie de
constraint in `docs/STATE.md`). Eén wachtrij met prioriteit maakt dat stuurbaar.

### S5. Centrale rate-limiting en provider-status

**Bewijs:** elke externe client regelt zijn eigen tempo: `MusicBrainzClient.swift:200,216`,
`DeezerClient.swift:187`, `DiscogsClient.swift:117,128`, `QobuzClient.swift:728,748`,
`+ArtistRadio.swift:1655`. Zes implementaties van hetzelfde idee, en geen enkele weet iets
van de andere.

**Zij:** DroppedNeedle `infrastructure/resilience/{rate_limiter,retry}.py` + `degradation.py`;
Lidarr houdt per indexer een status bij met oplopende back-off na opeenvolgende fouten.

**Voorstel:** één `ProviderGate`-actor (token bucket per provider) + een `provider_status`-tabel
(consecutive_failures, disabled_until, last_error). Alle clients vragen een slot aan bij de
gate. Bij N opeenvolgende fouten gaat de provider tijdelijk uit en meldt de app dat als
gedegradeerde modus in plaats van stil te falen.

### S6. FTS5 voor zoeken

**Bewijs:** `Database/Schema.swift` heeft `idx_tracks_lower_title_artist` (regel 280) maar geen
FTS-tabel; GRDB — al een dependency — levert FTS5.

**Voorstel:** een `tracks_fts`-virtuele tabel (title, artist, album) met triggers, gebruikt door
LibraryView-zoek, CommandPalette en `/lyrics/search`. Bij 53k–76k tracks is dat het verschil
tussen een `LIKE`-scan en een indexlookup.

---

## 3. Functionaliteit

### F1. HealthCheckService

**Bewijs:** `/health` geeft nu `{status, tracks, hosts}` (`LibraryShareServer.swift:720-732`) —
verder niets. Bij een probleem (Roon-core weg, Qobuz-auth verlopen, analyzer niet bereikbaar,
schijf vol, match-rate ingezakt) merkt de gebruiker het pas aan een lege lijst.

**Zij:** Lidarr's ±30 checks, deels event-gedreven, met debounce en een grace-period bij opstart.

**Voorstel:** een `HealthCheck`-protocol + register. Startset, allemaal al meetbaar met bestaande
code: Roon-core bereikbaar · analyzer :5766 bereikbaar · vrije schijfruimte voor `library.db`
+ kunstcache · Qobuz-sessie geldig · Last.fm/ListenBrainz-token geldig ·
feature-match-rate onder drempel (`reconcileFeatureMatches` bestaat al) · laatste sync ouder dan
N dagen · apparaten in de wachtrij op goedkeuring · update beschikbaar · laatste discovery-run
`degraded` (het `v45_batch_degraded`-veld bestaat al). Uitkomst via `/health/detail` en een
badge in de menubar; DroppedNeedle's `DegradedBanner` is het UI-equivalent.

### F2. Backup + herstel van `library.db`

**Bewijs:** er is geen backupmechanisme; in `data/` staan handmatige `library_cache.db.bak`-
bestanden. De DB bevat inmiddels luistergeschiedenis, feedback, favorieten, bladwijzers,
playlists, radio-configs, labels en editorial-cache — deels **niet reconstrueerbaar** uit Roon.

**Zij:** Lidarr `Backup/BackupService` (gepland, met retentie) + `DatabaseRestorationService`.

**Voorstel:** geplande taak (via S4) die `VACUUM INTO` naar een tijdstempel-bestand doet,
N kopieën bewaart, en een "Herstel"-knop in Instellingen. Klein werk, groot vangnet.

### F3. Housekeeping

**Bewijs:** `editorial_cache`, `track_lyrics`, `recommendation_items`, `discovery_rejections`,
`artist_bio` (waarvan `docs/STATE.md` meldt dat de view hem niet meer aanroept) groeien
onbeperkt.

**Voorstel:** geplande opruimtaak — verlopen cache-rijen weg, batches ouder dan N maanden
opgeruimd, wezen verwijderd, daarna `VACUUM`. Lidarr doet dit als vaste taak.

### F4. Notificaties als provider-model

**Bewijs:** er is een discovery-digest, maar geen uitgaande notificaties.

**Zij:** Lidarr `Notifications/` — een providermodel met per-event-triggers en een Test-knop
per provider.

**Voorstel:** een `NotificationProvider`-protocol met eerst webhook + ntfy (en op iOS een
lokale notificatie). Events: weekly klaar · nieuwe discovery-batch · analyse afgerond ·
health degraded · nieuw album van een gevolgde artiest. De Test-knop is het detail dat het
verschil maakt: zonder testknop configureert niemand een webhook goed.

### F5. Import lists

**Bewijs:** `artist_watchlist` bestaat, maar wordt handmatig gevuld.

**Zij:** Lidarr `ImportLists/`; DroppedNeedle heeft `spotify_import_service`,
`lidarr_import_service`, `follow_service`.

**Voorstel:** periodieke import-bronnen die de watchlist voeden: Last.fm loved/top-artists,
ListenBrainz, een Qobuz-favorietenlijst. Sluit direct aan op de bestaande discovery-pijplijn.

### F6. Opgeslagen slimme filters

**Bewijs:** `FilteredTracksView.swift` filtert, maar filters zijn niet te bewaren; wél bestaat
al het patroon voor benoemde, opgeslagen configuraties (`radio_configs` + upsert-endpoint).

**Zij:** Lidarr `CustomFilters` + `AutoTagging`.

**Voorstel:** "Slimme lijsten" — zelfde opslagvorm als `radio_configs`, zelfde
server-of-record-endpoints, hergebruik van de bestaande filtermotor.

### F7. Versionering en documentatie van de share-API

**Bewijs:** routes worden met `hasPrefix` gematcht op ongeversioneerde paden
(`LibraryShareServer.swift:407-733`). De volgorde is al load-bearing — `/discover-weekly/refresh`
moet vóór `/discover-weekly` (regel 662), `/lyrics/search` vóór `/lyrics` (regel 702),
`/bookmark` moet expliciet `/bookmarks` uitsluiten (regel 467). Dat is een klasse bugs die
wacht op de volgende route.

**Zij:** DroppedNeedle serveert een OpenAPI-spec en houdt versies uit elkaar (`/api/v1/…`);
compat-API's zitten apart onder `api/compat/`.

**Voorstel:** exacte pad-matching in plaats van prefix (of een kleine routertabel met
methode+pad), een `/api/v1`-prefix voor nieuwe endpoints met de oude paden als alias, en één
markdown-bestand dat het contract vastlegt. Nu is de docstring bovenaan het bestand de
enige bron — en die loopt al achter (`/favorites`, `/bookmarks`, `/play-stats`,
`/on-this-day`, `/taste-timemachine`, `/year-review` staan er niet in).

### F8. Providerregister

**Bewijs:** de TIDAL-spike (`spike/tidal-streaming-provider`) introduceerde al een
`StreamingProvider`-protocol maar is niet gemerged.

**Zij:** Lidarr `ThingiProvider` + `Plugins/`; DroppedNeedle `infrastructure/plugins/`.

**Voorstel:** trek het protocol breder dan streaming: één registervorm voor
metadata-providers (MusicBrainz, Discogs, Deezer, Wikipedia, Last.fm) én streaming
(Qobuz, TIDAL), elk met eigen instellingen, status (uit S5) en een Test-knop. Dat maakt de
go/no-go op TIDAL bovendien goedkoper.

---

## 4. Design

### D1. Grotere componentbibliotheek, kleinere views

**Bewijs:** `Theme.swift` is 197 regels en dekt Spacing/Radius/Typography/Motion + `Card` +
`Badge` — een goede basis. Maar de schermen zijn groot: `LibraryView.swift` 1195 regels,
`NowPlayingView.swift` 883, `SettingsView.swift` 875, `RootView.swift` 730. Grote views zijn
waar ontwerpconsistentie stilletjes wegloopt (het bestaande commentaar op regel 100-103 zegt
dat letterlijk: drie concurrerende kaartrecepten bestonden naast elkaar).

**Zij:** Lidarr `Components/` ±60 primitieven; DroppedNeedle ±200 kleine Svelte-componenten.

**Voorstel:** breid de bibliotheek uit met wat nu per view opnieuw gebouwd wordt —
`SectionHeader`, `EmptyState` (bestaat als patroon, niet als component), `StatPill`,
`ProgressRow`, `ProviderCard` (bron + status + Test + instellingen — direct bruikbaar in
Instellingen voor Qobuz/Last.fm/Discogs/MusicBrainz), `Elevation`-schaal en een
`ZLayer`-schaal voor overlays. Splits daarna de drie grootste views per sectie op.

### D2. Skeletons per component in plaats van één generieke

**Bewijs:** er is `SkeletonRows` (ROADMAP B4) — één vorm voor alles.

**Zij:** DroppedNeedle heeft `AlbumCardSkeleton`, `ArtistHeaderSkeleton`, `CarouselSkeleton`
apart, zodat de laadstand exact de vorm van het echte element heeft en er geen sprong optreedt.

**Voorstel:** skeletons voor albumgrid, artiesthero en carrousel afzonderlijk.

### D3. Cijfers in een monospace-gezicht

**Bewijs:** `Typography` (Theme.swift:77-84) heeft title/heading/body/caption, alles systeemfont.
BPM, toonsoort, duur en percentages verspringen daardoor tijdens updates.

**Zij:** DroppedNeedle kiest bewust Space Mono voor cijfers naast twee tekstfonts.

**Voorstel:** `Typography.mono` = `.system(.body, design: .monospaced)`, toegepast op BPM/
Camelot/duur/percentage. Geen extra font nodig, alleen een token. Dynamic Type blijft intact.

---

## 5. Theme

### T1. Een echte palette in plaats van vaste systeemkleuren

**Bewijs:** `Appearance.swift` biedt ThemeMode (systeem/licht/donker) + 7 accenten — dat deel
is goed. Maar de semantische kleuren staan vast op systeemkleuren
(`Theme.swift:32-38`: `roonSuccess = .green`, `roonWarning = .orange`, `roonDanger = .red`,
`roonInfo = .blue`) en oppervlakken komen uit `.background.secondary` (regel 115, 126).
Er valt dus geen thema te wisselen: alleen de accentkleur beweegt mee.

**Zij:** Lidarr's thema is één plat object van ±80 tokens (`Styles/Themes/dark.js`) dat bij
mount als CSS-variabelen wordt gezet (`App/ApplyTheme.tsx`). Een thema toevoegen kost één
bestand en raakt geen enkele view.

**Voorstel:** hetzelfde idee, Swift-native:

```
struct ThemePalette {
    background, surface, surfaceRaised, separator: Color
    textPrimary, textSecondary: Color
    accent, success, warning, danger, info: Color
    shadow: Color
}
```

via `EnvironmentKey` (`\.palette`) aan de root gezet, met een ingebouwde set:
`system` (huidig gedrag, standaard) · `roonDark` · `roonLight` · `midnight` ·
`amoled` (echt zwart — precies wat de `WallDisplayView` wil). Accentkeuze blijft los, zodat
de bestaande 7 presets over elk thema heen werken. Migratie is mechanisch: `Color.roonSuccess`
→ `palette.success`, `.background.secondary` → `palette.surface`.

**Waarom dit de moeite is:** het is het enige punt waar RoonSage duidelijk achterloopt op
beide bronnen, en het is laag risico — geen gedragsverandering, alleen kleuren die door een
laag heen gaan.

### T2. Contrast valideren per thema

**Voorstel:** een unittest die per palette de WCAG-contrastratio tekst/achtergrond berekent en
onder 4,5:1 faalt. Voorkomt dat een nieuw thema onleesbaar in de release belandt. RoonSage
heeft `tappable44()` al (Theme.swift:50-52) — de toegankelijkheidsinstelling is er, deze test
sluit de kleurenkant.

### T3. `amoled` koppelen aan de Wall Display

De Wall Display draait mogelijk uren op een scherm. Een echt-zwart thema dat daar automatisch
op schakelt is functioneel (inbranden, stroom) én past bij de dominant-kleur-wash die er al is.

---

## 6. Veiligheid

De share-server is duidelijk al met aandacht gebouwd: constant-time tokenvergelijking
(`LibraryShareServer.swift:781-790`), per-IP brute-force-throttle (regel 373-376), CSRF-guard op
POST via verplichte JSON-content-type (regel 355-361), begrensde pending-queue (regel 165,
181-184), geclampte `Content-Length` (regel 766-777), en de updater verifieert de
code-signature én het team van de gedownloade app (`UpdateInstaller.swift:170-189`). Er lekken
ook geen secrets naar het log (grep over alle `Log.*`-aanroepen met token/key/password/secret →
alleen metadata, geen waarden). De punten hieronder zijn wat daar nog naast staat.

### V1. `/settings` stuurt secrets over onversleuteld HTTP — hoogste prioriteit

**Bewijs:** `LibraryShareServer.swift:642-647` serveert `SyncableSettings.exportCurrent()`; het
commentaar op regel 51-54 en 368-369 benoemt zelf dat daar API-keys, de Last.fm-sessie en het
Qobuz-wachtwoord in zitten. De server luistert op alle interfaces (`NWListener` zonder
interface-restrictie, regel 271) en adverteert bewust ook zijn ZeroTier-adres (regel 727,
736-757). Er is geen TLS: `send()` schrijft platte HTTP (regel 331-340).

Het gevolg: die secrets gaan in leesbare vorm over het LAN, en over ZeroTier over het pad
tussen de nodes. De token-gate beschermt tegen *ongeautoriseerde vraag*, niet tegen *meelezen*.

**Zij:** DroppedNeedle versleutelt provider-tokens at rest (Fernet, `infrastructure/crypto.py`)
en stuurt ze nooit naar de client — de server handelt namens de gebruiker. Lidarr ondersteunt
HTTPS met een eigen certificaat.

**Voorstel, in volgorde van waarde:**
1. **Stop met versturen.** Splits `SyncableSettings` in een niet-geheim deel (voorkeuren,
   drempels, zone-keuze) en een geheim deel. De architectuur ondersteunt dit al: clients
   sturen commando's naar de server (`POST /command`, `POST /generate`) en de server praat met
   Qobuz. Wat de client echt zelf nodig heeft, kan een kortlevend afgeleid token zijn.
2. Blijft er iets over dat wél moet syncen: versleutel het per goedgekeurd apparaat.
3. TLS op :5767 met een zelfondertekend certificaat en pinning in de client — dekt ook
   `/library` (die bevat je volledige luisterprofiel) en `/history`.

**Acceptatie:** een `tcpdump` op poort 5767 tijdens een client-sync bevat geen enkele
API-key of wachtwoord.

### V2. Grace-mode staat standaard open

**Bewijs:** `enforceToken` leest `UserDefaults.standard.bool(...)` (regel 91-94) — dat is
`false` tot iemand hem zet. Tot het eerste apparaat is goedgekeurd worden lees-GET's zonder
token gewoon geserveerd (regel 397-404). Secrets en mutaties zijn wél altijd gegate (regel
383) en zodra er één apparaat is goedgekeurd sluit het venster automatisch (regel 384) — dus
het raam is smal. Maar `/library`, `/history` en `/taste-analysis` (je volledige smaakprofiel)
liggen in dat venster open voor iedereen op het netwerk.

**Zij:** Lidarr heeft de optie "authenticatie uit" voor niet-lokale toegang verwijderd en dwingt
bij de eerste start een keuze af.

**Voorstel:** draai de standaard om — enforcement aan, en toon bij eerste start een
koppelscherm ("dit apparaat wacht op goedkeuring") in plaats van een open venster. De hele
pending-approval-machinerie bestaat al (regel 167-226); alleen de standaard klopt niet.

### V3. Loopback-uitzondering te breed

**Bewijs:** regel 370 slaat de hele auth-check over voor loopback-peers. Elk proces en elke
gebruiker op de mini kan daarmee Roon aansturen én `/settings` met secrets ophalen, zonder
token. De mini draait Docker, Plex, rclone en de \*arr-stack.

**Voorstel:** houd de uitzondering voor lezen, maar niet voor `/settings` en niet voor
mutaties — of maak het een instelling die standaard uit staat voor die twee categorieën.
Eén regel bij de `sensitive`-berekening op regel 383.

### V4. Apparaat-tokens in UserDefaults, plaintext

**Bewijs:** het master-token gaat naar de Keychain (regel 72), maar goedgekeurde
apparaat-tokens worden als JSON in `UserDefaults` gezet (regel 129-147). Dat is een leesbaar
plist-bestand zonder toegangscontrole — terwijl elk van die tokens volledige toegang geeft.

**Voorstel:** twee dingen, allebei klein: opslaan in de Keychain, en alleen een **hash** van het
token bewaren. De server hoeft de klare tekst nooit terug te lezen — hij vergelijkt alleen
(`isApprovedDevice`, regel 150-153). Vergelijken op hash blijft constant-time.

### V5. Rate limiting alleen op de auth-tak

**Bewijs:** `AuthThrottler` telt mislukte tokens (regel 373-376). Voor een *geldig* token is er
geen limiet, ook niet op de dure paden: `POST /generate` (regel 414) start een volledige
LLM-pijplijn, `POST /discovery/run` (regel 678) een discovery-pass van ~2 minuten, `/library`
serialiseert de hele bibliotheek. Een goedgekeurd apparaat met een bug in een retry-lus legt
de mini plat.

**Zij:** DroppedNeedle rate-limit **elke** route met token buckets en per-pad-overrides
(`middleware.py`).

**Voorstel:** per-token token bucket vóór de router, met strengere emmers voor `/generate`,
`/discovery/run` en `/library`, plus een "al bezig"-antwoord (409) als een run al loopt —
dat sluit aan op de scheduler uit S4.

### V6. Response-headers

**Bewijs:** `send()` (regel 331-340) zet alleen Content-Type, Content-Length en Connection.

**Voorstel:** `Cache-Control: no-store` op `/settings` en alles wat persoonsgegevens teruggeeft,
`X-Content-Type-Options: nosniff`. Klein, maar gratis.

### V7. Twee procedurele punten

- **SECURITY.md ontbreekt.** Lidarr heeft er één met een meldpunt en een reactietermijn. Voor
  een publieke repo met een netwerkdienst hoort dat erbij.
- **Secret-scan in CI.** `.env` staat correct in `.gitignore` (regel 87, geverifieerd: niet
  getrackt), maar er is geen gate die een toekomstige `git add -f` of een hardgecodeerde key
  tegenhoudt. Eén extra stap in `.github/workflows/native-tests.yml`.
- **Logredactie.** Er lekt nu niets, maar er is ook geen helper die het voorkomt.
  DroppedNeedle heeft `api/compat/common/redact.py` juist als vangnet. Een
  `Log.redacted(_:)`-helper is preventief goedkoop.

---

## 7. Voorgestelde volgorde

Gesorteerd op waarde-per-risico, en zo dat latere stappen op eerdere leunen.

**Fase 1 — veiligheid en fundament (eerst)**
1. V1 stap 1: secrets uit `/settings` halen · V2 enforcement standaard aan · V3 loopback
   versmallen · V4 tokens naar Keychain als hash. Samen één beveiligingsbatch, allemaal
   lokaal in `LibraryShareServer.swift` + `SyncableSettings.swift`.
2. S4 `TaskScheduler` — hierop leunen F1, F2, F3, F5 en V5.

**Fase 2 — snelheid**
3. S2 ETag + gzip, S3 keep-alive (klein, direct meetbaar).
4. S1 SSE-push (grootste winst, meeste werk).
5. S5 centrale rate-limiting + providerstatus, V5 per-token limieten.

**Fase 3 — functionaliteit**
6. F1 HealthCheckService (leunt op S4 en S5) → F2 backup → F3 housekeeping.
7. F7 route-tabel + `/api/v1` — doen vóór er nieuwe endpoints bijkomen, niet erna.
8. F4 notificaties, F5 import lists, F6 slimme lijsten, F8 providerregister.

**Fase 4 — design en thema**
9. T1 `ThemePalette` + T2 contrasttest + T3 amoled/Wall Display.
10. D1 componentbibliotheek + view-opsplitsing, D2 skeletons, D3 mono-cijfers.

**Los, wanneer het uitkomt:** S6 FTS5, V6 headers, V7 SECURITY.md + secret-scan.

Elk item afzonderlijk verifieerbaar: `cd native/RoonSage && swift test` +
`swift build -c release --product RoonSage` (en voor nieuwe SwiftUI-views de strengere
actor-isolatie-gate `-Xswiftc -swift-version -Xswiftc 6` uit `docs/STATE.md`), daarna
commit + push + tag in alle drie de namespaces.

---

## 8. Wat bewust NIET overnemen

- **Lidarr's DI-container en event-aggregator.** Dat frame past bij een .NET-app met tientallen
  providerimplementaties; RoonSage heeft actors en `async/await` en zou er alleen indirectie
  bij krijgen. Neem de *taak- en gezondheidsmodellen* over, niet het injectie-frame.
- **DroppedNeedle's Subsonic/Jellyfin-compat-API's.** RoonSage's client is Roon zelf plus de
  eigen apps; er is geen ecosysteem van derde-partij-clients om te bedienen. De MCP-server
  (`roonsage-mcp`) vervult die rol al.
- **De gelaagde repository-/service-provider-structuur van DroppedNeedle**
  (`core/dependencies/service_providers.py` is alleen al 2197 regels). RoonSage's
  extension-splitsing van `RoonClient` en `DatabaseManager` (ROADMAP C2/C5) doet hetzelfde werk
  met minder ceremonie.
- **Lidarr's download-/indexer-/qualityprofile-domein.** Dat is een ander product: RoonSage
  verwerft geen bestanden, het beveelt aan en speelt af.
