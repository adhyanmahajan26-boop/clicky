import CoreGraphics
import Testing
@testable import ClickyCore

@Test func cadenceStaysFastWhileThePointerMoves() {
    var cadence = CursorFollowCadence(now: 0)
    for frame in 0..<120 {
        let now = Double(frame) / 60
        do { let observedMode = cadence.observe(pointer: CGPoint(x: Double(frame) * 3, y: 100), at: now); #expect(observedMode == .fast) }
    }
}

@Test func cadenceGoesIdleAfterThePointerRestsForTheLinger() {
    var cadence = CursorFollowCadence(now: 0)
    cadence.observe(pointer: CGPoint(x: 10, y: 10), at: 0)
    cadence.observe(pointer: CGPoint(x: 40, y: 10), at: 0.1)  // moved
    // Still for less than the linger: fast (the spark click target needs these ticks).
    do { let observedMode = cadence.observe(pointer: CGPoint(x: 40, y: 10), at: 0.1 + 0.7); #expect(observedMode == .fast) }
    do { let observedMode = cadence.observe(pointer: CGPoint(x: 40, y: 10), at: 0.1 + CursorFollowCadence.lingerSeconds - 0.01); #expect(observedMode == .fast) }
    // Still past the linger: idle, and the interval drops to the slow poll.
    do { let observedMode = cadence.observe(pointer: CGPoint(x: 40, y: 10), at: 0.1 + CursorFollowCadence.lingerSeconds + 0.01); #expect(observedMode == .idle) }
    #expect(cadence.intervalSeconds == CursorFollowCadence.idleIntervalSeconds)
    #expect(abs(cadence.idleSeconds(at: 2.1) - 2.0) < 1e-9)
}

@Test func subThresholdJitterDoesNotCountAsMotion() {
    var cadence = CursorFollowCadence(now: 0)
    cadence.observe(pointer: CGPoint(x: 100, y: 100), at: 0)
    for step in 1...200 {
        let jitter = step.isMultiple(of: 2) ? 0.2 : -0.2
        cadence.observe(pointer: CGPoint(x: 100 + jitter, y: 100), at: Double(step) / 60)
    }
    #expect(cadence.mode == .idle)
}

@Test func aMotionEventWakesTheLoopImmediately() {
    var cadence = CursorFollowCadence(now: 0)
    cadence.observe(pointer: .zero, at: 0)
    cadence.observe(pointer: .zero, at: 5)
    #expect(cadence.mode == .idle)
    let woke = cadence.noteMotionEvent(at: 5.01)
    #expect(woke)  // woke: reschedule fast now
    #expect(cadence.mode == .fast)
    #expect(cadence.intervalSeconds == CursorFollowCadence.fastIntervalSeconds)
    let wokeAgain = cadence.noteMotionEvent(at: 5.02)
    #expect(!wokeAgain)  // already fast
    // The pointer then rests again: idle once the linger passes.
    cadence.observe(pointer: CGPoint(x: 20, y: 0), at: 5.03)
    do { let observedMode = cadence.observe(pointer: CGPoint(x: 20, y: 0), at: 5.03 + CursorFollowCadence.lingerSeconds + 0.05); #expect(observedMode == .idle) }
}

@Test func keepsFastOverridesIdle() {
    var cadence = CursorFollowCadence(now: 0)
    cadence.observe(pointer: .zero, at: 0)
    do { let observedMode = cadence.observe(pointer: .zero, at: 10, keepsFast: true); #expect(observedMode == .fast) }
    do { let observedMode = cadence.observe(pointer: .zero, at: 10.1); #expect(observedMode == .idle) }
}

/// Simulates the loop: 10 s with the pointer still after 1 s of motion. The
/// fast loop runs ~60 ticks for the motion + linger, then ~10 Hz.
@Test func stillPointerTickBudget() {
    var cadence = CursorFollowCadence(now: 0)
    var now = 0.0
    var ticks = 0
    var stillTicks = 0
    while now < 11 {
        let pointer = now < 1 ? CGPoint(x: now * 600, y: 0) : CGPoint(x: 600, y: 0)
        cadence.observe(pointer: pointer, at: now)
        ticks += 1
        if now >= 3 { stillTicks += 1 }
        now += cadence.intervalSeconds
    }
    // 8 s fully still → about 80 slow ticks (vs 480 at a fixed 60 Hz).
    #expect(stillTicks <= 82)
    #expect(stillTicks >= 78)
    #expect(ticks < 60 * 2 + 100)
}

@Test func slidingRateCountsOnlyTheWindow() {
    var rate = SlidingEventRate(windowSeconds: 5)
    for tick in 0..<600 { rate.record(at: Double(tick) / 60) }  // 10 s at 60 Hz
    let count = rate.count(at: 10)
    let ratePerSecond = rate.ratePerSecond(at: 10)
    let lateCount = rate.count(at: 100)
    #expect(count >= 299 && count <= 301)
    #expect(abs(ratePerSecond - 60) < 0.5)
    #expect(lateCount == 0)
    #expect(rate.totalCount == 600)
}
