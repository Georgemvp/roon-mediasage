<!-- ═══ START HIER (kopieer dit als prompt voor een nieuwe sessie) ═══
Lees docs/STATE.md, native/docs/AUDIT_PLEX_CLIENT_2026_08_23.md en
native/docs/PLEX_MIGRATION.md. Doel: RoonSage wordt een Plex-standalone speler —
Plex is de bibliotheek, de RoonSage-server is een optionele uitbreiding.

Pak de eerstvolgende open stap uit ## Next. Werk incrementeel: bewerken →
cd native/RoonSage && swift build -Xswiftc -strict-concurrency=complete &&
swift test && swift build -c release --product RoonSage &&
./native/scripts/check-localization.sh --strict → commit → push + tag
(v / ios-v / analyzer-v) → STATE.md bijwerken.

Die strict-concurrency-vlag is niet optioneel: zonder hem brak CI op v1.10.292
terwijl het lokaal bouwde.

Test met GUI-automatisering, niet alleen met unit-tests: `~/gui-wakker.sh status`,
dan `~/bin/rs-sim setup` / `build` / `tap X Y` / `shot PAD`. Vrijwel elke echte bug
van 2026-08-23 kwam uit kijken naar het scherm, niet uit de testsuite.
═══════════════════════════════════════════════════════════════════ -->

## Goal
Een snelle, stabiele Plexamp/Symfonium-achtige speler. Plex levert de bibliotheek,
het streamen en de sonische analyse; de analyzer voegt BPM/Camelot/vectoren toe voor
DJ, Song Paths, Alchemy en Sonic DNA. De server is optioneel, nooit vereist.

## Now
Plex-migratie fases 1 t/m 4a zijn af en getagd t/m **v1.10.296 / ios-v1.7.262 /
analyzer-v1.1.226**. De mini draait `analyzer-v1.1.223`.

**Wat werkt en geverifieerd is:** Plex-import (65.719/65.719), `/nearest` voor
vergelijkbare nummers en radio's, Plex-inlog per apparaat (PIN → Keychain),
serverontdekking via plex.tv (incl. het externe Remote-Access-adres), rechtstreeks
afspelen (`HTTP 206 audio/flac`), formaatweergave, hoezen via Plex' photo-transcoder.

**Wat NIET geverifieerd is:** niemand heeft de Plex-koppeling op een toestel
voltooid — dat vraagt een code intypen op plex.tv/link. Tot dat gebeurt is
"Plex-only werkt" een redenering, geen meting.

**Openstaand op de mini:** de live database heeft nog 147.692 rijen voor 79.704
unieke nummers (~68.000 duplicaten, local + plex naast elkaar). De fix zit in
`analyzer-v1.1.221+`; de opschoning gebeurt bij de eerstvolgende Plex-sync. De
cadans is gewist en de analyzer herstart, dus die zou moeten lopen — controleer met
`sqlite3 "file:$HOME/Library/Application Support/RoonSage/library.db?mode=ro" "SELECT source, COUNT(*) FROM tracks GROUP BY source;"`

## Next
1. **Plex koppelen op een echt toestel** en de standalone-modus end-to-end doorlopen.
   Zonder die stap staat alles hierboven op aannames.
2. Duplicaten op de mini bevestigen als opgeruimd (zie hierboven).
3. Uit de audit, punt A: zichtbare Instellingen-knop, schermtitel niet afkappen,
   "Mood"-chips tonen genres, palet-kopjes lokaliseren.
4. Uit de audit, punt B: artiest- en album-radio via `/nearest` op de artiest/album-
   ratingKey; wachtrij-top-up via `/nearest` op de laatst gespeelde track.
5. Uit de audit, punt C: crossfade, equalizer, CarPlay.
6. Uit de audit, punt D: historie/feedback/playlists lokaal op de client (nu leven
   die alleen op de mini — zonder dat vergeet een standalone toestel alles).
7. Fase 4b (artwork/offline/transcode volledig van Plex) en fase 5 (share-server van
   vereiste naar uitbreiding).

## Constraints
- "Geen Apple TV / tvOS (scope is strikt macOS 14+ en iOS 17+)" (user, 2026-08-23)
- "Alle UI-teksten/labels zijn in het Nederlands, code/symbolen/commentaren/APIs in het Engels" (user, 2026-08-23)
- "Geen AppKit in gedeelde modules (RoonSageCore, RoonSageUI, AudioAnalysis, AnalyzerCore); houd RoonProtocol en RoonSageCore platform-onafhankelijk" (user, 2026-08-23)
- "Zelfs als Roon wegvalt moet alles gewoon werken. Roon control is dan iets ernaast" — Roon is uitvoer, geen catalogus. Niets mag een werkende Roon-verbinding vereisen om de bibliotheek te tonen (user, 2026-08-23)
- "als je de ios client start, moet je de eerste keer worden gevraagd in te loggen op plex en dan moet de app werkende zijn. En daar waar je de analyzer voor nodig hebt, de roonprotocl etc krijg je een melding om te verbinden met de anlayzer" + "En de analyzer is dus optioneel" — Plex-first opstart; de app moet volledig bruikbaar zijn met ALLEEN een Plex-koppeling, en analyzer-afhankelijke functies tonen een verbind-melding in plaats van de app te blokkeren (user, 2026-08-23)
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
- FLAKE: `NotificationServiceTests.testRejectedDeliveryIsCountedNotSwallowed` — faalde één keer in de volledige suite, 3/3 groen geïsoleerd (2026-08-23)
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
