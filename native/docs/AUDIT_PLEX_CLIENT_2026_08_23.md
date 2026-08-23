# Audit — hoe zelfstandig is de client, en wat is er nodig voor Plexamp/Symfonium-niveau

> 2026-08-23. Alles hieronder is **gemeten**: tegen de draaiende Plex- en
> analyzer-installaties, tegen de echte `library.db`, en via GUI-automatisering
> op de iPhone 17-simulator (`~/bin/rs-sim` + idb, schermafdrukken in `/tmp/rsux`).
> Waar iets niet geverifieerd kon worden staat dat er expliciet bij.

---

## 1. Kan de client met alléén Plex functioneren?

**Sinds `v1.10.292`: ja, op papier. Nog niet end-to-end bewezen** — de laatste
stap vereist dat iemand een koppelcode op plex.tv/link invoert, en dat kan ik
niet namens jou.

Wat de GUI-test aan het licht bracht, en wat daarvan gefixt is:

| bevinding | status |
|---|---|
| Verse installatie ging rechtstreeks een **lege bibliotheek** in en vroeg nergens iets — Bonjour vond de mini en verbond binnen een seconde | gefixt, `plex_onboarding_done` |
| `plexBaseURL` stond op **`127.0.0.1`** — op een telefoon is dat de telefoon zelf; een correct gekoppeld toestel synchroniseerde 0 tracks en zei niet waarom | gefixt, serverontdekking via plex.tv |
| App toonde permanent **"Geen RoonSage-server gevonden"** terwijl de analyzer optioneel is | gefixt, `.disconnected` i.p.v. `.failed` |
| Lege bibliotheek zei **"niet verbonden — verbind eerst"**: een doodlopende hint naar een server die je niet nodig hebt | gefixt, "koppel met Plex" + knop |
| Zone-waarschuwing stond er terwijl "Dit apparaat" gekozen was én speelde | gefixt, `hasActiveOutput` |
| Laatste onboarding-stap toonde **rauwe sleutels** en knoppen liepen van het scherm af | gefixt |

### Serverontdekking — gemeten

plex.tv geeft voor dit account drie routes naar de mini:

```
LOKAAL   https://10-94-184-22….plex.direct:32400     (ZeroTier)
LOKAAL   https://192-168-178-59….plex.direct:32400   (LAN)
extern   https://82-217-191-164….plex.direct:14084   (Remote Access)
```

Die externe route is wat de app buitenshuis laat werken **zonder ZeroTier** — de
belangrijkste praktische winst van deze hele migratie. `reachableServer()` probeert
lokaal → direct extern → relay, met een `/identity`-probe van 3 s. Live gemeten:
gevonden in 0,7 s.

---

## 2. Wat werkt via de analyzer, en wat niet?

Van de **52 views** in `RoonSageUI` raken er **35** analyzer-API's aan en **17** niet.
Dat is geen goede maat voor bruikbaarheid — veel views raken de analyzer voor een
detail — dus hieronder per functie.

### Werkt op Plex alleen
Bibliotheek (bladeren, albums, artiesten), zoeken, afspelen, hoezen, wachtrij,
offline downloads, transcode, sleeptimer, visualizer, gapless, loudness-normalisatie,
en — met `plex_sonic_enabled` — vergelijkbare nummers, radio's en mixes.

### Vereist de analyzer
| functie | wat de analyzer levert dat Plex niet heeft |
|---|---|
| DJ-set, Live DJ, harmonisch mixen | BPM + Camelot-toonsoort |
| Song Paths, Song Alchemy | ruwe CLAP-vectoren (vectoroptelling) |
| Sonic DNA, smaakvector | ruwe vectoren |
| Sonische zoekopdracht ("klinkt als…") | CLAP **tekst**-embedding |
| Ontdekken (Qobuz/MusicBrainz/ListenBrainz/Deezer) | serverzijdige pipeline |
| Generate / Ask | LLM op de mini |
| Songteksten | LRCLIB + ingebedde LRC |
| Roon-zones | RoonProtocol |
| De Qobuz/streaminglaag | 16.102 rijen zonder bestand |

---

## 3. Waar horen de Plex-analysefuncties?

Plex Pass heeft **99,94%** van deze bibliotheek geanalyseerd (65.699 tracks,
8.521 albums, 3.413 artiesten) en beantwoordt `/library/metadata/<rk>/nearest`
vanuit een gewone client — ook op **album- en artiest-ratingKeys**.

| plek | nu | zou moeten |
|---|---|---|
| Vergelijkbare nummers | Plex ✅ (`v1.10.284`) | — |
| Stations / radio's | Plex ✅ (`v1.10.290`) | — |
| **Artiest-radio** | eigen kNN | `/nearest` op de **artiest**-ratingKey — dat is precies wat Plex' "similar artists" ís |
| **Album-radio** | eigen kNN | `/nearest` op de **album**-ratingKey |
| **Slimme wachtrij / top-up** | eigen kNN per regeneratie | `/nearest` op de laatst gespeelde track — geen index nodig |
| Mix-for-you | eigen pipeline | Plex' eigen mixes ophalen |

**Wat NIET naar Plex kan:** alles wat ruwe vectoren of tekst nodig heeft — Alchemy,
Song Paths, Sonic DNA, sonische zoekopdracht. `Track.tree` (55 MB) is ongedocumenteerd
binair en `/nearest` doet alleen k-NN vanaf een bestaande track, geen `seed − X + Y`.

**Waarschuwing die uit de meting kwam:** Plex doet **geen enkele duplicaat-hygiëne**.
Eén seed gaf vijf andere kopieën van datzelfde nummer terug plus drie van een tweede.
`SonicSelection.dropNearDuplicates` moet er altijd achter blijven.

