# Koel-audit — wat de RoonSage-mobiele-app ervan kan leren

> Gegenereerd: 2026-07-08. Bronnen: [koel/player](https://github.com/koel/player)
> (Flutter iOS/Android-client, volledige `lib/`-boom doorgelicht) én
> [koel/koel](https://github.com/koel/koel) (Laravel+Vue webapp/server, volledige
> `resources/assets/js/components/`-boom doorgelicht) — vergeleken met de native
> RoonSage-app (shell `native/iosapp` + gedeelde views in
> `native/RoonSage/Sources/RoonSageUI`).
>
> Architectuur-noot: Koel Player is exact dezelfde vorm als RoonSage-mobiel — een
> thin client die streamt van een eigen server. De vergelijking is dus 1-op-1 geldig.
> Kanttekening: laatste Koel Player-release is v1.1.0 (sept 2021); het is een
> gepolijste maar simpele app.

---

## 1. Oordeel in één alinea

RoonSage is functioneel véél rijker dan Koel Player (sonic engine, AI-generatie,
discovery-pipeline, karaoke-lyrics, Live Activity/widgets/Handoff, theming,
loudness/transcoding — Koel heeft dat allemaal niet). Maar Koel Player wint op
**vier mobiele fundamenten** die RoonSage mist: **offline downloads**,
**swipe-to-queue**, **globale zoek** en **frictieloze pairing (QR)**. Dat zijn
precies de dingen die een telefoon-app een telefoon-app maken: hij moet werken in
de trein, met één duim, zonder setup-gedoe.

## 2. Wat RoonSage al heeft en Koel niet (niet aan sleutelen)

Sonische radio's/adventure, AI-playlistgeneratie + templates, Ontdek-pipeline
(weekly/feed/insights), smaakprofiel + feedback-leren, karaoke-lyrics in DB,
BeatVisualizer, sleeptimer, opdrachtenpalet (⌘K), thema-presets + ambient-tint,
Live Activity/Dynamic Island, home-widget, Siri/Shortcuts, Handoff, Qobuz-sync,
loudness-normalisatie, onderweg-AAC-transcoding. Koel's web-EQ/visualizer zitten
niet eens in hun mobiele app. Koel's smart playlists overlappen deels met onze
RadioConfig-radio's maar dekken een ander vlak (metadata-regels) — zie K11.

## 3. Gap-analyse — wat Koel Player wél heeft

Severity: 🔴 kernwaarde mobiel · 🟠 merkbaar beter · ⚪ polish. Effort: S (<1u) · M (uren) · L (dag+)

### K1 🔴 L — Offline downloads + offline-modus
**Koel:** per track/album/artiest een download-knop (`playable_cache_icon.dart`),
eigen "Downloaded"-scherm met sortering (`downloaded.dart`), bestanden op schijf
(`download_provider.dart`), en een `download_sync_provider.dart` die elke 5 min
(bij connectiviteit) de metadata van gedownloade tracks her-synct met de server.
Bij geen verbinding: `no_connection.dart` routeert naar de gedownloade bibliotheek.
**RoonSage:** niets. Lokaal afspelen streamt on-demand van `/audio`
(`LocalPlayback.swift:362`); onderweg vereist dat ZeroTier-aan + bereik. Cache is
alleen artwork (`ImageCache.swift`/`DiskImageCache.swift`).
**Voorstel:** hergebruik de bestaande `/audio`-endpoint + AAC-transcode-pad
(`LocalTranscode.swift`) om tracks naar Application Support te downloaden;
`LocalPlaybackController.makeItem` checkt eerst het lokale bestand; "Gedownload"-
sectie in Bibliotheek-Overzicht; download-verb in `PlayActionsMenu`; offline-gate
in `WelcomeGate` ("Geen server — speel je downloads"). Loudness-metadata mee-cachen.
Dit is de grootste losse hefboom voor de iPhone-app.

### K2 🔴 S/M — Swipe-to-queue + lokaal "speel hierna"
**Koel:** swipe-rechts op elke track/album/artiest-rij → achteraan in de wachtrij,
met groene achtergrond + "Queued"-overlay; de rij blijft staan
(`swipe_to_queue_dismissible.dart`, `confirmDismiss` → `false`).
**RoonSage:** queue-verbs alleen via contextMenu (`PlayActionsMenu.swift:29-33`),
en die zijn **Roon-zone-only** — de lokale engine heeft géén insert-next
(commentaar `PlayActionsMenu.swift:22-24`). `swipeActions` bestaan alleen in
Bookmarks/DiscoverFeed/CustomRadio.
**Voorstel:** (a) `.swipeActions` op track-rijen in LibraryView, FilteredTracksView,
album/artiest-detail en playlist-detail: leading = "Hierna" / "In wachtrij";
(b) `LocalPlaybackController.insertNext(_:)` zodat de verbs ook bij "dit apparaat"
werken. Grootste dagelijkse-UX-winst per uur werk.

### K3 🟠 M — Globale zoek (één zoekingang over alles)
**Koel:** één zoekscherm over songs + artiesten + albums (+ podcasts)
(`search.dart`, `search_provider.dart`).
**RoonSage:** zoeken is per-scherm (`.searchable` in `LibraryView.swift:142`;
sonisch zoeken en AskView apart). Op iPhone is er geen ⌘K-equivalent.
**Voorstel:** één zoekscherm (of pull-down op Bibliotheek-Overzicht) met
gesecteerde resultaten: tracks / albums / artiesten / playlists / radio's, plus
een "Sonisch zoeken →"-doorsteek. Het opdrachtenpalet levert de patronen al.

### K4 🟠 M — QR-pairing
**Koel:** QR-login (`qr_login_button.dart`) — scannen i.p.v. host+wachtwoord typen.
**RoonSage:** handmatig host + token; bekend supportleed: stale token = #1
"connect niet"-oorzaak, plus device-approval-wachtrij.
**Voorstel:** analyzer-app (Instellingen → Server) toont QR met
`{hosts:[LAN,ZT], token}`; iOS scant → vult in, health-checkt, dient
device-approval-verzoek in. Eén-scan-onboarding voor nieuwe apparaten.

### K5 🟠 M — Alfabet-snelscroll in lange lijsten
**Koel:** letter-index aan de rechterrand (`alphabet_scrollbar.dart`).
**RoonSage:** 76,5k tracks / duizenden artiesten, maar alleen endless scroll
(`LibraryView.swift:595+`). SwiftUI heeft geen native sectionIndex — custom
overlay (verticale letterkolom + drag) op Artiesten/Albums/Tracks bij sortering
op titel/artiest.

### K6 🟠 S/M — Playlist-mappen
**Koel:** playlist-folders + aanmaak-sheet (`playlist_folder.dart`,
`create_playlist_folder_sheet.dart`).
**RoonSage:** vlakke lijst met bron-badges (`PlaylistsView.swift:117`). Met
LB-mirrors, Last.fm, AI-radio's en bewaarde playlists wordt dat druk.
**Voorstel:** `folder`-veld op de server-of-record `/playlists` (schema-bump) of
lichter: client-side groepering op bron uitbreiden tot inklapbare secties.

### K7 ⚪ S — Marquee voor lange titels
**Koel:** `marquee_text.dart` scrollt lange titels in Now Playing.
**RoonSage:** truncatie. Kleine polish, direct zichtbaar in de hero + mini-bar.

### K8 ⚪ S — Sorteervoorkeur onthouden per scherm
**Koel:** bewaart sort-config per scherm (`AppState.set('downloaded.sort', …)`).
**RoonSage:** `SortField` in LibraryView reset per sessie → `@AppStorage`.

### K9 ⚪ S — Pull-to-refresh + skeletons overal
**Koel:** elk scherm heeft een placeholder-skeleton + pull-to-refresh
(`ui/placeholders/*`, `pull_to_refresh.dart`).
**RoonSage:** `SkeletonRows` bestaat maar wordt niet uniform gebruikt — dit is al
UX_AUDIT-bevinding-categorie "lege/laad/fout-states" (11 stuks); Koel bevestigt de
prioriteit.

### K10 ⚪ M — Gapless lokaal afspelen
Geen Koel-feature per se (hun audio_handler queuet wel vooruit), maar de
vergelijking legde het bloot: onze lokale engine is één `AVPlayer` die pas bij
`didPlayToEndTime` de volgende track laadt (`LocalPlayback.swift:99,112`) → hoorbaar
gat. `AVQueuePlayer` met pre-enqueue van het volgende item dicht dat gat.

---

## 3b. Gap-analyse deel 2 — koel/koel (webapp/server)

De webapp is véél rijker dan hun mobiele player; dit zijn de features die naar
RoonSage-mobiel vertaalbaar zijn. (Web-vondsten die K1/K4 bevestigen:
`OfflineSongsScreen.vue`/`OfflineMark.vue`/`OfflineNotification.vue` en
`profile-preferences/QRLogin.vue` — zelfde patroon als voorgesteld.)

### K11 🟠 M — Slimme playlists (regel-gebaseerd, zelf-actualiserend)
**Koel:** regel-builder met AND-groepen/OR tussen groepen
(`smart-playlist/SmartPlaylistRule*.vue`); velden: titel, album, artiest, genre,
jaar, **play count**, **laatst gespeeld**, lengte, **datum toegevoegd**, datum
gewijzigd (`config/smart-playlist/models.ts`).
**RoonSage:** RadioConfig-radio's zijn sonisch/facet-gebaseerd (artiest/genre/
mood/activiteit) maar er is geen metadata-regel-playlist: "jazz uit >2015 dat ik
<3× speelde" of "toegevoegd afgelopen maand, nog nooit gespeeld" kan nu niet.
**Voorstel:** regel-laag bovenop de bestaande server-of-record: alle velden
zitten al in library.db (`listening_history` voor play count/laatst gespeeld,
track.year, genres, duur). Server evalueert regels bij afspelen → altijd actueel;
UI als extra sectie in CustomRadioEditorView (zelfde multi-select-patronen).
Complementair aan sonic radio's, niet concurrerend.

