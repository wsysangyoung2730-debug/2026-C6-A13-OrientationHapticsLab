import XCTest
@testable import OrientationCore

final class AngleLandmarkDetectorTests: XCTestCase {
    func testFullCircleBothWaysEmitsEachDirectionOnceIncludingRearAndReturnToFront() {
        for direction in [1, -1] {
            var detector = AngleLandmarkDetector()
            _ = detector.update(relativeDegrees: 0) // Same priming as a reference reset.
            let cues = (1...360).compactMap {
                detector.update(relativeDegrees: Double($0 * direction))?.signedDegrees
            }
            let expected = direction == 1
                ? [45, 90, 135, 180, -135, -90, -45, 0]
                : [-45, -90, -135, 180, 135, 90, 45, 0]
            XCTAssertEqual(cues, expected)
            XCTAssertNil(detector.update(relativeDegrees: 0))
        }
    }

    func testDefaultLeftAndRightAnglesAndLabels() throws {
        XCTAssertEqual(AngleCue.defaults.map(\.signedDegrees), [-135, -90, -45, 0, 45, 90, 135, 180])
        XCTAssertEqual(AngleCue(signedDegrees: 0).label, "정면 0°")
        XCTAssertEqual(AngleCue(signedDegrees: -45).label, "왼쪽 45°")
        XCTAssertEqual(AngleCue(signedDegrees: 45).label, "오른쪽 45°")
        XCTAssertEqual(AngleCue(signedDegrees: 180).label, "180°")
        XCTAssertEqual(AngleCue(signedDegrees: -180).label, "180°")
        let cue = AngleCue(signedDegrees: -90)
        XCTAssertEqual(try JSONDecoder().decode(AngleCue.self, from: JSONEncoder().encode(cue)), cue)
        for angle in [-135, -90, -45, 45, 90, 135, 180] {
            var detector = AngleLandmarkDetector()
            _ = detector.update(relativeDegrees: 0)
            XCTAssertEqual(detector.update(relativeDegrees: Double(angle))?.signedDegrees, angle)
        }
        var zeroDetector = AngleLandmarkDetector()
        XCTAssertEqual(zeroDetector.update(relativeDegrees: 0)?.signedDegrees, 0)
    }

    func testEntryHysteresisAndExactThresholds() {
        var detector = AngleLandmarkDetector(cues: [.init(signedDegrees: 45)])
        _ = detector.update(relativeDegrees: 0)
        XCTAssertNil(detector.update(relativeDegrees: 41.9))
        XCTAssertEqual(detector.update(relativeDegrees: 42)?.signedDegrees, 45)
        for angle in [44.0, 45, 47, 49, 50.9, 51, 46, 42] {
            XCTAssertNil(detector.update(relativeDegrees: angle), "angle=\(angle)")
        }
        XCTAssertNil(detector.update(relativeDegrees: 38.9))
        XCTAssertNil(detector.update(relativeDegrees: 41.9))
        XCTAssertEqual(detector.update(relativeDegrees: 42)?.signedDegrees, 45)
    }

    func testCrossingOutsideWindowStillFiresAndDoesNotQueueOlderCues() {
        var detector = AngleLandmarkDetector()
        _ = detector.update(relativeDegrees: 0)
        XCTAssertEqual(detector.update(relativeDegrees: 80)?.signedDegrees, 45)
        XCTAssertNil(detector.update(relativeDegrees: 81))
        XCTAssertNil(detector.update(relativeDegrees: 82))
        // The return path crosses 45° first, then 0°; the newer 0° cue wins.
        XCTAssertEqual(detector.update(relativeDegrees: 0)?.signedDegrees, 0)
        XCTAssertNil(detector.update(relativeDegrees: 0))
        XCTAssertEqual(detector.update(relativeDegrees: -100)?.signedDegrees, -90)
        XCTAssertNil(detector.update(relativeDegrees: -101))
        XCTAssertEqual(detector.update(relativeDegrees: 0)?.signedDegrees, 0)
    }

