import SwiftUI
import OrientationCore

struct ContentView: View {
    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: "location.north.circle.fill")
                .font(.system(size: 64))
                .foregroundStyle(.tint)
            Text("Orientation Haptics Lab").font(.title2.bold())
            Text("상대 방향과 진동을 검증하는 실험 앱")
                .foregroundStyle(.secondary)
        }
        .padding()
    }
}