### K12 ⚪ S/M — Home-shelves: herordenen + "zelden gespeeld"/"willekeurig"
**Koel:** home met blokken Most/Least played, New/Random albums & artists,
Similar songs — en een **ReorderBlocksModal** waarmee de gebruiker de blokken
zelf herschikt (`screens/home/*.vue`).
**RoonSage:** Bibliotheek-Overzicht heeft shelves (stats-hero, radiostations,
snelkoppelingen, filtertegels) maar vaste volgorde, en geen "zelden gespeeld"-
of "willekeurig album"-shelf — juist sterke herontdek-triggers voor 76,5k tracks.
**Voorstel:** 2 nieuwe shelves (goedkoop: data zit in listening_history) +
shelf-volgorde als user-preference.

### K13 🟠 M — AI-assistent als chat met acties
**Koel:** volwaardige AI-chat: geschiedenis, floating button, voorbeeldprompts,
natural-language-commando's die écht dingen doen (`ai/AiAssistantScreen.vue`,
`AiChatHistory.vue`, `AiSamplePrompts.vue`).
**RoonSage:** AskView is één-shot vraag→antwoord; generatie/afspelen zijn
losse schermen.
**Voorstel:** AskView → chat-UI met historie + voorbeeldprompts + acties
("speel iets rustigs op de woonkamer", "maak hier een playlist van") die naar de
bestaande generate/radio/transport-endpoints routeren. De LLM-infra (qwen op de
mini) en het opdrachtenpalet-vocabulaire bestaan al.

