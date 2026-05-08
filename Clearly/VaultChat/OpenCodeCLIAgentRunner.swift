import Foundation
import ClearlyCore

/// Spawns the user's locally-installed `opencode` CLI to answer a prompt. This
/// reuses the user's existing opencode provider auth; Clearly never reads or
/// stores credentials.
///
/// Invocation:
///   opencode --pure run --format json --title "Clearly Chat" [--model <m>]
///
/// The prompt is fed on stdin to avoid ARG_MAX with long retrieved-note
/// context. Chat handles retrieval in-process via `VaultChatRetriever`; the
/// stable cache-directory cwd keeps opencode away from the user's vault files.
struct OpenCodeCLIAgentRunner: AgentRunner {
    let binaryURL: URL
    let environment: [String: String]
    let workingDirectoryOverride: URL?

    init(
        binaryURL: URL,
        workingDirectory: URL? = nil,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) {
        self.binaryURL = binaryURL
        self.workingDirectoryOverride = workingDirectory
        self.environment = environment
    }

    func run(prompt: String, model: String?) async throws -> AgentResult {
        let arguments = Self.buildArguments(model: model)
        let (stdoutData, stderrText, status) = try await spawn(prompt: prompt, arguments: arguments)

        DiagnosticLog.log("opencode RUN: status=\(status) promptLen=\(prompt.count) stdoutLen=\(stdoutData.count) stderrLen=\(stderrText.count)")
        guard status == 0 else {
            throw AgentError.transport("opencode exited with status \(status). stderr: \(stderrText.prefix(512))")
        }

        let decoded = try Self.decode(data: stdoutData)
        return AgentResult(
            text: decoded.text,
            inputTokens: decoded.inputTokens,
            outputTokens: decoded.outputTokens,
            model: "opencode-cli"
        )
    }

    // MARK: - Argument layout

    static func buildArguments(model: String?) -> [String] {
        var args: [String] = [
            "--pure",
            "run",
            "--format", "json",
            "--title", "Clearly Chat",
        ]
        if let model, !model.isEmpty {
            args.append(contentsOf: ["--model", model])
        }
        return args
    }

    // MARK: - Process plumbing

    private func spawn(prompt: String, arguments: [String]) async throws -> (Data, String, Int32) {
        try await withCheckedThrowingContinuation { continuation in
            let process = Process()
            process.executableURL = binaryURL
            process.arguments = arguments
            process.currentDirectoryURL = workingDirectoryOverride ?? Self.stableWorkingDirectory()
            process.environment = ClaudeCLIAgentRunner.environmentForSubprocess(
                base: environment,
                currentDirectory: process.currentDirectoryURL,
                binaryURL: binaryURL
            )

            let stdin = Pipe()
            let stdout = Pipe()
            let stderr = Pipe()
            process.standardInput = stdin
            process.standardOutput = stdout
            process.standardError = stderr

            let capture = ProcessCaptureState()
            process.terminationHandler = { _ in
                capture.finish(status: process.terminationStatus, continuation: continuation)
            }

            do {
                try process.run()
            } catch {
                capture.fail(AgentError.transport(String(describing: error)), continuation: continuation)
                return
            }

            DispatchQueue.global(qos: .userInitiated).async {
                let data = stdout.fileHandleForReading.readDataToEndOfFile()
                capture.finishStdout(data, continuation: continuation)
            }
            DispatchQueue.global(qos: .userInitiated).async {
                let data = stderr.fileHandleForReading.readDataToEndOfFile()
                capture.finishStderr(data, continuation: continuation)
            }

            let writer = stdin.fileHandleForWriting
            DispatchQueue.global(qos: .userInitiated).async {
                if let data = prompt.data(using: .utf8) {
                    try? writer.write(contentsOf: data)
                }
                try? writer.close()
            }
        }
    }

    private static func stableWorkingDirectory() -> URL? {
        guard let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first else {
            return nil
        }
        let dir = caches.appendingPathComponent("wiki-agent", isDirectory: true)
        if !FileManager.default.fileExists(atPath: dir.path) {
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        }
        return dir
    }

    // MARK: - Response decoding

    struct DecodedResponse: Equatable {
        let text: String
        let inputTokens: Int
        let outputTokens: Int
    }

    static func decode(data: Data) throws -> DecodedResponse {
        struct Event: Decodable {
            struct Part: Decodable {
                struct Tokens: Decodable {
                    struct Cache: Decodable {
                        let read: Int?
                        let write: Int?
                    }

                    let input: Int?
                    let output: Int?
                    let total: Int?
                    let cache: Cache?
                }

                let text: String?
                let tokens: Tokens?
            }

            let type: String?
            let part: Part?
        }

        guard let raw = String(data: data, encoding: .utf8) else {
            throw AgentError.invalidResponse("opencode returned non-utf8 output")
        }

        let decoder = JSONDecoder()
        var textParts: [String] = []
        var inputTokens = 0
        var outputTokens = 0
        var sawJSON = false

        for line in raw.split(whereSeparator: { $0 == "\n" || $0 == "\r" }) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty, let bytes = trimmed.data(using: .utf8) else { continue }
            guard let event = try? decoder.decode(Event.self, from: bytes) else { continue }
            sawJSON = true
            if event.type == "text", let text = event.part?.text {
                textParts.append(text)
            }
            if event.type == "step_finish", let tokens = event.part?.tokens {
                inputTokens = tokens.input ?? max(0, (tokens.total ?? 0) - (tokens.output ?? 0))
                outputTokens = tokens.output ?? 0
            }
        }

        guard sawJSON else {
            throw AgentError.invalidResponse("opencode JSONL decode failure; raw: \(raw.prefix(512))")
        }
        let text = textParts.joined().trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else {
            throw AgentError.invalidResponse("opencode returned empty result")
        }
        return DecodedResponse(text: text, inputTokens: inputTokens, outputTokens: outputTokens)
    }
}
