@testable import AICoven
import XCTest

/// What the Tasks list decides by itself: when a pin ends, how one stands,
/// the order inside each part, the parts, and the words for a due day.
final class TaskRulesTests: XCTestCase {
    private let utc: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0) ?? .gmt
        calendar.firstWeekday = 2
        return calendar
    }()

    private let british = Locale(identifier: "en_GB")

    /// Wednesday 13 January 2027, 10:00 UTC.
    private var wednesday: Date {
        date(2027, 1, 13, 10)
    }

    private func date(_ year: Int, _ month: Int, _ day: Int, _ hour: Int = 0, in calendar: Calendar? = nil) -> Date {
        (calendar ?? utc).date(from: DateComponents(year: year, month: month, day: day, hour: hour)) ?? .distantPast
    }

    private func task(
        _ id: String, status: TaskStatus = .open, due: String? = nil, time: String? = nil, pin: TaskPin? = nil, made: TimeInterval = 0,
        changed: TimeInterval = 0
    ) -> TaskItem {
        TaskItem(
            id: id, covenID: nil, title: id, status: status, stage: .backlog,
            due: due.flatMap(TaskDueDate.init).flatMap { TaskDue(date: $0, time: time) }, pin: pin,
            createdAt: Date(timeIntervalSince1970: made), updatedAt: Date(timeIntervalSince1970: changed)
        )
    }

    // MARK: - Pins

    func testAPinEndsWithThePersonsDay_orTheirWeek() throws {
        XCTAssertEqual(TaskRules.pinEnd(for: .today, now: wednesday, calendar: utc), date(2027, 1, 14))
        XCTAssertEqual(TaskRules.pinEnd(for: .week, now: wednesday, calendar: utc), date(2027, 1, 18), "The week starts on Monday here")

        // A week that starts on Sunday ends a day sooner; on the week's first day it is the whole week.
        var american = utc
        american.firstWeekday = 1
        XCTAssertEqual(TaskRules.pinEnd(for: .week, now: wednesday, calendar: american), date(2027, 1, 17))
        XCTAssertEqual(TaskRules.pinEnd(for: .week, now: date(2027, 1, 11, 9), calendar: utc), date(2027, 1, 18))
        XCTAssertEqual(TaskRules.pinEnd(for: .week, now: date(2027, 1, 17, 23), calendar: utc), date(2027, 1, 18), "Its last day")

        // The day the clocks go forward is an hour short: the pin still ends at midnight.
        var berlin = Calendar(identifier: .gregorian)
        berlin.timeZone = try XCTUnwrap(TimeZone(identifier: "Europe/Berlin"))
        let shortDay = date(2027, 3, 28, 1, in: berlin)
        let end = TaskRules.pinEnd(for: .today, now: shortDay, calendar: berlin)
        XCTAssertEqual(end, date(2027, 3, 29, 0, in: berlin))
        XCTAssertEqual(end.timeIntervalSince(berlin.startOfDay(for: shortDay)), 23 * 3600)

        // Where the clocks go forward at midnight, that day starts at one o'clock:
        // the pin still ends when the next day, or week, starts, at midnight.
        var santiago = Calendar(identifier: .gregorian)
        santiago.timeZone = try XCTUnwrap(TimeZone(identifier: "America/Santiago"))
        santiago.firstWeekday = 2
        let lateStart = date(2027, 9, 5, 12, in: santiago)
        XCTAssertEqual(santiago.component(.hour, from: santiago.startOfDay(for: lateStart)), 1, "The day the test is about")
        XCTAssertEqual(TaskRules.pinEnd(for: .today, now: lateStart, calendar: santiago), santiago.startOfDay(for: date(2027, 9, 6, 12, in: santiago)))
        XCTAssertEqual(santiago.component(.hour, from: TaskRules.pinEnd(for: .today, now: lateStart, calendar: santiago)), 0)
        XCTAssertEqual(TaskRules.pinEnd(for: .week, now: lateStart, calendar: santiago), santiago.startOfDay(for: date(2027, 9, 6, 12, in: santiago)), "Sunday, the week's last day")
        // And a week that ends on such a day ends at its own start, one o'clock.
        let weekBefore = date(2027, 8, 31, 12, in: santiago)
        var sundayFirst = santiago
        sundayFirst.firstWeekday = 1
        XCTAssertEqual(TaskRules.pinEnd(for: .week, now: weekBefore, calendar: sundayFirst), sundayFirst.startOfDay(for: lateStart))
    }

    func testHowAPinStands() {
        let later = wednesday.addingTimeInterval(3600), earlier = wednesday.addingTimeInterval(-3600)
        XCTAssertEqual(TaskRules.pinState(of: task("a"), now: wednesday), .none)
        XCTAssertEqual(TaskRules.pinState(of: task("a", pin: TaskPin(period: .today, expiresAt: later)), now: wednesday), .today)
        XCTAssertEqual(TaskRules.pinState(of: task("a", pin: TaskPin(period: .week, expiresAt: later)), now: wednesday), .week)
        XCTAssertEqual(TaskRules.pinState(of: task("a", pin: TaskPin(period: .today, expiresAt: earlier)), now: wednesday), .review, "Still on today?")
        XCTAssertEqual(TaskRules.pinState(of: task("a", pin: TaskPin(period: .week, expiresAt: earlier)), now: wednesday), .none, "A week that is over is no pin")
        XCTAssertEqual(TaskRules.pinState(of: task("a", pin: TaskPin(period: .today, expiresAt: wednesday)), now: wednesday), .review, "At its end it has run out")
        XCTAssertEqual(
            TaskRules.pinState(of: task("a", status: .done, pin: TaskPin(period: .today, expiresAt: later)), now: wednesday), .none,
            "A finished task has none"
        )
        XCTAssertEqual(TaskPinState.today.activePeriod, .today)
        XCTAssertEqual(TaskPinState.week.activePeriod, .week)
        XCTAssertNil(TaskPinState.review.activePeriod)
        XCTAssertNil(TaskPinState.none.activePeriod)
        XCTAssertEqual(TaskPinPeriod.today.title, "Today")
        XCTAssertEqual(TaskPinPeriod.week.title, "This week")
    }

    // MARK: - Order

    func testTheOrders() {
        let tasks = [
            task("no-day-old", made: 1, changed: 5),
            task("late", due: "2027-02-01", made: 2, changed: 1),
            task("soon", due: "2027-01-14", made: 3, changed: 2),
            task("no-day-new", made: 4, changed: 9),
            task("soon-too", due: "2027-01-14", made: 5, changed: 3),
        ]
        func order(_ sort: TaskSort) -> [String] {
            TaskRules.ordered(tasks, by: sort, now: wednesday).map(\.id)
        }
        XCTAssertEqual(order(.dueDate), ["soon-too", "soon", "late", "no-day-new", "no-day-old"], "The soonest due; the same day, and those with none, by when they were changed")
        XCTAssertEqual(order(.recentlyUpdated), ["no-day-new", "no-day-old", "soon-too", "soon", "late"])
        XCTAssertEqual(order(.newest), ["soon-too", "no-day-new", "soon", "late", "no-day-old"])
        XCTAssertEqual(order(.oldest), ["no-day-old", "late", "soon", "no-day-new", "soon-too"])

        // What cannot be told apart stays in the order it came in.
        let same = [task("first"), task("second"), task("third")]
        for sort in TaskSort.allCases {
            XCTAssertEqual(TaskRules.ordered(same, by: sort, now: wednesday).map(\.id), ["first", "second", "third"], sort.title)
        }

        XCTAssertEqual(TaskSort.standard, .dueDate)
        XCTAssertEqual(TaskSort.resolve("newest"), .newest)
        XCTAssertEqual(TaskSort.resolve("something-else"), .dueDate)
        XCTAssertEqual(TaskSort.allCases.map(\.title), ["Recently updated", "Due date", "Newest", "Oldest"])
        XCTAssertEqual(TaskSort.allCases.map(\.rawValue), ["recently_updated", "due_date", "newest", "oldest"], "Kept on the device: they stay")
    }

    func testTheListsParts() {
        let later = wednesday.addingTimeInterval(3600), earlier = wednesday.addingTimeInterval(-3600)
        let open = [
            task("plain", changed: 1),
            task("today", pin: TaskPin(period: .today, expiresAt: later)),
            task("week", pin: TaskPin(period: .week, expiresAt: later)),
            task("yesterdays", pin: TaskPin(period: .today, expiresAt: earlier), changed: 2),
            task("last-weeks", pin: TaskPin(period: .week, expiresAt: earlier), changed: 3),
            task("today-due", due: "2027-01-13", pin: TaskPin(period: .today, expiresAt: later)),
        ]
        let finished = [task("done", status: .done, changed: 1), task("closed", status: .closed, changed: 2)]
        let parts = TaskRules.parts(open: open, finished: finished, sort: .recentlyUpdated, now: wednesday)
        XCTAssertEqual(parts.review.map(\.id), ["yesterdays"])
        XCTAssertEqual(parts.today.map(\.id), ["today", "today-due"])
        XCTAssertEqual(parts.week.map(\.id), ["week"])
        XCTAssertEqual(parts.open.map(\.id), ["last-weeks", "yesterdays", "plain"], "What is asked about is in Open too; a week that is over is no pin")
        XCTAssertEqual(parts.finished.map(\.id), ["closed", "done"])

        let byDue = TaskRules.parts(open: open, finished: finished, sort: .dueDate, now: wednesday)
        XCTAssertEqual(byDue.today.map(\.id), ["today-due", "today"], "Each part in the order chosen")

        // An hour on, today's pins have run out: they are asked about, and back in Open.
        let nextDay = TaskRules.parts(open: open, finished: [], sort: .recentlyUpdated, now: later)
        XCTAssertEqual(nextDay.today.map(\.id), [])
        XCTAssertEqual(Set(nextDay.review.map(\.id)), ["yesterdays", "today", "today-due"])
        XCTAssertEqual(nextDay.open.count, 6)
    }

    // MARK: - Words

    func testTheWordsForADueDay() throws {
        func words(_ due: String, time: String? = nil, status: TaskStatus = .open) -> String? {
            TaskDueLine(task: task("a", status: status, due: due, time: time), now: wednesday, calendar: utc, locale: british)?.text
        }
        XCTAssertNil(TaskDueLine(task: task("a"), now: wednesday, calendar: utc, locale: british), "No day, no words")
        XCTAssertEqual(words("2027-01-13"), "Due today")
        XCTAssertEqual(words("2027-01-14"), "Due tomorrow")
        XCTAssertEqual(words("2027-01-20"), "Due Wed 20 Jan")
        XCTAssertEqual(words("2028-03-01"), "Due 1 Mar 2028", "Another year is named")
        XCTAssertEqual(words("2027-01-12"), "Overdue · Due Tue 12 Jan")
        XCTAssertEqual(words("2027-01-12", status: .done), "Due Tue 12 Jan", "A finished task is not overdue")
        XCTAssertEqual(words("2027-01-13", time: "17:30"), "Due today, 17:30")
        XCTAssertEqual(words("2027-01-14", time: "09:05"), "Due tomorrow, 09:05")

        // A time the clock skips that day is said as it was set, not moved on.
        var berlin = Calendar(identifier: .gregorian)
        berlin.timeZone = try XCTUnwrap(TimeZone(identifier: "Europe/Berlin"))
        let skipped = TaskDueLine(
            task: task("a", due: "2027-03-28", time: "02:30"), now: date(2027, 3, 20, 12, in: berlin), calendar: berlin, locale: british
        )
        XCTAssertEqual(skipped?.text, "Due Sun 28 Mar, 02:30")
        XCTAssertEqual(TaskDueLine.timeWords("17:05", locale: Locale(identifier: "en_US"))?.replacingOccurrences(of: "\u{202F}", with: " "), "5:05 PM")
        XCTAssertNil(TaskDueLine.timeWords("soon", locale: british))

        let overdue = try XCTUnwrap(TaskDueLine(task: task("a", due: "2027-01-12"), now: wednesday, calendar: utc, locale: british))
        XCTAssertTrue(overdue.isOverdue)
        let today = try XCTUnwrap(TaskDueLine(task: task("a", due: "2027-01-13", time: "08:00"), now: wednesday, calendar: utc, locale: british))
        XCTAssertFalse(today.isOverdue, "Not overdue on its day, whatever the time")
    }

    func testTheLineUnderATasksTitle() {
        let later = wednesday.addingTimeInterval(3600)
        func line(_ task: TaskItem) -> [TaskRules.Context] {
            TaskRules.context(of: task, now: wednesday, calendar: utc, locale: british)
        }
        XCTAssertEqual(line(task("a")), [], "Nothing to say")
        XCTAssertEqual(line(task("a", due: "2027-01-14")), [.plain("Due tomorrow")])
        XCTAssertEqual(line(task("a", due: "2027-01-12")), [.overdue("Overdue · Due Tue 12 Jan")])
        XCTAssertEqual(
            line(task("a", due: "2027-01-13", pin: TaskPin(period: .week, expiresAt: later))), [.pin("This week"), .plain("Due today")]
        )
        XCTAssertEqual(line(task("a", pin: TaskPin(period: .today, expiresAt: wednesday))), [], "A pin that has run out is not named")
        XCTAssertEqual(line(task("a", status: .closed, due: "2027-01-12")), [.plain("Due Tue 12 Jan"), .plain("Closed")])
        XCTAssertEqual(line(task("a", status: .done)), [])
    }
}
