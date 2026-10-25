import Foundation
import Testing
import simd
import CoreMath
import Scene
@testable import Studio

/// Pure bookkeeping tests for `SourceStudioRouteClock`: the press-time `play`
/// offset, the live-tick mirror, the jump rebuild + fixed `1/30`
/// fast-forward, the 18,000-step fallback and the non-loop hold frame. The
/// stepper underneath is built directly from
/// points (the baseline cases use orientation none); these
/// tests compare the clock against a bare stepper stepped by hand, which is
/// exactly the equality the Studio preview placement relies on.
/// Speed 9 on 3 m straight legs: `PathLength` re-runs the padded generator,
/// so a straight two-point segment times at three times its geometric length
/// (see `SourceStudioRoute.Segment.duration`) — 9 / 9 = exactly 1 s, 30 frames
/// per segment, 60 frames for the whole route.
private func testPoints() -> [SourceStudioRoute.Point] {
    [SourceStudioRoute.Point(position: [0, 0, 0], speed: 9),
     SourceStudioRoute.Point(position: [3, 0, 0], speed: 9),
     SourceStudioRoute.Point(position: [3, 0, 3], speed: 9)]
}

/// A builder for the identity route world (translation offsets the whole
/// path, mirroring how a moved route object moves its child points).
private func loopingClock(steps: Int = SourceStudioRouteClock.maxRebuildSteps,
                          playing: Bool = true) -> SourceStudioRouteClock {
    SourceStudioRouteClock(maxRebuildSteps: steps, playing: playing) { world in
        let offset = SIMD3<Double>(Double(world.translation.x), Double(world.translation.y),
                                   Double(world.translation.z))
        return try? SourceStudioRouteStepper(points: testPoints().map {
            SourceStudioRoute.Point(position: $0.position + offset, aid: $0.aid,
                                    connection: $0.connection, linked: $0.linked,
                                    speed: $0.speed, easeType: $0.easeType)
        }, loop: true)
    }
}

private func nonLoopClock() -> SourceStudioRouteClock {
    SourceStudioRouteClock(playing: true) { _ in
        try? SourceStudioRouteStepper(points: testPoints(), loop: false)
    }
}

/// 60 s at `1/30` as repeated `Float` additions, the exact mirrored clock a
/// press at that instant would see.
private func framesTime(_ frames: Int) -> Float {
    var time: Float = 0
    for _ in 0..<frames { time += SourceStudioRouteClock.frameDelta }
    return time
}

private func translated(_ offset: Float) -> float4x4 {
    Transform.trs(SIMD3<Float>(offset, 0, 0), .identity, SIMD3<Float>(repeating: 1))
}

@Test("live ticks accumulate the mirrored clock and step the stepper per frame")
func liveStepping() throws {
    let clock = loopingClock()
    _ = clock.frame(at: 0, routeWorld: matrix_identity_float4x4) // installs Play
    var reference = try SourceStudioRouteStepper(points: testPoints(), loop: true)
    var time: Float = 0
    for _ in 0..<37 {
        time += SourceStudioRouteClock.frameDelta
        clock.step(delta: SourceStudioRouteClock.frameDelta)
        _ = try reference.step(deltaTime: Double(SourceStudioRouteClock.frameDelta))
        let frame = try #require(clock.frame(at: time, routeWorld: matrix_identity_float4x4))
        #expect(frame.placement.position == reference.current().position)
        #expect(frame.deltaTime == Double(SourceStudioRouteClock.frameDelta))
    }
    // The mirror consumes the identical Float additions, so it matches bit
    // for bit and the 1e-6 gate only has to absorb rebuild rounding.
    #expect(clock.reachedTime == time)
}

@Test("a jump rebuilds and fast-forwards to the same sample as stepping 1/30 repeatedly")
func jumpMatchesLiveStepping() throws {
    var time: Float = 0
    for _ in 0..<120 { time += SourceStudioRouteClock.frameDelta }
    var reference = try SourceStudioRouteStepper(points: testPoints(), loop: true)
    for _ in 0..<120 { _ = try reference.step(deltaTime: Double(SourceStudioRouteClock.frameDelta)) }

    let clock = loopingClock()
    let action = clock.jump(to: time, routeWorld: matrix_identity_float4x4)
    #expect(action == .rebuilt(steps: 120))
    #expect(clock.reachedTime == time)
    let frame = try #require(clock.frame(at: time, routeWorld: matrix_identity_float4x4))
    #expect(frame.placement.position == reference.current().position)
    // A mirrored live tick after the jump lands on the next frame on both
    // sides, so the placement keeps matching instead of drifting.
    time += SourceStudioRouteClock.frameDelta
    _ = try reference.step(deltaTime: Double(SourceStudioRouteClock.frameDelta))
    clock.step(delta: SourceStudioRouteClock.frameDelta)
    let next = try #require(clock.frame(at: time, routeWorld: matrix_identity_float4x4))
    #expect(next.placement.position == reference.current().position)
}

