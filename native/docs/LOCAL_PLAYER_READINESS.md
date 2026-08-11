# Hoe ver is RoonSage als lokale muziekspeler?

> Gegenereerd: 2026-08-11, na de local-first-serie (v1.10.228 → v1.10.238).
> Vraag van de user: "kijk in hoeverre hij nu al werkt als lokale music player?
> Het moet een soort Plexamp worden. Dus ook qua optimalisatie en snelheid."
>
> **Methode:** waar mogelijk gemeten, niet ingeschat. De cijfers hieronder komen
> van de echte `library.db` op de Mac mini (87.820 tracks, 477 MB) via een kopie
> in `/tmp`, plus greps over de code. Wat ik hier niet kan meten — opstarttijd op
> een iPhone, werkelijk RSS onder iOS, hoorbaar gedrag — staat expliciet als
> ongemeten gemarkeerd. De commando's staan onderaan.
>
> Verwant: [JELLYFIN_AUDIT](JELLYFIN_AUDIT.md) (ontbrekende features t.o.v. het
> Jellyfin-ecosysteem) en [LOCAL_FIRST_AUDIT](LOCAL_FIRST_AUDIT.md) (features die
> alleen op een zone werkten — afgerond).

---

## 1. Oordeel in één alinea

Als **speler in huis, op het netwerk** is RoonSage er grotendeels: één uitvoerpad,
gapless, bewerkbare wachtrij, loudness-normalisatie op gemeten LUFS, stations die
ook lokaal draaien, en een bibliotheek die op 87.820 tracks in tientallen
milliseconden bladert. Als **draagbare speler** — de Plexamp-belofte — is hij het
niet: zonder de mini kun je alleen horen wat toevallig in de cache staat, en de
sonische kant zet 113 MB in het RAM van je telefoon zonder dat ooit los te laten.
Dat zijn de twee dingen die tussen "goede thuisspeler" en "Plexamp" in staan; de
rest is afwerking.

## 2. Wat nu al werkt (gemeten of geverifieerd)

| | |
|---|---|
| Één speelpad | elke play/queue-verb routeert via de actieve uitvoer; zone-gates 62 → 15 |
| Gapless | `AVQueuePlayer` met één item vooruit (**hoorbaar nog niet geverifieerd**) |
| Wachtrij | tonen, herordenen, verwijderen, springen, leegmaken — méér dan de Roon-kant kan |
| Loudness | per track én per album, op analyzer-gemeten LUFS |
| Stations | Sonic/Song/Custom Radio, DJ-modi en Adventure draaien op dit apparaat |
| Scrobbelen | lokale plays gaan naar Last.fm én `listening_history` (sinds v1.10.235) |
| Systeemintegratie | lockscreen, Control Center, CarPlay, Live Activity, widgets, Handoff, Siri |
| Afspeel-cache | wat je speelde blijft lokaal; overgeslagen op mobiele data |
| Actie-pariteit | lokaal Nu-speelt heeft dezelfde zes acties als de zone-hero |

En wat geen enkele concurrent heeft: **Roon-zones als uitvoer**. RAAT is gesloten;
Symfonium cast naar Chromecast, Sonos en zelfs Plexamp-clients, maar niet naar
Roon.

## 3. Snelheid en geheugen — de meting

**Database** (87.820 tracks, 477 MB):

| Tabel | MB |
|---|---|
| `track_audio_features` | 227,5 |
| `track_lyrics` | 86,3 |
| `tracks` | 25,0 |
| `lyrics_fts_data` | 11,7 |

**Hot queries** (sqlite3-CLI incl. procesopstart, dus in de app sneller):

| Query | Plan | Tijd |
|---|---|---|
| Trackpagina op titel (200) | index `idx_tracks_lower_title_artist` | **23 ms** |
| Tracks van één album | index `idx_tracks_album_key` | **20 ms** |
| Albumgrid (120) | index + temp B-tree voor ORDER BY | **74 ms** |
| Artiestengrid (120) | **volledige SCAN** + temp B-tree | **66 ms** |

Oordeel: gezond. Pagination (200 tracks / 120 grid) en een zoek-debounce van
250 ms staan er al. Het artiestengrid is de enige die zonder index draait — nu
onschuldig, maar hij schaalt lineair mee met de bibliotheek.

**Geheugen:**

| Post | Omvang | Wordt vrijgegeven? |
|---|---|---|
| Sonische vectorindex | 58.069 × 512 × 4 B = **113 MB** | **nee** |
| Afbeeldingscache (RAM) | plafond 96 MB / 400 items | ja — `NSCache` wijkt onder druk |
| Album-art op schijf | 34 MB (limiet 200 MB) | LRU-pruning |
| Audio-cache op schijf | limiet 2 GB, instelbaar | LRU-pruning |

