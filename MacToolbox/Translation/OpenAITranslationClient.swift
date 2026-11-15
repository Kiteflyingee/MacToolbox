import Foundation

public struct TranslationResponse: Equatable, Sendable {
    public enum Completion: Sendable { case complete, truncated, unknown }
    public let text: String
    public let completion: Completion

    public init(text: String, completion: Completion) { self.text = text; self.completion = completion }

    public static func decode(_ data: Data, response: HTTPURLResponse, now: Date = Date()) throws -> TranslationResponse {
        guard data.count <= AppLimits.translationResponseBytes else { throw TranslationError.responseTooLarge }
        guard (200...299).contains(response.statusCode) else {
            throw TranslationError.http(status: response.statusCode,
                retryAfterSeconds: retryAfter(response.value(forHTTPHeaderField: "Retry-After"), now: now))
        }
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let choices = object["choices"] as? [[String: Any]], let choice = choices.first,
              let message = choice["message"] as? [String: Any] else { throw TranslationError.invalidResponse }
        if let refusal = message["refusal"] as? String, !refusal.isEmpty { throw TranslationError.refused }
        if let calls = message["tool_calls"] as? [Any], !calls.isEmpty { throw TranslationError.invalidResponse }
        if message["function_call"] != nil && !(message["function_call"] is NSNull) { throw TranslationError.invalidResponse }
        let finish = choice["finish_reason"] as? String
        if finish == "content_filter" { throw TranslationError.refused }
        if finish == "tool_calls" || finish == "function_call" { throw TranslationError.invalidResponse }
        let text: String
        if let content = message["content"] as? String { text = content }
        else if let parts = message["content"] as? [[String: Any]] {
            text = parts.compactMap { part in part["type"] as? String == "text" ? part["text"] as? String : nil }.joined()
        } else { throw TranslationError.invalidResponse }
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw TranslationError.invalidResponse }
        return TranslationResponse(text: text, completion: finish == "length" ? .truncated : finish == "stop" ? .complete : .unknown)
    }

    private static func retryAfter(_ value: String?, now: Date) -> Int? {
        guard let value else { return nil }
        if let seconds = Int(value), (0...86_400).contains(seconds) { return seconds }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss zzz"
        guard let date = formatter.date(from: value) else { return nil }
        let interval = date.timeIntervalSince(now)
        guard interval.isFinite, interval >= 0, interval <= 86_400 else { return nil }
        return Int(ceil(interval))
    }
}

// Stateless and immutable; no unchecked Sendable or mutable delegate state.
final class RejectRedirects: NSObject, URLSessionTaskDelegate, Sendable {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping @Sendable (URLRequest?) -> Void) {
        completionHandler(nil)
    }
}

public actor OpenAITranslationClient {
    private let configuration: URLSessionConfiguration
    private let watchdog: Duration

    public init(configuration: URLSessionConfiguration = .ephemeral, watchdog: Duration = .seconds(65)) {
        let configuration = configuration.copy() as! URLSessionConfiguration
        configuration.urlCache = nil
        configuration.httpCookieStorage = nil
        configuration.httpShouldSetCookies = false
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.timeoutIntervalForRequest = 30
        configuration.timeoutIntervalForResource = 60
        self.configuration = configuration
        self.watchdog = watchdog
    }

    public func translate(endpoint: ChatEndpoint, model: String, key: SecretKey?, text: String,
                          target: TargetLanguage) async throws -> TranslationResponse {
        try Task.checkCancellation()
        let request = try ChatRequestBuilder.make(endpoint: endpoint, model: model, key: key, text: text, target: target)
        let session = URLSession(configuration: configuration, delegate: RejectRedirects(), delegateQueue: nil)
        // Invalidate only after all children have finished. Invalidating during
        // bytes(for:) task creation can raise an Objective-C exception.
        defer { session.invalidateAndCancel() }
        do {
            return try await withThrowingTaskGroup(of: TranslationResponse.self) { group in
                group.addTask { try await Self.perform(request, in: session) }
                let watchdog = self.watchdog
                group.addTask {
                    try await Task.sleep(for: watchdog)
                    throw TranslationError.timedOut
                }
                defer { group.cancelAll() }
                guard let result = try await group.next() else { throw CancellationError() }
                return result
            }
        } catch is CancellationError { throw CancellationError() }
        catch let error as TranslationError { throw error }
        catch let error as URLError {
            if Task.isCancelled { throw CancellationError() }
            throw error.code == .timedOut ? TranslationError.timedOut : TranslationError.transport
        } catch { throw TranslationError.transport }
    }

    private static func perform(_ request: URLRequest, in session: URLSession) async throws -> TranslationResponse {
        try Task.checkCancellation()
        // Foundation handles cancellation while awaiting response headers.
        let (bytes, response) = try await session.bytes(for: request)
        let task = bytes.task
        defer { task.cancel() }
        return try await withTaskCancellationHandler {
            try Task.checkCancellation()
            guard let response = response as? HTTPURLResponse else { throw TranslationError.invalidResponse }
            guard response.expectedContentLength <= Int64(AppLimits.translationResponseBytes) else { throw TranslationError.responseTooLarge }
            var data = Data()
            data.reserveCapacity(min(AppLimits.translationResponseBytes, max(0, Int(response.expectedContentLength))))
            for try await byte in bytes {
                if data.count % 4_096 == 0 { try Task.checkCancellation() }
                guard data.count < AppLimits.translationResponseBytes else { throw TranslationError.responseTooLarge }
                data.append(byte)
            }
            try Task.checkCancellation()
            return try TranslationResponse.decode(data, response: response)
        } onCancel: {
            task.cancel() // The task already exists; the session remains valid.
        }
    }
}