@Test("a jump beyond the fast-forward budget falls back until it is re-armed")
func rebuildCap() throws {
    let clock = loopingClock()
    _ = clock.frame(at: 0, routeWorld: matrix_identity_float4x4) // installs Play
    // 700 s at 1/30 is 21,000 frames, past the 18,000-frame (10-minute) budget.
    #expect(clock.jump(to: 700) == .rebuiltWithFallback(steps: 21_000))
    // Dropped: the continuous evaluator answers until a rebuild re-arms it.
    #expect(clock.frame(at: 700, routeWorld: matrix_identity_float4x4) == nil)
    // Inside the budget again: the world-matched route rebuilds.
    #expect(clock.jump(to: 2) == .rebuilt(steps: 60))
    #expect(clock.frame(at: 2, routeWorld: matrix_identity_float4x4) != nil)
    // An unplayable route has no frame ever: it keeps its Stop pin.
    let unplayable = SourceStudioRouteClock(playing: true) { _ in nil }
    #expect(unplayable.jump(to: 5) == .stepped)
    #expect(unplayable.frame(at: 5, routeWorld: matrix_identity_float4x4) == nil)
    #expect(unplayable.frame(at: 0, routeWorld: matrix_identity_float4x4) == nil)
}

@Test("a press at T starts the tween there: live ticks and jumps match a fresh stepper from T")
func playStartOffset() throws {
    // Press Play at frame 90 (tween time 0 = point 0), then live-tick 1/30.
    let press = framesTime(90)
    let clock = loopingClock(playing: false)
    #expect(clock.frame(at: press, routeWorld: matrix_identity_float4x4) == nil)
    #expect(clock.play(at: press, routeWorld: matrix_identity_float4x4) == .rebuilt(steps: 0))
    let atPress = try #require(clock.frame(at: press, routeWorld: matrix_identity_float4x4))
    #expect(atPress.deltaTime == 0) // Play's percentage-0 state.
    var reference = try SourceStudioRouteStepper(points: testPoints(), loop: true)
    var time = press
    for _ in 0..<13 {
        time += SourceStudioRouteClock.frameDelta
        clock.step(delta: SourceStudioRouteClock.frameDelta)
        _ = try reference.step(deltaTime: Double(SourceStudioRouteClock.frameDelta))
        let frame = try #require(clock.frame(at: time, routeWorld: matrix_identity_float4x4))
        #expect(frame.placement.position == reference.current().position)
    }
    // A jump back to 1/30 after the press sees one tween frame, not 91.
    #expect(clock.jump(to: framesTime(91), routeWorld: matrix_identity_float4x4) == .rebuilt(steps: 1))
    let oneFrame = try #require(clock.frame(at: framesTime(91), routeWorld: matrix_identity_float4x4))
    var fresh = try SourceStudioRouteStepper(points: testPoints(), loop: true)
    _ = try fresh.step(deltaTime: Double(SourceStudioRouteClock.frameDelta))
    #expect(oneFrame.placement.position == fresh.current().position)
}

@Test("a jump before the press instant has no frame until the clock reaches the press")
func jumpBeforePlayStart() throws {
    let press = framesTime(60)
    let clock = loopingClock(playing: false)
    _ = clock.play(at: press, routeWorld: matrix_identity_float4x4)
    // Scrubbing back before the press: the route was not playing there.
    #expect(clock.jump(to: framesTime(59), routeWorld: matrix_identity_float4x4) == .notPlayingYet)
    #expect(clock.frame(at: framesTime(59), routeWorld: matrix_identity_float4x4) == nil)
    // The mirrored clock keeps running there so a re-arm aligns bit for bit.
    clock.step(delta: SourceStudioRouteClock.frameDelta)
    // Crossing the press instant live re-arms the stepper: one tween frame,
    // exactly what a fresh stepper stepped once holds.
    let crossed = press + SourceStudioRouteClock.frameDelta
    let armed = try #require(clock.frame(at: crossed, routeWorld: matrix_identity_float4x4))
    #expect(clock.lastAction == .rebuilt(steps: 1))
    var oneStep = try SourceStudioRouteStepper(points: testPoints(), loop: true)
    _ = try oneStep.step(deltaTime: Double(SourceStudioRouteClock.frameDelta))
    #expect(armed.placement.position == oneStep.current().position)
    #expect(clock.jump(to: press, routeWorld: matrix_identity_float4x4) == .rebuilt(steps: 0))
    #expect(clock.frame(at: press, routeWorld: matrix_identity_float4x4) != nil)
}

