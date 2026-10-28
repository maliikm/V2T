import AppKit
import CryptoKit
import Foundation
import Network
import Security

struct GoogleAuthorizationResult {
    let code: String
    let verifier: String
    let redirectURI: String
}

/// Desktop OAuth with PKCE and an ephemeral listener bound only to loopback.
@MainActor
final class GoogleLoopbackAuthorization {
    private var listener: NWListener?
    private var continuation: CheckedContinuation<GoogleAuthorizationResult, Error>?
    private var timeout: Task<Void, Never>?
    private var state = ""
    private var verifier = ""
    private var redirectURI = ""

    func authorize(clientID: String, scopes: [String]) async throws -> GoogleAuthorizationResult {
        state = try Self.randomString()
        verifier = try Self.randomString()
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: .any)
        let listener = try NWListener(using: parameters)
        self.listener = listener
        return try await withCheckedThrowingContinuation { continuation in
            self.continuation = continuation
            listener.stateUpdateHandler = { [weak self] status in
                Task { @MainActor in
                    guard let self, self.continuation != nil else { return }
                    switch status {
                    case .ready:
                        guard let port = listener.port else {
                            self.finish(.failure(CalendarConnectionError.message("Couldn't start Google sign-in.")))
                            return
                        }
                        self.redirectURI = "http://127.0.0.1:\(port.rawValue)/oauth/callback"
                        var url = URLComponents(string: "https://accounts.google.com/o/oauth2/v2/auth")!
                        url.queryItems = [
                            .init(name: "client_id", value: clientID),
                            .init(name: "redirect_uri", value: self.redirectURI),
                            .init(name: "response_type", value: "code"),
                            .init(name: "scope", value: scopes.joined(separator: " ")),
                            .init(name: "state", value: self.state),
                            .init(name: "code_challenge", value: Self.challenge(for: self.verifier)),
                            .init(name: "code_challenge_method", value: "S256"),
                            .init(name: "access_type", value: "offline"),
                            .init(name: "prompt", value: "consent"),
                        ]
                        if !NSWorkspace.shared.open(url.url!) {
                            self.finish(.failure(CalendarConnectionError.message("Couldn't open the browser for Google sign-in.")))
                        }
                    case .failed:
                        self.finish(.failure(CalendarConnectionError.message("Couldn't listen for Google sign-in. Try connecting again.")))
                    default: break
                    }
                }
            }
            listener.newConnectionHandler = { [weak self] connection in
                Task { @MainActor in self?.receive(connection) }
            }
            listener.start(queue: .main)
            timeout = Task { [weak self] in
                try? await Task.sleep(nanoseconds: 180_000_000_000)
                guard !Task.isCancelled else { return }
                self?.finish(.failure(CalendarConnectionError.message("Google sign-in timed out. Try connecting again.")))
            }
        }
    }

    func cancel() { finish(.failure(CancellationError())) }

    private func receive(_ connection: NWConnection) {
        connection.start(queue: .main)
        // Bound each incomplete HTTP request as well as the overall sign-in.
        DispatchQueue.main.asyncAfter(deadline: .now() + 5) { connection.cancel() }
        read(connection, accumulated: Data())
    }

    private func read(_ connection: NWConnection, accumulated: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 16_384) { [weak self] data, _, complete, error in
            Task { @MainActor in
                guard let self, self.continuation != nil, error == nil else { connection.cancel(); return }
                var bytes = accumulated
                if let data { bytes.append(data) }
                guard bytes.count <= 16_384 else { connection.cancel(); return }
                guard let header = String(data: bytes, encoding: .utf8), header.contains("\r\n\r\n") else {
                    if complete { connection.cancel() } else { self.read(connection, accumulated: bytes) }
                    return
                }
                let requestLine = header.components(separatedBy: "\r\n")[0].split(separator: " ")
                guard requestLine.count == 3, requestLine[0] == "GET",
                      let result = Self.parseCallback(path: String(requestLine[1]), expectedState: self.state) else {
                    self.respond(connection, status: "400 Bad Request", text: "Invalid sign-in response.")
                    return
                }
                self.respond(connection, status: "200 OK", text: "You can close this tab and return to V2T.")
                switch result {
                case .success(let code):
                    self.finish(.success(.init(code: code, verifier: self.verifier, redirectURI: self.redirectURI)))
                case .failure(let error): self.finish(.failure(error))
                }
            }
        }
    }

    /// Invalid or duplicate state/code parameters must never complete sign-in.
    static func parseCallback(path: String, expectedState: String) -> Result<String, Error>? {
        guard let url = URLComponents(string: path), url.scheme == nil, url.host == nil,
              url.path == "/oauth/callback", let items = url.queryItems else { return nil }
        let states = items.filter { $0.name == "state" }
        guard states.count == 1, states[0].value == expectedState else { return nil }
        if items.contains(where: { $0.name == "error" }) {
            return .failure(CalendarConnectionError.message("Google sign-in was cancelled or access was denied."))
        }
        let codes = items.filter { $0.name == "code" }
        guard codes.count == 1, let code = codes[0].value, !code.isEmpty else { return nil }
        return .success(code)
    }

    private func respond(_ connection: NWConnection, status: String, text: String) {
        let body = Data(text.utf8)
        let header = "HTTP/1.1 \(status)\r\nContent-Type: text/plain; charset=utf-8\r\nContent-Length: \(body.count)\r\nCache-Control: no-store\r\nConnection: close\r\n\r\n"
        connection.send(content: Data(header.utf8) + body, completion: .contentProcessed { _ in connection.cancel() })
    }

    private func finish(_ result: Result<GoogleAuthorizationResult, Error>) {
        guard let continuation else { return }
        self.continuation = nil
        timeout?.cancel()
        timeout = nil
        listener?.cancel()
        listener = nil
        continuation.resume(with: result)
    }

    static func challenge(for verifier: String) -> String {
        base64URL(Data(SHA256.hash(data: Data(verifier.utf8))))
    }
    private static func randomString() throws -> String {
        var bytes = [UInt8](repeating: 0, count: 32)
        guard SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) == errSecSuccess else {
            throw CalendarConnectionError.message("Couldn't generate a secure sign-in request.")
        }
        return base64URL(Data(bytes))
    }
    private static func base64URL(_ data: Data) -> String {
        data.base64EncodedString().replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
    }
}
