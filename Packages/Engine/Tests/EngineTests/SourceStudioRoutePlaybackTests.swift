import Foundation
import Testing
import simd
import CoreMath
import Scene
@testable import Studio

/// Synthetic-record coverage for the recovered `childRoot` placement rules
/// (`OCIRoute.cs` `Play`/`Stop`, `AddObjectRoute.cs` parenting). Positions
/// verify against hand-computed straight-line positions; orientation rotations
/// verify against `UnityCoordinates.eulerDegrees` conversions, not against the
/// playback layer's own composition. Nothing here is an original CharaStudio
/// capture.
private func amount(_ position: SIMD3<Float>, rotation: SIMD3<Float> = .zero,
                    scale: SIMD3<Float> = .one) -> KoikatsuChangeAmount {
    .init(position: position, rotationDegrees: rotation, scale: scale)
}

private func routePoint(_ position: SIMD3<Float>, rotation: SIMD3<Float> = .zero, speed: Float = 2,
                        easeType: Int32 = 21, aid: SIMD3<Float>? = nil,
                        linked: Bool = false, connection: Int32 = 0) -> KoikatsuRoutePointRecord {
    .init(bone: .init(sourceKey: 1, transform: amount(position, rotation: rotation)), speed: speed,
          easeType: easeType, connection: connection, aid: .init(sourceKey: 0, transform: amount(aid ?? .zero)),
          aidInitialized: aid != nil, linked: linked)
}

private func routeRecord(_ points: [KoikatsuRoutePointRecord], active: Bool = true, loop: Bool = false,
                         orientation: Int32 = 0) -> KoikatsuRouteRecord {
    .init(points: points, active: active, loop: loop, visibleLine: true, orientation: orientation, color: .one)
}

/// Engine-space TRS of a Unity-space authored placement, the same conversion
/// the scene preview applies to imported objects.
private func nativeTRS(_ position: SIMD3<Float>, rotation: SIMD3<Float> = .zero,
                       scale: SIMD3<Float> = .one) -> float4x4 {
    Transform.trs(UnityCoordinates.position(position), UnityCoordinates.eulerDegrees(rotation), scale)
}

private func columnwiseEqual(_ lhs: float4x4, _ rhs: float4x4, tolerance: Float = 0.0001) -> Bool {
    for c in 0..<4 { for r in 0..<4 { if abs(lhs[c][r] - rhs[c][r]) > tolerance { return false } } }
    return true
}

private func approximately(_ lhs: SIMD3<Float>, _ rhs: SIMD3<Float>, tolerance: Float = 0.001) -> Bool {
    (0..<3).allSatisfy { abs(lhs[$0] - rhs[$0]) <= tolerance }
}

@Test("an inactive route pins childRoot to point 0's world placement")
func inactiveRoutePinsPoint0() throws {
    // Identical points make this route unplayable; the pin must not require segments.
    let record = routeRecord([routePoint([0, 0, 1]), routePoint([0, 0, 1])], active: false)
    for elapsed in [0.0, 5.0] {
        let (pinned, diagnostics) = SourceStudioRoutePlayback.childRootWorld(
            route: record, routeWorld: matrix_identity_float4x4,
            pointLocals: SourceStudioRoutePlayback.pointLocals(from: record), elapsed: elapsed)
        #expect(diagnostics.isEmpty)
        #expect(pinned.translation == SIMD3<Float>(0, 0, -1))  // Unity z=1 reflected
        #expect(columnwiseEqual(pinned, nativeTRS([0, 0, 1])))
    }
    // Point 0's world placement includes the route object's own transform.
    let routeWorld = Transform.translation(SIMD3<Float>(5, 0, 0))
    let (anchored, diagnostics) = SourceStudioRoutePlayback.childRootWorld(
        route: record, routeWorld: routeWorld,
        pointLocals: SourceStudioRoutePlayback.pointLocals(from: record), elapsed: 0)
    #expect(diagnostics.isEmpty)
    #expect(anchored.translation == SIMD3<Float>(5, 0, -1))
}

