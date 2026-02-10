import SwiftUI
import CloudKit
import Combine

// MARK: - Data Model

struct SessionRecord: Identifiable {
    let id: String          // recordName
    let sessionID: String
    let deviceID: String
    let timestamp: Date
    let scrollEvents: [ScrollTelemetryEvent]?
    let sessionEnd: SessionEndTelemetryEvent?
}

// MARK: - ViewModel

@MainActor
final class TelemetryDashboardVM: ObservableObject {
    @Published var sessions: [SessionRecord] = []
    @Published var isLoading = false
    @Published var errorMessage: String?
    @Published var statusMessage: String?

    private let container = CKContainer(identifier: "iCloud.com.apandji.ColorScroller")
    private let maxRetries = 3

    func fetch() async {
        isLoading = true
        errorMessage = nil
        statusMessage = "Connecting to CloudKit..."

        // Check account first
        do {
            let status = try await container.accountStatus()
            let statusName = ["couldNotDetermine", "available", "restricted", "noAccount", "temporarilyUnavailable"]
            let name = status.rawValue < statusName.count ? statusName[Int(status.rawValue)] : "unknown"
            statusMessage = "Account: \(name)"
            if status != .available {
                errorMessage = "iCloud account not available (status: \(name)). Sign into iCloud in Settings."
                isLoading = false
                return
            }
        } catch {
            statusMessage = "Account check failed"
        }

        // Retry loop for 503s
        let db = container.publicCloudDatabase
        let query = CKQuery(recordType: "Session", predicate: NSPredicate(value: true))

        for attempt in 1...maxRetries {
            statusMessage = attempt > 1 ? "Retry \(attempt)/\(maxRetries)..." : "Querying records..."

            do {
                let (results, _) = try await db.records(matching: query, resultsLimit: 200)
                var loaded: [SessionRecord] = []

                statusMessage = "Parsing \(results.count) records..."

                for (_, result) in results {
                    if case .success(let record) = result {
                        let sid = record["sessionID"] as? String ?? "—"
                        let did = record["deviceID"] as? String ?? "—"
                        let ts  = record["timestamp"] as? Double ?? 0
                        let date = Date(timeIntervalSince1970: ts)

                        // Parse CKAsset JSON files
                        var scrollEvents: [ScrollTelemetryEvent]?
                        var sessionEnd: SessionEndTelemetryEvent?

                        if let scrollAsset = record["scrollEventsFile"] as? CKAsset,
                           let url = scrollAsset.fileURL,
                           let data = try? Data(contentsOf: url) {
                            scrollEvents = try? JSONDecoder().decode([ScrollTelemetryEvent].self, from: data)
                        }

                        if let endAsset = record["sessionEndFile"] as? CKAsset,
                           let url = endAsset.fileURL,
                           let data = try? Data(contentsOf: url) {
                            sessionEnd = try? JSONDecoder().decode(SessionEndTelemetryEvent.self, from: data)
                        }

                        loaded.append(SessionRecord(
                            id: record.recordID.recordName,
                            sessionID: sid,
                            deviceID: did,
                            timestamp: date,
                            scrollEvents: scrollEvents,
                            sessionEnd: sessionEnd
                        ))
                    }
                }

                sessions = loaded.sorted { $0.timestamp > $1.timestamp }
                statusMessage = nil
                isLoading = false
                return  // Success — exit retry loop

            } catch let ckError as CKError {
                let code = ckError.code.rawValue
                let retryable = (code == 7 || code == 503)  // serviceUnavailable or HTTP 503
                let retryAfter = ckError.retryAfterSeconds ?? 2.0

                if retryable && attempt < maxRetries {
                    statusMessage = "Server busy (503) — retrying in \(Int(retryAfter))s..."
                    try? await Task.sleep(nanoseconds: UInt64(retryAfter * 1_000_000_000))
                    continue
                }

                errorMessage = "CloudKit error \(code): \(ckError.localizedDescription)"
                statusMessage = nil
                isLoading = false
                return

            } catch {
                if attempt < maxRetries {
                    statusMessage = "Error — retrying..."
                    try? await Task.sleep(nanoseconds: 2_000_000_000)
                    continue
                }
                errorMessage = error.localizedDescription
                statusMessage = nil
                isLoading = false
                return
            }
        }

        isLoading = false
    }
}

// MARK: - Dashboard View

struct TelemetryDashboardView: View {
    @StateObject private var vm = TelemetryDashboardVM()
    @Environment(\.dismiss) private var dismiss

    private var uniqueDevices: Int {
        Set(vm.sessions.map(\.deviceID)).count
    }

    private var totalBlocksSwiped: Int {
        vm.sessions.compactMap { $0.sessionEnd?.totalBlocksViewed }.reduce(0, +)
    }

    private var totalUnlocks: Int {
        vm.sessions.compactMap { $0.sessionEnd?.totalUnlocks }.reduce(0, +)
    }

