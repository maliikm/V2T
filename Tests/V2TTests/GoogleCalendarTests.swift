import Foundation
import Testing
@testable import V2T

@MainActor
struct GoogleCalendarTests {
    @Test func paginatesSelectedCalendarAndFiltersNonMeetings() async throws {
        let fixture = try CalendarFixture()
        defer { fixture.cleanUp() }
        var requests: [URLRequest] = []
        let connection = fixture.connection { request in
            requests.append(request)
            let query = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)!.queryItems ?? []
            #expect(request.httpMethod == "GET")
            #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer test-access")
            if request.url!.path.contains("calendarList") {
                if query.contains(where: { $0.name == "pageToken" }) {
                    return try CalendarFixture.response(request, ["items": [["id": "team+calendar@example.com", "summary": "Team"]]])
                }
                return try CalendarFixture.response(request, ["items": [["id": "me@example.com", "summary": "Personal", "primary": true]], "nextPageToken": "calendar-page-2"])
            }
            #expect(request.url!.absoluteString.contains("team%2Bcalendar%40example.com"))
            #expect(query.contains(.init(name: "singleEvents", value: "true")))
            #expect(query.contains(.init(name: "timeMin", value: "2026-10-28T16:00:00Z")))
            let meeting: [String: Any] = ["summary": "Budget", "start": ["dateTime": "2026-10-28T16:00:00.000Z"], "end": ["dateTime": "2026-10-28T17:00:00Z"]]
            if query.contains(where: { $0.name == "pageToken" }) {
                return try CalendarFixture.response(request, ["items": [meeting]])
            }
            var cancelled = meeting; cancelled["status"] = "cancelled"
            var declined = meeting; declined["attendees"] = [["self": true, "responseStatus": "declined"]]
            var focus = meeting; focus["eventType"] = "focusTime"
            let allDay: [String: Any] = ["summary": "All day", "start": ["date": "2026-10-28"], "end": ["date": "2026-10-29"]]
            return try CalendarFixture.response(request, ["items": [meeting, cancelled, declined, focus, allDay], "nextPageToken": "events-page-2"])
        }
        await connection.refreshCalendars()
        #expect(connection.calendars.count == 2)
        connection.selectedCalendarIDs = ["team+calendar@example.com"]
        let start = try #require(ISO8601DateFormatter().date(from: "2026-10-28T16:00:00Z"))
        let meetings = try await connection.meetings(from: start, to: start.addingTimeInterval(3600))
        #expect(meetings == [.init(title: "Budget", start: start, end: start.addingTimeInterval(3600))])
        #expect(requests.count == 4)
        #expect(fixture.defaults.stringArray(forKey: "googleCalendarIDs") == ["team+calendar@example.com"])
        connection.selectedCalendarIDs = []
        #expect(try await connection.meetings(from: start, to: start.addingTimeInterval(60)).isEmpty)
        #expect(requests.count == 4)
    }

    @Test func unauthorizedReadRefreshesOnceAndKeepsOfflineToken() async throws {
        let fixture = try CalendarFixture()
        defer { fixture.cleanUp() }
        var reads = 0
        var refreshes = 0
        let connection = fixture.connection { request in
            if request.url!.host == "oauth2.googleapis.com" {
                refreshes += 1
                #expect(request.httpMethod == "POST")
                let body = String(data: request.httpBody!, encoding: .utf8)!
                #expect(body.contains("grant_type=refresh_token"))
                #expect(body.contains("refresh_token=test-refresh"))
                return try CalendarFixture.response(request, ["access_token": "new-access", "expires_in": 3600])
            }
            reads += 1
            if reads == 1 { return try CalendarFixture.response(request, [:], status: 401) }
            #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer new-access")
            return try CalendarFixture.response(request, ["items": [["id": "primary", "summary": "Calendar"]]])
        }
        await connection.refreshCalendars()
        #expect(connection.lastError == nil)
        #expect(reads == 2 && refreshes == 1)
        let tokens = try #require(JSONSerialization.jsonObject(with: fixture.secrets["google-tokens"]!) as? [String: Any])
        #expect(tokens["accessToken"] as? String == "new-access")
        #expect(tokens["refreshToken"] as? String == "test-refresh")
    }

    @Test func disconnectDuringRefreshCannotRestoreCredentialsOrFetchEvents() async throws {
        let fixture = try CalendarFixture(expired: true)
        defer { fixture.cleanUp() }
        var pending: CheckedContinuation<(Data, URLResponse), Error>?
        var requestToFinish: URLRequest?
        var requests = 0
        let connection = fixture.connection { request in
            requests += 1
            requestToFinish = request
            return try await withCheckedThrowingContinuation { pending = $0 }
        }
        let refresh = Task { await connection.refreshCalendars() }
        for _ in 0..<100 where pending == nil { await Task.yield() }
        let continuation = try #require(pending)
        let request = try #require(requestToFinish)
        connection.disconnect()
        continuation.resume(returning: try CalendarFixture.response(request, ["access_token": "late-access", "expires_in": 3600]))
        await refresh.value
        #expect(!connection.isConnected)
        #expect(connection.calendars.isEmpty)
        #expect(fixture.secrets["google-tokens"] == nil)
        #expect(requests == 1)
    }
}

@MainActor
private final class CalendarFixture {
    let name = "V2TCalendarTests.\(UUID().uuidString)"
    let defaults: UserDefaults
    var secrets: [String: Data] = [:]

    init(expired: Bool = false) throws {
        defaults = try #require(UserDefaults(suiteName: name))
        secrets["google-client"] = try JSONSerialization.data(withJSONObject: ["client_id": "test.apps.googleusercontent.com"])
        secrets["google-tokens"] = try JSONSerialization.data(withJSONObject: [
            "accessToken": "test-access", "refreshToken": "test-refresh",
            "expiresAt": Date().addingTimeInterval(expired ? -60 : 3600).timeIntervalSinceReferenceDate,
        ])
    }
    func cleanUp() { defaults.removePersistentDomain(forName: name) }
    func connection(send: @escaping (URLRequest) async throws -> (Data, URLResponse)) -> GoogleCalendarConnection {
        GoogleCalendarConnection(defaults: defaults, loadSecret: { self.secrets[$0] },
            saveSecret: { self.secrets[$1] = $0 }, deleteSecret: { self.secrets[$0] = nil }, sendRequest: send)
    }
    static func response(_ request: URLRequest, _ json: [String: Any], status: Int = 200) throws -> (Data, URLResponse) {
        (try JSONSerialization.data(withJSONObject: json), try #require(HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)))
    }
}