@Test("an active route without orientation keeps point 0's rotation")
func orientationNoneKeepsPoint0Rotation() throws {
    let record = routeRecord([routePoint([0, 0, 1], rotation: SIMD3(10, 20, 30)), routePoint([2, 0, 1])])
    let locals = [nativeTRS([0, 0, 1], rotation: SIMD3(10, 20, 30)), nativeTRS([2, 0, 1])]
    let point0Rotation = Transform.rotation(UnityCoordinates.eulerDegrees(SIMD3<Float>(10, 20, 30)))

    let (start, startDiagnostics) = SourceStudioRoutePlayback.childRootWorld(
        route: record, routeWorld: matrix_identity_float4x4, pointLocals: locals, elapsed: 0)
    #expect(startDiagnostics.isEmpty)
    #expect(start.translation == SIMD3<Float>(0, 0, -1))
    #expect(columnwiseEqual(Transform.rotation(start.rotationQuaternion), point0Rotation))

    // Straight 2-unit segment at speed 2: the recovered PathLength quirk
    // re-runs the control-point generator over the already-padded array, so
    // the segment times at 3 s and 1.5 s sits at the midpoint.
    let (mid, midDiagnostics) = SourceStudioRoutePlayback.childRootWorld(
        route: record, routeWorld: matrix_identity_float4x4, pointLocals: locals, elapsed: 1.5)
    #expect(midDiagnostics.isEmpty)
    #expect(approximately(mid.translation, SIMD3<Float>(1, 0, -1)))
    #expect(columnwiseEqual(Transform.rotation(mid.rotationQuaternion), point0Rotation))
    #expect(approximately(mid.scaleFactors, SIMD3<Float>(repeating: 1)))
}

@Test("orient-to-path replaces childRoot rotation with the evaluator aim")
func orientToPathUsesAim() throws {
    // Facing Unity +x is a 90-degree yaw; converted, it is the expected rotation.
    let expectedYaw = Transform.rotation(UnityCoordinates.eulerDegrees(SIMD3<Float>(0, 90, 0)))
    for orientation in [Int32(1), Int32(2)] {  // xy and y; the path is horizontal so both aim +x
        let record = routeRecord([routePoint([0, 0, 1]), routePoint([2, 0, 1])], orientation: orientation)
        // 1.5 s is the midpoint of the 3 s (PathLength-quirk) segment.
        let (mid, diagnostics) = SourceStudioRoutePlayback.childRootWorld(
            route: record, routeWorld: matrix_identity_float4x4,
            pointLocals: SourceStudioRoutePlayback.pointLocals(from: record), elapsed: 1.5)
        #expect(diagnostics.isEmpty, "orientation \(orientation)")
        #expect(approximately(mid.translation, SIMD3<Float>(1, 0, -1)), "orientation \(orientation)")
        #expect(columnwiseEqual(Transform.rotation(mid.rotationQuaternion), expectedYaw),
                "orientation \(orientation) must face the lookahead")
    }
}

@Test("a non-looping route holds its end position and last aim after finishing")
func nonLoopHoldsEnd() throws {
    let record = routeRecord([routePoint([0, 0, 1]), routePoint([2, 0, 1])],
                             loop: false, orientation: 1)
    let locals = SourceStudioRoutePlayback.pointLocals(from: record)
    let (ended, endDiagnostics) = SourceStudioRoutePlayback.childRootWorld(
        route: record, routeWorld: matrix_identity_float4x4, pointLocals: locals, elapsed: 5)
    #expect(ended.translation == SIMD3<Float>(2, 0, -1))
    // At percentage 1 the lookahead clamps onto the finished position and the
    // instantaneous aim is degenerate, but `onComplete` only deactivates the
    // route: `childRoot` keeps the last non-degenerate aim rotation, which the
    // playback layer reproduces from the final segment at `1 - lookAhead`.
    // Here that faces Unity +x — a 90-degree yaw, the same as mid-flight.
    #expect(endDiagnostics.isEmpty)
    let expectedYaw = Transform.rotation(UnityCoordinates.eulerDegrees(SIMD3<Float>(0, 90, 0)))
    #expect(columnwiseEqual(Transform.rotation(ended.rotationQuaternion), expectedYaw))
    // 3.05 s is just past this route's 3 s (PathLength-quirk) total.
    let (justAfter, _) = SourceStudioRoutePlayback.childRootWorld(
        route: record, routeWorld: matrix_identity_float4x4, pointLocals: locals, elapsed: 3.05)
    #expect(columnwiseEqual(justAfter, ended, tolerance: 0.001))
}

