import Foundation
import CloudKit

// MARK: - Telemetry Event Types

struct ScrollTelemetryEvent: Codable {
    let sessionID: String
    let deviceID: String
    let timestamp: Double          // timeIntervalSince1970
    let cardIndex: Int
    let totalBlocksViewed: Int
    let blocksSeen: Int
    let unlockedCount: Int
    let blocksSinceLastUnlock: Int
    let activeScrollSeconds: Double
    let sessionLengthSeconds: Double
    let timeOfDayBucket: Int       // 0 morning, 1 afternoon, 2 evening, 3 night
    let wasUnlock: Bool
    let skinRarity: String?        // nil = monochrome, "common", "rare", "special"
}

struct SessionEndTelemetryEvent: Codable {
    let sessionID: String
    let deviceID: String
    let timestamp: Double
    let totalBlocksViewed: Int
    let totalUnlocks: Int
    let sessionLengthSeconds: Double
}

// MARK: - BehaviorLogger
//
// Passive telemetry collector. Writes scroll events to local JSON files
// (source of truth) and uploads to CloudKit on session end for automatic
// aggregation across TestFlight devices.
//
// Data is used to train a churn-prediction model post-exhibition.

final class BehaviorLogger {
    static let shared = BehaviorLogger()

    let sessionID = UUID().uuidString
    let deviceID: String

    private var scrollBuffer: [ScrollTelemetryEvent] = []
    private var lastUnlockAtViewCount: Int = 0
    private let flushThreshold = 20   // flush to disk every N events

    private init() {
        // Persistent anonymous device ID (survives app restarts)
        if let existing = UserDefaults.standard.string(forKey: "cs_deviceID") {
            deviceID = existing
        } else {
            let newID = UUID().uuidString
            UserDefaults.standard.set(newID, forKey: "cs_deviceID")
            deviceID = newID
        }
    }

    // MARK: - Log Scroll Event

    func logScroll(
        cardIndex: Int,
        totalBlocksViewed: Int,
        blocksSeen: Int,
        unlockedCount: Int,
        activeScrollSeconds: Double,
        sessionLengthSeconds: Double,
        timeOfDayBucket: Int,
        wasUnlock: Bool,
        skinRarity: BlockRarity?
    ) {
        if wasUnlock { lastUnlockAtViewCount = totalBlocksViewed }

        let event = ScrollTelemetryEvent(
            sessionID: sessionID,
            deviceID: deviceID,
            timestamp: Date().timeIntervalSince1970,
            cardIndex: cardIndex,
            totalBlocksViewed: totalBlocksViewed,
            blocksSeen: blocksSeen,
            unlockedCount: unlockedCount,
            blocksSinceLastUnlock: totalBlocksViewed - lastUnlockAtViewCount,
            activeScrollSeconds: activeScrollSeconds,
            sessionLengthSeconds: sessionLengthSeconds,
            timeOfDayBucket: timeOfDayBucket,
            wasUnlock: wasUnlock,
            skinRarity: skinRarity?.rawValue
        )

        scrollBuffer.append(event)

        if scrollBuffer.count >= flushThreshold {
            flushToDisk()
        }
    }

    // MARK: - Session End

    func logSessionEnd(
        totalBlocksViewed: Int,
        totalUnlocks: Int,
        sessionLengthSeconds: Double
    ) {
        // Final flush of any buffered scroll events
        flushToDisk()

        let endEvent = SessionEndTelemetryEvent(
            sessionID: sessionID,
            deviceID: deviceID,
            timestamp: Date().timeIntervalSince1970,
            totalBlocksViewed: totalBlocksViewed,
            totalUnlocks: totalUnlocks,
            sessionLengthSeconds: sessionLengthSeconds
        )

        if let data = try? JSONEncoder().encode(endEvent) {
            try? data.write(to: sessionEndFileURL, options: .atomic)
        }

        syncToCloudKit()
    }

    // MARK: - File URLs

