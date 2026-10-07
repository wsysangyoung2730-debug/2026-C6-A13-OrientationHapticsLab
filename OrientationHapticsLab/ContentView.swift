import SwiftUI
import OrientationCore

struct ContentView: View {
    @StateObject private var model = LabModel()
    @Environment(\.scenePhase) private var scenePhase
    @State private var simulatedHeading = 0.0

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 20) {
                    Text("사이클 \(model.cycleNumber)")
                        .font(.subheadline.monospacedDigit()).foregroundStyle(.secondary)
                    VStack(spacing: 8) {
                        Text(model.isCalibrated ? model.directionLabel : "기준 설정 대기")
                            .font(.title2.bold())
                        Text(model.isCalibrated ? "\(abs(model.relativeDegrees), specifier: "%.0f")°" : "—°")
                            .font(.system(size: 88, weight: .bold, design: .rounded))
                            .monospacedDigit().minimumScaleFactor(0.5).lineLimit(1)
                        Text(model.status).font(.subheadline).multilineTextAlignment(.center)
                    }
                    .frame(maxWidth: .infinity).padding(24)
                    .background(.background, in: RoundedRectangle(cornerRadius: 24))
                    HapticStatusView(haptics: model.haptics)
                    Button { model.reset() } label: {
                        Label("현재 방향을 0°로 리셋", systemImage: "scope")
                            .font(.title3.bold()).frame(maxWidth: .infinity).padding(.vertical, 16)
                    }
                    .buttonStyle(.borderedProminent).disabled(!model.canReset)
                    .accessibilityHint("현재 방향을 기준으로 새 측정 사이클을 시작합니다.")
                    Button(model.isRunning ? "측정 중지" : "측정 시작") {
                        if model.isRunning { model.stop() } else { model.start() }
                    }.buttonStyle(.bordered)
                    WalkMetricsView(snapshot: model.walk, status: model.stepStatus)
                    GroupBox("각도 신호 체험") {
                        VStack(spacing: 12) {
                            ForEach(AngleCue.defaults) { cue in
                                HStack {
                                    Toggle(cue.label, isOn: Binding(
                                        get: { model.enabledAngles.contains(cue.id) },
                                        set: { model.setEnabled(cue.id, enabled: $0) }))
                                    Button("체험") { model.preview(cue) }
                                        .accessibilityLabel("\(cue.label) 진동 체험")
                                        .buttonStyle(.bordered)
                                }
                            }
                        }
                    }
                    if model.isSimulation {
                        GroupBox("시뮬레이터 화면 미리보기 · 실제 진동 없음") {
                            Slider(value: $simulatedHeading, in: -180...180, step: 1)
                                .onChange(of: simulatedHeading) { _, value in model.simulate(heading: value) }
                            Text("가상 방향 \(simulatedHeading, specifier: "%.0f")°")
                        }
                    }
                    Text("배 앞쪽 허리 · 세로 고정 · 화면 바깥쪽\n측정 중에는 앱을 열고 화면을 켜 두세요.")
                        .font(.footnote).foregroundStyle(.secondary).multilineTextAlignment(.center)
                }
                .padding()
            }
            .background(Color(.systemGroupedBackground))
            .navigationTitle("방향 진동 실험")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    NavigationLink { LogsView(store: model.sessionStore) } label: {
                        Label("로그", systemImage: "clock.arrow.circlepath")
                    }
                }
            }
        }
        .task { model.start() }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active { model.start() }
            else { model.stop(reason: .appInterrupted) }
        }
    }
}

struct HapticStatusView: View {
    @ObservedObject var haptics: HapticService
    var body: some View {
        VStack(spacing: 4) {
            Text(haptics.currentlyPlaying.map { "신호: \($0)" } ?? "각도 신호 대기")
                .font(.headline)
            Text(haptics.lastError ?? haptics.status)
                .font(.caption).foregroundStyle(.secondary)
        }
        .accessibilityElement(children: .combine)
    }
}