@Test("replay resets the press instant and stop drops every frame")
func replayAndStop() throws {
    let press = framesTime(30)
    let clock = loopingClock(playing: false)
    _ = clock.play(at: press, routeWorld: matrix_identity_float4x4)
    var time = press
    for _ in 0..<20 {
        time += SourceStudioRouteClock.frameDelta
        clock.step(delta: SourceStudioRouteClock.frameDelta)
    }
    // `Replay all` re-presses a playing route: the tween restarts from point 0
    // at the new instant.
    #expect(clock.play(at: time, routeWorld: matrix_identity_float4x4) == .rebuilt(steps: 0))
    let restarted = try #require(clock.frame(at: time, routeWorld: matrix_identity_float4x4))
    var fresh = try SourceStudioRouteStepper(points: testPoints(), loop: true)
    #expect(restarted.placement.position == fresh.current().position)
    // `Stop` answers nothing, even at the mirrored instant.
    #expect(clock.stop() == .stopped)
    #expect(clock.frame(at: time, routeWorld: matrix_identity_float4x4) == nil)
    clock.step(delta: SourceStudioRouteClock.frameDelta)
    #expect(clock.frame(at: framesTime(51), routeWorld: matrix_identity_float4x4) == nil)
    // Pressing Play again after a stop re-arms the stepper.
    let later = framesTime(51)
    #expect(clock.play(at: later, routeWorld: matrix_identity_float4x4) == .rebuilt(steps: 0))
    #expect(clock.frame(at: later, routeWorld: matrix_identity_float4x4) != nil)
}

@Test("a non-loop route ends inactive at its end and the clock keeps the hold")
func nonLoopCompletion() throws {
    let clock = nonLoopClock()
    var reference = try SourceStudioRouteStepper(points: testPoints(), loop: false)
    // Two segments of 1 s each (see `testPoints`): inactive from frame 60 on.
    var time: Float = 0
    for _ in 0..<100 {
        time += SourceStudioRouteClock.frameDelta
        clock.step(delta: SourceStudioRouteClock.frameDelta)
        _ = try reference.step(deltaTime: Double(SourceStudioRouteClock.frameDelta))
    }
    let frame = try #require(clock.frame(at: time, routeWorld: matrix_identity_float4x4))
    #expect(frame.placement == reference.current())
    #expect(!frame.placement.active)
    for (got, want) in zip([frame.placement.position.x, frame.placement.position.y,
                            frame.placement.position.z], [3.0, 0.0, 3.0]) {
        #expect(abs(got - want) < 1e-5)
    }
    // A jump to the same time rebuilds to the identical hold placement.
    let rebuilt = nonLoopClock()
    #expect(rebuilt.jump(to: time, routeWorld: matrix_identity_float4x4) == .rebuilt(steps: 100))
    let hold = try #require(rebuilt.frame(at: time, routeWorld: matrix_identity_float4x4))
    #expect(hold.placement == frame.placement)
}

@Test("a route world change rebuilds like a jump")
func routeWorldChangeRebuilds() throws {
    let clock = loopingClock()
    var time: Float = 0
    for _ in 0..<45 {
        time += SourceStudioRouteClock.frameDelta
        clock.step(delta: SourceStudioRouteClock.frameDelta)
    }
    let moved = translated(2)
    let frame = try #require(clock.frame(at: time, routeWorld: moved))
    var reference = try SourceStudioRouteStepper(
        points: testPoints().map { SourceStudioRoute.Point(position: $0.position + SIMD3(2, 0, 0),
                                                           aid: $0.aid, connection: $0.connection,
                                                           linked: $0.linked, speed: $0.speed,
                                                           easeType: $0.easeType) },
        loop: true)
    for _ in 0..<45 { _ = try reference.step(deltaTime: Double(SourceStudioRouteClock.frameDelta)) }
    #expect(clock.lastAction == .rebuilt(steps: 45))
    #expect(frame.placement.position == reference.current().position)
}

