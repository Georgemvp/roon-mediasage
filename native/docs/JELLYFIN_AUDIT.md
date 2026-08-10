# Jellyfin-audit — wat de lokale speler van RoonSage ervan kan leren

> Gegenereerd: 2026-08-10. Aanleiding: user wil "een professionele lokale music
> player met ondersteuning voor zone play via Roon in plaats van andersom".
> Vergeleken: het [Jellyfin](https://github.com/jellyfin/jellyfin-web)-ecosysteem
> (web + android), [Finamp](https://github.com/finamp-app/finamp) (de facto
> Jellyfin-muziekclient), [Symfonium](https://symfonium.app/) (commercieel,
> Android, de rijkste van het stel) en [JellyAmp](https://satsdisco.github.io/JellyAmp/)
> (Swift/AVQueuePlayer, dezelfde vorm als wij) — naast de lokale motor van
> RoonSage (`RoonSageCore/LocalPlayback.swift`, `LocalQueue.swift`,
> `RoonClient+LocalPlayback.swift`) en de UI in `RoonSageUI`.
>
> **LICENTIE-HEK — zelfde regel als bij [KOEL_AUDIT](KOEL_AUDIT.md) en de
> Lidarr/DroppedNeedle-benchmark: geen regel code overgenomen.** Jellyfin is
> GPL-2.0 en deze repo MIT; controleer per project de licentie voordat je ook
> maar iets overneemt. Alleen mechanismen zelfstandig herbouwen. Symfonium is
> closed source, dus daar is per definitie alleen waarneembaar gedrag bekeken.
>
> Architectuur-noot: Finamp en RoonSage-lokaal zijn exact dezelfde vorm — een
> thin client die van een eigen server streamt. De vergelijking is 1-op-1
> geldig. Symfonium is een bredere aggregator (Plex + Jellyfin + Subsonic +
> lokale bestanden + SMB/WebDAV in één app); daar is alleen de speler-laag
> vergelijkbaar, niet het bronmodel.

---

## 1. Oordeel in één alinea

Jellyfin **zelf** is geen voorbeeld: gapless is een van zijn oudste openstaande
verzoeken ([web #1132](https://github.com/jellyfin/jellyfin-web/issues/1132),
[android #981](https://github.com/jellyfin/jellyfin-android/issues/981)) en de
officiële clients hebben het niet. De lat wordt gelegd door Finamp en Symfonium,
en die winnen op precies één as: **wat er gebeurt als het netwerk wegvalt.**
RoonSage is inhoudelijk veel rijker (sonic engine, discovery, AI-generatie,
analyzer-gemeten LUFS) en heeft sinds 2026-08-10 gapless en een bewerkbare
wachtrij — maar het is nog altijd een pure streamer. Zonder bereik heb je niets.
Offline is niet één feature maar drie lagen, en de goedkoopste laag levert
meteen de meeste dagelijkse winst op.

## 2. Wat RoonSage al heeft en zij niet (niet aan sleutelen)

Sonische engine op CLAP-embeddings (Similar/Map/Path/Alchemy/Fingerprint,
vector-index), vrije-tekst sonische zoek, Ontdek-pipeline met acht producers,
AI-playlistgeneratie, smaakprofiel met feedback-leren, karaoke-lyrics met
FTS-zoek, Live Activity/Dynamic Island, widgets, Handoff, Siri/Shortcuts,
Wall Display, en loudness-normalisatie op **analyzer-gemeten LUFS per track én
per album** (de meeste clients leunen op ReplayGain-tags of doen niets).

En het punt dat de rolverdeling rechtvaardigt: **Roon-zones.** Symfonium cast
naar Chromecast, UPnP/DLNA, Sonos en zelfs Plexamp-clients, maar naar Roon kan
niemand — RAAT is een gesloten SDK. Onze zone-ondersteuning is dus geen
tweederangs-alternatief voor casting, het is een doel dat geen enkele
concurrent heeft. Dat is precies waarom de gevraagde omkering klopt: lokale
speler als product, Roon-zones als de bijzondere uitvoer.

Ook al beter dan de Roon-kant: de lokale wachtrij is **bewerkbaar** (herordenen,
verwijderen, speel-hierna). Roons extensie-API kan alleen lezen en
play-from-here.

## 3. Gap-analyse

Severity: 🔴 kernwaarde mobiel · 🟠 merkbaar beter · ⚪ polish.
Effort: S (<1u) · M (uren) · L (dag+)

### J1 🔴 S/M — Afspeel-cache (de goedkope offline-laag)
**Symfonium:** onderscheidt expliciet drie lagen — *playback cache*,
*automatic caching* en *manual caching*. De eerste is gratis winst: wat je
zojuist speelde staat nog op schijf.
**RoonSage:** niets. `makeItem` bouwt elke keer een verse `/audio`-URL
(`LocalPlayback.swift`), dus een nummer terugspringen betekent opnieuw over het
netwerk. Album-art cachet al wél naar schijf (`DiskImageCache`) — audio niet.
**Voorstel:** een LRU-schijfcache voor de laatste N MB gestreamde audio, in
dezelfde vorm als `DiskImageCache`. Lost meteen op: terugspringen, herhalen,
en de eerste seconden van een net gespeeld album. **Beste winst per uur werk in
dit hele document.**

### J2 🔴 L — Echte downloads + offline-modus
**Finamp:** dit is z'n bestaansrecht — offline sync die "intentional rather than
bolted on" aanvoelt; per album/playlist markeren, en de app blijft bruikbaar
zonder server.
**RoonSage:** geen enkele downloadweg; `downloadTask` bestaat alleen in
`UpdateInstaller`. Bibliotheek-metadata staat al lokaal in GRDB, dus het gat is
puur de audio plus een offline-modus in de UI.
**Voorstel:** "Bewaar op dit apparaat" op album/playlist/artiest, een
downloadwachtrij, en een filter dat bij geen bereik alleen het aanwezige toont.
Bouwt op J1's cachelaag — doe J1 eerst, dan is dit een uitbreiding en geen
nieuw subsysteem. Overlapt met `KOEL_AUDIT` **K1**.

### J3 🟠 S/M — AirPlay-routekiezer
**Iedereen:** een zichtbare uitvoerkiezer hoort bij een telefoonspeler.
**RoonSage:** geen `AVRoutePickerView` in de hele boom — geverifieerd. Je kunt
alleen via Control Center wisselen. Stond al als restpunt in ROADMAP D9.
**Voorstel:** `AVRoutePickerView` in de Now Playing-hero en in de OutputSelector.
Nu extra zinvol omdat de sessie sinds `b8096d5` op `.longFormAudio` staat, wat
precies de policy is die AirPlay 2 als long-form route laat aanbieden.

### J4 🟠 M — Crossfade en smart fade
**Symfonium:** "smart fades and crossfades are no longer Beta" — smart fade =
alleen faden waar het past, niet tussen doorlopende albumtracks.
**RoonSage:** niets. Was voorheen onbouwbaar met één `AVPlayer`; sinds de
`AVQueuePlayer`-ombouw (`76eddab`) is het bereikbaar, al vraagt echt overlappend
faden twee spelers of `AVAudioEngine`.
**Voorstel:** begin met fade-in/fade-out bij pauze, stop en de sleeptimer — dat
kan met `player.volume`-ramps en is goedkoop. Volledige crossfade pas bij J5.
Let op de interactie: crossfade **mag niet** aanstaan tussen tracks van hetzelfde
album, anders sloop je precies de gapless-winst.

### J5 🟠 L — DSP-equalizer
**Symfonium:** equalizer tot 256 banden.
**RoonSage:** geen. De hits op "equalizer" in `LocalNowPlaying`/`NowPlayingView`
zijn de score-visualizer, geen DSP.
**Voorstel:** vereist `AVAudioEngine` + `AVAudioUnitEQ` in plaats van
`AVQueuePlayer`, dus een tweede motorombouw. Zelfde ombouw als echte crossfade —
plan ze samen of niet. Overlapt met `KOEL_AUDIT` **K15**.

### J6 🟠 M — Eén zoekingang
**Finamp/Symfonium:** één zoekveld over alles.
**RoonSage:** zoeken zit per scherm (`LibraryView`, `AskView`,
`CustomRadioEditorView`); `SonicSearchView` is een aparte sonische ingang. Bij
76,5k tracks is dat te veel deuren.
**Voorstel:** één ingang die tracks, albums, artiesten, playlists, labels én de
sonische zoek samenbrengt. Overlapt met `KOEL_AUDIT` **K3** — dezelfde klus,
tweede keer gevonden vanuit een andere hoek. Dat is een signaal.

### J7 ⚪ M — Downloadformaat kiezen (en wat dat met gapless doet)
**Finamp:** transcodeert bij het downloaden naar AAC, Opus of FLAC.
**RoonSage:** `LocalTranscode` transcodeert alleen *tijdens streamen* naar AAC.
**Voorstel + waarschuwing:** AAC en MP3 hebben encoder-padding, FLAC niet — dat
is de reden dat gapless bestandsafhankelijk is
([Apple DevForums](https://developer.apple.com/forums/thread/111413)).
**Onderweg-AAC en gapless sluiten elkaar dus uit.** Als downloads komen: bied
FLAC aan voor wie gapless wil, en maak in de UI zichtbaar dat de AAC-modus
gaten introduceert. Dit is een productbeslissing voor Casper, geen technische.

### J8 ⚪ S — Fade-out op de sleeptimer
**Symfonium:** smart fades dekken ook het inslapen.
**RoonSage:** `pauseForSleep()` knipt hard weg.
**Voorstel:** valt gratis uit J4's volume-ramp.

### J9 ⚪ S — Wachtrij-afronding
**RoonSage:** "wachtrij wissen" en "spring naar het spelende nummer" ontbreken;
bewaren-als-playlist bestaat al.
**Voorstel:** twee knoppen in `QueueView`, triviaal na de ombouw van vandaag.

### Bewust NIET overnemen
- **Chromecast / UPnP / DLNA / Sonos** (Symfonium) — onze uitvoer buiten dit
  apparaat is Roon, en dat dekt het hele huis met betere kwaliteit. AirPlay (J3)
  is de enige die ontbreekt omdat die *op het apparaat zelf* hoort.
- **Multi-server-aggregatie** (Symfonium: Plex + Jellyfin + Subsonic + SMB) —
  in strijd met de product-constitutie (library-first: Roon-bibliotheek + Qobuz).
- **Podcasts / audiobooks** (Finamp, Audiobookshelf-koppeling) — buiten scope,
  zelfde reden als in KOEL_AUDIT.
- **Material You / volledig aanpasbare tabs** (Symfonium) — we hebben al een
  themasysteem met accentkeuze; tabs herordenen is complexiteit zonder vraag.
- **Een OpenSubsonic-laag op de analyzer** zou Symfonium, Feishin en de rest in
  één klap client van RoonSage maken. Blijft een verleidelijk server-idee, geen
  speler-item. NOTED (not done) — stond ook al in KOEL_AUDIT.

## 4. Aanbevolen batches

| Batch | Inhoud | Effort | Waarom in deze volgorde |
|---|---|---|---|
| 1 | J1 afspeel-cache + J9 wachtrij-afronding | S/M | goedkoopste echte winst; J1 is het fundament onder J2 |
| 2 | J3 AirPlay-kiezer + J8 fade-out sleeptimer | S | klein, zichtbaar, sluit ROADMAP D9 af |
| 3 | J4 fades (pauze/stop/sleep, nog geen crossfade) | M | bouwt op de AVQueuePlayer van vandaag |
| 4 | J6 één zoekingang | M | dubbel gevonden (ook KOEL K3) — vindbaarheid bij 76,5k tracks |
| 5 | J2 downloads + offline-modus | L | het grootste gat; pas zinvol ná J1 |
| 6 | J7 downloadformaat + de gapless-waarschuwing in de UI | M | hoort bij J2, aparte beslissing |
| Backlog | J5 EQ + echte crossfade (samen: AVAudioEngine-ombouw, ook KOEL K15) | L | tweede motorombouw, niet nu |

## 5. Status

- [ ] Batch 1 — J1/J9
- [ ] Batch 2 — J3/J8
- [ ] Batch 3 — J4
- [ ] Batch 4 — J6
- [ ] Batch 5 — J2
- [ ] Batch 6 — J7
- [ ] Backlog — J5 + crossfade

## 6. Al gedaan sinds deze vraag begon

Niet meer openstaand, hier genoteerd zodat de audit niet naar afgeronde dingen
blijft wijzen:

- **Gapless** (`76eddab`) — `AVQueuePlayer` met één item vooruit; was `KOEL_AUDIT` K10.
- **Bewerkbare lokale wachtrij + speel-hierna** (`48bfd14`) — was `KOEL_AUDIT` K2(b).
- **Long-form audiosessie** (`b8096d5`) — voorwaarde voor J3.
- **Lokaal als standaarduitvoer** (`76eddab`) — de gevraagde omkering.

**Restpunt uit de gapless-ombouw:** de loudness-gain hangt aan `player.volume`
(per speler, niet per item), dus hij verschuift pas ná de overgang. Dat is het
mechanisme achter de "klik tussen nummers" die Finamp-gebruikers melden
([finamp#998](https://github.com/finamp-app/finamp/issues/998)). Oplossing is
een per-item `AVAudioMix`; vereist async laden van de asset-track.