@Test("isFinished reports the onComplete of a non-looping route")
func isFinishedReportsOnComplete() throws {
    let record = routeRecord([routePoint([0, 0, 1]), routePoint([2, 0, 1])],
                             loop: false, orientation: 1)
    let locals = SourceStudioRoutePlayback.pointLocals(from: record)
    func finished(_ elapsed: Double) -> Bool {
        SourceStudioRoutePlayback.isFinished(route: record, routeWorld: matrix_identity_float4x4,
                                             pointLocals: locals, elapsed: elapsed)
    }
    #expect(!finished(0))
    #expect(!finished(1.5))     // mid-flight on the 3 s (PathLength-quirk) segment
    #expect(finished(3.05))     // onComplete has fired
    #expect(finished(5))
    #expect(!finished(-1))      // treated as 0, like childRootWorld
    // A looping route never finishes, and an unplayable route reports no
    // finish beyond what the record itself says.
    let looping = routeRecord([routePoint([0, 0, 1]), routePoint([2, 0, 1])],
                              loop: true, orientation: 1)
    #expect(!SourceStudioRoutePlayback.isFinished(route: looping, routeWorld: matrix_identity_float4x4,
                                                  pointLocals: SourceStudioRoutePlayback.pointLocals(from: looping),
                                                  elapsed: 100))
    let unplayable = routeRecord([routePoint([1, 0, 1]), routePoint([1, 0, 1])], loop: false)
    #expect(!SourceStudioRoutePlayback.isFinished(route: unplayable, routeWorld: matrix_identity_float4x4,
                                                  pointLocals: SourceStudioRoutePlayback.pointLocals(from: unplayable),
                                                  elapsed: 10))
}

@Test("a looping route wraps elapsed time past one circuit")
func loopWraps() throws {
    let record = routeRecord([routePoint([0, 0, 0]), routePoint([2, 0, 0]), routePoint([2, 2, 0])], loop: true)
    let route = try SourceStudioRoute(record: record)
    let total = try route.segments().reduce(0) { $0 + $1.duration }
    let locals = SourceStudioRoutePlayback.pointLocals(from: record)
    let (early, _) = SourceStudioRoutePlayback.childRootWorld(
        route: record, routeWorld: matrix_identity_float4x4, pointLocals: locals, elapsed: 0.4)
    let (wrapped, diagnostics) = SourceStudioRoutePlayback.childRootWorld(
        route: record, routeWorld: matrix_identity_float4x4, pointLocals: locals, elapsed: total + 0.4)
    #expect(diagnostics.isEmpty)
    #expect(columnwiseEqual(wrapped, early, tolerance: 0.0001))
    // 0.4 s is inside the first straight segment (3 s with the PathLength
    // quirk, so it is 0.4/3 of the way along its 2-unit run).
    #expect(approximately(early.translation, SIMD3<Float>(2 * (0.4 / 3), 0, 0)))
}

@Test("invalid elapsed time is reported and treated as zero")
func invalidElapsedClampsToZero() throws {
    let record = routeRecord([routePoint([0, 0, 1]), routePoint([2, 0, 1])])
    let locals = SourceStudioRoutePlayback.pointLocals(from: record)
    let (atZero, zeroDiagnostics) = SourceStudioRoutePlayback.childRootWorld(
        route: record, routeWorld: matrix_identity_float4x4, pointLocals: locals, elapsed: 0)
    #expect(zeroDiagnostics.isEmpty)
    for elapsed in [-1, -0.5, Double.nan, Double.infinity, -Double.infinity] {
        let (clamped, diagnostics) = SourceStudioRoutePlayback.childRootWorld(
            route: record, routeWorld: matrix_identity_float4x4, pointLocals: locals, elapsed: elapsed)
        #expect(diagnostics.contains { $0.contains("treated as 0") }, "\(elapsed)")
        #expect(columnwiseEqual(clamped, atZero), "\(elapsed)")
    }
}

@Test("a mismatched point-local count is reported and replaced by the record's authored transforms")
func mismatchedLocalsFallBack() throws {
    let record = routeRecord([routePoint([0, 0, 1]), routePoint([2, 0, 1])])
    let authored = SourceStudioRoutePlayback.pointLocals(from: record)
    let (expected, _) = SourceStudioRoutePlayback.childRootWorld(
        route: record, routeWorld: matrix_identity_float4x4, pointLocals: authored, elapsed: 0.5)
    let (reported, diagnostics) = SourceStudioRoutePlayback.childRootWorld(
        route: record, routeWorld: matrix_identity_float4x4, pointLocals: [authored[0]], elapsed: 0.5)
    #expect(diagnostics.contains { $0.contains("1 point locals for 2 route points") })
    #expect(columnwiseEqual(reported, expected))
}

