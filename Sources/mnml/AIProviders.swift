import Foundation
import Security

struct AIModel: Identifiable, Equatable {
    let id: String
    let title: String
    let images: Bool
    let pdfs: Bool
    let budget: Int

    func accepts(_ files: [Attachment]) -> Bool {
        files.allSatisfy { file in
            if file.mime == "application/pdf" { return pdfs }
            if file.mime.hasPrefix("image/") { return images }
            return file.mime == "text/plain" || file.mime == "text/csv"
        }
    }
}

enum AIProvider: String, CaseIterable, Identifiable {
    case gemini, groq, openai, anthropic

    var id: String { rawValue }
    var title: String {
        switch self {
        case .gemini: "Gemini"
        case .groq: "Groq"
        case .openai: "OpenAI"
        case .anthropic: "Anthropic"
        }
    }
    var keyURL: URL {
        let url: String
        switch self {
        case .gemini: url = "https://aistudio.google.com/apikey"
        case .groq: url = "https://console.groq.com/keys"
        case .openai: url = "https://platform.openai.com/api-keys"
        case .anthropic: url = "https://console.anthropic.com/settings/keys"
        }
        return URL(string: url)!
    }
    var models: [AIModel] {
        switch self {
        case .gemini: [
            AIModel(id: "gemini-flash-latest", title: "Flash", images: true, pdfs: true, budget: 400_000),
            AIModel(id: "gemini-flash-lite-latest", title: "Flash-Lite", images: true, pdfs: true, budget: 400_000),
        ]
        case .groq: [
            AIModel(id: "qwen/qwen3.8-27b", title: "Qwen 3.8 27B · free", images: true, pdfs: false, budget: 16_000),
            AIModel(id: "openai/gpt-oss-120b", title: "GPT-OSS 120B · free", images: false, pdfs: false, budget: 16_000),
        ]
        case .openai: [
            AIModel(id: "gpt-5.6-luna", title: "GPT-5.6 Luna · paid", images: true, pdfs: true, budget: 120_000),
            AIModel(id: "gpt-5.6-terra", title: "GPT-5.6 Terra · paid", images: true, pdfs: true, budget: 120_000),
        ]
        case .anthropic: [
            AIModel(id: "claude-haiku-4-5-20251001", title: "Claude Haiku 4.5 · paid", images: true, pdfs: true, budget: 120_000),
            AIModel(id: "claude-sonnet-5", title: "Claude Sonnet 5 · paid", images: true, pdfs: true, budget: 120_000),
        ]
        }
    }
    func model(_ id: String) -> AIModel {
        models.first { $0.id == id } ?? AIModel(id: id, title: "Custom: \(id)", images: false, pdfs: false, budget: 16_000)
    }
}

enum AIKey {
    private static func query(_ provider: AIProvider) -> [String: Any] {
        let service = provider == .gemini ? "mnml Gemini key" : "mnml \(provider.title) key"
        return [kSecClass as String: kSecClassGenericPassword,
                kSecAttrService as String: service + (Store.testing ? " (test)" : ""),
                kSecAttrAccount as String: provider.title]
    }
    static func read(_ provider: AIProvider) -> String? {
        var asked = query(provider)
        asked[kSecReturnData as String] = true
        var found: AnyObject?
        guard SecItemCopyMatching(asked as CFDictionary, &found) == errSecSuccess,
              let data = found as? Data, let key = String(data: data, encoding: .utf8), !key.isEmpty
        else { return nil }
        return key
    }
    static func readAsync(_ provider: AIProvider) async -> String? {
        await Task.detached(priority: .userInitiated) { read(provider) }.value
    }
    static func keepAsync(_ key: String, for provider: AIProvider) async {
        await Task.detached(priority: .userInitiated) {
            let query = query(provider)
            SecItemDelete(query as CFDictionary)
            let key = key.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !key.isEmpty else { return }
            var item = query
            item[kSecValueData as String] = Data(key.utf8)
            item[kSecAttrLabel as String] = "mnml — \(provider.title) API key"
            SecItemAdd(item as CFDictionary, nil)
        }.value
    }
}

struct AIInput {
    let system: String
    let turns: [(mine: Bool, text: String)]
    let files: [Attachment]
}

enum AITransport {
    enum Failure: LocalizedError {
        case status(AIProvider, Int, String)
        case stream(AIProvider, String)
        case unsupported
        var errorDescription: String? {
            switch self {
            case .status(let provider, let code, let message):
                if code == 429 { return "\(provider.title)'s limit was reached. Try again later." }
                return "\(provider.title) said \(code)\(message.isEmpty ? "" : ": \(message)")"
            case .stream(let provider, let message): return "\(provider.title): \(message)"
            case .unsupported: return "This model cannot read one of the attached files. Choose a compatible model."
            }
        }
    }

