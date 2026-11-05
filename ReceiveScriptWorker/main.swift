import Foundation
import JavaScriptCore

enum ReceiveScriptFailure: Error, Sendable, Codable {
    case invalidFunction
    case invalidResult
    case lineTooLong
    case outputTooLarge
    case backlog
    case timeout
    case exception(String)
    case worker(String)

}

struct ReceiveScriptRequest: Codable {
    var source: String?
    var lines: [String] = []
}

struct ReceiveScriptReply: Codable {
    var outputs: [String?] = []
    var failure: ReceiveScriptFailure?
}

/// Only JSON messages cross this process boundary. No native objects, filesystem APIs,
/// or network APIs are exported to JavaScript. The wire types match ReceiveScript.swift.
enum ReceiveScriptWorker {

    static func run() {
        var context: JSContext?
        var function: JSValue?
        while let line = readLine() {
            let reply: ReceiveScriptReply
            do {
                let request = try JSONDecoder().decode(ReceiveScriptRequest.self, from: Data(line.utf8))
                if let source = request.source {
                    guard source.utf8.count <= 65_536, let next = JSContext() else {
                        throw ReceiveScriptFailure.outputTooLarge
                    }
                    context = next
                    function = next.evaluateScript(source + "\n;typeof process === 'function' ? process : undefined")
                    if let exception = next.exception {
                        throw ReceiveScriptFailure.exception(String((exception.toString() ?? "JavaScript error").prefix(1024)))
                    }
                    guard function?.isUndefined == false else { throw ReceiveScriptFailure.invalidFunction }
                }
                guard let context, let function else { throw ReceiveScriptFailure.invalidFunction }
                var outputs: [String?] = []
                var outputBytes = 0
                for text in request.lines {
                    context.exception = nil
                    guard let result = function.call(withArguments: [text]) else {
                        throw ReceiveScriptFailure.invalidResult
                    }
                    if let exception = context.exception {
                        throw ReceiveScriptFailure.exception(String((exception.toString() ?? "JavaScript error").prefix(1024)))
                    }
                    if result.isNull {
                        outputs.append(nil)
                    } else {
                        guard result.isString, let output = result.toString() else {
                            throw ReceiveScriptFailure.invalidResult
                        }
                        outputBytes += output.utf8.count
                        guard output.utf8.count <= 65_536, outputBytes <= 131_072 else {
                            throw ReceiveScriptFailure.outputTooLarge
                        }
                        outputs.append(output)
                    }
                }
                reply = ReceiveScriptReply(outputs: outputs)
            } catch {
                reply = ReceiveScriptReply(failure: (error as? ReceiveScriptFailure) ?? .worker(error.localizedDescription))
            }
            guard var data = try? JSONEncoder().encode(reply) else { break }
            data.append(10)
            do { try FileHandle.standardOutput.write(contentsOf: data) } catch { break }
        }
    }
}


ReceiveScriptWorker.run()
