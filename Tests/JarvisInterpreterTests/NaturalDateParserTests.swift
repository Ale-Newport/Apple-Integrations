import XCTest
@testable import JarvisCore
@testable import JarvisInterpreter

/// Date handling tests. "Now" is fixed to Saturday 17 Oct 2026, 13:08 in Europe/London (BST, UTC+1; the
/// clocks go back on Sunday 25 Oct 2026), a week starting on Monday.
final class NaturalDateParserTests: XCTestCase {
    static let london = TimeZone(identifier: "Europe/London")!

    func context(now: String = "2026-10-17T13:08:00+01:00", zone: TimeZone = london, language: Language = .en, firstWeekday: Int = 2) -> DateContext {
        let date = ISODates.date(from: now, timeZone: zone)!
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = zone
        calendar.firstWeekday = firstWeekday
        calendar.locale = Locale(identifier: "en_GB")
        return DateContext(now: date, calendar: calendar, settings: JarvisSettings(), language: language)
    }

    func parse(_ text: String, _ context: DateContext? = nil, bare: Bool = false) -> ParsedWhen {
        NaturalDateParser().parse(text, context: context ?? self.context(), allowBareDuration: bare)
    }

    func iso(_ date: Date?, zone: TimeZone = london) -> String {
        date.map { ISODates.string(from: $0, timeZone: zone) } ?? "nil"
    }

    // MARK: Relative days and clock times

    func testTomorrowAtSixPM() {
        let when = parse("remind me tomorrow at 6 PM to submit my assignment")
        XCTAssertEqual(iso(when.instant), "2026-10-18T18:00:00+01:00")
        XCTAssertTrue(when.timeIsExplicit)
        XCTAssertTrue(when.assumptions.isEmpty)
    }

    func testSpanishTomorrowAtSixInTheAfternoon() {
        let when = parse("mañana a las 6 de la tarde", context(language: .es))
        XCTAssertEqual(iso(when.instant), "2026-10-18T18:00:00+01:00")
    }

    func testSpanishMananaIsTheDayButPorLaMananaIsMorning() {
        let day = parse("mañana", context(language: .es))
        XCTAssertEqual(iso(day.day), "2026-10-18T00:00:00+01:00")
        XCTAssertNil(day.instant)

        let morning = parse("mañana por la mañana a las 8", context(language: .es))
        XCTAssertEqual(iso(morning.instant), "2026-10-18T08:00:00+01:00")
    }

    func testSevenThirtyTomorrowMorning() {
        let when = parse("7:30 tomorrow morning")
        XCTAssertEqual(iso(when.instant), "2026-10-18T07:30:00+01:00")
    }

    func testBareHourPicksSoonestFutureOccurrenceAndExplainsIt() {
        // 13:08 now: "at 6" → 18:00 today (the soonest 6 o'clock still ahead).
        let when = parse("at 6")
        XCTAssertEqual(iso(when.instant), "2026-10-17T18:00:00+01:00")
        XCTAssertEqual(when.assumptions, ["No AM/PM given, so I used 6:00 PM"])
    }

    func testBareHourAfterEveningRollsToTomorrowMorning() {
        let late = context(now: "2026-10-17T23:30:00+01:00")
        let when = parse("at 6", late)
        XCTAssertEqual(iso(when.instant), "2026-10-18T06:00:00+01:00")
    }

    func testBareHourOnAnotherDayUsesBusinessHoursHeuristic() {
        XCTAssertEqual(iso(parse("friday at 3").instant), "2026-10-23T15:00:00+01:00")
        XCTAssertEqual(iso(parse("friday at 9").instant), "2026-10-23T09:00:00+01:00")
        XCTAssertFalse(parse("friday at 3").assumptions.isEmpty)
    }

    func testTwentyFourHourClock() {
        XCTAssertEqual(iso(parse("tomorrow at 18:30").instant), "2026-10-18T18:30:00+01:00")
        XCTAssertEqual(iso(parse("tomorrow at 08:15").instant), "2026-10-18T08:15:00+01:00")
    }