    static func request(_ input: AIInput, provider: AIProvider, model: AIModel, key: String) throws -> URLRequest {
        guard model.accepts(input.files) else { throw Failure.unsupported }
        let endpoint: String
        switch provider {
        case .gemini:
            let id = model.id.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed.subtracting(CharacterSet(charactersIn: "/?#"))) ?? model.id
            endpoint = "https://generativelanguage.googleapis.com/v1beta/models/\(id):streamGenerateContent?alt=sse"
        case .groq: endpoint = "https://api.groq.com/openai/v1/chat/completions"
        case .openai: endpoint = "https://api.openai.com/v1/responses"
        case .anthropic: endpoint = "https://api.anthropic.com/v1/messages"
        }
        var request = URLRequest(url: URL(string: endpoint)!)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if provider == .gemini { request.setValue(key, forHTTPHeaderField: "x-goog-api-key") }
        else { request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization") }
        if provider == .anthropic { request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version") }

        let last = input.turns.count - 1
        let messages: [[String: Any]] = input.turns.enumerated().map { n, turn in
            let role = turn.mine ? "user" : "assistant"
            if n != last { return ["role": role, "content": turn.text] }
            return ["role": role, "content": content(turn.text, files: input.files, provider: provider)]
        }
        let body: [String: Any]
        switch provider {
        case .gemini:
            body = ["systemInstruction": ["parts": [["text": input.system]]],
                    "contents": input.turns.enumerated().map { n, turn in
                        var parts: [[String: Any]] = [["text": turn.text]]
                        if n == last { parts += input.files.map { ["inlineData": ["mimeType": $0.mime, "data": $0.data.base64EncodedString()]] } }
                        return ["role": turn.mine ? "user" : "model", "parts": parts]
                    }]
        case .groq:
            body = ["model": model.id, "stream": true, "max_completion_tokens": 4096,
                    "messages": [["role": "system", "content": input.system]] + messages]
        case .openai:
            body = ["model": model.id, "instructions": input.system, "stream": true, "store": false,
                    "max_output_tokens": 4096, "input": messages]
        case .anthropic:
            body = ["model": model.id, "system": input.system, "stream": true,
                    "max_tokens": 4096, "messages": messages]
        }
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        return request
    }

    private static func content(_ text: String, files: [Attachment], provider: AIProvider) -> [[String: Any]] {
        var parts: [[String: Any]] = [["type": provider == .openai ? "input_text" : "text", "text": text]]
        for file in files {
            if file.mime == "text/plain" || file.mime == "text/csv" {
                let body = String(data: file.data, encoding: .utf8) ?? ""
                parts.append(["type": provider == .openai ? "input_text" : "text",
                              "text": "<file name=\"\(file.name)\">\n\(body)\n</file>"])
            } else if provider == .openai {
                let data = "data:\(file.mime);base64,\(file.data.base64EncodedString())"
                if file.mime == "application/pdf" { parts.append(["type": "input_file", "filename": file.name, "file_data": data]) }
                else { parts.append(["type": "input_image", "image_url": data]) }
            } else if provider == .anthropic {
                let source = ["type": "base64", "media_type": file.mime, "data": file.data.base64EncodedString()]
                parts.append(["type": file.mime == "application/pdf" ? "document" : "image", "source": source])
            } else if provider == .groq {
                parts.append(["type": "image_url", "image_url": ["url": "data:\(file.mime);base64,\(file.data.base64EncodedString())"]])
            }
        }
        return parts
    }

    static func text(_ line: String, provider: AIProvider) -> String? {
        guard line.hasPrefix("data:"),
              let data = line.dropFirst(5).trimmingCharacters(in: .whitespaces).data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return nil }
        switch provider {
        case .gemini:
            guard let candidates = json["candidates"] as? [[String: Any]],
                  let parts = (candidates.first?["content"] as? [String: Any])?["parts"] as? [[String: Any]]
            else { return nil }
            let text = parts.compactMap { $0["text"] as? String }.joined()
            return text.isEmpty ? nil : text
        case .groq:
            return ((json["choices"] as? [[String: Any]])?.first?["delta"] as? [String: Any])?["content"] as? String
        case .openai:
            return json["type"] as? String == "response.output_text.delta" ? json["delta"] as? String : nil
        case .anthropic:
            guard json["type"] as? String == "content_block_delta" else { return nil }
            return (json["delta"] as? [String: Any])?["text"] as? String
        }
    }

    static func streamError(_ line: String) -> String? {
        guard line.hasPrefix("data:"),
              let data = line.dropFirst(5).trimmingCharacters(in: .whitespaces).data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return nil }
        let type = json["type"] as? String
        guard type == "error" || type == "response.failed" else { return nil }
        let source = type == "response.failed" ? (json["response"] as? [String: Any])?["error"] : json["error"]
        return (source as? [String: Any])?["message"] as? String ?? "The response failed."
    }

    static func stream(_ input: AIInput, provider: AIProvider, model: AIModel, key: String) -> AsyncThrowingStream<String, Error> {
        AsyncThrowingStream { out in
            let job = Task {
                do {
                    let request = try request(input, provider: provider, model: model, key: key)
                    let (bytes, response) = try await URLSession.shared.bytes(for: request)
                    let code = (response as? HTTPURLResponse)?.statusCode ?? 0
                    guard code == 200 else {
                        var body = ""
                        for try await line in bytes.lines { body += line; if body.count > 4096 { break } }
                        let message = (try? JSONSerialization.jsonObject(with: Data(body.utf8)) as? [String: Any])
                            .flatMap { ($0["error"] as? [String: Any])?["message"] as? String } ?? ""
                        throw Failure.status(provider, code, message)
                    }
                    for try await line in bytes.lines {
                        try Task.checkCancellation()
                        if let message = streamError(line) { throw Failure.stream(provider, message) }
                        if let piece = text(line, provider: provider) { out.yield(piece) }
                    }
                    out.finish()
                } catch { out.finish(throwing: error) }
            }
            out.onTermination = { _ in job.cancel() }
        }
    }
}