## 4. Gap-analyse t.o.v. Plexamp

Severity: 🔴 blokkeert de Plexamp-belofte · 🟠 merkbaar · ⚪ afwerking.
Effort: S (<1u) · M (uren) · L (dag+)

### P1 🔴 L — Offline downloads
Nog steeds het grootste gat, en het derde audit-document waarin het bovenaan
staat (`KOEL_AUDIT` K1, `JELLYFIN_AUDIT` J2). De afspeel-cache (J1) vult zich
alleen met wat je toevallig al speelde en is een cache, geen bibliotheek: je kunt
niet zeggen "neem dit album mee". Zonder bereik is dit geen draagbare speler.
Het fundament ligt er nu wel — `LocalAudioCache` is de opslaglaag, wat ontbreekt
is markeren, een downloadwachtrij en een offline-filter in de UI.

### P2 🔴 M — De sonische index kost 113 MB op je telefoon
`activeIndex` bouwt de `VectorIndex` **client-side uit de eigen DB** — er is geen
remote-tak (`RoonClient+Features.swift:25`). Zodra je Similar, Music Map, Song
Paths, Alchemy of een station gebruikt, staat er 58.069 × 512 float32 = 113 MB
resident. `SonicLibraryCache.invalidate()` bestaat, maar wordt alleen bij een
sync of een handmatige reload aangeroepen: **er is nergens
`didReceiveMemoryWarning`-afhandeling**, dus onder druk laat de app dit niet los.
De afbeeldingscache doet dat wél (`NSCache` wijkt vanzelf).

Op een Mac is dat prima. Op een iPhone is 113 MB naast de art-cache en de
AVPlayer-buffers een reëel jetsam-risico, precies tijdens muziek luisteren.
**Voorstel:** (a) de cache loslaten op een memory warning; (b) overwegen de
k-NN-vraag aan de analyzer te stellen in plaats van de matrix mee te dragen —
de server heeft hem toch al. **Ongemeten:** werkelijke RSS op een toestel; dat
vraagt een Instruments-run die ik hier niet kan draaien.

### P3 🟠 S — Artiestengrid scant de hele tabel
De enige hot query zonder index. 66 ms nu, maar hij groeit mee.
**Voorstel:** een index op `LOWER(artist)`, zoals `idx_tracks_lower_title_artist`
al voor titels bestaat.

### P4 🟠 M — Gapless is ongehoord, en de klik staat er nog
De boekhouding is getest, het geluid niet. En de loudness-gain hangt aan
`player.volume` (per speler, niet per item), dus hij verschuift net ná de
overgang — het mechanisme achter de klik die Finamp-gebruikers melden. Fix is een
per-item `AVAudioMix`; die vraagt async laden van de asset-track.

### P5 🟠 S/M — Geen AirPlay-routekiezer
`AVRoutePickerView` ontbreekt nog steeds. Extra zuur nu de sessie op
`.longFormAudio` staat — precies de policy die AirPlay 2 als long-form route laat
aanbieden.

### P6 🟠 M — Geen fades
Geen crossfade, en de sleeptimer knipt hard weg. Sinds de `AVQueuePlayer`-ombouw
is een volume-ramp bij pauze/stop/slaaptimer goedkoop. Let op: crossfade mag
níét aan tussen tracks van hetzelfde album, anders sloop je de gapless-winst.

### P7 🟠 M — Zoeken zit nog per scherm
Voor de derde keer gevonden (`KOEL_AUDIT` K3, `JELLYFIN_AUDIT` J6). Bij 87.820
tracks te veel deuren: Library, Ask, CustomRadioEditor en SonicSearch los.

### P8 ⚪ L — Geen DSP-equalizer
Vraagt `AVAudioEngine` in plaats van `AVQueuePlayer`: dezelfde motorombouw als
echte crossfade. Plan ze samen of geen van beide.

### P9 ⚪ S — Half-offline is niet zichtbaar
Zonder de mini blijft bladeren werken (lokale GRDB) en tonen eerder geziene
hoezen zich (schijfcache), maar afspelen lukt alleen uit de audio-cache en
sonisch zoeken faalt (`/text-embed`). De app zegt daar niets over; je merkt het
pas als je op play drukt. **Voorstel:** één statusregel die zegt wat er nu wél kan.

### Bewust NIET overnemen van Plexamp
- **Eigen sonic-analyse-blackbox** — die van ons is CLAP en van onszelf.
- **Plex-account/cloudkoppeling** — library-first, één gebruiker.
- **Visualizers als hoofdfeature** — we hebben er één, dat is genoeg.

