import AppKit
import CryptoKit
import Foundation
import Network
import Security

struct CalendarMeeting: Equatable {
    let title: String
    let start: Date
    let end: Date
}

struct GoogleCalendarSummary: Decodable, Identifiable {
    let id: String
    let summary: String
    let primary: Bool?
}

struct GoogleDesktopClient: Codable {
    let client_id: String
    let client_secret: String?
}

private struct GoogleTokens: Codable {
    var accessToken: String
    var refreshToken: String
    var expiresAt: Date
}

private struct GoogleTokenResponse: Decodable {
    let access_token: String
    let refresh_token: String?
    let expires_in: Double
    let scope: String?
}

/// Only the user's explicit Connect action opens Google consent. Credentials
/// stay in Keychain; calendar titles never go to the cloud transcription API.
@MainActor
final class GoogleCalendarConnection: ObservableObject {
    @Published private(set) var isConnected = false
    @Published private(set) var isConnecting = false
    @Published private(set) var hasClient = false
    @Published private(set) var calendars: [GoogleCalendarSummary] = []
    @Published var lastError: String?
    @Published var selectedCalendarIDs: Set<String> {
        didSet { defaults.set(Array(selectedCalendarIDs), forKey: "googleCalendarIDs") }
    }
    private let defaults: UserDefaults
    private let saveSecret: (Data, String) throws -> Void
    private let deleteSecret: (String) throws -> Void
    private let sendRequest: (URLRequest) async throws -> (Data, URLResponse)
    private var client: GoogleDesktopClient?
    private var tokens: GoogleTokens?
    private var authorization: GoogleLoopbackAuthorization?
    private var connectionTask: Task<Void, Never>?
    private var refreshTask: Task<GoogleTokens, Error>?
    private var connectionGeneration = UUID()
    private static let scopes = [
        "https://www.googleapis.com/auth/calendar.events.readonly",
        "https://www.googleapis.com/auth/calendar.calendarlist.readonly",
    ]

    init(defaults: UserDefaults = .standard,
         loadSecret: (String) -> Data? = SecureStore.load,
         saveSecret: @escaping (Data, String) throws -> Void = { try SecureStore.save($0, account: $1) },
         deleteSecret: @escaping (String) throws -> Void = SecureStore.delete,
         sendRequest: @escaping (URLRequest) async throws -> (Data, URLResponse) = { try await URLSession.shared.data(for: $0) }) {
        self.defaults = defaults
        self.saveSecret = saveSecret
        self.deleteSecret = deleteSecret
        self.sendRequest = sendRequest
        selectedCalendarIDs = Set(defaults.stringArray(forKey: "googleCalendarIDs") ?? ["primary"])
        client = loadSecret("google-client").flatMap { try? JSONDecoder().decode(GoogleDesktopClient.self, from: $0) }
        tokens = loadSecret("google-tokens").flatMap { try? JSONDecoder().decode(GoogleTokens.self, from: $0) }
        hasClient = client != nil
        isConnected = client != nil && tokens != nil
    }

    func importClient(from url: URL) {
        guard !isConnecting else { return }
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        do {
            struct File: Decodable { let installed: GoogleDesktopClient }
            let parsed = try JSONDecoder().decode(File.self, from: Data(contentsOf: url)).installed
            guard parsed.client_id.hasSuffix(".apps.googleusercontent.com") else {
                throw CalendarConnectionError.message("Import a Google Desktop app OAuth client JSON file.")
            }
            // A different OAuth client cannot refresh the old client's tokens.
            if client?.client_id != parsed.client_id { disconnect() }
            try saveSecret(JSONEncoder().encode(parsed), "google-client")
            client = parsed
            hasClient = true
            lastError = nil
        } catch { lastError = "Couldn't import the Desktop OAuth client: \(error.localizedDescription)" }
    }

    func connect() {
        guard let client, !isConnecting else { return }
        isConnecting = true
        lastError = nil
        let generation = UUID()
        connectionGeneration = generation
        connectionTask = Task {
            defer {
                if connectionGeneration == generation { isConnecting = false; authorization = nil }
            }
            do {
                let flow = GoogleLoopbackAuthorization()
                authorization = flow
                let result = try await flow.authorize(clientID: client.client_id, scopes: Self.scopes)
                var fields = ["client_id": client.client_id, "code": result.code,
                              "code_verifier": result.verifier, "redirect_uri": result.redirectURI,
                              "grant_type": "authorization_code"]
                fields["client_secret"] = client.client_secret
                let response: GoogleTokenResponse = try await postForm(
                    url: URL(string: "https://oauth2.googleapis.com/token")!, fields: fields
                )
                try Task.checkCancellation()
                guard connectionGeneration == generation else { return }
                if let scopes = response.scope,
                   !Set(Self.scopes).isSubset(of: Set(scopes.split(separator: " ").map(String.init))) {
                    throw CalendarConnectionError.message("Google didn't grant both calendar permissions. Connect again and allow calendar and event read access.")
                }
                guard let refresh = response.refresh_token ?? tokens?.refreshToken else {
                    throw CalendarConnectionError.message("Google didn't return offline access. Reconnect and approve calendar access.")
                }
                let saved = GoogleTokens(accessToken: response.access_token, refreshToken: refresh,
                                         expiresAt: Date().addingTimeInterval(response.expires_in))
                try saveTokens(saved)
                isConnected = true
                await refreshCalendars()
            } catch is CancellationError {
                // Cancel/disconnect already updated the UI.
            } catch {
                if connectionGeneration == generation { lastError = error.localizedDescription }
            }
        }
    }