@Test("an unplayable active route is reported and stays pinned to point 0")
func unplayableActiveRoutePins() throws {
    // Coincident points: the segment has no playable duration.
    let record = routeRecord([routePoint([1, 2, 3]), routePoint([1, 2, 3])], active: true, loop: true)
    let (pinned, diagnostics) = SourceStudioRoutePlayback.childRootWorld(
        route: record, routeWorld: matrix_identity_float4x4,
        pointLocals: SourceStudioRoutePlayback.pointLocals(from: record), elapsed: 1)
    #expect(diagnostics.contains { $0.contains("no playable duration") })
    #expect(diagnostics.contains { $0.contains("pinned to point 0") })
    #expect(pinned.translation == SIMD3<Float>(1, 2, -3))
    // Unknown orientation ordinals must not become an implicit "none".
    let badOrient = routeRecord([routePoint([0, 0, 1]), routePoint([2, 0, 1])], orientation: 7)
    let (badPinned, badDiagnostics) = SourceStudioRoutePlayback.childRootWorld(
        route: badOrient, routeWorld: matrix_identity_float4x4,
        pointLocals: SourceStudioRoutePlayback.pointLocals(from: badOrient), elapsed: 1)
    #expect(badDiagnostics.contains { $0.contains("unknown orientation 7") })
    #expect(badPinned.translation == SIMD3<Float>(0, 0, -1))
}

@Test("the pin, moving placement, held end, and unplayable pin keep the route's world scale")
func placementsKeepWorldScale() throws {
    let record = routeRecord([routePoint([0, 0, 1]), routePoint([2, 0, 1])])
    // Point 0's own scale must not replace the scale inherited from the route.
    let locals = [nativeTRS([0, 0, 1], scale: SIMD3<Float>(repeating: 3)), nativeTRS([2, 0, 1])]
    let scaled = Transform.scale(SIMD3<Float>(repeating: 2))
    let expectedScale = SIMD3<Float>(repeating: 2)
    let (pinned, pinDiagnostics) = SourceStudioRoutePlayback.childRootWorld(
        route: .init(points: record.points, active: false, loop: record.loop, visibleLine: record.visibleLine,
                     orientation: record.orientation, color: record.color),
        routeWorld: scaled, pointLocals: locals, elapsed: 0)
    #expect(pinDiagnostics.isEmpty)
    #expect(approximately(pinned.scaleFactors, expectedScale))
    let (played, playDiagnostics) = SourceStudioRoutePlayback.childRootWorld(
        route: record, routeWorld: scaled, pointLocals: locals, elapsed: 0.5)
    #expect(playDiagnostics.isEmpty)
    #expect(approximately(played.scaleFactors, expectedScale))
    let (held, _) = SourceStudioRoutePlayback.childRootWorld(
        route: record, routeWorld: scaled, pointLocals: locals, elapsed: 5)
    #expect(approximately(held.scaleFactors, expectedScale))

    let unplayable = routeRecord([routePoint([0, 0, 1]), routePoint([0, 0, 1])])
    let (unplayablePin, diagnostics) = SourceStudioRoutePlayback.childRootWorld(
        route: unplayable, routeWorld: scaled,
        pointLocals: SourceStudioRoutePlayback.pointLocals(from: unplayable), elapsed: 1)
    #expect(diagnostics.contains { $0.contains("no playable duration") })
    #expect(approximately(unplayablePin.scaleFactors, expectedScale))
}

