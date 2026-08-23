<!-- ═══ START HIER (kopieer dit als prompt voor een nieuwe sessie) ═══
Lees docs/STATE.md en ga verder met het snoeiprogramma in ## Next, stap voor stap.
Werk incrementeel: per batch bewerken → cd native/RoonSage && swift build && swift test
→ commit → (push+tag alleen als Casper daar in dat gesprek om vraagt) → STATE.md bijwerken.
Houd dit bestand onder ~40 regels. Historie staat in docs/STATE-archief-2026-08-23.md.
═══════════════════════════════════════════════════════════════════ -->

## Goal
Van monoliet naar een snelle, stabiele Plexamp/Symfonium-achtige client. Maatstaf is
iOS: snel en zonder bugs. Snoeien is het middel, niet het doel.

## Now
Snoeiprogramma gestart na de audit van 2026-08-23 (twee onafhankelijke audits, zelfde
diagnose). Stap 1 is af en gecommit (`e464bdd`, nog niet gepusht/getagd): AudioAnalysis
gesplitst in een lichte kern + `CLAPEngine`, waardoor de 746 MB CLAP-modellen uit beide
client-apps verdwijnen. Gemeten iOS-bundel 793 MB → 96 MB. 1074 tests, 0 failures.

## Next
1. ~~CLAP-modellen uit de clients~~ — AF (`e464bdd`)
2. Plex als catalogus + streaming/transcode/remote onderzoeken en beslissen (§ Decisions).
   Plex draait al, indexeert `/Volumes/4tbdrive/Muziek`, 65.738 tracks, stabiele ratingKeys.
3. Identiteit repareren — `native/docs/STANDALONE_LIBRARY_PLAN.md` §5d, of vervallen als
   Plex' ratingKey de sleutel wordt.
4. Eén `RecommendationEngine` i.p.v. ~10 motoren (51 bestanden raken similarity/kNN).
5. `RoonClient` opbreken: 13.041 regels / 547 functies / 115 properties → < 2.000, alleen
   protocol + transport.
6. UI snoeien: 31 navigatiebestemmingen → ~10, gemeten op echt gebruik via `/play-stats`.

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
- **Open, ligt bij Casper:** Plex als catalogus + streaming/transcode/remote-laag, met de analyzer teruggebracht tot alléén analyse. Zie de audit; Plex dekt ~2.800 regels eigen code die we onderhouden, maar heeft geen CLAP/BPM/Camelot. Raakt de constraint "de analyzer is de primaire bron".
- Sonic-fit CLAP zit achter `SonicFitScoring`; alleen `ClapSonicFit` in de analyzer-app registreert. Client = provider nil = pre-sonische ordening (2026-08-23).

## Facts
- test/build: `cd native/RoonSage && swift build && swift test`; release: `swift build -c release --product RoonSage`; lint: `swiftlint lint --config .swiftlint.yml`
- iOS: `cd native/iosapp && xcodegen generate`, dan `xcodebuild -project RoonSageiOS.xcodeproj -scheme RoonSageiOS -sdk iphonesimulator -derivedDataPath build/dd build`
- Tag-namespaces: app `vX.Y.Z` · iOS `ios-vX.Y.Z` · analyzer `analyzer-vX.Y.Z`. Laatst getagd: v1.10.281 / ios-v1.7.247 / analyzer-v1.1.211; de mini draait analyzer-v1.1.202.
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