    private var totalSessionTime: Double {
        vm.sessions.compactMap { $0.sessionEnd?.sessionLengthSeconds }.reduce(0, +)
    }

    private var avgSessionTime: Double {
        let times = vm.sessions.compactMap { $0.sessionEnd?.sessionLengthSeconds }
        guard !times.isEmpty else { return 0 }
        return times.reduce(0, +) / Double(times.count)
    }

    var body: some View {
        NavigationView {
            ZStack {
                Color.black.ignoresSafeArea()

                if vm.isLoading && vm.sessions.isEmpty {
                    VStack(spacing: 16) {
                        ProgressView()
                            .tint(.white)
                            .scaleEffect(1.2)
                        Text(vm.statusMessage ?? "Fetching CloudKit data...")
                            .font(.system(size: 13, weight: .medium, design: .monospaced))
                            .foregroundStyle(.white.opacity(0.5))
                            .multilineTextAlignment(.center)
                    }
                } else if let error = vm.errorMessage {
                    VStack(spacing: 12) {
                        Image(systemName: "exclamationmark.icloud")
                            .font(.system(size: 36))
                            .foregroundStyle(.red.opacity(0.7))
                        Text(error)
                            .font(.system(size: 12, design: .monospaced))
                            .foregroundStyle(.white.opacity(0.6))
                            .multilineTextAlignment(.center)
                            .padding(.horizontal)
                        Button("Retry") { Task { await vm.fetch() } }
                            .font(.system(size: 14, weight: .semibold))
                            .padding(.top, 4)
                    }
                } else {
                    ScrollView {
                        VStack(spacing: 20) {
                            // Header
                            headerSection

                            // Summary cards
                            summaryGrid

                            // Session list
                            sessionList
                        }
                        .padding(.horizontal, 16)
                        .padding(.bottom, 40)
                    }
                }
            }
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Text("TELEMETRY")
                        .font(.system(size: 16, weight: .black, design: .monospaced))
                        .foregroundStyle(.white)
                }
                ToolbarItem(placement: .topBarTrailing) {
                    HStack(spacing: 12) {
                        Button {
                            Task { await vm.fetch() }
                        } label: {
                            Image(systemName: "arrow.clockwise")
                                .font(.system(size: 14, weight: .semibold))
                        }
                        Button("Done") { dismiss() }
                            .font(.system(size: 14, weight: .semibold))
                    }
                }
            }
            .toolbarBackground(.black, for: .navigationBar)
            .toolbarColorScheme(.dark, for: .navigationBar)
        }
        .preferredColorScheme(.dark)
        .task { await vm.fetch() }
    }

    // MARK: - Header

    private var headerSection: some View {
        VStack(spacing: 4) {
            HStack(spacing: 8) {
                Circle()
                    .fill(vm.sessions.isEmpty ? .gray : .green)
                    .frame(width: 8, height: 8)
                Text(vm.sessions.isEmpty ? "NO DATA" : "LIVE")
                    .font(.system(size: 11, weight: .bold, design: .monospaced))
                    .foregroundStyle(vm.sessions.isEmpty ? .gray : .green)
            }
            .padding(.top, 8)

            Text("\(vm.sessions.count)")
                .font(.system(size: 48, weight: .black, design: .rounded))
                .foregroundStyle(.white)
            Text("sessions recorded")
                .font(.system(size: 12, weight: .medium, design: .monospaced))
                .foregroundStyle(.white.opacity(0.4))
        }
    }

    // MARK: - Summary Grid

    private var summaryGrid: some View {
        LazyVGrid(columns: [
            GridItem(.flexible(), spacing: 12),
            GridItem(.flexible(), spacing: 12)
        ], spacing: 12) {
            StatCard(title: "DEVICES", value: "\(uniqueDevices)", icon: "iphone", color: .cyan)
            StatCard(title: "BLOCKS SWIPED", value: "\(totalBlocksSwiped)", icon: "hand.draw", color: .orange)
            StatCard(title: "UNLOCKS", value: "\(totalUnlocks)", icon: "lock.open", color: .green)
            StatCard(title: "AVG SESSION", value: formatDuration(avgSessionTime), icon: "clock", color: .purple)
            StatCard(title: "TOTAL TIME", value: formatDuration(totalSessionTime), icon: "hourglass", color: .pink)
            StatCard(title: "SCROLL EVENTS", value: "\(vm.sessions.compactMap { $0.scrollEvents?.count }.reduce(0, +))", icon: "list.bullet", color: .yellow)
        }
    }

    // MARK: - Session List

    private var sessionList: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("SESSIONS")
                .font(.system(size: 11, weight: .bold, design: .monospaced))
                .foregroundStyle(.white.opacity(0.4))
                .padding(.top, 8)

            ForEach(vm.sessions) { session in
                SessionRow(session: session)
            }
        }
    }

    private func formatDuration(_ seconds: Double) -> String {
        if seconds < 60 { return String(format: "%.0fs", seconds) }
        let m = Int(seconds) / 60
        let s = Int(seconds) % 60
        return "\(m)m \(s)s"
    }
}

