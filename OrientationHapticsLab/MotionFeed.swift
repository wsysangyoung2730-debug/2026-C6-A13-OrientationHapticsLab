import CoreMotion
import Foundation
import OrientationCore

struct HeadingSample: Sendable {
    let heading: Double?
    let timestamp: TimeInterval
    let receivedAt: Date
}

@MainActor
final class MotionFeed {
    private let manager = CMMotionManager()
    private var generation = UUID()
    var isAvailable: Bool { manager.isDeviceMotionAvailable }

    func start(onSample: @escaping @MainActor (HeadingSample) -> Void,
               onError: @escaping @MainActor (String) -> Void) {
        stop()
        guard manager.isDeviceMotionAvailable,
              CMMotionManager.availableAttitudeReferenceFrames().contains(.xArbitraryZVertical) else {
            onError("이 기기에서 방향 센서를 사용할 수 없어요.")
            return
        }
        let current = generation
        manager.deviceMotionUpdateInterval = 1.0 / 60.0
        manager.startDeviceMotionUpdates(using: .xArbitraryZVertical, to: .main) { [weak self] data, error in
            let message = error?.localizedDescription
            let sample: HeadingSample?
            if let data {
                let r = data.attitude.rotationMatrix
                let matrix = ReferenceToDeviceRotationMatrix(
                    m11: r.m11, m12: r.m12, m13: r.m13,
                    m21: r.m21, m22: r.m22, m23: r.m23,
                    m31: r.m31, m32: r.m32, m33: r.m33)
                sample = HeadingSample(
                    heading: HeadingMath.screenOutwardHeadingDegrees(referenceToDevice: matrix),
                    timestamp: data.timestamp, receivedAt: Date())
            } else { sample = nil }
            Task { @MainActor [weak self] in
                guard self?.generation == current else { return }
                if let message { onError(message) }
                else if let sample { onSample(sample) }
            }
        }
    }

    func stop() {
        generation = UUID()
        manager.stopDeviceMotionUpdates()
    }
}
