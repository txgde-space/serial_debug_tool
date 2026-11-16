import Foundation
import JavaScriptCore
import AppKit

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



/// Authentication runs in a separate invocation of the sandbox-inheriting helper.
/// JavaScript receives no Keychain or AppKit bindings.
@MainActor
enum SSHAuthenticationPrompt {
    static func run() -> Never {
        let environment = ProcessInfo.processInfo.environment
        let prompt = String((CommandLine.arguments.dropFirst().first ?? "").prefix(4096))
        let kind = environment["SSH_ASKPASS_PROMPT"]
        let confirming = kind == "confirm" || prompt.contains("yes/no")
        let notice = kind == "none"
        if !confirming, SSHKeychain.isPasswordPrompt(prompt, kind: kind) {
            do {
                if let password = try SSHPasswordBroker.password(environment: environment) {
                    FileHandle.standardOutput.write(Data((password + "\n").utf8))
                    Darwin.exit(0)
                }
            } catch {
                // A configured saved credential must not silently become another password dialog.
                FileHandle.standardError.write(Data("Unable to read the saved SSH credential from the application.\n".utf8))
                Darwin.exit(1)
            }
        }
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        switch environment["SERIAL_DEBUG_SSH_THEME"] {
        case "dark": app.appearance = NSAppearance(named: .darkAqua)
        case "light": app.appearance = NSAppearance(named: .aqua)
        default: break
        }
        let labels = environment["SERIAL_DEBUG_SSH_LABELS"].flatMap { $0.data(using: .utf8) }
            .flatMap { try? JSONDecoder().decode([String: String].self, from: $0) } ?? [:]
        let alert = NSAlert()
        alert.messageText = confirming ? labels["trustHost"] ?? "Trust SSH Host?" : labels["authenticate"] ?? "SSH Authentication"
        alert.informativeText = (environment["SERIAL_DEBUG_SSH_CONTEXT"] ?? "") + "\n\n" + prompt
        alert.icon = NSImage(systemSymbolName: "network", accessibilityDescription: nil)
        alert.addButton(withTitle: confirming ? labels["trust"] ?? "Trust" : labels["confirm"] ?? "OK")
        alert.addButton(withTitle: labels["cancel"] ?? "Cancel")
        let field = NSSecureTextField(frame: NSRect(x: 0, y: 0, width: 320, height: 24))
        if !confirming && !notice {
            field.placeholderString = labels["secret"] ?? "Password"
            alert.accessoryView = field
        }
        let parent = getppid()
        let timer = Timer(timeInterval: 0.5, repeats: true) { _ in
            if getppid() != parent || kill(parent, 0) != 0 { Darwin.exit(1) }
        }
        RunLoop.main.add(timer, forMode: RunLoop.Mode("NSModalPanelRunLoopMode"))
        app.activate(ignoringOtherApps: true)
        if !confirming && !notice { alert.window.initialFirstResponder = field }
        let response = alert.runModal()
        timer.invalidate()
        guard response == .alertFirstButtonReturn else { Darwin.exit(1) }
        let answer = confirming ? "yes" : notice ? "" : field.stringValue
        guard !answer.contains(where: { $0 == "\n" || $0 == "\r" || $0 == "\0" }) else { Darwin.exit(1) }
        FileHandle.standardOutput.write(Data((answer + "\n").utf8))
        Darwin.exit(0)
    }
}

if ProcessInfo.processInfo.environment["SERIAL_DEBUG_SSH_ASKPASS"] == "1" {
    MainActor.assumeIsolated { SSHAuthenticationPrompt.run() }
} else {
    ReceiveScriptWorker.run()
}
