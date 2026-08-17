import Darwin
import Foundation
import ProxyLensCore

public final class ProcessJavaScriptExecutor: ScriptExecutor, @unchecked Sendable {
    public let workerExecutableURL: URL
    public let timeoutMilliseconds: Int
    private let fileManager: FileManager
    private let temporaryRootURL: URL

    public init(
        workerExecutableURL: URL,
        timeoutMilliseconds: Int = ScriptExecutionLimits.defaultTimeoutMilliseconds,
        fileManager: FileManager = .default,
        temporaryRootURL: URL? = nil
    ) {
        self.workerExecutableURL = workerExecutableURL
        self.timeoutMilliseconds = min(
            max(1, timeoutMilliseconds),
            ScriptExecutionLimits.maximumTimeoutMilliseconds
        )
        self.fileManager = fileManager
        self.temporaryRootURL = temporaryRootURL ?? fileManager.temporaryDirectory
    }

    public func execute(_ request: ScriptExecutionRequest) async throws -> ScriptExecutionResult {
        let directoryURL = temporaryRootURL.appendingPathComponent(
            "ProxyLensScript-\(UUID().uuidString)",
            isDirectory: true
        )
        try fileManager.createDirectory(
            at: directoryURL,
            withIntermediateDirectories: false,
            attributes: [.posixPermissions: 0o700]
        )
        defer { try? fileManager.removeItem(at: directoryURL) }

        let inputURL = directoryURL.appendingPathComponent("input.json", isDirectory: false)
        let outputURL = directoryURL.appendingPathComponent("output.json", isDirectory: false)
        let inputData = try JSONEncoder().encode(request)
        guard inputData.count <= ScriptExecutionLimits.maximumInputByteCount else {
            throw ScriptExecutionError.inputTooLarge(
                maximumByteCount: ScriptExecutionLimits.maximumInputByteCount
            )
        }
        try inputData.write(to: inputURL, options: .atomic)
        try fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: inputURL.path)

        let process = Process()
        process.executableURL = workerExecutableURL
        process.arguments = [ScriptWorkerCommand.argument, inputURL.path, outputURL.path]
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice

        do {
            try process.run()
        } catch {
            throw ScriptExecutionError.workerFailed(status: -1)
        }

        let status: Int32
        if let exitStatus = await waitForExit(
            process,
            milliseconds: timeoutMilliseconds
        ) {
            status = exitStatus
        } else {
            process.terminate()
            if await waitForExit(process, milliseconds: 100) == nil {
                _ = kill(process.processIdentifier, SIGKILL)
            }
            _ = await waitForExit(process, milliseconds: 1_000)
            throw ScriptExecutionError.timedOut(milliseconds: timeoutMilliseconds)
        }

        guard status == EXIT_SUCCESS else {
            throw ScriptExecutionError.workerFailed(status: status)
        }
        guard fileManager.fileExists(atPath: outputURL.path) else {
            throw ScriptExecutionError.workerFailed(status: status)
        }
        let outputData = try boundedOutput(at: outputURL)
        let envelope: ScriptWorkerEnvelope
        do {
            envelope = try JSONDecoder().decode(ScriptWorkerEnvelope.self, from: outputData)
        } catch {
            throw ScriptExecutionError.invalidOutput(error.localizedDescription)
        }
        if let error = envelope.error {
            throw error
        }
        guard let result = envelope.result else {
            throw ScriptExecutionError.invalidOutput("Worker returned no result")
        }
        return result
    }

    private func waitForExit(
        _ process: Process,
        milliseconds: Int
    ) async -> Int32? {
        var remainingMilliseconds = max(0, milliseconds)
        while process.isRunning, remainingMilliseconds > 0 {
            let delayMilliseconds = min(5, remainingMilliseconds)
            try? await Task.sleep(for: .milliseconds(delayMilliseconds))
            remainingMilliseconds -= delayMilliseconds
        }
        return process.isRunning ? nil : process.terminationStatus
    }

    private func boundedOutput(at url: URL) throws -> Data {
        let attributes = try fileManager.attributesOfItem(atPath: url.path)
        let byteCount = (attributes[.size] as? NSNumber)?.intValue ?? 0
        guard byteCount <= ScriptExecutionLimits.maximumOutputByteCount else {
            throw ScriptExecutionError.outputTooLarge(
                maximumByteCount: ScriptExecutionLimits.maximumOutputByteCount
            )
        }
        return try Data(contentsOf: url, options: [.mappedIfSafe])
    }
}
