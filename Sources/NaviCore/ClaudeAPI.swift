import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking   // URLSession and URLRequest live here on Linux
#endif

/// Direct Messages API backend, with the key saved in the Keychain (or
/// ANTHROPIC_API_KEY when none is saved). Streams, and keeps
/// the full assistant content (thinking blocks included). Screenshots from
/// earlier turns are swapped for a short note before each request, and only
/// the last few exchanges are sent, so only the newest screen is in context.
public final class APIBackend: ChatBackend {
    public init() {}
    public static let defaultModel = "claude-opus-5-5"
    /// Earlier exchanges (user + assistant message pairs) sent with each turn.
    public static let keepExchanges = 4
    private var messages: [[String: Any]] = []
    private var lastUsed = Date.distantPast
    public private(set) var lastStats: TurnStats?
    public var prunesInPlace: Bool { true }

    public func reset() { messages = [] }
    public var holdsHistory: Bool { !messages.isEmpty }

    /// Only the latest screenshot is kept: earlier user turns keep their text,
    /// their images become a note.
    public static func pruned(_ messages: [[String: Any]], keepExchanges: Int = keepExchanges) -> [[String: Any]] {
        messages.suffix(keepExchanges * 2).map { m in
            guard m["role"] as? String == "user", let content = m["content"] as? [[String: Any]] else { return m }
            var out = m
            out["content"] = content.map { block in
                block["type"] as? String == "image" ? Prompt.text("[earlier screenshot, no longer attached]") : block
            }
            return out
        }
    }

    public func send(_ content: [[String: Any]], onText: @escaping (String) -> Void) async throws -> String {
        do {
            let text = try await stream(content, onText: onText)
            ClaudeAccess.report(.success(()), .api)
            return text
        } catch {
            ClaudeAccess.report(.failure(error), .api)
            throw error
        }
    }

