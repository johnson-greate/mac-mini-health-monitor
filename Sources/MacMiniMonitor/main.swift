import SwiftUI
import UserNotifications
import MonitorCore

@MainActor
final class Monitor: ObservableObject {
    @Published var samples: [Sample] = []
    @Published var storageError: String?
    @Published var diskError: String?
    @Published var sensorError: String?
    @Published var notificationStatus = "Checking..."
    @Published var now = Date()
    @Published var threshold: Double {
        didSet { UserDefaults.standard.set(threshold, forKey: "thresholdGiB") }
    }
    private let store: HistoryStore
    private var transitions = AlertTransitions()
    private var timer: Timer?
    private var collecting = false

    init() {
        let saved = UserDefaults.standard.double(forKey: "thresholdGiB")
        threshold = saved > 0 ? saved : 20
        let directory = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("MacMiniHealthMonitor", isDirectory: true)
        store = HistoryStore(url: directory.appendingPathComponent("history.jsonl"))
        do {
            samples = try store.prune(now: now)
            if let last = samples.last {
                _ = transitions.update(freeBytes: last.freeBytes, threshold: thresholdBytes, thermal: last.thermal)
            }
        } catch { storageError = error.localizedDescription }
        refreshNotificationStatus()
        collect()
        timer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.collect() }
        }
    }

    var thresholdBytes: UInt64 { UInt64(max(1, min(threshold, 100_000)) * 1_073_741_824) }
    var latest: Sample? { samples.last }
    var historyGaps: [Gap] { gaps(in: samples, now: now) }
    var minimum: UInt64? { samples.compactMap(\.freeBytes).min() }
    var highest: Thermal? { samples.map(\.thermal).filter { $0 != .unknown }.max { $0.rank < $1.rank } }

    func collect() {
        guard !collecting else { return }
        collecting = true
        Task {
            let result = await Task.detached(priority: .utility) { Result { try readSensors() } }.value
            self.finishCollect(result)
        }
    }

    private func finishCollect(_ sensorResult: Result<SensorReadings, Error>) {
        defer { collecting = false }
        now = Date()
        let free: UInt64?
        do { free = try rootFreeBytes(); diskError = nil }
        catch { free = nil; diskError = error.localizedDescription }
        let sensors: SensorReadings?
        switch sensorResult {
        case .success(let readings): sensors = readings; sensorError = nil
        case .failure(let error): sensors = nil; sensorError = "macmon unavailable: \(error.localizedDescription)"
        }
        let sample = Sample(time: now, freeBytes: free, thermal: .current(), cpuTemperature: sensors?.cpuTemperature, gpuTemperature: sensors?.gpuTemperature, fanRPM: sensors?.fanRPM)
        let warnings = transitions.update(freeBytes: free, threshold: thresholdBytes, thermal: sample.thermal)
        if warnings.disk { notify(title: "Low disk space", body: "Root filesystem is below \(Int(threshold)) GiB available.", id: "disk") }
        if warnings.thermal { notify(title: "High thermal state", body: "System thermal state is \(sample.thermal.rawValue).", id: "thermal") }
        do {
            try store.append(sample)
            samples = try store.load(now: now)
            storageError = nil
        } catch { storageError = error.localizedDescription }
    }

    func refreshNotificationStatus() {
        UNUserNotificationCenter.current().getNotificationSettings { settings in
            Task { @MainActor in
                switch settings.authorizationStatus {
                case .authorized, .provisional, .ephemeral: self.notificationStatus = "Allowed"
                case .denied: self.notificationStatus = "Denied; change in System Settings"
                case .notDetermined: self.notificationStatus = "Not requested"
                @unknown default: self.notificationStatus = "Unknown"
                }
            }
        }
    }
    func requestNotifications() {
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in
            Task { @MainActor in self.refreshNotificationStatus() }
        }
    }
    private func notify(title: String, body: String, id: String) {
        let content = UNMutableNotificationContent()
        content.title = title; content.body = body; content.sound = .default
        UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: "\(id)-\(UUID().uuidString)", content: content, trigger: nil)) { _ in }
    }
}

func size(_ bytes: UInt64?) -> String {
    guard let bytes else { return "N/A" }
    return String(format: "%.2f GiB", Double(bytes) / 1_073_741_824)
}

func temperature(_ value: Double?) -> String {
    value.map { String(format: "%.1f °C", $0) } ?? "N/A"
}

