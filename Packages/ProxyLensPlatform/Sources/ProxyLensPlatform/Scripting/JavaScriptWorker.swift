import Darwin
import Foundation
@preconcurrency import JavaScriptCore
import ProxyLensCore

struct ScriptWorkerEnvelope: Codable {
    let result: ScriptExecutionResult?
    let error: ScriptExecutionError?

    init(result: ScriptExecutionResult) {
        self.result = result
        self.error = nil
    }

    init(error: ScriptExecutionError) {
        self.result = nil
        self.error = error
    }
}

enum JavaScriptWorker {
    static func evaluate(_ request: ScriptExecutionRequest) throws -> ScriptExecutionResult {
        guard let context = JSContext() else {
            throw ScriptExecutionError.invalidOutput("JavaScriptCore could not create a context")
        }

        var capturedException: String?
        context.name = "ProxyLens isolated script"
        context.isInspectable = false
        context.exceptionHandler = { _, exception in
            capturedException = exception?.toString() ?? "Unknown JavaScript exception"
        }

        let messageData = try JSONEncoder().encode(request.message)
        guard let messageJSON = String(data: messageData, encoding: .utf8) else {
            throw ScriptExecutionError.invalidOutput("Message is not valid UTF-8 JSON")
        }
        context.setObject(messageJSON, forKeyedSubscript: "__proxylensMessageJSON" as NSString)
        context.setObject(request.hook.rawValue, forKeyedSubscript: "__proxylensHook" as NSString)

        let result = context.evaluateScript(wrapper(source: request.source))
        if let capturedException {
            if capturedException.contains("__PROXYLENS_MISSING_HANDLER__") {
                throw ScriptExecutionError.missingHandler(request.hook.handlerName)
            }
            if capturedException.contains("__PROXYLENS_ASYNC_UNSUPPORTED__") {
                throw ScriptExecutionError.asynchronousResultUnsupported
            }
            throw ScriptExecutionError.javaScriptException(capturedException)
        }
        guard let resultJSON = result?.toString(), let resultData = resultJSON.data(using: .utf8)
        else {
            throw ScriptExecutionError.invalidOutput("Handler did not produce JSON")
        }
        guard resultData.count <= ScriptExecutionLimits.maximumOutputByteCount else {
            throw ScriptExecutionError.outputTooLarge(
                maximumByteCount: ScriptExecutionLimits.maximumOutputByteCount
            )
        }

        do {
            return try JSONDecoder().decode(ScriptExecutionResult.self, from: resultData)
        } catch let error as ScriptExecutionError {
            throw error
        } catch {
            throw ScriptExecutionError.invalidOutput(error.localizedDescription)
        }
    }

    private static func wrapper(source: String) -> String {
        """
        (() => {
          "use strict";
          const __message = JSON.parse(__proxylensMessageJSON);
          const __logs = [];
          const __context = {
            log(value) {
              if (__logs.length <= \(ScriptExecutionLimits.maximumLogCount)) {
                __logs.push(String(value).slice(0, \(ScriptExecutionLimits.maximumLogByteCount + 1)));
              }
            }
          };
          if (__proxylensHook === "request") {
            __context.request = __message;
          } else {
            __context.response = __message;
          }
          const __handlers = (() => {
        \(source)
            return {
              request: typeof onRequest === "function" ? onRequest : null,
              response: typeof onResponse === "function" ? onResponse : null
            };
          })();
          const __handler = __handlers[__proxylensHook];
          if (typeof __handler !== "function") {
            throw new Error("__PROXYLENS_MISSING_HANDLER__");
          }
          const __returned = __handler(__context);
          if (__returned !== null && typeof __returned === "object"
              && typeof __returned.then === "function") {
            throw new Error("__PROXYLENS_ASYNC_UNSUPPORTED__");
          }
          const __resultMessage = (__returned !== null && typeof __returned === "object")
            ? __returned
            : (__proxylensHook === "request" ? __context.request : __context.response);
          return JSON.stringify({
            hook: __proxylensHook,
            message: __resultMessage,
            logs: __logs
          });
        })()
        """
    }
}

public enum ScriptWorkerCommand {
    public static let argument = "--proxylens-script-worker"

    public static func run(inputURL: URL, outputURL: URL) -> Int32 {
        applyResourceLimits()

        do {
            let inputData = try boundedData(
                at: inputURL,
                maximumByteCount: ScriptExecutionLimits.maximumInputByteCount
            )
            let request = try JSONDecoder().decode(ScriptExecutionRequest.self, from: inputData)
            let result = try JavaScriptWorker.evaluate(request)
            try write(ScriptWorkerEnvelope(result: result), to: outputURL)
            return EXIT_SUCCESS
        } catch let error as ScriptExecutionError {
            try? write(ScriptWorkerEnvelope(error: error), to: outputURL)
            return EXIT_SUCCESS
        } catch {
            try? write(
                ScriptWorkerEnvelope(error: .invalidOutput(error.localizedDescription)),
                to: outputURL
            )
            return EXIT_FAILURE
        }
    }

    private static func boundedData(at url: URL, maximumByteCount: Int) throws -> Data {
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        let byteCount = (attributes[.size] as? NSNumber)?.intValue ?? 0
        guard byteCount <= maximumByteCount else {
            throw ScriptExecutionError.inputTooLarge(maximumByteCount: maximumByteCount)
        }
        return try Data(contentsOf: url, options: [.mappedIfSafe])
    }

    private static func write(_ envelope: ScriptWorkerEnvelope, to url: URL) throws {
        let data = try JSONEncoder().encode(envelope)
        guard data.count <= ScriptExecutionLimits.maximumOutputByteCount else {
            throw ScriptExecutionError.outputTooLarge(
                maximumByteCount: ScriptExecutionLimits.maximumOutputByteCount
            )
        }
        try data.write(to: url, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }

    private static func applyResourceLimits() {
        var cpuLimit = rlimit(rlim_cur: 6, rlim_max: 6)
        _ = setrlimit(RLIMIT_CPU, &cpuLimit)
    }
}
