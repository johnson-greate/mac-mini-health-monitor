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
    private let navy = Color(red: 0.055, green: 0.09, blue: 0.15)
    private let panel = Color(red: 0.105, green: 0.15, blue: 0.22)
    private let gold = Color(red: 0.90, green: 0.72, blue: 0.38)
    private let muted = Color(red: 0.72, green: 0.77, blue: 0.82)

    private func metric(_ title: String, icon: String, value: String, detail: String) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            Label(title, systemImage: icon).font(.caption.weight(.medium)).foregroundStyle(muted)
            Text(value).font(.system(size: 21, weight: .semibold, design: .rounded))
                .monospacedDigit().lineLimit(1).minimumScaleFactor(0.7)
            Text(detail).font(.caption2).foregroundStyle(muted).lineLimit(1)
        }
        .frame(maxWidth: .infinity, minHeight: 72, alignment: .leading)
        .padding(10)
        .background(panel, in: RoundedRectangle(cornerRadius: 6))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                VStack(alignment: .leading, spacing: 3) {
                    Text("MAC MINI HEALTH").font(.caption.weight(.semibold)).foregroundStyle(gold)
                    Text("System monitor").font(.system(size: 19, weight: .semibold))
                }
                Spacer()
                if let url = Bundle.main.url(forResource: "GreateLogo", withExtension: "png"), let logo = NSImage(contentsOf: url) {
                    Link(destination: URL(string: "https://www.greate.com.hk/")!) {
                        Image(nsImage: logo).resizable().scaledToFit().frame(width: 70, height: 20)
                            .padding(.horizontal, 6).padding(.vertical, 4)
                            .background(Color.white, in: RoundedRectangle(cornerRadius: 4))
                    }
                    .accessibilityLabel("Visit Greate (HK) Limited website")
                    .help("Visit the Greate website")
                }
                Button { NSApp.terminate(nil) } label: { Image(systemName: "power") }
                    .buttonStyle(.plain).foregroundStyle(muted).help("Quit monitor")
            }
            HStack(spacing: 7) {
                Image(systemName: "thermometer.medium").foregroundStyle(gold)
                Text("Thermal state").foregroundStyle(muted)
                Text(monitor.latest?.thermal.rawValue.capitalized ?? "N/A").fontWeight(.semibold)
                Spacer()
                Text(monitor.latest.map { $0.time.formatted(date: .omitted, time: .shortened) } ?? "No reading")
                    .foregroundStyle(muted)
            }.font(.caption)

            LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 8) {
                metric("SSD available", icon: "internaldrive", value: size(monitor.latest?.freeBytes), detail: "Local storage")
                metric("Fan", icon: "fan", value: rpm(monitor.latest?.fanRPM), detail: "Managed by macOS")
                metric("CPU temperature", icon: "cpu", value: temperature(monitor.latest?.cpuTemperature), detail: "Sensor average")
                metric("GPU temperature", icon: "display", value: temperature(monitor.latest?.gpuTemperature), detail: "Sensor average")
            }
            if let latest = monitor.latest, monitor.now.timeIntervalSince(latest.time) > 2 * interval {
                Text("Reading is stale").foregroundStyle(gold)
            }
            if let error = monitor.storageError { Text("Storage error: \(error)").foregroundStyle(gold).textSelection(.enabled) }
            if let error = monitor.diskError { Text("Disk reading unavailable: \(error)").foregroundStyle(gold) }
            if let error = monitor.sensorError { Text(error).foregroundStyle(gold) }
            Divider().overlay(muted.opacity(0.25))
            HStack {
                Text("7-day history").font(.subheadline.weight(.semibold))
                Spacer()
                Text("\(monitor.samples.count) readings · \(monitor.historyGaps.count) gaps")
                    .font(.caption2).foregroundStyle(muted)
            }
            HStack {
                VStack(alignment: .leading, spacing: 3) {
                    Text("LOWEST SSD").font(.caption2).foregroundStyle(muted)
                    Text(size(monitor.minimum)).font(.subheadline.weight(.semibold)).monospacedDigit()
                }
                Spacer()
                VStack(alignment: .trailing, spacing: 3) {
                    Text("HIGHEST THERMAL").font(.caption2).foregroundStyle(muted)
                    Text(monitor.highest?.rawValue.capitalized ?? "N/A").font(.subheadline.weight(.semibold))
                }
            }
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 5) {
                    ForEach(Array(monitor.historyGaps.enumerated()), id: \.offset) { _, gap in
                        Text("Gap: \(gap.start.formatted()) – \(gap.end.formatted())").foregroundStyle(gold)
                    }
                    Text("Readings (newest first)").fontWeight(.medium)
                    ForEach(Array(monitor.samples.reversed().enumerated()), id: \.offset) { _, sample in
                        VStack(alignment: .leading) {
                            HStack { Text(sample.time.formatted(date: .abbreviated, time: .shortened)); Spacer(); Text(size(sample.freeBytes)); Text(sample.thermal.rawValue.capitalized) }
                            Text("CPU \(temperature(sample.cpuTemperature))  ·  GPU \(temperature(sample.gpuTemperature))  ·  Fan \(rpm(sample.fanRPM))")
                        }
                    }
                }.font(.caption).frame(maxWidth: .infinity, alignment: .leading)
            }.frame(height: 112)
            Divider().overlay(muted.opacity(0.25))
            Text("SSD temperature: N/A").font(.caption).foregroundStyle(muted)
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
        }
        .padding(16).frame(width: 390)
        .foregroundStyle(Color.white)
        .background(navy)
        .preferredColorScheme(.dark)
    }
}

func menuBarIcon() -> NSImage? {
    guard let url = Bundle.main.url(forResource: "MenuBarIcon", withExtension: "png"),
          let source = NSImage(contentsOf: url) else { return nil }
    let size = NSSize(width: 24, height: 18)
    let icon = NSImage(size: size, flipped: false) { rect in
        let crop = NSRect(x: source.size.width * 0.04, y: source.size.height * 0.20,
                          width: source.size.width * 0.92, height: source.size.height * 0.60)
        source.draw(in: rect.insetBy(dx: 0, dy: 1.2), from: crop, operation: .sourceOver, fraction: 1)
        return true
    }
    icon.isTemplate = false
    return icon
}

@main
struct MacMiniMonitorApp: App {
    @StateObject private var monitor = Monitor()
    var body: some Scene {
        MenuBarExtra {
            MonitorView(monitor: monitor)
        } label: {
            if let icon = menuBarIcon() {
                Image(nsImage: icon).accessibilityLabel("Mac Mini Health")
            } else {
                Image(systemName: "heart.text.square").accessibilityLabel("Mac Mini Health")
            }
        }.menuBarExtraStyle(.window)
    }
}
