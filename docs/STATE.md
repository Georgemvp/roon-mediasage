<!-- ═══ START HIER (kopieer dit als prompt voor een nieuwe sessie) ═══
Lees docs/STATE.md en pak de eerstvolgende open stap uit de genummerde lijst hieronder.
Werk incrementeel: per batch bewerken → cd native/RoonSage && swift build && swift test
→ commit → (push+tag alleen als Casper daar in dat gesprek om vraagt) → STATE.md bijwerken.
Houd dit bestand onder ~70 regels. Historie staat in docs/STATE-archief-2026-08-23.md.
═══════════════════════════════════════════════════════════════════ -->

## Goal
Van monoliet naar een snelle, stabiele Plexamp/Symfonium-achtige client. Maatstaf is
iOS: snel en zonder bugs. Snoeien is het middel, niet het doel.

## Now
**Plex-migratie: fases 1 t/m 3 LIVE op de mini, fase 4a gebouwd en getagd.**
`analyzer-v1.1.215` draait, `plex_sync_enabled` staat aan, de echte import is gedraaid:
tracks 89.752 → 96.644 (plex 65.719 / roon 30.925), onbereikbare analyses 19.537 → 8.959.
Backup vóór de import: `library-pre-plex-20260823-161349.db`.

Sindsdien getagd t/m **v1.10.287 / ios-v1.7.253 / analyzer-v1.1.217**: Plex-inlog per
apparaat (PIN-flow, Keychain) en rechtstreeks afspelen vanaf Plex. 1110 tests, 8 skipped,
0 failures; release-build groen; lokalisatie 0 missend; lint 474 = baseline.

Nog UIT (bewust, zet ze aan in Instellingen → Plex): `plex_sonic_enabled`,
`plex_direct_play_enabled`. Beide hebben een Plex-koppeling op dat apparaat nodig.

**Openstaande beslissing van Casper:** waar gaan `listening_history` (44.157 rijen),
`track_feedback` en `playlists` heen als de analyzer optioneel wordt? Aanname nu:
client houdt ze zelf, analyzer wordt sync-peer — Plex accepteert geen teruggedateerde
historie-import, dus verhuizen zou die data vernietigen.

## Next
1. ~~CLAP-modellen uit de clients~~ AF · 2. ~~STATE opschonen~~ AF
3. ~~PlexLibrarySource + PlexSyncService~~ AF (`7ad4a0b`, `eda751a`). Artwork lost op via
   de bestaande /artwork-route; geen aparte resolver nodig.
3b. ~~Fase 2: `/nearest` voor vergelijkbaar~~ AF (`5edb9a2`). ~~Fase 3: Roon-walk
   degradeert~~ AF (`bc4c514`). Fase 4 (audio/offline van Plex) en fase 5 (share-server
   krimpen) staan nog open — zie PLEX_MIGRATION.
4. ~~RadioEngine-signatuur~~ AF (`57a66b1`). De audit-aanname "10 motoren samenvoegen" was
   fout — zie de commit; er valt hier niets meer samen te voegen.
5. `RoonClient` opbreken: 13.041 regels / 547 functies / 115 properties -> < 2.000.
6. UI snoeien: 31 navigatiebestemmingen -> ~10, gemeten op echt gebruik via `/play-stats`.
7. Beslissen over Plex als volwaardige catalogus + streaming-/transcodelaag (§ Decisions).
   Zou ~2.800 regels eigen code kunnen vervangen (LibraryShareServer, LocalAudioCache,
   LocalTranscode, AudioTranscoder, Downloads, Offline, ArtworkProvider, LibrarySyncService).
8. Opruimen: 8.038 analyzer-rijen wijzen naar bestanden die niet meer bestaan (steekproef
   300/300 weg), waarvan 1.638 in `MuziekDown` — de SoulSync-verhuizing.