// MARK: - Stat Card

struct StatCard: View {
    let title: String
    let value: String
    let icon: String
    let color: Color

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Image(systemName: icon)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(color)
                Spacer()
            }
            Text(value)
                .font(.system(size: 22, weight: .bold, design: .rounded))
                .foregroundStyle(.white)
            Text(title)
                .font(.system(size: 9, weight: .bold, design: .monospaced))
                .foregroundStyle(.white.opacity(0.35))
        }
        .padding(14)
        .background(Color.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(color.opacity(0.2), lineWidth: 1)
        )
    }
}

// MARK: - Session Row

struct SessionRow: View {
    let session: SessionRecord
    @State private var expanded = false

    private var timeAgo: String {
        let interval = Date().timeIntervalSince(session.timestamp)
        if interval < 60 { return "just now" }
        if interval < 3600 { return "\(Int(interval / 60))m ago" }
        if interval < 86400 { return "\(Int(interval / 3600))h ago" }
        return "\(Int(interval / 86400))d ago"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Main row
            Button {
                withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) {
                    expanded.toggle()
                }
            } label: {
                HStack {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(session.sessionID.prefix(12) + "...")
                            .font(.system(size: 13, weight: .semibold, design: .monospaced))
                            .foregroundStyle(.white)
                        Text(timeAgo)
                            .font(.system(size: 11, weight: .medium, design: .monospaced))
                            .foregroundStyle(.white.opacity(0.35))
                    }
                    Spacer()

                    // Quick stats
                    if let end = session.sessionEnd {
                        HStack(spacing: 12) {
                            MiniStat(value: "\(end.totalBlocksViewed)", label: "swipes")
                            MiniStat(value: "\(end.totalUnlocks)", label: "unlocks")
                            MiniStat(value: formatSeconds(end.sessionLengthSeconds), label: "time")
                        }
                    } else {
                        Text("no end data")
                            .font(.system(size: 10, design: .monospaced))
                            .foregroundStyle(.white.opacity(0.25))
                    }

                    Image(systemName: "chevron.right")
                        .font(.system(size: 10, weight: .bold))
                        .foregroundStyle(.white.opacity(0.2))
                        .rotationEffect(.degrees(expanded ? 90 : 0))
                        .padding(.leading, 4)
                }
            }
            .buttonStyle(.plain)
            .padding(14)

            // Expanded detail
            if expanded {
                VStack(alignment: .leading, spacing: 8) {
                    DetailRow(label: "Session ID", value: session.sessionID)
                    DetailRow(label: "Device ID", value: String(session.deviceID.prefix(16)) + "...")
                    DetailRow(label: "Timestamp", value: session.timestamp.formatted(.dateTime))

                    if let events = session.scrollEvents {
                        DetailRow(label: "Scroll events", value: "\(events.count)")
                        if let last = events.last {
                            DetailRow(label: "Last card index", value: "\(last.cardIndex)")
                            DetailRow(label: "Active scroll time", value: formatSeconds(last.activeScrollSeconds))
                        }
                    }

                    if let end = session.sessionEnd {
                        DetailRow(label: "Total blocks viewed", value: "\(end.totalBlocksViewed)")
                        DetailRow(label: "Total unlocks", value: "\(end.totalUnlocks)")
                        DetailRow(label: "Session length", value: formatSeconds(end.sessionLengthSeconds))
                    }
                }
                .padding(.horizontal, 14)
                .padding(.bottom, 14)
                .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
        .background(Color.white.opacity(0.04), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(.white.opacity(0.06), lineWidth: 1)
        )
    }

    private func formatSeconds(_ s: Double) -> String {
        if s < 60 { return String(format: "%.0fs", s) }
        let m = Int(s) / 60
        let sec = Int(s) % 60
        return "\(m)m \(sec)s"
    }
}

struct MiniStat: View {
    let value: String
    let label: String

    var body: some View {
        VStack(spacing: 2) {
            Text(value)
                .font(.system(size: 13, weight: .bold, design: .rounded))
                .foregroundStyle(.white)
            Text(label)
                .font(.system(size: 8, weight: .bold, design: .monospaced))
                .foregroundStyle(.white.opacity(0.3))
        }
    }
}

struct DetailRow: View {
    let label: String
    let value: String

    var body: some View {
        HStack {
            Text(label)
                .font(.system(size: 10, weight: .semibold, design: .monospaced))
                .foregroundStyle(.white.opacity(0.35))
            Spacer()
            Text(value)
                .font(.system(size: 10, weight: .medium, design: .monospaced))
                .foregroundStyle(.white.opacity(0.7))
                .lineLimit(1)
        }
    }
}
