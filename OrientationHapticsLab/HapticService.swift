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

    init(preset: Preset = .directional, intensity: Double = 0.9, sharpness: Double = 0.8) {
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

/// Sends haptic commands; Core Haptics cannot confirm that a wearer felt them.
@MainActor
final class HapticService: ObservableObject {
    let supportsHaptics: Bool

    @Published private(set) var isReady = false
    @Published private(set) var status = "진동 준비 중"
    /// Non-nil only after the player accepts its start command. This is not a sensation sensor.
    @Published private(set) var currentlyPlaying: String?
    @Published private(set) var currentlyPlayingAngle: Double?
    @Published private(set) var lastError: String?

    static let resetPatternDescription = "부드러운 긴 진동 두 번"

    private var engine: CHHapticEngine?
    private var player: (any CHHapticAdvancedPatternPlayer)?
    private var engineGeneration: UInt = 0
    private var playbackGeneration: UInt = 0
    private var isForeground: Bool
    private var subscriptions = Set<AnyCancellable>()

    init() {
        supportsHaptics = CHHapticEngine.capabilitiesForHardware().supportsHaptics
        isForeground = UIApplication.shared.applicationState == .active

        NotificationCenter.default.publisher(for: UIApplication.willResignActiveNotification)
            .sink { [weak self] _ in
                Task { @MainActor [weak self] in self?.suspend() }
            }
            .store(in: &subscriptions)
        NotificationCenter.default.publisher(for: UIApplication.didBecomeActiveNotification)
            .sink { [weak self] _ in
                Task { @MainActor [weak self] in
                    self?.isForeground = true
                    self?.prepare()
                }
            }
            .store(in: &subscriptions)

        guard supportsHaptics else {
            status = "이 기기는 Core Haptics 진동을 지원하지 않음"
            return
        }
        // Create early, before the first angle crossing, to reduce startup latency.
        do {
            try createEngine()
            prepare()
        } catch {
            reportFailure("진동 엔진 생성 실패", error: error)
        }
    }

    /// Can also be called explicitly when beginning a measurement cycle.
    func prepare() {
        guard supportsHaptics else { return }
        guard isForeground else {
            status = "앱이 활성화되면 진동 준비"
            return
        }
        do {
            if engine == nil { try createEngine() }
            guard let engine else { return }
            // Rebind every start: an already queued stop callback belongs to the previous epoch.
            installHandlers(on: engine)
            try engine.start()
            isReady = true
            lastError = nil
            if currentlyPlaying == nil { status = "진동 준비됨" }
        } catch {
            invalidatePlayback()
            reportFailure("진동 준비 실패", error: error)
        }
    }

    /// Returns whether Core Haptics accepted a playback command, not whether it was felt.
    @discardableResult
    func playAngle(_ signedDegrees: Double, configuration: HapticConfiguration? = nil) -> Bool {
        guard let magnitude = Self.supportedMagnitude(signedDegrees) else {
            stop()
            lastError = "지원하는 각도는 왼쪽·오른쪽 30°, 45°, 90°입니다."
            status = "진동 각도 설정 오류"
            return false
        }
        let direction = signedDegrees < 0 ? "왼쪽" : "오른쪽"
        let settings = configuration ?? Self.defaultConfiguration(for: signedDegrees)
        return play(
            events: Self.configuredEvents(isLeft: signedDegrees < 0, magnitude: magnitude, configuration: settings),
            label: "\(direction) \(magnitude)°",
            signedDegrees: signedDegrees
        )
    }

    @discardableResult
    func playReset() -> Bool {
        play(events: [
            Self.pulse(at: 0, duration: 0.17, intensity: 0.85, sharpness: 0.2),
            Self.pulse(at: 0.30, duration: 0.17, intensity: 0.85, sharpness: 0.2)
        ], label: "기준 방향 리셋")
    }

    /// Cancels pending playback and releases the engine. A later prepare/play creates it again.
    func stop() {
        invalidatePlayback()
        engineGeneration &+= 1
        let oldEngine = engine
        engine = nil
        isReady = false
        oldEngine?.stop(completionHandler: nil)
        status = supportsHaptics ? "진동 중지됨" : "이 기기는 진동을 지원하지 않음"
    }

    static func defaultConfiguration(for signedDegrees: Double) -> HapticConfiguration {
        let magnitude = supportedMagnitude(signedDegrees)
        let intensity = magnitude == 30 ? 0.85 : magnitude == 45 ? 0.92 : 1.0
        return HapticConfiguration(preset: .directional, intensity: intensity, sharpness: 0.8)
    }

    static func patternDescription(for signedDegrees: Double, configuration: HapticConfiguration? = nil) -> String {
        if let configuration, configuration.preset != .directional {
            return configuration.describe
        }
        guard let magnitude = supportedMagnitude(signedDegrees) else { return "지원하지 않는 각도" }
        let prefix = signedDegrees < 0 ? "긴 진동 한 번" : "짧은 진동 두 번"
        let count = magnitude == 30 ? "한 번" : magnitude == 45 ? "두 번" : "세 번"
        return "\(prefix) 뒤, 짧은 진동 \(count)"
    }

    private func createEngine() throws {
        let newEngine = try CHHapticEngine()
        newEngine.playsHapticsOnly = true
        newEngine.isMutedForAudio = true
        newEngine.isAutoShutdownEnabled = true
        installHandlers(on: newEngine)
        engine = newEngine
    }

    private func installHandlers(on newEngine: CHHapticEngine) {
        engineGeneration &+= 1
        let generation = engineGeneration
        newEngine.stoppedHandler = { [weak self] reason in
            Task { @MainActor [weak self] in
                guard let self, self.engineGeneration == generation else { return }
                self.engineStopped(reason)
            }
        }
        newEngine.resetHandler = { [weak self] in
            Task { @MainActor [weak self] in
                guard let self, self.engineGeneration == generation else { return }
                self.invalidatePlayback()
                self.isReady = false
                self.status = "진동 엔진 복구 중"
                // Every playback creates a new player, so no pre-reset players are reused.
                if self.isForeground { self.prepare() }
            }
        }
    }

    private func play(events: [CHHapticEvent], label: String, signedDegrees: Double? = nil) -> Bool {
        // Always replace the previous signal. Do not queue obsolete angles behind it.
        invalidatePlayback()
        guard supportsHaptics else {
            status = "진동 미지원 · 실제 아이폰에서 확인 필요"
            return false
        }
        guard isForeground else {
            status = "진동 보류 · 앱을 화면에 열어 주세요"
            return false
        }
        prepare()
        guard isReady, let engine else { return false }
        let generation = playbackGeneration
        do {
            let pattern = try CHHapticPattern(events: events, parameters: [])
            let newPlayer = try engine.makeAdvancedPlayer(with: pattern)
            newPlayer.completionHandler = { [weak self] error in
                // Convert Foundation error before crossing into the main actor.
                let message = error?.localizedDescription
                Task { @MainActor [weak self] in
                    guard let self, self.playbackGeneration == generation else { return }
                    self.currentlyPlaying = nil
                    self.currentlyPlayingAngle = nil
                    self.player = nil
                    if let message {
                        self.lastError = message
                        self.status = "진동 재생 실패"
                    } else {
                        self.status = "진동 준비됨"
                    }
                }
            }
            player = newPlayer
            try newPlayer.start(atTime: CHHapticTimeImmediate)
            currentlyPlaying = label
            currentlyPlayingAngle = signedDegrees
            status = "진동 재생 중"
            lastError = nil
            return true
        } catch {
            invalidatePlayback()
            reportFailure("진동 재생 실패", error: error)
            return false
        }
    }

    private func invalidatePlayback() {
        // A cancelled player's delayed completion must never clear a newer signal.
        playbackGeneration &+= 1
        try? player?.cancel()
        player = nil
        currentlyPlaying = nil
        currentlyPlayingAngle = nil
    }

    private func suspend() {
        isForeground = false
        stop()
        if supportsHaptics { status = "진동 일시 중지 · 앱이 활성화되면 다시 준비" }
    }

    private func engineStopped(_ reason: CHHapticEngine.StoppedReason) {
        invalidatePlayback()
        isReady = false
        switch reason {
        case .applicationSuspended:
            status = "앱 비활성화로 진동 일시 중지"
        case .audioSessionInterrupt:
            status = "시스템이 진동을 중단함 · 다음 요청 때 다시 준비"
        case .idleTimeout:
            status = "진동 대기 중 · 다음 요청 때 다시 준비"
        case .notifyWhenFinished, .engineDestroyed:
            status = "진동 중지됨 · 다음 요청 때 다시 준비"
        case .gameControllerDisconnect:
            status = "진동 장치 연결 해제"
        case .systemError:
            status = "시스템 진동 오류 · 다음 요청 때 다시 준비"
            lastError = "Core Haptics 엔진이 시스템 오류로 중지되었습니다."
        @unknown default:
            status = "진동 중지됨 · 다음 요청 때 다시 준비"
        }
    }

    private func reportFailure(_ context: String, error: Error) {
        isReady = false
        currentlyPlaying = nil
        currentlyPlayingAngle = nil
        lastError = error.localizedDescription
        status = context
    }

    private static func supportedMagnitude(_ value: Double) -> Int? {
        guard value.isFinite else { return nil }
        return [30, 45, 90].first { abs(abs(value) - Double($0)) < 0.001 }
    }

    private static func configuredEvents(
        isLeft: Bool,
        magnitude: Int,
        configuration: HapticConfiguration
    ) -> [CHHapticEvent] {
        let intensity = Float(configuration.intensity)
        let sharpness = Float(configuration.sharpness)
        switch configuration.preset {
        case .directional:
            var events: [CHHapticEvent]
            if isLeft {
                events = [pulse(at: 0, duration: 0.10, intensity: intensity, sharpness: sharpness * 0.5)]
            } else {
                events = [
                    pulse(at: 0, duration: 0.03, intensity: intensity, sharpness: sharpness),
                    pulse(at: 0.06, duration: 0.03, intensity: intensity, sharpness: sharpness)
                ]
            }
            let count = magnitude == 30 ? 1 : magnitude == 45 ? 2 : 3
            for index in 0..<count {
                events.append(pulse(
                    at: 0.16 + Double(index) * 0.09,
                    duration: 0.035,
                    intensity: intensity,
                    sharpness: sharpness
                ))
            }
            return events
        case .single:
            return [pulse(at: 0, duration: 0.065, intensity: intensity, sharpness: sharpness)]
        case .double, .triple:
            let count = configuration.preset == .double ? 2 : 3
            return (0..<count).map { index in
                pulse(at: Double(index) * 0.13, duration: 0.065, intensity: intensity, sharpness: sharpness)
            }
        case .long:
            return [pulse(at: 0, duration: 0.30, intensity: intensity, sharpness: sharpness)]
        }
    }

    private static func pulse(
        at time: TimeInterval,
        duration: TimeInterval,
        intensity: Float,
        sharpness: Float
    ) -> CHHapticEvent {
        CHHapticEvent(
            eventType: .hapticContinuous,
            parameters: [
                CHHapticEventParameter(parameterID: .hapticIntensity, value: intensity),
                CHHapticEventParameter(parameterID: .hapticSharpness, value: sharpness)
            ],
            relativeTime: time,
            duration: duration
        )
    }
}
