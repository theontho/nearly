import Foundation
import ClearlyCore

/// Spawns the user's locally-installed `copilot` CLI to answer a prompt.
/// Like the Claude and Codex runners, this uses the user's existing CLI auth;
/// Clearly never reads or stores Copilot credentials.
///
/// Invocation:
///   copilot -s --no-color --log-level none --disable-builtin-mcps \
///           --no-custom-instructions --no-auto-update --no-remote \
///           --stream off --available-tools "" [--model <m>] -p <prompt>
///
/// Chat handles retrieval in-process via `VaultChatRetriever`, so Copilot runs
/// without tools and only answers over the prompt's inlined context.
struct CopilotCLIAgentRunner: AgentRunner {
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
        let arguments = Self.buildArguments(prompt: prompt, model: model)
        let (stdoutData, stderrText, status) = try await spawn(arguments: arguments)

        DiagnosticLog.log("copilot RUN: status=\(status) promptLen=\(prompt.count) stdoutLen=\(stdoutData.count) stderrLen=\(stderrText.count)")
        guard status == 0 else {
            throw AgentError.transport("copilot exited with status \(status). stderr: \(stderrText.prefix(512))")
        }

        let text = String(data: stdoutData, encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !text.isEmpty else {
            throw AgentError.invalidResponse("copilot returned empty result")
        }
        return AgentResult(
            text: text,
            inputTokens: 0,
            outputTokens: 0,
            model: "copilot-cli"
        )
    }

    // MARK: - Argument layout

    static func buildArguments(prompt: String, model: String?) -> [String] {
        var args: [String] = [
            "--silent",
            "--no-color",
            "--log-level", "none",
            "--disable-builtin-mcps",
            "--no-custom-instructions",
            "--no-auto-update",
            "--no-remote",
            "--stream", "off",
            "--available-tools", "",
        ]
        if let model, !model.isEmpty {
            args.append(contentsOf: ["--model", model])
        }
        args.append(contentsOf: ["--prompt", prompt])
        return args
    }

    // MARK: - Process plumbing

    private func spawn(arguments: [String]) async throws -> (Data, String, Int32) {
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

            let stdout = Pipe()
            let stderr = Pipe()
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
