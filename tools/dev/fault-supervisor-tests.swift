import Foundation
import Darwin

// Offscreen tests for RealProcessRunner's parent-death supervisor.
// Compiles the real LineStream.swift + ProcessRunner.swift (no stubs).
// Usage: fault-supervisor-tests <scratch-dir>

@main
struct SupervisorTests {
    static var failures: [String] = []
    static let args = CommandLine.arguments
    static let root = URL(fileURLWithPath: args.count > 1 ? args[1] : NSTemporaryDirectory())
        .appendingPathComponent("pkd-supervisor-tests-\(UUID().uuidString)", isDirectory: true)

    static func check(_ name: String, _ condition: @autoclosure () -> Bool, _ detail: @autoclosure () -> String = "") {
        if condition() { print("  PASS \(name)") }
        else {
            print("  FAIL \(name)\(detail().isEmpty ? "" : " — \(detail())")")
            failures.append(name)
        }
    }

    static func script(_ name: String, _ body: String) -> URL {
        let url = root.appendingPathComponent(name)
        try? body.write(to: url, atomically: true, encoding: .utf8)
        try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
        return url
    }

    static func sleep(_ seconds: Double) async {
        try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
    }

    static func alive(_ pid: Int32) -> Bool {
        kill(pid, 0) == 0
    }