    private func stream(_ content: [[String: Any]], onText: @escaping (String) -> Void) async throws -> String {
        guard let key = ClaudeAccess.apiKey else { throw ClaudeError.noKey }
        if Date().timeIntervalSince(lastUsed) > 15 * 60 { reset() }
        lastUsed = Date()

        let settings = Settings.shared
        let history = Self.pruned(messages) + [["role": "user", "content": content]]
        let body: [String: Any] = [
            "model": settings.model.isEmpty ? Self.defaultModel : Self.apiModel(settings.model),
            "max_tokens": 16000,
            "stream": true,
            "output_config": ["effort": settings.effort],
            "fallbacks": "default",
            "system": Prompt.system(for: .current, tools: Prompt.tools(cli: false, readFiles: false)),
            "messages": history,
            // Web search and fetch, for real links (a page to open, a file to download).
            "tools": [["type": "web_search_20260209", "name": "web_search", "max_uses": 2]],
        ]

        var req = URLRequest(url: URL(string: "https://api.anthropic.com/v1/messages")!)
        req.httpMethod = "POST"
        req.timeoutInterval = 180
        req.setValue(key, forHTTPHeaderField: "x-api-key")
        req.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        req.setValue("server-side-fallback-2026-07-01", forHTTPHeaderField: "anthropic-beta")
        req.setValue("application/json", forHTTPHeaderField: "content-type")
        req.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (lines, status) = try await Self.streamLines(req)
        guard status == 200 else {
            var errBody = ""
            for try await line in lines { errBody += line }
            throw ClaudeError.http(status, errBody)
        }

        var blocks: [Int: [String: Any]] = [:]
        var text = ""
        var stopReason: String?
        var stopDetails: [String: Any]?
        let started = Date()
        NotificationCenter.default.post(name: .naviWaiting, object: Shell.Waiting.sent)
        var stats = TurnStats(usage: nil)

        for try await line in lines {
            guard line.hasPrefix("data:"),
                  let event = try? JSONSerialization.jsonObject(with: Data(line.dropFirst(5).utf8)) as? [String: Any]
            else { continue }
            switch event["type"] as? String {
            case "message_start":
                if let m = (event["message"] as? [String: Any])?["model"] as? String { trace("API model: \(m)") }
                stats = TurnStats(usage: (event["message"] as? [String: Any])?["usage"] as? [String: Any])
            case "content_block_start":
                if let i = event["index"] as? Int, let block = event["content_block"] as? [String: Any] {
                    blocks[i] = block
                    // Text after a lookup starts a new line, so beats don't run together.
                    if block["type"] as? String == "text", !text.isEmpty, !text.hasSuffix("\n") { text += "\n" }
                    if block["type"] as? String == "thinking" {
                        NotificationCenter.default.post(name: .naviWaiting, object: Shell.Waiting.thinking(tokens: 0))
                    }
                    if block["type"] as? String == "server_tool_use" {
                        trace("API tool: \(block["name"] as? String ?? "?")")
                        NotificationCenter.default.post(name: .naviLookingUp, object: block["name"])
                    }
                }
            case "content_block_delta":
                guard let i = event["index"] as? Int, let delta = event["delta"] as? [String: Any] else { break }
                var block = blocks[i] ?? [:]
                switch delta["type"] as? String {
                case "text_delta":
                    let t = delta["text"] as? String ?? ""
                    block["text"] = (block["text"] as? String ?? "") + t
                    text += t
                    if stats.firstText == nil { stats.firstText = Date().timeIntervalSince(started) }
                    if stats.firstTag == nil, !TagParser.parse(text).annotations.isEmpty {
                        stats.firstTag = Date().timeIntervalSince(started)
                    }
                    onText(text)
                case "thinking_delta":
                    let before = (block["thinking"] as? String ?? "").count / 4
                    block["thinking"] = (block["thinking"] as? String ?? "") + (delta["thinking"] as? String ?? "")
                    // About four characters a token; said every 50, as Claude Code does.
                    let now = (block["thinking"] as? String ?? "").count / 4
                    if now / 50 > before / 50 {
                        NotificationCenter.default.post(name: .naviWaiting, object: Shell.Waiting.thinking(tokens: now))
                    }
                case "signature_delta":
                    block["signature"] = delta["signature"] as? String
                case "input_json_delta":
                    // A server tool's input arrives in pieces; it's whole at content_block_stop.
                    block["partial_json"] = (block["partial_json"] as? String ?? "") + (delta["partial_json"] as? String ?? "")
                default: break
                }
                blocks[i] = block
            case "content_block_stop":
                if let i = event["index"] as? Int, var block = blocks[i], let json = block.removeValue(forKey: "partial_json") as? String {
                    block["input"] = (try? JSONSerialization.jsonObject(with: Data(json.utf8))) ?? [String: Any]()
                    blocks[i] = block
                }
            case "message_delta":
                if let d = event["delta"] as? [String: Any] {
                    stopReason = d["stop_reason"] as? String ?? stopReason
                    stopDetails = d["stop_details"] as? [String: Any] ?? stopDetails
                }
                if let out = (event["usage"] as? [String: Any])?["output_tokens"] as? Int { stats.output = out }
            case "error":
                let err = event["error"] as? [String: Any]
                throw ClaudeError.stream(err?["message"] as? String ?? "unknown")
            default: break
            }
        }

        if stopReason == "refusal" {
            throw ClaudeError.refused(stopDetails?["explanation"] as? String ?? "no reason given")
        }
        guard !text.isEmpty else { throw ClaudeError.empty }
        stats.total = Date().timeIntervalSince(started)
        lastStats = stats
        let assistant = blocks.keys.sorted().compactMap { blocks[$0] }
        messages = history + [["role": "assistant", "content": assistant]]
        return text
    }

    /// The response as lines of SSE, with the HTTP status. Apple platforms stream;
    /// Linux's FoundationNetworking has no `bytes(for:)`, so there the whole body is
    /// read first (the core builds and self-tests on Linux; the Mac and Windows
    /// shells are what run this).
    private static func streamLines(_ req: URLRequest) async throws -> (AsyncThrowingStream<String, Error>, Int) {
        #if canImport(FoundationNetworking)
        let (data, response) = try await URLSession.shared.data(for: req)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        let all = String(decoding: data, as: UTF8.self).split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        return (AsyncThrowingStream { c in all.forEach { c.yield($0) }; c.finish() }, status)
        #else
        let (bytes, response) = try await URLSession.shared.bytes(for: req)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        let stream = AsyncThrowingStream<String, Error> { c in
            let t = Task {
                do { for try await line in bytes.lines { c.yield(line) }; c.finish() } catch { c.finish(throwing: error) }
            }
            c.onTermination = { _ in t.cancel() }
        }
        return (stream, status)
        #endif
    }

    /// Menu choices are Claude Code aliases; map them for the raw API.
    private static func apiModel(_ alias: String) -> String {
        switch alias {
        case "opus": return "claude-opus-5-5"
        case "sonnet": return "claude-sonnet-5-5"
        case "haiku": return "claude-haiku-5-5"
        default: return alias
        }
    }
}