@Test("the playback aid composes through the curve point's local transform")
func playbackAidComposesThroughPointLocal() throws {
    // Route IKKOKU-B point dicKey 8 as captured from the original: the aid
    // transform is Point-local under a point rotated -15 degrees about Y, so
    // the curve must bend through the composed route-local aid.
    let record = routeRecord([
        routePoint([0.8, 0.2, 0.6], rotation: SIMD3(0, -15, 0), aid: SIMD3(-0.2683783, 0.675, -0.3895974),
                   connection: 1),
        routePoint([2, 0.4, 0]),
    ])
    // The evaluator runs in Unity route-local space; the route-local aid
    // verified against the original capture for this point is
    // (0.6416017, 0.875, 0.1542164).
    let expected = try SourceStudioRoute(points: [
        .init(position: [0.8, 0.2, 0.6], aid: [0.6416017, 0.875, 0.1542164], connection: .curve),
        .init(position: [2, 0.4, 0]),
    ], loop: false).evaluate(at: 1).position
    let expectedTranslation = UnityCoordinates.position(SIMD3<Float>(Float(expected.x), Float(expected.y), Float(expected.z)))
    let (played, diagnostics) = SourceStudioRoutePlayback.childRootWorld(
        route: record, routeWorld: matrix_identity_float4x4,
        pointLocals: SourceStudioRoutePlayback.pointLocals(from: record), elapsed: 1)
    #expect(diagnostics.isEmpty)
    #expect(approximately(played.translation, expectedTranslation, tolerance: 0.00001))

    // The pre-fix composition used the raw Point-local aid, which bends the
    // curve far away: 1 s is inside this segment, so the expectation above
    // must not coincide with the buggy placement.
    let buggy = try SourceStudioRoute(points: [
        .init(position: [0.8, 0.2, 0.6], aid: [-0.2683783, 0.675, -0.3895974], connection: .curve),
        .init(position: [2, 0.4, 0]),
    ], loop: false).evaluate(at: 1).position
    let buggyTranslation = SIMD3<Float>(Float(buggy.x), Float(buggy.y), -Float(buggy.z))
    #expect(simd_distance(played.translation, buggyTranslation) > 0.1)
}

@Test("snapshot sampling pins the fixture scene's inactive route to its first point")
func samplesPinFixtureRoute() throws {
    let input = SceneDocumentBytes.scene()
    let snapshot = try KoikatsuSceneReader.decodeDocument(input.data).snapshot
    let samples = SourceStudioRoutePlayback.samples(in: snapshot, elapsed: 0.5)
    #expect(samples.count == 1)
    let sample = try #require(samples.first)
    #expect(sample.sourceKey == 20 && sample.name == "Route")
    #expect(!sample.active && sample.loop && sample.visibleLine)
    #expect(sample.orientation == 2 && sample.pointCount == 2)
    #expect(sample.diagnostics.isEmpty)
    // Route object and point 0 share the fixture transform [1,2,3] rot [0,15,0];
    // the sample reports their composed world position and rotation.
    let placement = nativeTRS([1, 2, 3], rotation: SIMD3(0, 15, 0))
    let expected = placement * placement
    // The sample reports the Unity-space position, hence the reflection back.
    #expect(columnwiseEqual(Transform.translation(sample.childRootPosition),
                            Transform.translation(UnityCoordinates.position(expected.translation)),
                            tolerance: 0.001))
    #expect(columnwiseEqual(Transform.rotation(UnityCoordinates.eulerDegrees(sample.childRootRotationEulerZXY)),
                            Transform.rotation(expected.rotationQuaternion), tolerance: 0.001))
}

@Test("activeOverride replaces the record's saved active flag")
func activeOverrideReplacesRecordFlag() throws {
    let points = [routePoint([0, 0, 1]), routePoint([2, 0, 1])]
    let locals = SourceStudioRoutePlayback.pointLocals(from: routeRecord(points))
    let stopped = routeRecord(points, active: false)
    let playing = routeRecord(points, active: true)
    // A record-inactive route the user pressed Play on evaluates like the
    // record-active copy at the same elapsed time (mid-segment at 1.5 s).
    let (played, playDiagnostics) = SourceStudioRoutePlayback.childRootWorld(
        route: stopped, routeWorld: matrix_identity_float4x4, pointLocals: locals,
        elapsed: 1.5, activeOverride: true)
    #expect(playDiagnostics.isEmpty)
    #expect(approximately(played.translation, SIMD3<Float>(1, 0, -1)))
    let (recorded, _) = SourceStudioRoutePlayback.childRootWorld(
        route: playing, routeWorld: matrix_identity_float4x4, pointLocals: locals, elapsed: 1.5)
    #expect(columnwiseEqual(played, recorded))
    // A nil override keeps the record; a false override pins a record-active
    // route to point 0, like `Stop`.
    let (recordInactive, _) = SourceStudioRoutePlayback.childRootWorld(
        route: stopped, routeWorld: matrix_identity_float4x4, pointLocals: locals, elapsed: 1.5)
    #expect(columnwiseEqual(recordInactive, Transform.translation(SIMD3<Float>(0, 0, -1))))
    let (stoppedActive, stopDiagnostics) = SourceStudioRoutePlayback.childRootWorld(
        route: playing, routeWorld: matrix_identity_float4x4, pointLocals: locals,
        elapsed: 1.5, activeOverride: false)
    #expect(stopDiagnostics.isEmpty)
    #expect(columnwiseEqual(stoppedActive, recordInactive))
}
