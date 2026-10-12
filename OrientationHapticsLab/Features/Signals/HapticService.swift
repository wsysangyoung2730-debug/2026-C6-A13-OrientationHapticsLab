import Combine
import CoreHaptics
import UIKit

/// Saved per angle by the app. Values remain valid after decoding and UI edits.
struct HapticConfiguration: Codable, Equatable, Sendable {
    enum Preset: String, Codable, CaseIterable, Identifiable, Sendable {
        case directional
        case single
        case double
        case triple
        case long

        var id: String { rawValue }

        var title: String {
            switch self {
            case .directional: "방향·각도 기본 리듬"
            case .single: "짧게 한 번"
            case .double: "짧게 두 번"
            case .triple: "짧게 세 번"
            case .long: "길게 한 번"
            }
        }
    }

    var preset: Preset
    var intensity: Double {
        didSet { intensity = Self.bounded(intensity, fallback: 0.9) }
    }
    var sharpness: Double {
        didSet { sharpness = Self.bounded(sharpness, fallback: 0.8) }
    }

    init(preset: Preset = .directional, intensity: Double = 1.0, sharpness: Double = 0.8) {
        self.preset = preset
        self.intensity = Self.bounded(intensity, fallback: 0.9)
        self.sharpness = Self.bounded(sharpness, fallback: 0.8)
    }

    var describe: String {
        "\(preset.title) · 세기 \(Int((intensity * 100).rounded()))% · 선명도 \(Int((sharpness * 100).rounded()))%"
    }

    private enum CodingKeys: String, CodingKey { case preset, intensity, sharpness }

    init(from decoder: any Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            preset: try values.decode(Preset.self, forKey: .preset),
            intensity: try values.decode(Double.self, forKey: .intensity),
            sharpness: try values.decode(Double.self, forKey: .sharpness)
        )
    }

    private static func bounded(_ value: Double, fallback: Double) -> Double {
        value.isFinite ? min(1, max(0, value)) : fallback
    }
}

/// Queues a signal without waiting for the hardware. Published playback begins on driver acceptance.
@MainActor
final class HapticService: ObservableObject {
    let supportsHaptics: Bool
    @Published private(set) var isReady = false
    @Published private(set) var status = "진동 준비 중"
    @Published private(set) var currentlyPlaying: String?
    @Published private(set) var currentlyPlayingAngle: Double?
    @Published private(set) var lastError: String?
    static let resetPatternDescription = "긴 진동 한 번 (0.70초)"

    private let driver: any HapticDriving
    private var revision: UInt = 0
    private var pendingLabel: String?
    private var pendingAngle: Double?
    private var timeout: Task<Void, Never>?
    private var isForeground: Bool
    private let responseTimeout: Duration
    private var subscriptions = Set<AnyCancellable>()

    init(driver: any HapticDriving = HapticEngineDriver(), supportsHaptics: Bool? = nil,
         isForeground: Bool? = nil, responseTimeout: Duration = .seconds(3)) {
        self.driver = driver
        self.supportsHaptics = supportsHaptics ?? CHHapticEngine.capabilitiesForHardware().supportsHaptics
        self.isForeground = isForeground ?? (UIApplication.shared.applicationState == .active)
        self.responseTimeout = responseTimeout
        NotificationCenter.default.publisher(for: UIApplication.willResignActiveNotification)
            .sink { @Sendable [weak self] _ in Task { @MainActor [weak self] in self?.suspend() } }
            .store(in: &subscriptions)
        NotificationCenter.default.publisher(for: UIApplication.didBecomeActiveNotification)
            .sink { @Sendable [weak self] _ in Task { @MainActor [weak self] in self?.isForeground = true } }
            .store(in: &subscriptions)
        if !self.supportsHaptics { status = "이 기기는 진동을 지원하지 않아요." }
    }

    func prepare() {
        guard supportsHaptics, isForeground, pendingLabel == nil, !isReady else { return }
        revision &+= 1
        let token = revision
        status = "진동 준비 중"
        armTimeout(token)
        let callback = makeReply()
        Task { await driver.prepare(revision: token, reply: callback) }
    }

    @discardableResult
    func playAngle(_ signedDegrees: Double, configuration: HapticConfiguration? = nil) -> Bool {
        guard let magnitude = Self.supportedMagnitude(signedDegrees) else {
            stop()
            lastError = "지원하는 각도는 0°, 45°, 90°, 135°, 180°입니다."
            return false
        }
        let label = magnitude == 0 ? "정면 0°" : magnitude == 180 ? "180°" : "\(signedDegrees < 0 ? "왼쪽" : "오른쪽") \(magnitude)°"
        return play(events: Self.configuredEvents(isLeft: signedDegrees < 0, magnitude: magnitude,
                   configuration: configuration ?? Self.defaultConfiguration(for: signedDegrees)),
                    label: label, angle: signedDegrees)
    }

    @discardableResult
    func playReset() -> Bool {
        play(events: [Self.pulse(at: 0, duration: 0.70, intensity: 1.0, sharpness: 0.6)],
             label: "기준 방향 리셋")
    }

    /// Cancel only the current signal; normal resets must reuse the prepared engine.
    func stop() { cancel(suspend: false) }

    private func suspend() {
        isForeground = false
        cancel(suspend: true)
    }

