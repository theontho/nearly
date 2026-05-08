import Foundation
import ClearlyCore

/// Spawns the user's locally-installed `gemini` CLI to answer a prompt. This
/// reuses the user's existing Gemini CLI auth; Clearly never reads or stores
/// credentials.
///
/// Invocation:
///   gemini --skip-trust --approval-mode plan --output-format text \
///          [--model <m>] --prompt ""
///
/// The actual prompt is fed on stdin so long retrieved-note context doesn't hit
/// ARG_MAX. Chat handles retrieval in-process via `VaultChatRetriever`, and
/// `approval-mode plan` keeps the CLI read-only if the model asks for tools.
struct GeminiCLIAgentRunner: AgentRunner {
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

        DiagnosticLog.log("gemini RUN: status=\(status) promptLen=\(prompt.count) stdoutLen=\(stdoutData.count) stderrLen=\(stderrText.count)")
        guard status == 0 else {
            throw AgentError.transport("gemini exited with status \(status). stderr: \(stderrText.prefix(512))")
        }

        let text = String(data: stdoutData, encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !text.isEmpty else {
            throw AgentError.invalidResponse("gemini returned empty result")
        }
        return AgentResult(
            text: text,
            inputTokens: 0,
            outputTokens: 0,
            model: "gemini-cli"
        )
    }

    // MARK: - Argument layout

    static func buildArguments(model: String?) -> [String] {
        var args: [String] = [
            "--skip-trust",
            "--approval-mode", "plan",
            "--output-format", "text",
        ]
        if let model, !model.isEmpty {
            args.append(contentsOf: ["--model", model])
        }
        args.append(contentsOf: ["--prompt", ""])
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
}