## 5. Aanbevolen volgorde

| Batch | Inhoud | Effort | Waarom |
|---|---|---|---|
| 1 | P2 geheugen loslaten + P3 artiest-index | S/M | goedkoop, en P2 is een crashrisico op je telefoon |
| 2 | P5 AirPlay + P6 fades (nog geen crossfade) | S/M | klein, zichtbaar, sluit ROADMAP D9 af |
| 3 | P4 per-item AVAudioMix (de klik) | M | maakt gapless af |
| 4 | **P1 offline downloads** | L | het eigenlijke Plexamp-gat; bouwt op de bestaande cache |
| 5 | P7 één zoekingang | M | drie audits wijzen dezelfde kant op |
| Backlog | P8 EQ + echte crossfade (samen), P9 offline-status | L | tweede motorombouw |

P2 staat bewust vóór alles: het is de enige bevinding die de app kan laten
sneuvelen tijdens gebruik, en het is een paar uur werk.

## 6. Status

- [x] Batch 1 — P2/P3 · v1.10.239 / ios-v1.7.204
      P3 gemeten: 27,0 ms → 2,5 ms per query (10× warm in één proces), 2,55 MB index.
      Twee tests bewaken het nu, rood-groen bewezen door de migratie tijdelijk uit te zetten.
      P2 is compile-geverifieerd en de DispatchSource-API empirisch bevestigd; dat de
      handler onder echte druk vuurt is niet te forceren op deze machine.
- [x] Batch 2 — P5/P6 · AirPlay-routekiezer (`AirPlayRouteButton`) + volume-ramp bij
      pauze/stop/slaaptimer (`LocalPlayback.fade(to:over:then:)`). Echte crossfade
      bewust niet: die deelt de motorombouw met P8.
- [x] Batch 3 — P4 · per-item `AVAudioMix`, zodat de loudness-gain met het item
      meereist in plaats van met de speler. **Of de klik weg is, is ongehoord.**
- [x] Batch 4 — P1 · `RoonClient+Downloads` + `DownloadsView`; twee tiers, pinned
      bestanden in Application Support en nooit gesnoeid.
- [x] Batch 5 — P7 · v1.10.255 / ios-v1.7.220. Eén zoekbalk voor artiest/album/track,
      plus de doorgeefrij naar sonisch zoeken. **De vondst zat niet in de UI maar in de
      SQL:** `searchAlbums`/`searchArtists` sorteren `ORDER BY artist, year, album`,
      dus alfabetisch. Een sectie op vijf afkappen liet de exacte treffer wegvallen —
      "Dire Straits" stond achter "Alchemy: Dire Straits Live". `UnifiedSearch` haalt nu
      120 kandidaten op en herordent op relevantie (exact > prefix > woord-prefix >
      bevat), stabiel zodat de lijst niet flikkert tijdens typen.
- [ ] Backlog — P8 (EQ + echte crossfade, samen; tweede motorombouw naar
      `AVAudioEngine`). P9 is af via de offline-banner.

## 7. Nog altijd niet geverifieerd (vraagt een toestel)

1. Gapless hoorbaar, ook met scherm uit.
2. De klik op de overgang.
3. Een station dat op dit apparaat blijft doorspelen als de wachtrij leegloopt.
4. Of een lokale play op Last.fm verschijnt (`cjjansen13`).
5. Opstarttijd en werkelijk geheugengebruik op de iPhone.

## 8. Meetcommando's (herhaalbaar)

```bash
# DB-omvang en hot queries (werk op een KOPIE — de app heeft de WAL open)
cp ~/Library/Application\ Support/RoonSage/library.db /tmp/audit.db
sqlite3 /tmp/audit.db "SELECT name, ROUND(SUM(pgsize)/1048576.0,1) FROM dbstat
                       GROUP BY name ORDER BY 2 DESC LIMIT 8;"
sqlite3 /tmp/audit.db "EXPLAIN QUERY PLAN
  SELECT artist, COUNT(DISTINCT album_key) FROM tracks WHERE artist IS NOT NULL
  GROUP BY LOWER(artist) ORDER BY LOWER(artist) LIMIT 120;"

# Kosten van de vectorindex
sqlite3 /tmp/audit.db "SELECT COUNT(*) FROM track_audio_features WHERE embedding IS NOT NULL;"
# × 512 × 4 bytes = resident bytes per kopie

# Wordt er iets vrijgegeven onder geheugendruk?
grep -rn 'didReceiveMemoryWarning\|totalCostLimit' native/RoonSage/Sources --include='*.swift'
```