### K14 ⚪ M — Map-browser (bestandsstructuur) met breadcrumbs
**Koel:** MediaBrowserScreen: door de mappenstructuur bladeren met breadcrumbs
(`media-browser/*`, `playable/media-browser/Breadcrumbs.vue`).
**RoonSage:** geen map-weergave; de analyzer scant nota bene zelf het
bestandssysteem (4tbdrive). Handig voor boxsets/klassiek waar mapstructuur
betekenis draagt. Laag-prio maar goedkoop: paden staan al in de analyzer-DB.

### K15 ⚪ L — Echte equalizer (lokaal afspelen)
**Koel:** 10-bands Web-Audio-EQ met presets + eigen presets opslaan
(`ui/equalizer/*`, incl. `EqualizerSavePresetForm.vue`).
**RoonSage:** bewust overgeslagen in de LMS-audit (B4); alleen
loudness-normalisatie. Roon-zones doen hun eigen DSP — dit zou alléén lokaal
afspelen gelden en vergt AVPlayer → AVAudioEngine-ombouw. Tweede audit op rij
waar dit gat opduikt; blijft backlog, maar de ombouw kan meeliften met K10
(gapless), dat dezelfde engine-wissel nodig heeft.

### K16 ⚪ M — Fullscreen-visualizer-modus
**Koel:** apart visualizer-scherm met verwisselbare visualizer-plug-ins op echte
audio-analyse (`VisualizerScreen.vue`, `visualizers/asteroid/…/AudioAnalyzer.ts`,
three.js).
**RoonSage:** BeatVisualizer is een inline synthetische canvas (BPM/energie).
**Voorstel (licht):** fullscreen-modus voor de bestaande BeatVisualizer +
art/lyrics-combinatie ("kiosk/party-modus") — géén echte audio-tap nodig; de
synthetische aanpak schaalt prima naar fullscreen.