    func testMeridiemVariants() {
        XCTAssertEqual(iso(parse("tomorrow 6pm").instant), "2026-10-18T18:00:00+01:00")
        XCTAssertEqual(iso(parse("tomorrow 6 p.m.").instant), "2026-10-18T18:00:00+01:00")
        XCTAssertEqual(iso(parse("tomorrow at 12 am").instant), "2026-10-18T00:00:00+01:00")
        XCTAssertEqual(iso(parse("tomorrow at 12 pm").instant), "2026-10-18T12:00:00+01:00")
        XCTAssertEqual(iso(parse("tomorrow at 11:45 pm").instant), "2026-10-18T23:45:00+01:00")
    }

    func testNamedTimes() {
        XCTAssertEqual(iso(parse("tomorrow at noon").instant), "2026-10-18T12:00:00+01:00")
        XCTAssertEqual(iso(parse("tomorrow at midnight").instant), "2026-10-18T00:00:00+01:00")
        XCTAssertEqual(iso(parse("mañana al mediodía", context(language: .es)).instant), "2026-10-18T12:00:00+01:00")
    }

    func testHalfPastAndQuarterTo() {
        XCTAssertEqual(iso(parse("tomorrow at half past 7 in the morning").instant), "2026-10-18T07:30:00+01:00")
        XCTAssertEqual(iso(parse("tomorrow at quarter to 9 in the evening").instant), "2026-10-18T20:45:00+01:00")
    }

    func testSpanishClockPhrases() {
        let es = context(language: .es)
        XCTAssertEqual(iso(parse("mañana a las 7 y media de la mañana", es).instant), "2026-10-18T07:30:00+01:00")
        XCTAssertEqual(iso(parse("mañana a las 8 menos cuarto de la noche", es).instant), "2026-10-18T19:45:00+01:00")
        XCTAssertEqual(iso(parse("mañana a las 18:30", es).instant), "2026-10-18T18:30:00+01:00")
        XCTAssertEqual(iso(parse("mañana a las seis y cuarto de la tarde", es).instant), "2026-10-18T18:15:00+01:00")
    }

    func testPartOfDayWithoutHourUsesSettingsAndSaysSo() {
        let when = parse("tomorrow morning")
        XCTAssertEqual(iso(when.instant), "2026-10-18T09:00:00+01:00")
        XCTAssertFalse(when.timeIsExplicit)
        XCTAssertEqual(when.assumptions.count, 1)
    }

    func testTonight() {
        let when = parse("tonight at 8")
        XCTAssertEqual(iso(when.instant), "2026-10-17T20:00:00+01:00")
    }

    // MARK: Offsets

    func testInTwoHours() {
        let when = parse("in two hours")
        XCTAssertEqual(iso(when.instant), "2026-10-17T15:08:00+01:00")
    }

    func testInThirtyMinutesSpanish() {
        let when = parse("dentro de 30 minutos", context(language: .es))
        XCTAssertEqual(iso(when.instant), "2026-10-17T13:38:00+01:00")
    }

    func testInAnHourAndAHalf() {
        XCTAssertEqual(iso(parse("in an hour and a half").instant), "2026-10-17T14:38:00+01:00")
        XCTAssertEqual(iso(parse("en una hora y media", context(language: .es)).instant), "2026-10-17T14:38:00+01:00")
    }

    func testInThreeDaysAndWeeks() {
        XCTAssertEqual(iso(parse("in 3 days").day), "2026-10-20T00:00:00+01:00")
        XCTAssertEqual(iso(parse("in two weeks").day), "2026-10-31T00:00:00+00:00")
    }

    // MARK: Weekdays

    func testNextMondayFromSaturday() {
        XCTAssertEqual(iso(parse("next Monday").day), "2026-10-19T00:00:00+01:00")
    }

    func testBareWeekdayIsTheUpcomingOne() {
        XCTAssertEqual(iso(parse("on Tuesday").day), "2026-10-20T00:00:00+01:00")
        XCTAssertEqual(iso(parse("el martes", context(language: .es)).day), "2026-10-20T00:00:00+01:00")
    }

