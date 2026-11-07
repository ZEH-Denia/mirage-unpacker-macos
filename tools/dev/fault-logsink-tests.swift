import Foundation

// Independent lifecycle/concurrency tests for the real PKDKit LogSink.
// Compiled together with app/Sources/PKDKit/Support/LogSink.swift (no stubs).
// Usage: fault-logsink-tests <scratch-dir>

@main
struct LogSinkTests {
    static let root = URL(fileURLWithPath: CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : NSTemporaryDirectory())
        .appendingPathComponent("pkd-logsink-tests-\(UUID().uuidString)", isDirectory: true)

    static var failures: [String] = []

    static func check(_ name: String, _ condition: @autoclosure () -> Bool, _ detail: @autoclosure () -> String = "") {
        if condition() {
            print("  PASS \(name)")
        } else {
            let extra = detail()
            print("  FAIL \(name)\(extra.isEmpty ? "" : " — \(extra)")")
            failures.append(name)
        }
    }

    static func readLines(_ url: URL) -> [String] {
        guard let data = try? Data(contentsOf: url),
              let text = String(data: data, encoding: .utf8) else { return [] }
        var lines = text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        if lines.last == "" { lines.removeLast() }
        return lines
    }

    static func scratch() -> URL {
        let url = root.appendingPathComponent("case-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    static func main() {
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        print("LogSink lifecycle tests — \(root.path)")
        defer { try? FileManager.default.removeItem(at: root) }

        testSmallCloseFlushesTail()
        testProbe3Regression()
        testDrainAndFlushAfterCloseDoNotTruncate()
        testRepeatedCloseAndLateAppend()
        testMultiJobIsolation()
        testConcurrentAppendDrainAndClose()
        testFlushWhileAppending()
        testCloseWhileAppending()
        testOverflowAndManyLines()
        testPerformanceSmoke()

        if failures.isEmpty {
            print("ALL LOGSINK TESTS PASSED")
        } else {
            print("FAILURES: \(failures.joined(separator: ", "))")
            exit(1)
        }
    }

    // 1) Short job: close must flush the <16 KiB tail even if nobody ever drains.
    static func testSmallCloseFlushesTail() {
        let dir = scratch()
        let sink = LogSink(logDirectory: dir)
        let job = UUID()
        for i in 0..<10 { sink.append(jobID: job, text: "small-\(i)") }
        sink.close(jobID: job)
        let lines = readLines(sink.logFileURL(for: job))
        check("small/close creates complete file", lines == (0..<10).map { "small-\($0)" }, "got \(lines.count) lines")
    }

    // 2) Original probe3 sequence: big append overflow, small tail, close, later drain.
    static func testProbe3Regression() {
        let dir = scratch()
        let sink = LogSink(logDirectory: dir)
        let job = UUID()
        let big = String(repeating: "B", count: 20_000)
        sink.append(jobID: job, text: big)
        sink.flushFiles()
        let afterBig = (try? Data(contentsOf: sink.logFileURL(for: job)).count) ?? -1
        sink.append(jobID: job, text: "TAIL-AFTER-CLOSE")
        sink.close(jobID: job)
        let text = (try? String(contentsOf: sink.logFileURL(for: job), encoding: .utf8)) ?? ""
        check("probe3 big overflow written", afterBig == 20_001, "size \(afterBig)")
        check("probe3 tail is flushed by close", text.contains("TAIL-AFTER-CLOSE"), "tail missing")
        check("probe3 big content preserved", text.hasPrefix(big), "big content missing/truncated")
        check("probe3 total size", text.utf8.count == 20_001 + "TAIL-AFTER-CLOSE\n".utf8.count, "size \(text.utf8.count)")

        _ = sink.drain()
        sink.flushFiles()
        let afterDrain = (try? String(contentsOf: sink.logFileURL(for: job), encoding: .utf8)) ?? ""
        check("probe3 drain/flush after close does not change file", afterDrain == text, "file changed after close")
    }

    // 3) A late drain/flush after close must never reopen at offset 0 / truncate.
    static func testDrainAndFlushAfterCloseDoNotTruncate() {
        let dir = scratch()
        let sink = LogSink(logDirectory: dir)
        let job = UUID()
        for i in 0..<20 { sink.append(jobID: job, text: "before-\(i)") }
        sink.close(jobID: job)
        let before = readLines(sink.logFileURL(for: job))
        _ = sink.drain()
        sink.flushFiles()
        _ = sink.drain()
        sink.flushFiles()
        let after = readLines(sink.logFileURL(for: job))
        check("drain/flush after close preserve old log", before == after && after.count == 20, "before \(before.count), after \(after.count)")
    }

    // 4) Repeated close is idempotent; append after close appends instead of truncating.
    static func testRepeatedCloseAndLateAppend() {
        let dir = scratch()
        let sink = LogSink(logDirectory: dir)
        let job = UUID()
        sink.append(jobID: job, text: "first")
        sink.close(jobID: job)
        sink.close(jobID: job)
        sink.append(jobID: job, text: "late")
        sink.close(jobID: job)
        let lines = readLines(sink.logFileURL(for: job))
        check("repeated close + late append preserves order", lines == ["first", "late"], "got \(lines)")
    }

    // 5) Interleaved jobs must not leak lines or share handles.
    static func testMultiJobIsolation() {
        let dir = scratch()
        let sink = LogSink(logDirectory: dir)
        let a = UUID(), b = UUID(), c = UUID()
        for i in 0..<30 {
            sink.append(jobID: a, text: "A-\(i)")
            if i % 2 == 0 { sink.append(jobID: b, text: "B-\(i)") }
            if i % 3 == 0 { sink.append(jobID: c, text: "C-\(i)") }
        }
        sink.close(jobID: b)
        for i in 30..<40 { sink.append(jobID: a, text: "A-\(i)") }
        sink.close(jobID: a)
        sink.close(jobID: c)
        let la = readLines(sink.logFileURL(for: a))
        let lb = readLines(sink.logFileURL(for: b))
        let lc = readLines(sink.logFileURL(for: c))
        check("multi-job A complete/order", la == (0..<40).map { "A-\($0)" }, "A \(la.count)")
        check("multi-job B complete/order", lb == stride(from: 0, to: 30, by: 2).map { "B-\($0)" }, "B \(lb.count)")
        check("multi-job C complete/order", lc == stride(from: 0, to: 30, by: 3).map { "C-\($0)" }, "C \(lc.count)")
    }

    // 6) Concurrent append + concurrent drain on the same job: no loss/dup/reorder.
    static func testConcurrentAppendDrainAndClose() {
        let dir = scratch()
        let sink = LogSink(logDirectory: dir)
        let job = UUID()
        let orderLock = NSLock()
        var expected: [String] = []
        let group = DispatchGroup()
        let perThread = 400

        for thread in 0..<4 {
            DispatchQueue.global().async(group: group) {
                for i in 0..<perThread {
                    let line = "t\(thread)-\(i)"
                    orderLock.lock()
                    expected.append(line)
                    sink.append(jobID: job, text: line)
                    orderLock.unlock()
                }
            }
        }
        DispatchQueue.global().async {
            for _ in 0..<800 { _ = sink.drain(); usleep(500) }
        }
        group.wait()
        sink.flushFiles()
        sink.close(jobID: job)
        let got = readLines(sink.logFileURL(for: job))
        orderLock.lock()
        let want = expected
        orderLock.unlock()
        check("concurrent append/drain no loss", got.count == want.count, "got \(got.count), want \(want.count)")
        check("concurrent append/drain exact order", got == want, "first mismatch: \(got.first == want.first ? "n/a" : "check")")
        check("concurrent append/drain no duplicate", Set(got).count == got.count, "duplicates present")
    }


    // 6b) flushFiles racing with append must preserve every line and order.
    static func testFlushWhileAppending() {
        let dir = scratch()
        let sink = LogSink(logDirectory: dir)
        let job = UUID()
        let orderLock = NSLock()
        var expected: [String] = []
        let group = DispatchGroup()
        DispatchQueue.global().async(group: group) {
            for i in 0..<3_000 {
                orderLock.lock()
                let line = "flushrace-\(i)"
                expected.append(line)
                sink.append(jobID: job, text: line)
                orderLock.unlock()
            }
        }
        for _ in 0..<30 {
            sink.flushFiles()
            usleep(1_000)
        }
        group.wait()
        sink.flushFiles()
        sink.close(jobID: job)
        let got = readLines(sink.logFileURL(for: job))
        orderLock.lock()
        let want = expected
        orderLock.unlock()
        check("flush/append race no loss", got.count == want.count, "got \(got.count), want \(want.count)")
        check("flush/append race exact order", got == want, "order mismatch")
    }

    // 6c) close racing with append: no loss; post-close appends must append, not truncate.
    static func testCloseWhileAppending() {
        let dir = scratch()
        let sink = LogSink(logDirectory: dir)
        let job = UUID()
        let orderLock = NSLock()
        var expected: [String] = []
        let group = DispatchGroup()
        DispatchQueue.global().async(group: group) {
            for i in 0..<2_000 {
                orderLock.lock()
                let line = "closerace-\(i)"
                expected.append(line)
                sink.append(jobID: job, text: line)
                orderLock.unlock()
                usleep(50)
            }
        }
        usleep(30_000)
        sink.close(jobID: job)
        group.wait()
        sink.close(jobID: job)
        let got = readLines(sink.logFileURL(for: job))
        orderLock.lock()
        let want = expected
        orderLock.unlock()
        check("close/append race no loss", got.count == want.count, "got \(got.count), want \(want.count)")
        check("close/append race exact order", got == want, "order mismatch")
    }

    // 7) Many lines and frequent overflow chunks; close must preserve every line.
    static func testOverflowAndManyLines() {
        let dir = scratch()
        let sink = LogSink(logDirectory: dir)
        let job = UUID()
        let count = 20_000
        for i in 0..<count { sink.append(jobID: job, text: "overflow-\(i)-\(String(repeating: "x", count: 4))") }
        sink.close(jobID: job)
        let lines = readLines(sink.logFileURL(for: job))
        check("overflow many lines complete", lines.count == count, "got \(lines.count)")
        check("overflow first/last order", lines.first == "overflow-0-xxxx" && lines.last == "overflow-\(count - 1)-xxxx", "boundary mismatch")
    }

    // 8) Performance smoke: appending 100k lines should not block absurdly.
    static func testPerformanceSmoke() {
        let dir = scratch()
        let sink = LogSink(logDirectory: dir)
        let job = UUID()
        let started = Date()
        for i in 0..<100_000 { sink.append(jobID: job, text: "perf-\(i)") }
        let appendElapsed = Date().timeIntervalSince(started)
        sink.close(jobID: job)
        let closeElapsed = Date().timeIntervalSince(started) - appendElapsed
        let lines = readLines(sink.logFileURL(for: job))
        print(String(format: "  INFO append100k=%.3fs close=%.3fs lines=%d", appendElapsed, closeElapsed, lines.count))
        check("perf 100k lines complete", lines.count == 100_000, "got \(lines.count)")
        check("perf 100k append under 10s", appendElapsed < 10, String(format: "%.3fs", appendElapsed))
        check("perf 100k close under 10s", closeElapsed < 10, String(format: "%.3fs", closeElapsed))
    }
}
