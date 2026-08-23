@testable import AudioAnalysis
import XCTest

/// Hard identity out of the file's own tags (AudioAnalysis/MetadataReader).
///
/// The routing lives in `applyRawTag` precisely so it can be tested without a
/// tagged audio file: this is where MusicBrainz ids were landing in the artist
/// and album NAME fields — 412 tracks in the real library were keyed on a UUID
/// that way, invisible to every join.
final class TrackIdentityTagsTests: XCTestCase {

    private func route(_ pairs: [(String, String)]) -> TrackMetadata {
        var m = TrackMetadata()
        for (k, v) in pairs { MetadataReader.applyRawTag(k.uppercased(), v, into: &m) }
        return m
    }

    /// Ringo Starr's MB artist id, from the row that exposed this.
    private let artistMBID = "300c4c73-33ac-4255-9d57-4e32627f5e13"
    private let recordingMBID = "b1a9c0e9-d987-4042-ae91-78d6a3267d69"

    // MARK: - The regression

    func testMusicBrainzArtistIDDoesNotBecomeTheArtistName() {
        // The exact enumeration order that broke it: the MB tag before the plain
        // one, in a file whose commonMetadata is empty (most FLACs).
        let m = route([
            ("MUSICBRAINZ_ARTISTID", artistMBID),
            ("ARTIST", "Ringo Starr"),
        ])
        XCTAssertEqual(m.artist, "Ringo Starr")
        XCTAssertEqual(m.artistMBID, artistMBID)
    }

    func testMusicBrainzAlbumIDDoesNotBecomeTheAlbumName() {
        let m = route([
            ("MUSICBRAINZ_ALBUMID", recordingMBID),
            ("ALBUM", "Time Takes Time"),
        ])
        XCTAssertEqual(m.album, "Time Takes Time")
        XCTAssertEqual(m.albumMBID, recordingMBID)
    }

    func testAlbumArtistIDDoesNotBecomeTheArtistNameEither() {
        // MUSICBRAINZ_ALBUMARTISTID contains both "ALBUM" and "ARTIST", so it hit
        // the artist branch first under the old chain.
        let m = route([("MUSICBRAINZ_ALBUMARTISTID", artistMBID)])
        XCTAssertNil(m.artist)
        XCTAssertNil(m.album)
        XCTAssertEqual(m.artistMBID, artistMBID)
    }

    func testABareUUIDIsNeverStoredAsAName() {
        // Belt and braces for a tag scheme we haven't seen: no MUSICBRAINZ
        // prefix, but the value is plainly an identifier.
        let m = route([("ALBUMID", artistMBID), ("ALBUM", "Time Takes Time")])
        XCTAssertEqual(m.album, "Time Takes Time")
    }

    // MARK: - What we now harvest

    func testReadsTheIdentityTagsThatAreActuallyInTheseFiles() {
        let m = route([
            ("ISRC", "GBAYE9900123"),
            ("MUSICBRAINZ_TRACKID", recordingMBID),
            ("MUSICBRAINZ_RELEASETRACKID", "8d51f0d0-2a1e-4b47-96d6-3d0b2f0a11cc"),
            ("ARTIST", "Ringo Starr"),
            ("TITLE", "Golden Blunders"),
        ])
        XCTAssertEqual(m.isrc, "GBAYE9900123")
        XCTAssertEqual(m.recordingMBID, recordingMBID)
        XCTAssertEqual(m.releaseTrackMBID, "8d51f0d0-2a1e-4b47-96d6-3d0b2f0a11cc")
        XCTAssertEqual(m.artist, "Ringo Starr")
        XCTAssertEqual(m.title, "Golden Blunders")
    }

    func testID3TXXXDescriptionsRouteLikeVorbisComments() {
        // ID3 spells it "MusicBrainz Release Track Id"; FLAC spells it
        // MUSICBRAINZ_RELEASETRACKID. Punctuation is squashed so both land.
        let m = route([("MusicBrainz Release Track Id", recordingMBID)])
        XCTAssertEqual(m.releaseTrackMBID, recordingMBID)
    }

    func testFirstTagWinsSoASecondSpellingCannotOverwrite() {
        let m = route([
            ("MUSICBRAINZ_TRACKID", recordingMBID),
            ("MUSICBRAINZ_RECORDINGID", artistMBID),
        ])
        XCTAssertEqual(m.recordingMBID, recordingMBID)
    }

    // MARK: - Normalisation

    func testISRCNormalisesAndRejectsMalformed() {
        XCTAssertEqual(MetadataReader.normalisedISRC("gb-aye-99-00123"), "GBAYE9900123")
        XCTAssertEqual(MetadataReader.normalisedISRC("GBAYE9900123"), "GBAYE9900123")
        // A malformed identifier is worse than none: it would join rows that
        // aren't the same recording.
        XCTAssertNil(MetadataReader.normalisedISRC("GBAYE99001"))       // too short
        XCTAssertNil(MetadataReader.normalisedISRC("1BAYE9900123"))     // country code isn't alphabetic
        XCTAssertNil(MetadataReader.normalisedISRC(""))
        XCTAssertNil(MetadataReader.normalisedISRC(nil))
    }

    func testMBIDNormalisesCaseAndRejectsNonUUIDs() {
        XCTAssertEqual(MetadataReader.normalisedMBID("300C4C73-33AC-4255-9D57-4E32627F5E13"), artistMBID)
        XCTAssertEqual(MetadataReader.normalisedMBID("  \(artistMBID) "), artistMBID)
        XCTAssertNil(MetadataReader.normalisedMBID("not-a-uuid"))
        XCTAssertNil(MetadataReader.normalisedMBID("300c4c73-33ac-4255-9d57-4e32627f5e1"))   // 11 in the tail
        XCTAssertNil(MetadataReader.normalisedMBID("300c4c73_33ac_4255_9d57_4e32627f5e13"))
        XCTAssertNil(MetadataReader.normalisedMBID("zzzc4c73-33ac-4255-9d57-4e32627f5e13"))  // not hex
    }

    func testTagsThatAreNotIdentityStillRouteAsBefore() {
        let m = route([
            ("ARTIST", "Ringo Starr"), ("ALBUM", "Time Takes Time"),
            ("TITLE", "Golden Blunders"), ("GENRE", "Rock"), ("DATE", "1992-05-22"),
        ])
        XCTAssertEqual(m.artist, "Ringo Starr")
        XCTAssertEqual(m.album, "Time Takes Time")
        XCTAssertEqual(m.title, "Golden Blunders")
        XCTAssertEqual(m.genre, "Rock")
        XCTAssertEqual(m.year, 1992)
    }
}