### Bewust NIET overnemen
- **Podcasts** (`podcasts.dart`, `PodcastScreen.vue` e.v.) — buiten de
  product-constitutie (library-first: Roon-bibliotheek + Qobuz).
- **Broadcast/internet-radio** (`radio_stations.dart`, `RadioStationListScreen.vue`)
  — onze radio's zijn algoritmisch over de eigen bibliotheek; dat is het product.
- **Metadata-editing op mobiel** (`edit_album_sheet.dart`, `EditSongForm.vue`) —
  Roon is de metadata-bron; muteren vanaf de telefoon is een voetgeweer.
- **Frosted context-menu's** — native `contextMenu` is op iOS de juiste keuze.
- **Multi-user/SSO/2FA/uitnodigingen, playlist-collaboration, uploads, embeds/
  sharing, YouTube-integratie** (`auth/sso`, `two-factor`, `PlaylistCollaboration*`,
  `UploadScreen.vue`, `embed/*`, `YouTubeScreen.vue`) — RoonSage is één-persoons
  en library-first.
- **Star-rating** (`StarRating.vue`) — het feedback-leren is bewust binair
  (thumbs → leer-chokepoint); 5-sterren fragmenteert dat signaal.
- **Subsonic/OpenSubsonic-API-compat** (`SubsonicCredentials.vue`) — géén
  mobiel-item, maar noteer als los server-idee: een OpenSubsonic-laag op de
  analyzer zou elke bestaande Subsonic-client (Symfonium e.d.) compatibel maken.
  NOTED (not done).

## 4. Aanbevolen batches

| Batch | Inhoud | Effort | Waarom eerst |
|---|---|---|---|
| 1 | K2 swipe-to-queue + `insertNext` lokaal; K7 marquee; K8 sort-persist | S/M | dagelijkse-UX-winst, klein |
| 2 | K3 globale zoek + K5 alfabet-index | M | vindbaarheid bij 76,5k tracks |
| 3 | K12 home-shelves (zelden gespeeld/willekeurig + herordenen) | S/M | herontdekking, goedkoop |
| 4 | K4 QR-pairing | M | lost #1-supportklacht structureel op |
| 5 | K11 slimme playlists (regel-laag) | M | uniek gat naast sonic radio's; data ligt klaar |
| 6 | K13 AI-chat-assistent | M | bestaande LLM-infra, hoge zichtbaarheid |
| 7 | K1 offline downloads + offline-modus | L | grootste feature-gat; bouwt op transcode-pad |
| Backlog | K6 playlist-mappen; K9 states-uniformering (→ UX_AUDIT); K10 gapless + K15 EQ (zelfde engine-ombouw); K14 map-browser; K16 fullscreen-visualizer | S–L | |

## 5. Status

- [ ] Batch 1 — K2/K7/K8
- [ ] Batch 2 — K3/K5
- [ ] Batch 3 — K12
- [ ] Batch 4 — K4
- [ ] Batch 5 — K11
- [ ] Batch 6 — K13
- [ ] Batch 7 — K1
- [ ] Backlog — K6/K9/K10+K15/K14/K16
