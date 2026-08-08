@testable import RoonSageCore
import XCTest

/// Backup retention and the housekeeping boundaries. The retention rule is where
/// this class of code goes wrong — "delete the old ones" that deletes the newest,
/// or that eats a neighbouring file — so it is pure and asserted directly.
final class MaintenanceTests: XCTestCase {

    // MARK: - Backup filenames

    func testBackupFilenamesSortChronologicallyAsStrings() {
        let early = DatabaseManager.backupFilename(at: Date(timeIntervalSince1970: 1_700_000_000))
        let late = DatabaseManager.backupFilename(at: Date(timeIntervalSince1970: 1_800_000_000))
        XCTAssertLessThan(early, late, "de retentie leunt op lexicografische volgorde")
        XCTAssertTrue(late.hasPrefix("library-"))
        XCTAssertTrue(late.hasSuffix(".db"))
    }

    func testBackupDirectorySitsNextToTheDatabase() {
        let db = URL(fileURLWithPath: "/data/RoonSage/library.db")
        XCTAssertEqual(DatabaseManager.backupDirectory(for: db).path, "/data/RoonSage/backups")
    }

    // MARK: - Retention

    private let names = [
        "library-20260801-030000.db",
        "library-20260802-030000.db",
        "library-20260803-030000.db",
        "library-20260804-030000.db",
        "library-20260805-030000.db",
    ]

    func testPruneKeepsTheNewestN() {
        let doomed = DatabaseManager.prunableBackups(names, keep: 2)
        XCTAssertEqual(doomed, [
            "library-20260801-030000.db",
            "library-20260802-030000.db",
            "library-20260803-030000.db",
        ])
        XCTAssertFalse(doomed.contains("library-20260805-030000.db"),
                       "de nieuwste back-up mag NOOIT weg")
    }

    func testPruneIsANoOpWhenThereAreFewerThanKeep() {
        XCTAssertEqual(DatabaseManager.prunableBackups(names, keep: 5), [])
        XCTAssertEqual(DatabaseManager.prunableBackups(names, keep: 10), [])
        XCTAssertEqual(DatabaseManager.prunableBackups([], keep: 3), [])
    }

    /// The directory sits next to `library.db`; anything that is not one of our
    /// own backups must be left strictly alone.
    func testPruneNeverTouchesForeignFiles() {
        let mixed = names + [
            "library.db",                    // the live database
            "library.db-wal",
            "aantekeningen.txt",
            "library-oud.db.bak",
        ]
        let doomed = DatabaseManager.prunableBackups(mixed, keep: 1)
        XCTAssertFalse(doomed.contains("library.db"), "de LIVE database mag nooit in de lijst staan")
        XCTAssertFalse(doomed.contains("library.db-wal"))
        XCTAssertFalse(doomed.contains("aantekeningen.txt"))
        XCTAssertFalse(doomed.contains("library-oud.db.bak"))
        XCTAssertEqual(doomed.count, 4, "alleen onze eigen back-ups, min de nieuwste")
    }

    func testKeepZeroPrunesEverythingOfOurs() {
        XCTAssertEqual(DatabaseManager.prunableBackups(names, keep: 0).count, names.count)
    }

    func testNegativeKeepIsRefusedRatherThanInterpreted() {
        XCTAssertEqual(DatabaseManager.prunableBackups(names, keep: -1), [],
                       "een onzinnige retentie mag niet alles wissen")
    }

    // MARK: - Housekeeping report

    func testHousekeepingReportStartsEmpty() {
        let r = DatabaseManager.HousekeepingReport()
        XCTAssertEqual(r.expiredEditorial, 0)
        XCTAssertEqual(r.oldBatches, 0)
        XCTAssertEqual(r.oldBatchItems, 0)
    }
}
