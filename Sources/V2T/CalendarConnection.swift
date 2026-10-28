import EventKit
import Foundation

struct CalendarMeeting: Equatable {
    let title: String
    let start: Date
    let end: Date
}

struct CalendarSummary: Identifiable, Equatable {
    let id: String
    let title: String
    let account: String
}

@MainActor
protocol CalendarEventSource {
    var hasReadAccess: Bool { get }
    func requestAccess() async throws -> Bool
    func calendars() -> [CalendarSummary]
    func meetings(calendarIDs: Set<String>, from start: Date, to end: Date) -> [CalendarMeeting]
}

/// Reads the same synced events as Apple Calendar, including Google accounts.
/// EventKit expands recurring events and applies exceptions and time zones.
/// There are deliberately no event creation, modification, or deletion APIs.
@MainActor
final class SystemCalendarSource: CalendarEventSource {
    private let store = EKEventStore()
    var hasReadAccess: Bool { EKEventStore.authorizationStatus(for: .event) == .fullAccess }
    func requestAccess() async throws -> Bool {
        if hasReadAccess { return true }
        return try await store.requestFullAccessToEvents()
    }
    func calendars() -> [CalendarSummary] {
        guard hasReadAccess else { return [] }
        return store.calendars(for: .event).map {
            CalendarSummary(id: $0.calendarIdentifier, title: $0.title, account: $0.source.title)
        }.sorted { ($0.account, $0.title) < ($1.account, $1.title) }
    }
    func meetings(calendarIDs: Set<String>, from start: Date, to end: Date) -> [CalendarMeeting] {
        guard hasReadAccess, end > start, !calendarIDs.isEmpty else { return [] }
        let selected = store.calendars(for: .event).filter { calendarIDs.contains($0.calendarIdentifier) }
        guard !selected.isEmpty else { return [] } // Never pass nil and broaden to every calendar.
        let predicate = store.predicateForEvents(withStart: start, end: end, calendars: selected)
        return store.events(matching: predicate).compactMap { event in
            guard !event.isAllDay, event.status != .canceled,
                  !(event.attendees ?? []).contains(where: { $0.isCurrentUser && $0.participantStatus == .declined }),
                  let title = event.title?.trimmingCharacters(in: .whitespacesAndNewlines), !title.isEmpty,
                  let a = event.startDate, let b = event.endDate, b > a,
                  a < end, b > start else { return nil }
            return CalendarMeeting(title: title, start: a, end: b)
        }
    }
}

@MainActor
final class CalendarConnection: ObservableObject {
    @Published private(set) var isConnected = false
    @Published private(set) var isConnecting = false
    @Published private(set) var calendars: [CalendarSummary] = []
    @Published var lastError: String?
    @Published var selectedCalendarIDs: Set<String> {
        didSet { defaults.set(Array(selectedCalendarIDs), forKey: "systemCalendarIDs") }
    }
    private let defaults: UserDefaults
    private let source: CalendarEventSource
    private var generation = UUID()

    init(defaults: UserDefaults = .standard, source: CalendarEventSource? = nil) {
        self.defaults = defaults
        self.source = source ?? SystemCalendarSource()
        selectedCalendarIDs = Set(defaults.stringArray(forKey: "systemCalendarIDs") ?? [])
        isConnected = defaults.bool(forKey: "systemCalendarEnabled") && self.source.hasReadAccess
        if isConnected { refreshCalendars() }
    }

    func connect() async {
        guard !isConnecting else { return }
        isConnecting = true
        lastError = nil
        let token = UUID()
        generation = token
        defer { if generation == token { isConnecting = false } }
        do {
            let granted = try await source.requestAccess()
            guard generation == token else { return }
            guard granted, source.hasReadAccess else {
                lastError = "Allow Calendar access for V2T in System Settings → Privacy & Security → Calendars. Your work administrator may restrict this permission."
                return
            }
            defaults.set(true, forKey: "systemCalendarEnabled")
            isConnected = true
            refreshCalendars()
        } catch {
            if generation == token { lastError = "Couldn't access calendars. Check V2T's Calendar permission in System Settings." }
        }
    }

    func disconnect() {
        generation = UUID()
        defaults.set(false, forKey: "systemCalendarEnabled")
        isConnecting = false
        isConnected = false
        calendars = []
        lastError = nil
    }

    func refreshCalendars() {
        guard defaults.bool(forKey: "systemCalendarEnabled") else { return }
        guard source.hasReadAccess else {
            isConnected = false; calendars = []
            lastError = "Calendar access is unavailable. Allow V2T in System Settings → Privacy & Security → Calendars."
            return
        }
        isConnected = true
        calendars = source.calendars()
        // Offer every synced calendar initially; preserve an explicit empty
        // selection, including after disconnect/reconnect.
        if defaults.object(forKey: "systemCalendarIDs") == nil {
            selectedCalendarIDs = Set(calendars.map(\.id))
        }
        lastError = calendars.isEmpty ? "No calendars are synced yet. Add your Google account in Apple Calendar → Add Account, then refresh here." : nil
    }

    func meetings(from start: Date, to end: Date) async throws -> [CalendarMeeting] {
        guard isConnected else { return [] }
        guard source.hasReadAccess else {
            refreshCalendars()
            throw CalendarAccessError.unavailable
        }
        guard !selectedCalendarIDs.isEmpty, end > start else { return [] }
        return source.meetings(calendarIDs: selectedCalendarIDs, from: start, to: end)
    }
}

enum CalendarAccessError: Error { case unavailable }