    private var docsDir: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
    }

    private var scrollEventsFileURL: URL {
        docsDir.appendingPathComponent("telemetry_scrolls_\(sessionID).json")
    }

    private var sessionEndFileURL: URL {
        docsDir.appendingPathComponent("telemetry_session_\(sessionID).json")
    }

    // MARK: - Disk I/O

    private func flushToDisk() {
        guard !scrollBuffer.isEmpty else { return }

        // Read existing events (if any) and append the buffer
        var all: [ScrollTelemetryEvent] = []
        if let data = try? Data(contentsOf: scrollEventsFileURL),
           let existing = try? JSONDecoder().decode([ScrollTelemetryEvent].self, from: data) {
            all = existing
        }
        all.append(contentsOf: scrollBuffer)
        scrollBuffer.removeAll()

        if let data = try? JSONEncoder().encode(all) {
            try? data.write(to: scrollEventsFileURL, options: .atomic)
        }
    }

    // MARK: - CloudKit Sync
    //
    // Uploads the session's JSON files as CKAssets on a single "Session" record.
    // One record per session — keeps the schema minimal.
    //
    // ⚠️ First run must be in Xcode (dev environment) to create the record type,
    //     then deploy schema to production via CloudKit Dashboard before TestFlight.

    private func syncToCloudKit() {
        Task {
            let container = CKContainer(identifier: "iCloud.com.apandji.ColorScroller")

            // Diagnostic: check account status
            do {
                let status = try await container.accountStatus()
                print("[BehaviorLogger] Account status: \(status.rawValue) (1=available, 0=couldNotDetermine, 2=restricted, 3=noAccount, 4=temporarilyUnavailable)")
                print("[BehaviorLogger] Container ID: \(container.containerIdentifier ?? "nil")")
            } catch {
                print("[BehaviorLogger] ⚠️ Account status check failed: \(error)")
            }

            let maxRetries = 4

            for attempt in 1...maxRetries {
                do {
                    let record = CKRecord(recordType: "Session")
                    record["sessionID"] = sessionID as NSString
                    record["deviceID"] = deviceID as NSString
                    record["timestamp"] = NSNumber(value: Date().timeIntervalSince1970)

                    let fm = FileManager.default
                    if fm.fileExists(atPath: scrollEventsFileURL.path) {
                        record["scrollEventsFile"] = CKAsset(fileURL: scrollEventsFileURL)
                    }
                    if fm.fileExists(atPath: sessionEndFileURL.path) {
                        record["sessionEndFile"] = CKAsset(fileURL: sessionEndFileURL)
                    }

                    let db = container.publicCloudDatabase
                    try await db.save(record)
                    print("[BehaviorLogger] ✅ CloudKit sync OK — session \(sessionID)")
                    return  // Success — done

                } catch let ckError as CKError {
                    let retryAfter = ckError.retryAfterSeconds ?? 5.0
                    let isRetryable = ckError.code == .serviceUnavailable ||
                                      ckError.code == .requestRateLimited ||
                                      ckError.code == .networkFailure ||
                                      ckError.code == .networkUnavailable

                    print("[BehaviorLogger] ⚠️ Attempt \(attempt)/\(maxRetries) failed:")
                    print("  Code: \(ckError.code.rawValue) (\(ckError.code))")
                    print("  Description: \(ckError.localizedDescription)")

                    if isRetryable && attempt < maxRetries {
                        print("  ⏳ Retrying in \(Int(retryAfter))s...")
                        try? await Task.sleep(nanoseconds: UInt64(retryAfter * 1_000_000_000))
                        continue
                    }

                    print("[BehaviorLogger] ❌ CloudKit sync failed after \(attempt) attempts")
                    if let underlying = ckError.userInfo[NSUnderlyingErrorKey] as? NSError {
                        print("  Underlying: \(underlying)")
                    }
                    // Local files are the source of truth — data is not lost
                    return

                } catch {
                    print("[BehaviorLogger] ❌ CloudKit sync failed: \(error)")
                    return
                }
            }
        }
    }

    // MARK: - Export (debug panel fallback)

    func exportFileURLs() -> [URL] {
        flushToDisk()
        let fm = FileManager.default
        var urls: [URL] = []
        if fm.fileExists(atPath: scrollEventsFileURL.path) { urls.append(scrollEventsFileURL) }
        if fm.fileExists(atPath: sessionEndFileURL.path) { urls.append(sessionEndFileURL) }
        return urls
    }

    // MARK: - Debug: Fetch All CloudKit Records

    func fetchAllCloudKitRecords() {
        Task {
            let container = CKContainer(identifier: "iCloud.com.apandji.ColorScroller")
            let db = container.publicCloudDatabase

            let query = CKQuery(recordType: "Session", predicate: NSPredicate(value: true))

            do {
                let (results, _) = try await db.records(matching: query, resultsLimit: 100)
                print("\n══════════════════════════════════════")
                print("📊 CloudKit Records: \(results.count) found")
                print("══════════════════════════════════════")

                for (_, result) in results {
                    switch result {
                    case .success(let record):
                        let sid = record["sessionID"] as? String ?? "?"
                        let did = record["deviceID"] as? String ?? "?"
                        let ts = record["timestamp"] as? Double ?? 0
                        let date = Date(timeIntervalSince1970: ts)
                        let hasScrolls = record["scrollEventsFile"] != nil
                        let hasEnd = record["sessionEndFile"] != nil
                        print("  Session: \(sid.prefix(8))...")
                        print("  Device:  \(did.prefix(8))...")
                        print("  Time:    \(date)")
                        print("  Scroll events file: \(hasScrolls ? "✅" : "❌")")
                        print("  Session end file:   \(hasEnd ? "✅" : "❌")")
                        print("  ──────────────────────────────────")
                    case .failure(let error):
                        print("  ❌ Record error: \(error.localizedDescription)")
                    }
                }
                print("══════════════════════════════════════\n")
            } catch {
                print("[BehaviorLogger] ❌ CloudKit query failed: \(error.localizedDescription)")
            }
        }
    }
}