    func cancelConnection() {
        connectionGeneration = UUID()
        connectionTask?.cancel()
        connectionTask = nil
        authorization?.cancel()
        authorization = nil
        isConnecting = false
    }

    func disconnect() {
        cancelConnection()
        refreshTask?.cancel()
        refreshTask = nil
        tokens = nil
        calendars = []
        isConnected = false
        do { try deleteSecret("google-tokens") }
        catch { lastError = "Couldn't remove saved Google credentials: \(error.localizedDescription)" }
    }

    func refreshCalendars() async {
        guard isConnected else { return }
        let generation = connectionGeneration
        do {
            struct Page: Decodable { let items: [GoogleCalendarSummary]?; let nextPageToken: String? }
            var pageToken: String?
            var result: [GoogleCalendarSummary] = []
            repeat {
                var query = [URLQueryItem(name: "minAccessRole", value: "reader"), URLQueryItem(name: "maxResults", value: "250")]
                if let pageToken { query.append(.init(name: "pageToken", value: pageToken)) }
                let page: Page = try await get(path: "users/me/calendarList", query: query)
                result += page.items ?? []
                pageToken = page.nextPageToken
            } while pageToken != nil
            guard connectionGeneration == generation, isConnected else { return }
            calendars = result
            lastError = nil
        } catch { if connectionGeneration == generation { lastError = error.localizedDescription } }
    }

    func meetings(from start: Date, to end: Date) async throws -> [CalendarMeeting] {
        guard isConnected, !selectedCalendarIDs.isEmpty else { return [] }
        struct EventDate: Decodable { let dateTime: String? }
        struct Event: Decodable {
            let summary: String?
            let status: String?
            let start: EventDate?
            let end: EventDate?
            let eventType: String?
            let attendees: [Attendee]?
            struct Attendee: Decodable {
                let isSelf: Bool?
                let responseStatus: String?
                enum CodingKeys: String, CodingKey { case isSelf = "self", responseStatus }
            }
        }
        struct Page: Decodable { let items: [Event]?; let nextPageToken: String? }
        let formatter = ISO8601DateFormatter()
        let fractionalFormatter = ISO8601DateFormatter()
        fractionalFormatter.formatOptions.insert(.withFractionalSeconds)
        let generation = connectionGeneration
        var result: [CalendarMeeting] = []
        for id in selectedCalendarIDs.sorted() {
            let escaped = id.addingPercentEncoding(withAllowedCharacters: .urlPathComponent) ?? "primary"
            var pageToken: String?
            repeat {
                var query: [URLQueryItem] = [
                    .init(name: "timeMin", value: formatter.string(from: start)),
                    .init(name: "timeMax", value: formatter.string(from: end)),
                    .init(name: "singleEvents", value: "true"), .init(name: "orderBy", value: "startTime"),
                    .init(name: "maxResults", value: "250"),
                ]
                if let pageToken { query.append(.init(name: "pageToken", value: pageToken)) }
                let page: Page = try await get(path: "calendars/\(escaped)/events", query: query)
                guard generation == connectionGeneration, isConnected else { throw CancellationError() }
                for event in page.items ?? [] {
                    guard event.status != "cancelled", event.eventType == nil || event.eventType == "default",
                          !(event.attendees ?? []).contains(where: { $0.isSelf == true && $0.responseStatus == "declined" }),
                          let title = event.summary, !title.isEmpty,
                          let a = event.start?.dateTime.flatMap({ formatter.date(from: $0) ?? fractionalFormatter.date(from: $0) }),
                          let b = event.end?.dateTime.flatMap({ formatter.date(from: $0) ?? fractionalFormatter.date(from: $0) }), b > a else { continue }
                    let meeting = CalendarMeeting(title: title, start: a, end: b)
                    if !result.contains(meeting) { result.append(meeting) }
                }
                pageToken = page.nextPageToken
            } while pageToken != nil
        }
        return result
    }

