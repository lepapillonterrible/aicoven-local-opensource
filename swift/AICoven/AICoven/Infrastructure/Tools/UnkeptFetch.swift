import Foundation

/// Fetching what is not to be kept by the way: with a session that keeps
/// nothing of what it fetches, following no redirect, and taking no more
/// than a given number of bytes.
nonisolated enum UnkeptFetch {
    /// A session that keeps nothing of what it fetches (no cache on disk
    /// or in memory, no cookies), so that what is fetched does not
    /// outlive its use on the device.
    static let session: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.urlCache = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        configuration.httpCookieStorage = nil
        configuration.httpShouldSetCookies = false
        configuration.urlCredentialStorage = nil
        return URLSession(configuration: configuration)
    }()

    /// Why something was not fetched.
    enum Failure: Error, Equatable {
        /// Its server did not give it: an answer that is not a success
        /// (a redirect among them), or nothing in it.
        case unavailable
        /// It is larger than was asked for.
        case tooLarge
    }

    /// What is at `url`, asked with `headers`: no cookie is sent or kept,
    /// a redirect is not followed, and no more than `most` bytes are
    /// taken.
    @concurrent
    static func data(from url: URL, headers: [String: String] = [:], atMost most: Int, session: URLSession = session) async throws -> Data {
        var request = URLRequest(url: url)
        request.timeoutInterval = 30
        request.httpShouldHandleCookies = false
        request.cachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        for (field, value) in headers {
            request.setValue(value, forHTTPHeaderField: field)
        }
        let (bytes, response) = try await session.bytes(for: request, delegate: NoRedirects())
        guard let http = response as? HTTPURLResponse, (200 ..< 300).contains(http.statusCode) else { throw Failure.unavailable }
        guard response.expectedContentLength <= Int64(most) else { throw Failure.tooLarge }
        var data = Data()
        if response.expectedContentLength > 0 { data.reserveCapacity(Int(response.expectedContentLength)) }
        for try await byte in bytes {
            data.append(byte)
            if data.count > most { throw Failure.tooLarge }
        }
        guard !data.isEmpty else { throw Failure.unavailable }
        return data
    }

    /// Follows no redirect: what is fetched is at the address given, or
    /// it is not fetched.
    private final class NoRedirects: NSObject, URLSessionTaskDelegate {
        func urlSession(
            _ session: URLSession,
            task: URLSessionTask,
            willPerformHTTPRedirection response: HTTPURLResponse,
            newRequest request: URLRequest,
            completionHandler: @escaping (URLRequest?) -> Void
        ) {
            completionHandler(nil)
        }
    }
}
