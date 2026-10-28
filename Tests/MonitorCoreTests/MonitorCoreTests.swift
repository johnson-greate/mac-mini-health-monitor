import Foundation
import MonitorCore

func XCTAssertTrue(_ value: Bool, file: StaticString = #file, line: UInt = #line) { precondition(value, "Expected true at \(file):\(line)") }
func XCTAssertFalse(_ value: Bool, file: StaticString = #file, line: UInt = #line) { precondition(!value, "Expected false at \(file):\(line)") }
func XCTAssertEqual<T: Equatable>(_ a: T, _ b: T, file: StaticString = #file, line: UInt = #line) { precondition(a == b, "Values differ at \(file):\(line)") }
func XCTAssertGreaterThan<T: Comparable>(_ a: T, _ b: T, file: StaticString = #file, line: UInt = #line) { precondition(a > b, "Expected greater value at \(file):\(line)") }
func XCTAssertThrowsError<T>(_ operation: () throws -> T, file: StaticString = #file, line: UInt = #line) {
    do { _ = try operation(); preconditionFailure("Expected error at \(file):\(line)") } catch { }
}

final class MonitorCoreTests {
    let now = Date(timeIntervalSince1970: 2_000_000_000)
    func sample(_ offset: TimeInterval, _ free: UInt64? = 100, _ thermal: Thermal = .nominal) -> Sample {
        Sample(time: now.addingTimeInterval(offset), freeBytes: free, thermal: thermal)
    }
    func testRetentionAndRestart() throws {
        let dir = URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appendingPathComponent(".build/test-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("history")
        let store = HistoryStore(url: url)
        try store.append(sample(-retention - 1))
        try store.append(sample(-60, 50, .serious))
        try store.append(sample(0, nil, .unknown))
        let restarted = HistoryStore(url: url)
        XCTAssertEqual(try restarted.prune(now: now), [sample(-60, 50, .serious), sample(0, nil, .unknown)])
        XCTAssertEqual(try restarted.load(now: now), [sample(-60, 50, .serious), sample(0, nil, .unknown)])
    }
    func testGapsAreNotSamples() {
        let result = gaps(in: [sample(-240), sample(-120), sample(0)], now: now)
        XCTAssertEqual(result.count, 1) // leading gap; exactly 120 seconds is not a gap
        XCTAssertEqual(gaps(in: [sample(-121), sample(0)], now: now).count, 2)
        XCTAssertEqual(gaps(in: [], now: now).count, 1)
        XCTAssertEqual(gaps(in: [sample(-121)], now: now).count, 2)
    }
    func testWarningsRequireRecoveryAndUnknownDoesNotReset() {
        var state = AlertTransitions()
        XCTAssertTrue(state.update(freeBytes: 9, threshold: 10, thermal: .serious).disk)
        let repeated = state.update(freeBytes: 9, threshold: 10, thermal: .critical)
        XCTAssertFalse(repeated.disk); XCTAssertFalse(repeated.thermal)
        _ = state.update(freeBytes: nil, threshold: 10, thermal: .unknown)
        XCTAssertFalse(state.update(freeBytes: 9, threshold: 10, thermal: .serious).thermal)
        _ = state.update(freeBytes: 10, threshold: 10, thermal: .fair)
        let again = state.update(freeBytes: 9, threshold: 10, thermal: .critical)
        XCTAssertTrue(again.disk); XCTAssertTrue(again.thermal)
    }
    func testCorruptAndUnwritableStorageSurfaceErrors() throws {
        let dir = URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appendingPathComponent(".build/test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("history")
        try Data("broken\n".utf8).write(to: url)
        XCTAssertThrowsError { try HistoryStore(url: url).append(sample(0)) }
        XCTAssertEqual(try String(contentsOf: url, encoding: .utf8), "broken\n")
        let impossible = url.appendingPathComponent("child")
        XCTAssertThrowsError { try HistoryStore(url: impossible).append(sample(0)) }
    }
    func testRootFilesystemReading() throws {
        let bytes = try rootFreeBytes()
        XCTAssertGreaterThan(bytes, 0)
        print("statfs available: \(bytes / 1024) KiB")
    }
    func testSensorParsingAndLegacyHistory() throws {
        let legacy = Data("{\"time\":0,\"freeBytes\":100,\"thermal\":\"nominal\"}".utf8)
        let old = try JSONDecoder().decode(Sample.self, from: legacy)
        XCTAssertEqual(old.cpuTemperature, nil); XCTAssertEqual(old.fanRPM, nil)
        let sensors = try SensorReadings.parse(Data("{\"temp\":{\"cpu_temp_avg\":55.3,\"gpu_temp_avg\":50.0},\"fans\":[{\"rpm\":1002}]}".utf8))
        XCTAssertEqual(sensors.cpuTemperature, 55.3); XCTAssertEqual(sensors.gpuTemperature, 50.0); XCTAssertEqual(sensors.fanRPM, 1002)
        let reading = Sample(time: now, freeBytes: 100, thermal: .nominal, cpuTemperature: sensors.cpuTemperature, gpuTemperature: sensors.gpuTemperature, fanRPM: sensors.fanRPM)
        XCTAssertEqual(try JSONDecoder().decode(Sample.self, from: JSONEncoder().encode(reading)), reading)
        let absent = try SensorReadings.parse(Data("{\"temp\":{\"cpu_temp_avg\":null,\"gpu_temp_avg\":999},\"fans\":[]}".utf8))
        XCTAssertEqual(absent.cpuTemperature, nil); XCTAssertEqual(absent.gpuTemperature, nil); XCTAssertEqual(absent.fanRPM, nil)
        XCTAssertThrowsError { try SensorReadings.parse(Data("bad json".utf8)) }
        XCTAssertThrowsError { try readSensors(executable: "/does/not/exist") }
    }
}

@main
struct TestRunner {
    static func main() throws {
        let tests = MonitorCoreTests()
        try tests.testRetentionAndRestart()
        tests.testGapsAreNotSamples()
        tests.testWarningsRequireRecoveryAndUnknownDoesNotReset()
        try tests.testCorruptAndUnwritableStorageSurfaceErrors()
        try tests.testRootFilesystemReading()
        try tests.testSensorParsingAndLegacyHistory()
        print("6 core tests passed")
    }
}