    func testFastCrossingRearmsWhenAlreadyOutsideOuterWindow() {
        var detector = AngleLandmarkDetector(cues: [.init(signedDegrees: 45)])
        detector.update(relativeDegrees: 0)
        XCTAssertEqual(detector.update(relativeDegrees: 60)?.signedDegrees, 45)
        XCTAssertEqual(detector.update(relativeDegrees: 0)?.signedDegrees, 45)
        XCTAssertNil(detector.update(relativeDegrees: 0))
    }

    func testWrapBoundaryDoesNotCrossFrontAngles() {
        var detector = AngleLandmarkDetector()
        _ = detector.update(relativeDegrees: 0)
        XCTAssertEqual(detector.update(relativeDegrees: 180)?.signedDegrees, 180)
        XCTAssertNil(detector.update(relativeDegrees: 179))
        XCTAssertNil(detector.update(relativeDegrees: -179))
        XCTAssertNil(detector.update(relativeDegrees: -170))
        XCTAssertEqual(detector.update(relativeDegrees: -80)?.signedDegrees, -90)
        XCTAssertNil(detector.update(relativeDegrees: -79))
        XCTAssertEqual(detector.update(relativeDegrees: -20)?.signedDegrees, -45)
    }

    func testFullTurnCanReachSameDirectionAgain() {
        var detector = AngleLandmarkDetector(cues: [.init(signedDegrees: 45)])
        detector.update(relativeDegrees: 0)
        XCTAssertEqual(detector.update(relativeDegrees: 45)?.signedDegrees, 45)
        for angle in [90.0, 179, -90, 0] {
            XCTAssertNil(detector.update(relativeDegrees: angle))
        }
        XCTAssertEqual(detector.update(relativeDegrees: 45)?.signedDegrees, 45)
    }

    func testResetClearsLatchesAndInterpolation() {
        var detector = AngleLandmarkDetector()
        _ = detector.update(relativeDegrees: 0)
        XCTAssertEqual(detector.update(relativeDegrees: 45)?.signedDegrees, 45)
        XCTAssertNil(detector.update(relativeDegrees: 45))
        detector.reset()
        _ = detector.update(relativeDegrees: 0)
        XCTAssertEqual(detector.update(relativeDegrees: 45)?.signedDegrees, 45)
        detector.reset()
        XCTAssertNil(detector.update(relativeDegrees: -100))
    }

    func testInvalidReadingBreaksInterpolationWithoutReplayingLatchedCue() {
        var detector = AngleLandmarkDetector(cues: [.init(signedDegrees: 45)])
        detector.update(relativeDegrees: 0)
        XCTAssertNil(detector.update(relativeDegrees: .nan))
        XCTAssertNil(detector.update(relativeDegrees: 60))
        XCTAssertEqual(detector.update(relativeDegrees: 45)?.signedDegrees, 45)
        XCTAssertNil(detector.update(relativeDegrees: .infinity))
        XCTAssertNil(detector.update(relativeDegrees: 45))
    }

    func testSelectionChangesCannotReplayOldCrossing() {
        var detector = AngleLandmarkDetector(cues: [])
        detector.update(relativeDegrees: 0)
        detector.setCues([.init(signedDegrees: 45)])
        XCTAssertNil(detector.update(relativeDegrees: 60))
        XCTAssertEqual(detector.update(relativeDegrees: 45)?.signedDegrees, 45)
        detector.setCues([])
        XCTAssertNil(detector.update(relativeDegrees: 45))
    }

    func testInvalidCueAndToleranceInputsAreSafe() {
        XCTAssertEqual(AngleCue(signedDegrees: .min).label, "유효하지 않은 각도")
        XCTAssertGreaterThan(AngleCue(signedDegrees: .min).magnitudeDegrees, 0)
        let detector = AngleLandmarkDetector(
            cues: [0, Int.min, Int.max, 45, 45].map(AngleCue.init),
            entryToleranceDegrees: .nan,
            rearmToleranceDegrees: -1
        )
        XCTAssertEqual(detector.cues.map(\.signedDegrees), [0, 45])
        XCTAssertEqual(detector.entryToleranceDegrees, 3)
        XCTAssertEqual(detector.rearmToleranceDegrees, 6)
    }
}