    func testNextWeekdayMeansTheFollowingWeek() {
        // Saturday 17th: "next Friday" = Friday 23rd; from Wednesday it is the following week's Friday.
        XCTAssertEqual(iso(parse("next friday").day), "2026-10-23T00:00:00+01:00")
        let wednesday = context(now: "2026-10-14T09:00:00+01:00")
        let when = parse("next friday", wednesday)
        XCTAssertEqual(iso(when.day), "2026-10-23T00:00:00+01:00")
        XCTAssertFalse(when.assumptions.isEmpty, "the ambiguous reading must be surfaced")
    }

    func testSameWeekdayAfterTheTimeHasPassedMovesAWeek() {
        // It is Saturday 13:08; "Saturday at 9 am" has passed → next Saturday.
        let when = parse("saturday at 9 am")
        XCTAssertEqual(iso(when.instant), "2026-10-24T09:00:00+01:00")
        XCTAssertFalse(when.assumptions.isEmpty)
        // …but still later today is today.
        XCTAssertEqual(iso(parse("saturday at 5 pm").instant), "2026-10-17T17:00:00+01:00")
    }

    func testSpanishProximoLunes() {
        let es = context(language: .es)
        XCTAssertEqual(iso(parse("el próximo lunes", es).day), "2026-10-19T00:00:00+01:00")
        XCTAssertEqual(iso(parse("el lunes que viene", es).day), "2026-10-19T00:00:00+01:00")
    }

    // MARK: Absolute dates

    func testAbsoluteDatesInferTheYear() {
        XCTAssertEqual(iso(parse("June 5").day), "2027-06-05T00:00:00+01:00")
        XCTAssertEqual(iso(parse("on 5th of November").day), "2026-11-05T00:00:00+00:00")
        XCTAssertEqual(iso(parse("el 5 de junio de 2028", context(language: .es)).day), "2028-06-05T00:00:00+01:00")
        XCTAssertEqual(iso(parse("2026-12-25").day), "2026-12-25T00:00:00+00:00")
    }

    func testNumericDatesFollowTheLanguage() {
        XCTAssertEqual(iso(parse("11/03", context(language: .en)).day), "2026-11-03T00:00:00+00:00")
        XCTAssertEqual(iso(parse("11/03", context(language: .es)).day), "2027-03-11T00:00:00+00:00")
        XCTAssertEqual(iso(parse("25/12", context(language: .en)).day), "2026-12-25T00:00:00+00:00", "25 cannot be a month")
    }

    func testImpossibleDatesAreIgnored() {
        XCTAssertNil(parse("february 30").day)
    }

    func testOrdinalDayOfMonth() {
        XCTAssertEqual(iso(parse("on the 25th").day), "2026-10-25T00:00:00+01:00")
        XCTAssertEqual(iso(parse("on the 3rd").day), "2026-11-03T00:00:00+00:00")
    }

    // MARK: Spans

    func testThisWeekRunsFromTodayToTheEndOfTheWeek() {
        let when = parse("this week")
        XCTAssertEqual(iso(when.span?.start), "2026-10-17T00:00:00+01:00")
        XCTAssertEqual(iso(when.span?.end), "2026-10-19T00:00:00+01:00")
    }

    func testNextWeekIsTheWholeNextWeek() {
        let when = parse("next week")
        XCTAssertEqual(iso(when.span?.start), "2026-10-19T00:00:00+01:00")
        XCTAssertEqual(iso(when.span?.end), "2026-10-26T00:00:00+00:00")
    }

    func testThisWeekendOnASaturdayStartsToday() {
        let when = parse("this weekend")
        XCTAssertEqual(iso(when.span?.start), "2026-10-17T00:00:00+01:00")
        XCTAssertEqual(iso(when.span?.end), "2026-10-19T00:00:00+01:00")
    }

    func testNextSevenDays() {
        let when = parse("the next 7 days")
        XCTAssertNotNil(when.span)
        XCTAssertEqual(iso(when.span?.end), "2026-10-25T00:00:00+01:00")
    }

    // MARK: Durations and ranges