    private func accessToken(forceRefresh: Bool = false) async throws -> String {
        guard let client, let tokens else { throw CalendarConnectionError.message("Connect Google Calendar in Settings.") }
        if !forceRefresh, tokens.expiresAt.timeIntervalSinceNow > 60 { return tokens.accessToken }
        let generation = connectionGeneration
        if let refreshTask {
            let refreshed = try await refreshTask.value
            guard generation == connectionGeneration, isConnected else { throw CancellationError() }
            return refreshed.accessToken
        }
        let task = Task<GoogleTokens, Error> {
            var fields = ["client_id": client.client_id, "refresh_token": tokens.refreshToken, "grant_type": "refresh_token"]
            fields["client_secret"] = client.client_secret
            let response: GoogleTokenResponse = try await postForm(url: URL(string: "https://oauth2.googleapis.com/token")!, fields: fields)
            try Task.checkCancellation()
            return GoogleTokens(accessToken: response.access_token, refreshToken: response.refresh_token ?? tokens.refreshToken,
                                expiresAt: Date().addingTimeInterval(response.expires_in))
        }
        refreshTask = task
        defer { if generation == connectionGeneration { refreshTask = nil } }
        let refreshed = try await task.value
        guard generation == connectionGeneration, isConnected else { throw CancellationError() }
        try saveTokens(refreshed)
        return refreshed.accessToken
    }

    private func saveTokens(_ value: GoogleTokens) throws {
        try saveSecret(JSONEncoder().encode(value), "google-tokens")
        tokens = value
    }

    private func get<T: Decodable>(path: String, query: [URLQueryItem]) async throws -> T {
        var components = URLComponents(string: "https://www.googleapis.com/calendar/v3/\(path)")!
        components.queryItems = query
        let generation = connectionGeneration
        for attempt in 0..<2 {
            try Task.checkCancellation()
            var request = URLRequest(url: components.url!)
            request.timeoutInterval = 30
            request.setValue("Bearer \(try await accessToken(forceRefresh: attempt > 0))", forHTTPHeaderField: "Authorization")
            guard generation == connectionGeneration, isConnected else { throw CancellationError() }
            let (data, response) = try await sendRequest(request)
            let code = (response as? HTTPURLResponse)?.statusCode ?? 0
            if code == 401, attempt == 0 { continue }
            guard (200..<300).contains(code) else {
                throw CalendarConnectionError.message("Google Calendar returned HTTP \(code). Check the Calendar API setup and reconnect in Settings.")
            }
            return try JSONDecoder().decode(T.self, from: data)
        }
        throw CalendarConnectionError.message("Reconnect Google Calendar in Settings.")
    }

    private func postForm<T: Decodable>(url: URL, fields: [String: String]) async throws -> T {
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = 30
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.httpBody = OAuthForm.encode(fields)
        let (data, response) = try await sendRequest(request)
        guard let response = response as? HTTPURLResponse, (200..<300).contains(response.statusCode) else {
            throw CalendarConnectionError.message("Google sign-in expired or was rejected. Check the Desktop OAuth client and reconnect.")
        }
        return try JSONDecoder().decode(T.self, from: data)
    }
}

private extension CharacterSet {
    static let urlPathComponent = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-._~"))
}

enum OAuthForm {
    static func encode(_ fields: [String: String]) -> Data {
        Data(fields.sorted { $0.key < $1.key }.map {
            "\($0.key.addingPercentEncoding(withAllowedCharacters: .urlPathComponent)!)=\($0.value.addingPercentEncoding(withAllowedCharacters: .urlPathComponent)!)"
        }.joined(separator: "&").utf8)
    }
}

enum CalendarConnectionError: LocalizedError {
    case message(String)
    var errorDescription: String? { if case .message(let text) = self { return text }; return nil }
}

/// OAuth material is separate from transcription provider keys and is never logged.
enum SecureStore {
    private static func query(_ account: String) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: "com.wielventures.v2t.google-calendar", kSecAttrAccount as String: account]
    }
    static func load(_ account: String) -> Data? {
        var query = query(account)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess else { return nil }
        return result as? Data
    }
    static func save(_ data: Data, account: String) throws {
        let query = query(account)
        var status = SecItemUpdate(query as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        if status == errSecItemNotFound {
            var add = query
            add[kSecValueData as String] = data
            add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
            status = SecItemAdd(add as CFDictionary, nil)
        }
        guard status == errSecSuccess else { throw NSError(domain: NSOSStatusErrorDomain, code: Int(status)) }
    }
    static func delete(_ account: String) throws {
        let status = SecItemDelete(query(account) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw NSError(domain: NSOSStatusErrorDomain, code: Int(status))
        }
    }
}