    private func cancel(suspend: Bool) {
        revision &+= 1
        let token = revision
        clearPlayback()
        if suspend { isReady = false }
        status = supportsHaptics ? "진동 중지됨" : "이 기기는 진동을 지원하지 않아요."
        Task { await driver.cancel(revision: token, suspend: suspend) }
    }

    private func play(events: [HapticPulse], label: String, angle: Double? = nil) -> Bool {
        guard supportsHaptics, isForeground else {
            status = supportsHaptics ? "진동 보류 · 앱을 화면에 열어 주세요" : "진동 미지원 · 실제 아이폰에서 확인 필요"
            return false
        }
        revision &+= 1
        let token = revision
        clearPlayback()
        pendingLabel = label
        pendingAngle = angle
        lastError = nil
        status = "진동 신호 준비 중"
        armTimeout(token)
        let callback = makeReply()
        Task { await driver.play(events, revision: token, reply: callback) }
        return true
    }

    private func makeReply() -> HapticReply {
        { [weak self] token, event in
            Task { @MainActor [weak self] in self?.receive(token: token, event: event) }
        }
    }

    private func receive(token: UInt, event: HapticDriverEvent) {
        guard token == revision else { return }
        switch event {
        case .ready:
            isReady = true
            if pendingLabel == nil { timeout?.cancel(); status = "진동 준비됨" }
        case .playing:
            isReady = true
            currentlyPlaying = pendingLabel
            currentlyPlayingAngle = pendingAngle
            status = "진동 재생 중"
        case .finished:
            clearPlayback()
            status = "진동 준비됨"
        case .failed(let message):
            clearPlayback()
            isReady = false
            lastError = message
            status = "진동 재생 실패"
        }
    }

    private func armTimeout(_ token: UInt) {
        timeout?.cancel()
        timeout = Task { [weak self, responseTimeout] in
            try? await Task.sleep(for: responseTimeout)
            guard !Task.isCancelled, let self, self.revision == token else { return }
            self.cancel(suspend: true)
            self.lastError = "진동 장치의 응답이 늦어 신호를 취소했어요. 측정은 계속됩니다."
            self.status = "진동 응답 지연"
        }
    }

    private func clearPlayback() {
        timeout?.cancel()
        timeout = nil
        pendingLabel = nil
        pendingAngle = nil
        currentlyPlaying = nil
        currentlyPlayingAngle = nil
    }

    static func defaultConfiguration(for signedDegrees: Double) -> HapticConfiguration {
        return HapticConfiguration(preset: .directional, intensity: 1.0, sharpness: 0.85)
    }

    static func patternDescription(for signedDegrees: Double, configuration: HapticConfiguration? = nil) -> String {
        if let configuration, configuration.preset != .directional {
            return configuration.describe
        }
        guard let magnitude = supportedMagnitude(signedDegrees) else { return "지원하지 않는 각도" }
        switch magnitude {
        case 0, 180: return "긴 진동 한 번"
        case 45: return "진동 한 번"
        case 90: return "진동 두 번"
        case 135: return "진동 세 번"
        default: return "진동"
        }
    }

    private static func supportedMagnitude(_ value: Double) -> Int? {
        guard value.isFinite else { return nil }
        return [0, 45, 90, 135, 180].first { abs(abs(value) - Double($0)) < 0.001 }
    }

    private static func configuredEvents(
        isLeft: Bool,
        magnitude: Int,
        configuration: HapticConfiguration
    ) -> [HapticPulse] {
        let intensity = Float(configuration.intensity)
        let sharpness = Float(configuration.sharpness)
        switch configuration.preset {
        case .directional:
            // 0도와 180도는 긴 진동
            // 45도(315도) 1번, 90도(270도) 2번, 135도(225도) 3번
            switch magnitude {
            case 0, 180:
                return [pulse(at: 0, duration: 0.70, intensity: intensity, sharpness: sharpness)]
            case 45:
                return [pulse(at: 0, duration: 0.12, intensity: intensity, sharpness: sharpness)]
            case 90:
                let interval = 0.25
                return (0..<2).map { index in
                    pulse(at: Double(index) * interval, duration: 0.12, intensity: intensity, sharpness: sharpness)
                }
            case 135:
                let interval = 0.25
                return (0..<3).map { index in
                    pulse(at: Double(index) * interval, duration: 0.12, intensity: intensity, sharpness: sharpness)
                }
            default:
                return [pulse(at: 0, duration: 0.12, intensity: intensity, sharpness: sharpness)]
            }
        case .single:
            return [pulse(at: 0, duration: 0.15, intensity: intensity, sharpness: sharpness)]
        case .double, .triple:
            let count = configuration.preset == .double ? 2 : 3
            return (0..<count).map { index in
                pulse(at: Double(index) * 0.22, duration: 0.10, intensity: intensity, sharpness: sharpness)
            }
        case .long:
            return [pulse(at: 0, duration: 0.45, intensity: intensity, sharpness: sharpness)]
        }
    }

    private static func pulse(at time: TimeInterval, duration: TimeInterval, intensity: Float, sharpness: Float) -> HapticPulse {
        HapticPulse(time: time, duration: duration, intensity: intensity, sharpness: sharpness)
    }
}