---

## 4. Transcode, offline, formaat

| | status |
|---|---|
| **Transcode** | ✅ AAC + Opus (runtime-probe), bitrate instelbaar, standaard alleen op mobiele data |
| **Offline** | ✅ downloadwachtrij op achtergrond-`URLSession`, "favorieten offline houden", "op mobiele data downloaden", downloads worden nooit automatisch opgeruimd |
| **Afspeelformaat zichtbaar** | ❌ **nergens** |

Dat laatste is een echt gat. Plex levert het kant-en-klaar:

```
Media : bitrate 893 · audioCodec flac · container flac · audioChannels 2
Stream: codec flac · bitDepth 16 · samplingRate 44100 · channels 2
```

Plexamp en Symfonium tonen dit prominent ("FLAC 16/44.1"). Wij hebben de data en
tonen niets — niet in Now Playing, niet in het track-infoblad.

---

## 5. Afspeelfuncties vs Plexamp / Symfonium

| | RoonSage | Plexamp | Symfonium |
|---|---|---|---|
| Gapless | ✅ | ✅ | ✅ |
| Loudness-normalisatie | ✅ | ✅ | ✅ |
| Sleeptimer | ✅ | ✅ | ✅ |
| Visualizer | ✅ | ✅ | — |
| Songteksten (LRC, karaoke) | ✅ | ✅ | ✅ |
| Offline downloads | ✅ | ✅ | ✅ |
| Widgets / Live Activity | ✅ | ✅ | — |
| AirPlay | ✅ | ✅ | — |
| **Crossfade** | ❌ | ✅ | ✅ |
| **Equalizer** | ❌ | — | ✅ |
| **CarPlay** | ❌ | ✅ | ✅ (Android Auto) |
| **Formaat/bitrate tonen** | ❌ | ✅ | ✅ |

---

## 6. Kleinere bevindingen uit de doorloop

1. **Schermtitel afgekapt tot "St…" / "S…"** in de bovenbalk — de titel is
   onleesbaar naast de output-kiezer.
2. **Instellingen is alleen via het ⌘-palet te vinden** — geen zichtbare knop.
3. **"Browse by → Mood" toont genres** (Punk, Hard Rock), geen stemmingen.
4. **Mini-speler toont een placeholder** waar de bibliotheek wél een hoes heeft.
5. **Gemengde taal**: het palet-kopje "Navigatie" is hardgecodeerd Nederlands in
   een Engelse UI.
6. **Een track speelde niet af** (`AVError` / `FigFilePlayer signalled err`) — dat
   was het symptoom dat de dubbele-bibliotheek-bug blootlegde.
7. **De versie in "Over" zegt 1.6.2 (build 1)** op een simulatorbuild.

### De ernstigste, en die was van mij
Na de Plex-import stonden **local** en **plex** allebei in de bibliotheek zonder
dat een van beide de ander verdrong:

```
local  65.871
plex   65.719      48.663 recordings in ALLEBEI
roon   16.102
147.692 rijen voor 79.704 unieke nummers → ~68.000 duplicaten
```

Gefixt in `v1.10.291`. De live database heeft de opschoning nog nodig; die gebeurt
bij de eerste Plex-sync ná de uitrol van `analyzer-v1.1.223`.

---

## 7. Plan — naar Plexamp/Symfonium-niveau

Op volgorde van waarde per eenheid werk.

### A. Afmaken wat half is (klein, hoge waarde)
1. **Formaat tonen** — "FLAC 16/44.1 · 893 kbps" in Now Playing en het track-infoblad,
   plus een badge als er getranscodeerd wordt. Data is er al.
2. **Zichtbare Instellingen-knop** in de bovenbalk.
3. **Schermtitel niet meer afkappen** — titel onder de balk, of de output-kiezer inklappen.
4. **"Mood" hernoemen naar "Genre"**, of echte mood-chips uit de CLAP-labels halen.
5. **Palet-kopjes lokaliseren.**

### B. Plex' analyse volledig benutten (middel, dat is de snelheidswinst)
6. **Artiest- en album-radio via `/nearest`** op de artiest/album-ratingKey.
7. **Slimme wachtrij-top-up via `/nearest`** op de laatst gespeelde track — dat maakt
   "endless" gratis en verwijdert de vectorindex uit het afspeelpad.
8. **Plex' eigen mixes tonen** naast de eigen stations.

### C. Speler op niveau brengen (middel)
9. **Crossfade** — Plexamp en Symfonium hebben het allebei; `AVQueuePlayer` +
   `AVAudioMix` heeft de haken al (de loudness-mix gebruikt ze).
10. **Equalizer** via `AVAudioUnitEQ` — het grootste gat versus Symfonium.
11. **CarPlay** — `CPNowPlayingTemplate` + een bibliotheek-tab.

### D. Zelfstandig worden afmaken (groot)
12. **Historie/feedback/playlists lokaal** — nu leven die alleen op de mini. Zonder
    dat is een standalone toestel wél een speler maar vergeet het alles.
13. **Fase 4b**: artwork/offline/transcode volledig van Plex.
14. **Fase 5**: de share-server van vereiste naar uitbreiding.

### Wat NIET moet
- De analyzer schrappen. Plex heeft geen BPM, geen Camelot, geen vectoren — dat
  zijn precies de functies die deze app onderscheiden van Plexamp.
- `/nearest` zonder terugval gebruiken. Het is ongedocumenteerd en kan bij een
  Plex-update breken; de kanarie-test (`testLiveNearestEndpointStillAnswers`)
  bestaat daarvoor.