    func testDurations() {
        XCTAssertEqual(parse("tomorrow at 3 pm for one hour").duration, 3_600)
        XCTAssertEqual(parse("lasting two hours").duration, 7_200)
        XCTAssertEqual(parse("for 90 minutes").duration, 5_400)
        XCTAssertEqual(parse("for an hour and a half").duration, 5_400)
        XCTAssertEqual(parse("durante una hora", context(language: .es)).duration, 3_600)
        XCTAssertEqual(parse("de dos horas", context(language: .es)).duration, 7_200)
        XCTAssertEqual(parse("por 45 minutos", context(language: .es)).duration, 2_700)
    }

    func testBareDurationForTimers() {
        XCTAssertEqual(parse("10 minutes", bare: true).duration, 600)
        XCTAssertEqual(parse("1 hour 30 minutes", bare: true).duration, 5_400)
        XCTAssertEqual(parse("1h30", bare: true).duration, 5_400)
        XCTAssertEqual(parse("2h 15m", bare: true).duration, 8_100)
        XCTAssertEqual(parse("cinco minutos", context(language: .es), bare: true).duration, 300)
        XCTAssertNil(parse("10 minutes", bare: false).duration)
    }

    func testTimeRange() {
        let when = parse("friday from 3 to 4 pm")
        XCTAssertEqual(iso(when.instant), "2026-10-23T15:00:00+01:00")
        XCTAssertEqual(iso(when.endInstant), "2026-10-23T16:00:00+01:00")
        XCTAssertEqual(when.duration, 3_600)

        let spanish = parse("el viernes de 10 a 12", context(language: .es))
        XCTAssertEqual(iso(spanish.instant), "2026-10-23T10:00:00+01:00")
        XCTAssertEqual(iso(spanish.endInstant), "2026-10-23T12:00:00+01:00")
    }

    func testStartPlusDurationGivesEnd() {
        let when = parse("tuesday at 10 am lasting two hours")
        XCTAssertEqual(iso(when.instant), "2026-10-20T10:00:00+01:00")
        XCTAssertEqual(iso(when.endInstant), "2026-10-20T12:00:00+01:00")
    }

    // MARK: Time zones and DST

    func testResolvesInTheUsersTimeZoneAcrossTheFallBackTransition() {
        // Clocks go back on Sunday 25 Oct 2026: 18:00 that day is GMT (UTC+0), not BST.
        let when = parse("sunday october 25 at 6 pm")
        XCTAssertEqual(iso(when.instant), "2026-10-25T18:00:00+00:00")
    }

    func testNonExistentLocalTimeMovesForwardAcrossSpringForward() {
        // 29 Mar 2026 01:30 does not exist in London (01:00 → 02:00).
        let march = context(now: "2026-03-20T10:00:00+00:00")
        let when = parse("march 29 at 1:30 am", march)
        XCTAssertEqual(iso(when.instant), "2026-03-29T02:00:00+01:00")
    }

    func testOtherTimeZones() {
        let tokyo = TimeZone(identifier: "Asia/Tokyo")!
        let ctx = context(now: "2026-10-17T22:00:00+09:00", zone: tokyo)
        XCTAssertEqual(iso(parse("tomorrow at 9 am", ctx).instant, zone: tokyo), "2026-10-18T09:00:00+09:00")
        let newYork = TimeZone(identifier: "America/New_York")!
        let ny = context(now: "2026-10-17T08:00:00-04:00", zone: newYork, firstWeekday: 1)
        XCTAssertEqual(iso(parse("next monday at 9", ny).instant, zone: newYork), "2026-10-19T09:00:00-04:00")
    }

    // MARK: Consumed ranges

    func testConsumedRangesRemoveOnlyTheDatePhrases() {
        let text = FoldedText("Remind me tomorrow at 6 PM to submit my assignment")
        let when = NaturalDateParser().parse(text, context: context())
        let remainder = text.removing(when.consumed).original
        XCTAssertEqual(remainder, "Remind me to submit my assignment")
    }

    func testMaskedTextIsNeverParsedAsADate() {
        let text = FoldedText.withQuotesMasked("Create a note \"call at 6 pm tomorrow\"")
        let when = NaturalDateParser().parse(text, context: context())
        XCTAssertTrue(when.isEmpty)
    }
}
