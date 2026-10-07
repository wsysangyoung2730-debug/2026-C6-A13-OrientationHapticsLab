import CoreMotion
import Foundation
import OrientationCore

@MainActor
final class PedometerFeed {
    private let live = CMPedometer()
    private var activeCycle: UUID?
    // Each closed cycle owns its query object until completion, independent of the live pedometer.
    private var finalQueries: [UUID: CMPedometer] = [:]

    func start(
        cycleID: UUID,
        from startDate: Date,
        onSample: @escaping @MainActor (WalkingSample) -> Void,
        onStatus: @escaping @MainActor (String) -> Void
    ) {
        stop()
        guard CMPedometer.isStepCountingAvailable() else {
            onStatus("걸음 센서 미지원 · 방향 측정은 계속됩니다.")
            return
        }
        switch CMPedometer.authorizationStatus() {
        case .denied, .restricted:
            onStatus("걸음 권한 없음 · 설정의 동작 및 피트니스에서 허용할 수 있어요. 방향 측정은 계속됩니다.")
            return
        case .notDetermined, .authorized:
            break
        @unknown default:
            break
        }
        activeCycle = cycleID
        onStatus("걸음 센서 준비 중 · 처리된 자료는 늦게 도착할 수 있어요.")
        live.startUpdates(from: startDate) { [weak self] data, error in
            let message = error?.localizedDescription
            let sample = data.map {
                WalkingSample(startDate: startDate, endDate: $0.endDate,
                              steps: $0.numberOfSteps.intValue, distance: $0.distance?.doubleValue)
            }
            Task { @MainActor [weak self] in
                guard self?.activeCycle == cycleID else { return }
                if let message {
                    onStatus("걸음 수신 오류: \(message) · 방향 측정은 계속됩니다.")
                } else if let sample {
                    onSample(sample)
                    onStatus("걸음 센서 수신 중 · 마지막 수신 \(Date().formatted(date: .omitted, time: .standard))")
                }
            }
        }
    }

    func stop() {
        activeCycle = nil
        live.stopUpdates()
    }

    func queryFinal(
        cycleID: UUID,
        from startDate: Date,
        to endDate: Date,
        completion: @escaping @MainActor (WalkingSample?, String?) -> Void
    ) {
        guard CMPedometer.isStepCountingAvailable(),
              CMPedometer.authorizationStatus() == .authorized,
              endDate > startDate else {
            completion(nil, "종료 시 수신값 · 걸음 최종 조회 불가")
            return
        }
        let query = CMPedometer()
        finalQueries[cycleID] = query
        query.queryPedometerData(from: startDate, to: endDate) { [weak self] data, error in
            let message = error?.localizedDescription
            let sample = data.map {
                // Query dates bound the completed cycle; never use the time this callback arrives.
                WalkingSample(startDate: startDate, endDate: endDate,
                              steps: $0.numberOfSteps.intValue, distance: $0.distance?.doubleValue)
            }
            Task { @MainActor [weak self] in
                guard let self, self.finalQueries.removeValue(forKey: cycleID) != nil else { return }
                completion(sample, message.map { "종료 시 수신값 · 최종 조회 오류: \($0)" })
            }
        }
    }
}
