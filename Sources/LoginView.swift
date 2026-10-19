import SwiftUI

struct LoginView: View {
    @EnvironmentObject var model: HealthModel

    var body: some View {
        ZStack {
            LinearGradient(colors: [Color(red: 0.16, green: 0.10, blue: 0.38), Color(red: 0.03, green: 0.02, blue: 0.08)],
                           startPoint: .top, endPoint: .bottom).ignoresSafeArea()
            VStack(spacing: 18) {
                Spacer()
                ZStack {
                    RingView(progress: 0.78, color: Theme.heart, lineWidth: 18).frame(width: 230, height: 230)
                    RingView(progress: 0.62, color: Color(red: 0.55, green: 0.50, blue: 1.0), lineWidth: 18).frame(width: 178, height: 178)
                    RingView(progress: 0.38, color: Color(red: 0.20, green: 0.90, blue: 0.60), lineWidth: 18).frame(width: 126, height: 126)
                }
                .padding(.bottom, 12)
                Text("Tu pulsera,\nde un vistazo.").font(.system(size: 34, weight: .bold)).multilineTextAlignment(.center)
                Text("Conecta tu cuenta de Google para ver los datos de tu Fitbit Air.")
                    .font(.body).foregroundStyle(.white.opacity(0.7)).multilineTextAlignment(.center).padding(.horizontal, 32)
                if let e = model.error { Text(e).font(.footnote).foregroundStyle(.orange).multilineTextAlignment(.center).padding(.horizontal, 28) }
                Spacer()
                Button { Task { await model.signIn() } } label: {
                    HStack(spacing: 10) {
                        Text("G").font(.system(size: 20, weight: .bold, design: .rounded)).foregroundStyle(Color(red: 0.26, green: 0.52, blue: 0.96))
                        Text("Iniciar sesión con Google").font(.headline)
                    }
                    .foregroundStyle(.black).frame(maxWidth: .infinity).padding(.vertical, 16)
                    .background(.white, in: Capsule())
                }
                Text("Solo lectura · sin servidores intermedios").font(.footnote).foregroundStyle(.white.opacity(0.55))
            }
            .padding(.horizontal, 24).padding(.bottom, 12)
            .foregroundStyle(.white)
        }
        .preferredColorScheme(.dark)
    }
}

#if DEBUG
#Preview { LoginView().previewEnvironment() }
#endif