## Constraints
- "Geen Apple TV / tvOS (scope is strikt macOS 14+ en iOS 17+)" (user, 2026-08-23)
- "Alle UI-teksten/labels zijn in het Nederlands, code/symbolen/commentaren/APIs in het Engels" (user, 2026-08-23)
- "Geen AppKit in gedeelde modules (RoonSageCore, RoonSageUI, AudioAnalysis, AnalyzerCore); houd RoonProtocol en RoonSageCore platform-onafhankelijk" (user, 2026-08-23)
- "Zelfs als Roon wegvalt moet alles gewoon werken. Roon control is dan iets ernaast" — Roon is uitvoer, geen catalogus. Niets mag een werkende Roon-verbinding vereisen om de bibliotheek te tonen (user, 2026-08-23)
- "Ik wil echt toe naar een snelle plexamp/symphonica app want de roonsage app op ios is te sloom en te bugged" (user, 2026-08-23)
- "Behalve lord of the rings trilogie, die moeten in hdr etc blijven" — FileFlows op /Volumes/8tbDrive: LOTR nooit aanraken (user, 2026-07-29)
- "Test alle functies in RoonSage iOS, gebruik enkel max mini als zone" (user, 2026-07-22)
- "Ik vind het niet erg als het dagen duurt … zoals bij audiomuse" — analysekwaliteit gaat vóór analyseduur (user, 2026-07-13)
- "maak gebruik van een external drive" — zwaar datasetwerk op /Volumes/Elements (user, 2026-07-08)
- Commit + push + tag per geverifieerde batch, alle drie de namespaces (user, 2026-07-06)
- NIET tests verzwakken om ze groen te krijgen (hard stop)
- Nooit de client-app op de mini deployen — alleen de analyzer
- CLAPEngine mag NOOIT een dependency van RoonSageCore/RoonSageUI worden: dat blaast elke client weer op met ~746 MB

## Decisions
- **BESLIST 2026-08-23 (user: "Ja"):** Alchemy, Song Paths en Sonic DNA blijven → CLAPEngine blijft, de analyzer krimpt tot batchjob i.p.v. server, en vergelijkbaar/radio delegeert naar Plex. Plan: `native/docs/PLEX_MIGRATION.md`. Getoetst: Plex' `/nearest` geeft HTTP 200 vanuit een gewone client (99,94% van de tracks geanalyseerd), maar levert géén BPM/toonsoort/loudness en géén ruwe vectoren.
- Sonic-fit CLAP zit achter `SonicFitScoring`; alleen `ClapSonicFit` in de analyzer-app registreert. Client = provider nil = pre-sonische ordening (2026-08-23).

## Facts
- test/build: `cd native/RoonSage && swift build && swift test`; release: `swift build -c release --product RoonSage`; lint: `swiftlint lint --config .swiftlint.yml`
- iOS: `cd native/iosapp && xcodegen generate`, dan `xcodebuild -project RoonSageiOS.xcodeproj -scheme RoonSageiOS -sdk iphonesimulator -derivedDataPath build/dd build`
- Tag-namespaces: app `vX.Y.Z` · iOS `ios-vX.Y.Z` · analyzer `analyzer-vX.Y.Z`. Laatst getagd: v1.10.285 / ios-v1.7.251 / analyzer-v1.1.215.
- Lokaal signeren KAN NIET (`security find-identity -v -p codesigning` → 0 valid identities), dus deploy loopt altijd via de CI-DMG.
- Deploy = handmatig: CI-DMG downloaden → `bootout` → installeren → `bootstrap`. Lokaal signeren kan niet meer. Een tag levert een DMG, geen uitrol.
- GUI-verificatie: `~/bin/rs-sim` (iOS-simulator) en `~/bin/macui` (analyzer-app). Volledige route in het archief onder ## Facts.
- Metingen 2026-08-23: 85.948 regels eigen Swift / 454 bestanden · 82 views · 50 migraties · 17 externe API's · 1 dependency (GRDB) · 1074 tests.

## Open items
- Feed: "Beste albums van de 2000's" en "Meer in pop/rock" ontbreken — er is geen generator voor (2026-08-23)
- Qobuz `playlist/get` geeft 503 → AI-radio-sync landt niet (sinds 2026-07-19)
- `dedup-migrate.sql` moet periodiek herdraaien tot de walker updatet i.p.v. dupliceert; `markAllForReanalysis` (FeatureStore.swift:428) maakt duplicaten
- SoulSync-nestelbug: verplaatsing gedaan, 86 GB opruimen nog niet (2026-07-18)
- Vijf tags zonder GitHub-release: v1.10.173/174/180/181/182 (2026-07-18)
- Sidecar-bloat: metadata.db 423 → 800 MB; `explicit` is NULL voor alle rijen (CSV-parsebug)
- SEC-M2: cleartext secrets over 5766/5767 — TLS of ZeroTier-only, architectuurbeslissing
- `searchTracks` conflateert hard-fail en leeg naar `resolveTrackID`
- Skip re-steer vangt alleen skips via de app-`next()`, niet Roon-zijdige
- `CLAPEmbeddingTests.testEmbeddingMatchesGolden` crasht onder geheugendruk (MPSGraph); env-vlag `ROONSAGE_CLAP_CPU_ONLY` is de workaround
- Tweede analyzer-autostart bestaat nog maar is onschadelijk; bron niet vastgesteld (2026-08-22)

## Failed attempts
- ATTEMPT 1 [L1] (2026-08-23, jaartallen): `COALESCE(excluded.year, year)` op de ON CONFLICT-tak van `replaceAlbumTracks` → loste het niet op; details in het archief.
