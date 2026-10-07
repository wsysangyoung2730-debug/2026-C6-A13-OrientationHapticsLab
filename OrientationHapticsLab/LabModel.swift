import Combine
import Foundation
import OrientationCore
import UIKit

@MainActor
final class LabModel: ObservableObject {
    let haptics = HapticService()
    @Published private(set) var relativeDegrees: Double = 0
    @Published private(set) var continuousDegrees: Double = 0
    @Published private(set) var isCalibrated = false
    @Published private(set) var isRunning = false
    @Published private(set) var canReset = false
    @Published private(set) var status = "아이폰을 허리에 세로로 고정해 주세요."
    @Published private(set) var cycleNumber = 0
    @Published private(set) var lastSignal = "아직 신호 없음"
    @Published private(set) var enabledAngles = Set(AngleCue.defaults.map(\.id))
    private let feed = MotionFeed()
    private var tracker = RelativeHeadingTracker()
    private var detector = AngleLandmarkDetector()
    private var latestSample: HeadingSample?
    private var watchdog: Task<Void, Never>?
    private var editing = false

    var isSimulation: Bool {
        #if targetEnvironment(simulator)
        true
        #else
        false
        #endif
    }

    var directionLabel: String {
        abs(relativeDegrees) < 0.5 ? "정면" : relativeDegrees < 0 ? "왼쪽" : "오른쪽"
    }

    func start() {
        guard !isRunning else { return }
        isRunning = true
        UIApplication.shared.isIdleTimerDisabled = true
        haptics.prepare()
        if isSimulation {
            simulate(heading: 0)
            status = "시뮬레이터 · 화면과 각도 계산만 미리보기"
            return
        }
        status = "방향 센서 준비 중"
        feed.start(onSample: { [weak self] sample in self?.consume(sample) },
                   onError: { [weak self] error in self?.sensorFailed(error) })
        watchdog = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(500))
                guard !Task.isCancelled, let self else { return }
                if let sample = self.latestSample, Date().timeIntervalSince(sample.receivedAt) > 1 {
                    self.invalidateReference(message: "방향 수신이 끊겼어요. 다시 기준을 설정해 주세요.")
                    self.latestSample = nil
                }
            }
        }
    }

    func stop() {
        feed.stop()
        watchdog?.cancel()
        watchdog = nil
        haptics.stop()
        isRunning = false
        latestSample = nil
        invalidateReference(message: "측정 중지 · 시작 후 기준을 다시 설정해 주세요.")
        UIApplication.shared.isIdleTimerDisabled = false
    }

    func reset() {
        guard isRunning, let sample = latestSample, let heading = sample.heading,
              isSimulation || Date().timeIntervalSince(sample.receivedAt) < 0.5,
              tracker.reset(absoluteHeadingDegrees: heading) != nil else {
            status = "안정적인 방향을 받은 후 다시 눌러 주세요."
            return
        }
        haptics.stop()
        detector.reset()
        _ = detector.update(relativeDegrees: 0)
        relativeDegrees = 0
        continuousDegrees = 0
        cycleNumber += 1
        isCalibrated = true
        status = "현재 방향을 0°로 설정했어요."
        lastSignal = "기준 방향 리셋"
        haptics.playReset()
    }

    func setEnabled(_ angle: Int, enabled: Bool) {
        if enabled { enabledAngles.insert(angle) } else { enabledAngles.remove(angle) }
        detector.setCues(AngleCue.defaults.filter { enabledAngles.contains($0.id) })
        if isCalibrated { _ = detector.update(relativeDegrees: relativeDegrees) }
    }

    func setEditing(_ value: Bool) {
        editing = value
        haptics.stop()
        detector.reset()
        if !value, isCalibrated { _ = detector.update(relativeDegrees: relativeDegrees) }
    }

    func preview(_ cue: AngleCue) {
        haptics.playAngle(Double(cue.signedDegrees))
    }

    func simulate(heading: Double) {
        guard isSimulation, isRunning else { return }
        consume(HeadingSample(heading: heading, timestamp: ProcessInfo.processInfo.systemUptime, receivedAt: Date()))
    }

    private func consume(_ sample: HeadingSample) {
        guard isRunning else { return }
        if !isSimulation, let previous = latestSample, sample.timestamp - previous.timestamp > 0.5 {
            invalidateReference(message: "방향 측정이 중단됐어요. 기준을 다시 설정해 주세요.")
        }
        latestSample = sample
        guard let heading = sample.heading else {
            invalidateReference(message: "아이폰을 세로로 세워 주세요. 기준을 다시 설정해야 해요.")
            return
        }
        canReset = true
        guard let reading = tracker.update(absoluteHeadingDegrees: heading) else {
            status = "준비됨 · 현재 방향을 0°로 설정해 주세요."
            return
        }
        relativeDegrees = reading.relativeDegrees
        continuousDegrees = reading.continuousDegrees
        if !editing, let cue = detector.update(relativeDegrees: relativeDegrees) {
            lastSignal = cue.label
            haptics.playAngle(Double(cue.signedDegrees))
        }
    }

    private func sensorFailed(_ message: String) {
        stop()
        status = "센서 오류: \(message)"
    }

    private func invalidateReference(message: String) {
        tracker.clear()
        detector.reset()
        haptics.stop()
        isCalibrated = false
        canReset = false
        status = message
    }
}