    static func waitUntilGone(_ pid: Int32, timeout: Double) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if !alive(pid) { return true }
            await sleep(0.05)
        }
        return !alive(pid)
    }

    static func main() async {
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        if let index = args.firstIndex(of: "--child"), index + 3 < args.count {
            await childMode(engine: URL(fileURLWithPath: args[index + 1]),
                            pidfile: args[index + 2],
                            output: args[index + 3])
            return
        }

        print("Supervisor tests — \(root.path)")
        await testNormalExit()
        await testCancellation()
        await testImmediateCancel()
        await testParentDeath()
        await testConcurrentTwo()
        await testArgvSafety()

        if failures.isEmpty { print("ALL SUPERVISOR TESTS PASSED") }
        else { print("FAILURES: \(failures.joined(separator: ", "))"); exit(1) }
    }

    static func testNormalExit() async {
        let engine = script("engine-ok.sh", """
        #!/bin/bash
        echo "hello"
        sleep 0.1
        echo "done"
        exit 0
        """)
        let runner = RealProcessRunner()
        let request = ProcessRequest(executable: engine, arguments: [], superviseParentDeath: true)
        do {
            let output = try await runner.run(request, onStdoutLine: { _ in }, onStderrLine: { _ in })
            check("normal exit code", output.exitCode == 0, "exit \(output.exitCode)")
            check("normal output intact", output.stdoutLines.contains("hello") && output.stdoutLines.contains("done"))
        } catch {
            check("normal run", false, "\(error)")
        }
    }

    static func testCancellation() async {
        let pidfile = root.appendingPathComponent("cancel.pid").path
        let outputFile = root.appendingPathComponent("cancel.out").path
        let engine = script("engine-slow.sh", """
        #!/bin/bash
        echo $$ > "\(pidfile)"
        i=0
        while [ $i -lt 100000 ]; do
          i=$((i+1))
          echo tick >> "\(outputFile)"
          sleep 0.02
        done
        """)
        let runner = RealProcessRunner()
        let request = ProcessRequest(executable: engine, arguments: [], superviseParentDeath: true)
        let task = Task { () -> ProcessOutput? in
            try? await runner.run(request, onStdoutLine: { _ in }, onStderrLine: { _ in })
        }
        await sleep(0.5)
        let cancelStart = Date()
        await runner.cancel(grace: 1.0)
        _ = await task.value
        let cancelSeconds = Date().timeIntervalSince(cancelStart)
        check("cancel returns promptly", cancelSeconds < 3.0, String(format: "%.2fs", cancelSeconds))
        let pid: Int32?
        if let text = try? String(contentsOfFile: pidfile, encoding: .utf8) {
            pid = Int32(text.trimmingCharacters(in: .whitespacesAndNewlines))
        } else {
            pid = nil
        }
        var gone = true
        if let pid { gone = await waitUntilGone(pid, timeout: 2) }
        check("cancel leaves no engine", gone, "pid \(pid ?? -1)")
    }


    static func testImmediateCancel() async {
        let pidfile = root.appendingPathComponent("immediate.pid").path
        let engine = script("engine-immediate.sh", """
        #!/bin/bash
        echo $$ > "\(pidfile)"
        exec sleep 30
        """)
        let runner = RealProcessRunner()
        let request = ProcessRequest(executable: engine, arguments: [], superviseParentDeath: true)
        let task = Task { try? await runner.run(request, onStdoutLine: { _ in }, onStderrLine: { _ in }) }
        await sleep(0.5)
        runner.cancelImmediately()
        _ = await task.value
        let pid: Int32?
        if let text = try? String(contentsOfFile: pidfile, encoding: .utf8) {
            pid = Int32(text.trimmingCharacters(in: .whitespacesAndNewlines))
        } else { pid = nil }
        var gone = true
        if let pid { gone = await waitUntilGone(pid, timeout: 2) }
        check("immediate cancel leaves no engine", gone, "pid \(pid ?? -1)")
    }

    static func testParentDeath() async {
        let pidfile = root.appendingPathComponent("parentdeath.pid").path
        let outputFile = root.appendingPathComponent("parentdeath.out").path
        let engine = script("engine-parentdeath.sh", """
        #!/bin/bash
        echo $$ > "\(pidfile)"
        i=0
        while [ $i -lt 100000 ]; do
          i=$((i+1))
          echo tick >> "\(outputFile)"
          sleep 0.02
        done
        """)

        let host = Process()
        host.executableURL = URL(fileURLWithPath: args[0])
        host.arguments = [root.path, "--child", engine.path, pidfile, outputFile]
        do { try host.run() } catch { check("spawn parent-death host", false, "\(error)"); return }

        var enginePID: Int32 = -1
        let deadline = Date().addingTimeInterval(3)
        while Date() < deadline {
            if let text = try? String(contentsOfFile: pidfile, encoding: .utf8),
               let pid = Int32(text.trimmingCharacters(in: .whitespacesAndNewlines)) {
                enginePID = pid; break
            }
            await sleep(0.05)
        }
        check("parent-death engine started", enginePID > 0, "pid \(enginePID)")
        guard enginePID > 0 else { host.terminate(); return }

        kill(host.processIdentifier, SIGKILL)
        host.waitUntilExit()
        let gone = await waitUntilGone(enginePID, timeout: 3)
        check("SIGKILLed app leaves no engine", gone, "pid \(enginePID) still alive")
        if gone {
            let size1 = (try? FileManager.default.attributesOfItem(atPath: outputFile)[.size] as? Int) ?? 0
            await sleep(0.5)
            let size2 = (try? FileManager.default.attributesOfItem(atPath: outputFile)[.size] as? Int) ?? 0
            check("engine stopped writing", size1 == size2, "\(size1) -> \(size2)")
        }
    }

    static func testConcurrentTwo() async {
        let engine = script("engine-concurrent.sh", """
        #!/bin/bash
        echo start
        sleep 0.25
        echo done
        exit 0
        """)
        let runnerA = RealProcessRunner()
        let runnerB = RealProcessRunner()
        let request = ProcessRequest(executable: engine, arguments: [], superviseParentDeath: true)
        async let a = runnerA.run(request, onStdoutLine: { _ in }, onStderrLine: { _ in })
        async let b = runnerB.run(request, onStdoutLine: { _ in }, onStderrLine: { _ in })
        do {
            let (oa, ob) = try await (a, b)
            check("concurrent two supervised runs", oa.exitCode == 0 && ob.exitCode == 0)
        } catch {
            check("concurrent two supervised runs", false, "\(error)")
        }
    }


    // 10) Paths/arguments are passed as argv, never interpolated into shell
    // syntax. Use sentinel files and literal $(...)/backticks to prove no eval.
    static func testArgvSafety() async {
        let specialRoot = root.appendingPathComponent("argv dir $(touch PWNED) `touch PWNED2` \"d\" 's'", isDirectory: true)
        try? FileManager.default.createDirectory(at: specialRoot, withIntermediateDirectories: true)
        let engine = specialRoot.appendingPathComponent("engine $(touch PWNED) `touch PWNED2` \"d\" 's'.sh")
        let argvFile = specialRoot.appendingPathComponent("argv.out")
        let body = #"""
        #!/bin/bash
        out="$1"; shift
        : > "$out"
        printf '%s\n' "$@" >> "$out"
        exit 0
        """#
        try? body.write(to: engine, atomically: true, encoding: .utf8)
        try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: engine.path)

        let sentinelA = specialRoot.appendingPathComponent("PWNED")
        let sentinelB = specialRoot.appendingPathComponent("PWNED2")
        let sentinelC = specialRoot.appendingPathComponent("PWNED3")
        let sentinelD = specialRoot.appendingPathComponent("PWNED4")
        for sentinel in [sentinelA, sentinelB, sentinelC, sentinelD] {
            try? FileManager.default.removeItem(at: sentinel)
        }
        let specialArgs = [
            "arg with spaces",
            "single ' quote",
            "double \" quote",
            "$(touch PWNED3)",
            "`touch PWNED4`",
            "semi;colon|pipe&and",
            "$HOME literal"
        ]
        let request = ProcessRequest(executable: engine,
                                     arguments: [argvFile.path] + specialArgs,
                                     currentDirectory: specialRoot,
                                     superviseParentDeath: true)
        let runner = RealProcessRunner()
        do {
            let output = try await runner.run(request, onStdoutLine: { _ in }, onStderrLine: { _ in })
            check("argv safety exit", output.exitCode == 0, "exit \(output.exitCode)")
            let lines = ((try? String(contentsOf: argvFile, encoding: .utf8)) ?? "")
                .split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
            let expected = specialArgs
            check("argv safety exact arguments", Array(lines.prefix(expected.count)) == expected,
                  "got \(lines.prefix(expected.count))")
            check("argv safety no shell expansion sentinels",
                  [sentinelA, sentinelB, sentinelC, sentinelD].allSatisfy { !FileManager.default.fileExists(atPath: $0.path) })
        } catch {
            check("argv safety run", false, "\(error)")
        }
    }

    static func childMode(engine: URL, pidfile: String, output: String) async {
        _ = pidfile; _ = output
        let runner = RealProcessRunner()
        let request = ProcessRequest(executable: engine, arguments: [], superviseParentDeath: true)
        Task { _ = try? await runner.run(request, onStdoutLine: { _ in }, onStderrLine: { _ in }) }
        while true { await sleep(1) }
    }
}
