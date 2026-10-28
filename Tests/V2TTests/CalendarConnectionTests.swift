import Foundation
import Testing
@testable import V2T

@MainActor
struct CalendarConnectionTests {
    @Test func connectionNeedsExplicitConsentAndPreservesSelection() async throws {
        let name = "V2TCalendar.\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        let source = MockCalendarSource()
        let connection = CalendarConnection(defaults: defaults, source: source)
        #expect(!connection.isConnected && source.requests == 0 && source.reads == 0)
        await connection.connect()
        #expect(source.requests == 1 && connection.isConnected)
        #expect(connection.selectedCalendarIDs == ["google", "personal"])
        connection.selectedCalendarIDs = ["google"]
        let now = Date()
        _ = try await connection.meetings(from: now, to: now.addingTimeInterval(60))
        #expect(source.selected == ["google"])
        connection.selectedCalendarIDs = []
        let before = source.reads
        #expect(try await connection.meetings(from: now, to: now.addingTimeInterval(60)).isEmpty)
        #expect(source.reads == before)
        connection.disconnect()
        await connection.connect()
        #expect(connection.selectedCalendarIDs.isEmpty)
    }
    @Test func deniedOrRevokedCalendarPermissionNeverReadsEvents() async throws {
        let name = "V2TCalendar.\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        let source = MockCalendarSource()
        source.grant = false
        let connection = CalendarConnection(defaults: defaults, source: source)
        await connection.connect()
        #expect(!connection.isConnected && connection.lastError != nil && source.reads == 0)
        source.grant = true
        await connection.connect()
        source.hasReadAccess = false
        await #expect(throws: CalendarAccessError.unavailable) { try await connection.meetings(from: Date(), to: Date().addingTimeInterval(60)) }
        #expect(!connection.isConnected && source.reads == 0)
    }
}

@MainActor
private final class MockCalendarSource: CalendarEventSource {
    var hasReadAccess = false
    var grant = true
    var requests = 0
    var reads = 0
    var selected: Set<String> = []
    func requestAccess() async throws -> Bool { requests += 1; hasReadAccess = grant; return grant }
    func calendars() -> [CalendarSummary] { [.init(id: "google", title: "Work", account: "Google"), .init(id: "personal", title: "Home", account: "iCloud")] }
    func meetings(calendarIDs: Set<String>, from start: Date, to end: Date) -> [CalendarMeeting] {
        selected = calendarIDs; reads += 1; return [.init(title: "Team call", start: start, end: end)]
    }
}
