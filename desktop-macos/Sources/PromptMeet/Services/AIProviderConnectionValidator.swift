import Foundation

struct AIProviderValidationResult: Equatable, Sendable {
    let isValid: Bool
    let message: String
}

private struct AIProviderValidationRequest {
    let providerName: String
    let modelID: String
    var request: URLRequest
}

struct AIProviderConnectionValidator: Sendable {
    private let session: URLSession

    init(session: URLSession = .shared) {
        self.session = session
    }

    func validate(
        workflow: AIWorkflow = .conversation,
        providerID: String,
        modelID: String,
        baseURL: String? = nil,
        secret: String
    ) async -> AIProviderValidationResult {
        let trimmedSecret = secret.trimmingCharacters(in: .whitespacesAndNewlines)
        do {
            guard !trimmedSecret.isEmpty else {
                throw AIProviderConfigurationError.emptySecret
            }
            var validation = try validationRequest(
                providerID: providerID,
                modelID: modelID,
                baseURL: baseURL
            )
            validation.request.setValue(
                "Bearer \(trimmedSecret)",
                forHTTPHeaderField: "Authorization"
            )
            let (data, response) = try await session.data(for: validation.request)
            guard let response = response as? HTTPURLResponse else {
                return AIProviderValidationResult(isValid: false, message: "提供方返回无效响应")
            }
            return Self.result(
                workflow: workflow,
                validation: validation,
                data: data,
                response: response,
                secret: trimmedSecret
            )
        } catch {
            let providerName = providerID == "openai" ? "OpenAI 兼容" : "DeepSeek"
            return AIProviderValidationResult(
                isValid: false,
                message: "\(workflow.displayName) · \(providerName) · \(modelID)："
                    + Self.redact(error.localizedDescription, secret: trimmedSecret)
            )
        }
    }

    private func validationRequest(
        providerID: String,
        modelID: String,
        baseURL: String?
    ) throws -> AIProviderValidationRequest {
        let providerName: String
        let normalizedModelID: String
        let url: URL
        if providerID == "openai" {
            let configuration = try OpenAICompatibleConfiguration(
                baseURL: baseURL ?? OpenAICompatibleConfiguration.defaultBaseURL,
                modelID: modelID
            )
            providerName = "OpenAI 兼容"
            normalizedModelID = configuration.modelID
            url = configuration.chatCompletionsURL
        } else if providerID == "deepseek" {
            let configuration = try DeepSeekConfiguration(
                baseURL: baseURL ?? DeepSeekConfiguration.defaultBaseURL,
                modelID: modelID
            )
            providerName = "DeepSeek"
            normalizedModelID = configuration.modelID
            url = configuration.chatCompletionsURL
        } else {
            throw AIProviderConfigurationError.unsupportedProvider(providerID)
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: [
            "model": normalizedModelID,
            "messages": [["role": "user", "content": "Reply with OK."]],
            "stream": false
        ])
        request.timeoutInterval = 20
        return AIProviderValidationRequest(
            providerName: providerName,
            modelID: normalizedModelID,
            request: request
        )
    }

    private static func result(
        workflow: AIWorkflow,
        validation: AIProviderValidationRequest,
        data: Data,
        response: HTTPURLResponse,
        secret: String
    ) -> AIProviderValidationResult {
        let prefix = "\(workflow.displayName) · \(validation.providerName) · \(validation.modelID)"
        guard !(200..<300).contains(response.statusCode) else {
            return AIProviderValidationResult(isValid: true, message: "\(prefix) 连接成功")
        }
        let providerMessage = providerMessage(from: data, secret: secret)
        let suffix = providerMessage.map { "：\($0)" } ?? ""
        return AIProviderValidationResult(
            isValid: false,
            message: "\(prefix) 连接失败，提供方返回 \(response.statusCode)\(suffix)"
        )
    }

    private static func providerMessage(from data: Data, secret: String) -> String? {
        guard let json = try? JSONSerialization.jsonObject(with: data) else { return nil }
        let message: String?
        if let object = json as? [String: Any] {
            if let error = object["error"] as? [String: Any] {
                message = error["message"] as? String
            } else if let error = object["error"] as? String {
                message = error
            } else {
                message = (object["message"] as? String) ?? (object["detail"] as? String)
            }
        } else {
            message = nil
        }
        guard let message else { return nil }
        let compact = message
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .prefix(500)
        guard !compact.isEmpty else { return nil }
        return redact(String(compact), secret: secret)
    }

    private static func redact(_ text: String, secret: String) -> String {
        guard !secret.isEmpty else { return text }
        return text.replacingOccurrences(of: secret, with: "••••••••")
    }
}
