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

    // MARK: - Scheduled library sync guards

    /// The Roon Browse API is single-session, so two walks at once fight each
    /// other. A manual sync must always win; the scheduled one steps aside.
    func testScheduledSyncStepsAsideForAManualOne() {
        XCTAssertEqual(
            RoonClient.shouldRunScheduledSync(isSyncing: true, isConnected: true), .skipBusy)
    }

    /// No Core attached is "try again later", not a failure — the connect loop is
    /// already retrying and a red task would be noise.
    func testScheduledSyncWaitsWhenTheCoreIsAbsent() {
        XCTAssertEqual(
            RoonClient.shouldRunScheduledSync(isSyncing: false, isConnected: false), .waitForCore)
    }

    func testScheduledSyncRunsWhenIdleAndConnected() {
        XCTAssertEqual(
            RoonClient.shouldRunScheduledSync(isSyncing: false, isConnected: true), .run)
    }

    /// Busy beats disconnected: if a walk is somehow in flight we never start a
    /// second one, whatever the connection says.
    func testBusyTakesPrecedenceOverDisconnected() {
        XCTAssertEqual(
            RoonClient.shouldRunScheduledSync(isSyncing: true, isConnected: false), .skipBusy)
    }

    // MARK: - Live DatabaseManager execution (VACUUM / VACUUM INTO)

    func testRunBackupCreatesValidDatabase() async throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("roonsage-backup-test-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let dbURL = dir.appendingPathComponent("library.db")
        let db = try DatabaseManager(url: dbURL)
        let backupURL = try await db.runBackup(databaseURL: dbURL, keep: 3)

        XCTAssertTrue(FileManager.default.fileExists(atPath: backupURL.path))
        // Verify the backed up DB opens and passes integrity check
        let backupDB = try DatabaseManager(url: backupURL)
        let count = try await backupDB.trackCount()
        XCTAssertEqual(count, 0)
    }

    func testRunHousekeepingExecutesVacuumSuccessfully() async throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("roonsage-housekeeping-test-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let dbURL = dir.appendingPathComponent("library.db")
        let db = try DatabaseManager(url: dbURL)
        let report = try await db.runHousekeeping(editorialTTLDays: 30, batchRetentionDays: 180)
        XCTAssertEqual(report.expiredEditorial, 0)
        XCTAssertEqual(report.oldBatches, 0)
        XCTAssertEqual(report.oldBatchItems, 0)
    }
}