@Test("route checkpoint restores irregular oriented history and exact continuation", arguments: [true, false])
func routeCheckpointContinuation(loop: Bool) throws {
    var builds = 0
    func makeClock() -> SourceStudioRouteClock {
        SourceStudioRouteClock(playing: true) { _ in
            builds += 1
            return try? SourceStudioRouteStepper(points: testPoints(), loop: loop, orientation: .xy,
                initialRotation: .identity, initialDelta: 0.013)
        }
    }
    let clock = makeClock(), control = makeClock()
    for value in [clock, control] {
        _ = value.frame(at: 0, routeWorld: matrix_identity_float4x4)
        // Cross the first segment boundary with an off-lattice history. The
        // damped rotation and previous delta must survive as well as position.
        for _ in 0..<53 { value.step(delta: 0.02) }
    }
    let checkpoint = clock.captureCheckpoint(), frame = clock.frame
    let time = clock.reachedTime, action = clock.lastAction
    #expect(frame?.placement.aim != nil)
    #expect(frame == control.frame)
    clock.step(delta: 0.011)
    clock.play(at: 9, routeWorld: translated(4))
    let buildsBeforeRestore = builds
    try clock.restoreCheckpoint(checkpoint)
    #expect(builds == buildsBeforeRestore)
    #expect(clock.reachedTime == time && clock.lastAction == action)
    #expect(clock.playing && clock.playStart == 0)
    #expect(clock.frame(at: time, routeWorld: matrix_identity_float4x4) == frame)
    #expect(builds == buildsBeforeRestore) // The saved world was restored too.
    for index in 0..<130 {
        let delta: Float = index.isMultiple(of: 2) ? 0.017 : 0.026
        clock.step(delta: delta); control.step(delta: delta)
        #expect(clock.frame == control.frame)
        #expect(clock.reachedTime == control.reachedTime)
    }
    #expect(clock.frame?.placement.active == loop)
}

@Test("route checkpoint preserves lazy stopped and fallback state without building")
func routeCheckpointInactiveStates() throws {
    for state in ["lazy", "stopped", "beforePlay", "fallback", "unplayable"] {
        var builds = 0
        let clock = SourceStudioRouteClock(maxRebuildSteps: 2, playing: true) { _ in
            builds += 1
            if state == "unplayable" { return nil }
            return try? SourceStudioRouteStepper(points: testPoints())
        }
        switch state {
        case "stopped": clock.play(at: 0.7, routeWorld: translated(2)); clock.stop()
        case "beforePlay": clock.play(at: 0.7, routeWorld: translated(2)); clock.jump(to: 0.2)
        case "fallback": clock.play(at: 0, routeWorld: translated(2)); clock.jump(to: 10)
        case "unplayable": _ = clock.frame(at: 0, routeWorld: translated(2))
        default: break
        }
        let checkpoint = clock.captureCheckpoint(), frame = clock.frame
        let time = clock.reachedTime, action = clock.lastAction
        let playing = clock.playing, start = clock.playStart
        clock.play(at: 12, routeWorld: translated(9)); clock.step(delta: 0.02)
        let buildsBeforeRestore = builds
        try clock.restoreCheckpoint(checkpoint)
        #expect(builds == buildsBeforeRestore)
        #expect(clock.frame == frame && clock.reachedTime == time && clock.lastAction == action)
        #expect(clock.playing == playing && clock.playStart == start)
        if state == "lazy" {
            #expect(clock.frame == nil)
            #expect(clock.frame(at: 0, routeWorld: matrix_identity_float4x4) != nil)
            #expect(builds == buildsBeforeRestore + 1)
        }
    }
}

@Test("route checkpoints retain their owner and reject another clock before mutation")
func routeCheckpointOwner() throws {
    var original: SourceStudioRouteClock? = loopingClock()
    weak var retained = original
    original?.play(at: 0, routeWorld: matrix_identity_float4x4)
    original?.step(delta: 0.02)
    let checkpoint = try #require(original).captureCheckpoint()
    let originalFrame = original?.frame
    original = nil
    #expect(retained != nil)
    let other = loopingClock(), control = loopingClock()
    for value in [other, control] {
        value.play(at: 4, routeWorld: translated(5)); value.step(delta: 0.017)
    }
    let frame = other.frame, action = other.lastAction, time = other.reachedTime
    do {
        try other.restoreCheckpoint(checkpoint)
        Issue.record("A checkpoint from another route must reject")
    } catch RigError.invalid(let reason) {
        #expect(reason == "Route checkpoint belongs to another clock instance.")
    }
    #expect(other.frame == frame && other.reachedTime == time && other.lastAction == action)
    #expect(other.playing && other.playStart == 4)
    #expect(retained?.frame == originalFrame && retained?.reachedTime == 0.02)
    other.step(delta: 0.021); control.step(delta: 0.021)
    #expect(other.frame == control.frame && other.reachedTime == control.reachedTime)
    let owner = try #require(retained)
    owner.step(delta: 0.07)
    try owner.restoreCheckpoint(checkpoint)
    #expect(owner.reachedTime == 0.02)
}
