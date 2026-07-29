import Foundation

@testable import PromptMeet

final class AIProviderValidationURLProtocol: URLProtocol, @unchecked Sendable {
    nonisolated(unsafe) static var handler: ((URLRequest) throws -> (HTTPURLResponse, Data))?
    nonisolated(unsafe) static var lastRequest: URLRequest?
    nonisolated(unsafe) static var lastBodyData: Data?

    override static func canInit(with request: URLRequest) -> Bool { true }
    override static func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        Self.lastRequest = request
        Self.lastBodyData = request.httpBody ?? Self.readBodyStream(request.httpBodyStream)
        guard let handler = Self.handler else { return }
        do {
            let (response, data) = try handler(request)
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        } catch {
            client?.urlProtocol(self, didFailWithError: error)
        }
    }

    override func stopLoading() {}

    private static func readBodyStream(_ stream: InputStream?) -> Data? {
        guard let stream else { return nil }
        stream.open()
        defer { stream.close() }
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 4096)
        while stream.hasBytesAvailable {
            let count = stream.read(&buffer, maxLength: buffer.count)
            guard count > 0 else { break }
            data.append(buffer, count: count)
        }
        return data
    }
}

final class KeychainSpy: KeychainStoring {
    var containsResult = false
    var failOnRead = false
    var readCount = 0
    var containsCount = 0
    var writtenValues: [String] = []
    var deletedAccounts: [String] = []
    var readResult: String?

    func read(service: String, account: String) throws -> String? {
        readCount += 1
        if failOnRead { throw BackendClientError.serviceMessage("read must not be called") }
        return readResult
    }

    func contains(service: String, account: String) throws -> Bool {
        containsCount += 1
        return containsResult
    }

    func write(_ value: String, service: String, account: String) throws {
        writtenValues.append(value)
        readResult = value
        containsResult = true
    }

    func delete(service: String, account: String) throws {
        deletedAccounts.append(account)
        readResult = nil
        containsResult = false
    }
}