func rpm(_ value: Int?) -> String { value.map { "\($0) RPM" } ?? "N/A" }

struct MonitorView: View {
    @ObservedObject var monitor: Monitor
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Mac Mini Health").font(.headline)
                Spacer()
                if let url = Bundle.main.url(forResource: "GreateLogo", withExtension: "png"), let logo = NSImage(contentsOf: url) {
                    Link(destination: URL(string: "https://www.greate.com.hk/")!) {
                        Image(nsImage: logo).resizable().scaledToFit().frame(width: 72, height: 24)
                    }
                    .accessibilityLabel("Visit Greate (HK) Limited website")
                    .help("Visit the Greate website")
                }
                Button("Quit") { NSApp.terminate(nil) }
            }
            Divider()
            HStack { Text("Root available"); Spacer(); Text(size(monitor.latest?.freeBytes)).monospacedDigit() }
            HStack { Text("Thermal state"); Spacer(); Text(monitor.latest?.thermal.rawValue.capitalized ?? "N/A") }
            HStack { Text("CPU average"); Spacer(); Text(temperature(monitor.latest?.cpuTemperature)) }
            HStack { Text("GPU average"); Spacer(); Text(temperature(monitor.latest?.gpuTemperature)) }
            HStack { Text("Fan"); Spacer(); Text(rpm(monitor.latest?.fanRPM)) }
            Text(monitor.latest.map { "Last saved: \($0.time.formatted(date: .abbreviated, time: .standard))" } ?? "No saved readings")
                .font(.caption).foregroundStyle(.secondary)
            if let latest = monitor.latest, monitor.now.timeIntervalSince(latest.time) > 2 * interval {
                Text("Reading is stale").foregroundStyle(.orange)
            }
            if let error = monitor.storageError { Text("Storage error: \(error)").foregroundStyle(.red).textSelection(.enabled) }
            if let error = monitor.diskError { Text("Disk reading unavailable: \(error)").foregroundStyle(.red) }
            if let error = monitor.sensorError { Text(error).foregroundStyle(.orange) }
            Divider()
            Text("Seven-day history").font(.headline)
            HStack { Text("Minimum available"); Spacer(); Text(size(monitor.minimum)) }
            HStack { Text("Highest thermal state"); Spacer(); Text(monitor.highest?.rawValue.capitalized ?? "N/A") }
            Text("\(monitor.samples.count) readings · \(monitor.historyGaps.count) missing periods").font(.caption)
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 5) {
                    ForEach(Array(monitor.historyGaps.enumerated()), id: \.offset) { _, gap in
                        Text("Gap: \(gap.start.formatted()) – \(gap.end.formatted())").foregroundStyle(.orange)
                    }
                    Text("Readings (newest first)").fontWeight(.medium)
                    ForEach(Array(monitor.samples.reversed().enumerated()), id: \.offset) { _, sample in
                        VStack(alignment: .leading) {
                            HStack { Text(sample.time.formatted(date: .abbreviated, time: .shortened)); Spacer(); Text(size(sample.freeBytes)); Text(sample.thermal.rawValue.capitalized) }
                            Text("CPU \(temperature(sample.cpuTemperature))  ·  GPU \(temperature(sample.gpuTemperature))  ·  Fan \(rpm(sample.fanRPM))")
                        }
                    }
                }.font(.caption).frame(maxWidth: .infinity, alignment: .leading)
            }.frame(height: 145)
            Divider()
            Text("SSD temperature: N/A").font(.caption)
            HStack {
                Text("Low disk threshold (GiB)")
                Spacer()
                Stepper("\(Int(monitor.threshold))", value: $monitor.threshold, in: 1...1000, step: 1).fixedSize()
            }.font(.caption)
            HStack {
                Text("Notifications: \(monitor.notificationStatus)").font(.caption)
                Spacer()
                if monitor.notificationStatus == "Not requested" { Button("Enable") { monitor.requestNotifications() } }
            }
        }.padding(14).frame(width: 390)
    }
}

@main
struct MacMiniMonitorApp: App {
    @StateObject private var monitor = Monitor()
    var body: some Scene {
        MenuBarExtra("Mac Mini Health", systemImage: "heart.text.square") {
            MonitorView(monitor: monitor)
        }.menuBarExtraStyle(.window)
    }
}
