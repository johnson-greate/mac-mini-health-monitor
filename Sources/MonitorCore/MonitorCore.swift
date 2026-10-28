import Foundation
import Darwin

public let interval: TimeInterval = 60
public let retention: TimeInterval = 7 * 24 * 60 * 60

public enum Thermal: String, Codable, CaseIterable {
    case nominal, fair, serious, critical, unknown
    public var rank: Int { switch self { case .nominal: return 0; case .fair: return 1; case .serious: return 2; case .critical: return 3; case .unknown: return -1 } }
    public static func current() -> Thermal {
        switch ProcessInfo.processInfo.thermalState {
        case .nominal: return .nominal
        case .fair: return .fair
        case .serious: return .serious
        case .critical: return .critical
        @unknown default: return .unknown
        }
    }
}

public struct Sample: Codable, Equatable, Identifiable {
    public var id: Date { time }
    public let time: Date
    public let freeBytes: UInt64?
    public let thermal: Thermal
    public let cpuTemperature: Double?
    public let gpuTemperature: Double?
    public let fanRPM: Int?
    public init(time: Date, freeBytes: UInt64?, thermal: Thermal, cpuTemperature: Double? = nil, gpuTemperature: Double? = nil, fanRPM: Int? = nil) {
        self.time = time; self.freeBytes = freeBytes; self.thermal = thermal
        self.cpuTemperature = cpuTemperature; self.gpuTemperature = gpuTemperature; self.fanRPM = fanRPM
    }
}

public struct SensorReadings: Decodable {
    private struct Temperatures: Decodable { let cpu_temp_avg: Double?; let gpu_temp_avg: Double? }
    private struct Fan: Decodable { let rpm: Int? }
    private let temp: Temperatures?
    private let fans: [Fan]?
    public var cpuTemperature: Double? { validTemperature(temp?.cpu_temp_avg) }
    public var gpuTemperature: Double? { validTemperature(temp?.gpu_temp_avg) }
    public var fanRPM: Int? { fans?.first?.rpm.flatMap { (0...20_000).contains($0) ? $0 : nil } }
    private func validTemperature(_ value: Double?) -> Double? {
        value.flatMap { $0.isFinite && (-20...150).contains($0) ? $0 : nil }
    }
    public static func parse(_ data: Data) throws -> SensorReadings {
        try JSONDecoder().decode(SensorReadings.self, from: data)
    }
}

public enum SensorError: Error { case failed, empty }

public func readSensors(executable: String = "/opt/homebrew/bin/macmon", timeout: TimeInterval = 8) throws -> SensorReadings {
    let process = Process()
    let pipe = Pipe()
    process.executableURL = URL(fileURLWithPath: executable)
    process.arguments = ["pipe", "--samples", "1", "--interval", "1000"]
    process.standardOutput = pipe
    process.standardError = FileHandle.nullDevice
    try process.run()
    let timer = DispatchSource.makeTimerSource(queue: .global())
    timer.schedule(deadline: .now() + timeout)
    timer.setEventHandler { if process.isRunning { _ = kill(process.processIdentifier, SIGKILL) } }
    timer.resume()
    let data = pipe.fileHandleForReading.readDataToEndOfFile()
    process.waitUntilExit()
    timer.cancel()
    guard process.terminationStatus == 0 else { throw SensorError.failed }
    let readings = try SensorReadings.parse(data)
    guard readings.cpuTemperature != nil || readings.gpuTemperature != nil || readings.fanRPM != nil else { throw SensorError.empty }
    return readings
}

public func rootFreeBytes() throws -> UInt64 {
    var info = statfs()
    guard statfs("/", &info) == 0 else { throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno)) }
    return UInt64(info.f_bavail) * UInt64(info.f_bsize)
}

public struct Gap: Equatable {
    public let start: Date
    public let end: Date
}

public func gaps(in samples: [Sample], now: Date) -> [Gap] {
    let times = samples.map(\.time).filter { $0 <= now }.sorted()
    guard let first = times.first else { return [Gap(start: now.addingTimeInterval(-retention), end: now)] }
    let beginning = now.addingTimeInterval(-retention)
    var result: [Gap] = []
    if first.timeIntervalSince(beginning) > 2 * interval { result.append(Gap(start: beginning, end: first)) }
    for (a, b) in zip(times, times.dropFirst()) where b.timeIntervalSince(a) > 2 * interval {
        result.append(Gap(start: a, end: b))
    }
    if now.timeIntervalSince(times.last!) > 2 * interval { result.append(Gap(start: times.last!, end: now)) }
    return result
}

public struct AlertTransitions {
    private var diskLow = false
    private var thermalHigh = false
    public init() {}
    public mutating func update(freeBytes: UInt64?, threshold: UInt64, thermal: Thermal) -> (disk: Bool, thermal: Bool) {
        var diskWarning = false
        if let freeBytes {
            let low = freeBytes < threshold
            diskWarning = low && !diskLow
            diskLow = low
        }
        var thermalWarning = false
        if thermal != .unknown {
            let high = thermal.rank >= Thermal.serious.rank
            thermalWarning = high && !thermalHigh
            thermalHigh = high
        }
        return (diskWarning, thermalWarning)
    }
}

public final class HistoryStore {
    public let url: URL
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()
    private var lastPrune: Date?
    // This also bounds history after clock changes or unusually frequent sampling.
    private let maximumSamples = 10_100
    public init(url: URL) { self.url = url }

    public func load(now: Date) throws -> [Sample] {
        guard FileManager.default.fileExists(atPath: url.path) else { return [] }
        let data = try Data(contentsOf: url)
        guard let text = String(data: data, encoding: .utf8) else { throw CocoaError(.fileReadCorruptFile) }
        let lines = text.split(separator: "\n", omittingEmptySubsequences: true)
        let samples = try lines.map { try decoder.decode(Sample.self, from: Data($0.utf8)) }
        return Array(samples.filter { $0.time >= now.addingTimeInterval(-retention) && $0.time <= now }.sorted { $0.time < $1.time }.suffix(maximumSamples))
    }

    public func prune(now: Date) throws -> [Sample] {
        let samples = try load(now: now)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        var data = Data()
        for sample in samples { data.append(try encoder.encode(sample)); data.append(10) }
        try data.write(to: url, options: .atomic)
        lastPrune = now
        return samples
    }

    public func append(_ sample: Sample) throws {
        if lastPrune == nil || sample.time.timeIntervalSince(lastPrune!) >= 3600 || sample.time < lastPrune! {
            _ = try prune(now: sample.time)
        }
        var data = try encoder.encode(sample); data.append(10)
        let handle = try FileHandle(forWritingTo: url)
        defer { try? handle.close() }
        try handle.seekToEnd()
        try handle.write(contentsOf: data)
    }
}
