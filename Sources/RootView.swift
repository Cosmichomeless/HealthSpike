import SwiftUI

struct RootView: View {
    @EnvironmentObject var model: HealthModel
    @Environment(\.scenePhase) private var phase
    /// Sin `@StateObject`: ni RootView ni las pantallas deben repintarse con cada muestra del pulso, solo quien lo muestra.
    @State private var live = LiveHeart()
    @EnvironmentObject var coach: CoachStore
    @EnvironmentObject var chat: CoachChat
    @State private var tab = Tab.today

    private enum Tab { case today, sleep, heart, activity, coach }

    var body: some View {
        Group {
            if model.auth.signedIn || Demo.on {
                TabView(selection: $tab) {
                    TodayView().tabItem { Label("Hoy", systemImage: "square.grid.2x2.fill") }.tag(Tab.today)
                    NavigationStack { SleepDetailView().routeDestinations() }.tabItem { Label("Sueño", systemImage: "moon.fill") }.tag(Tab.sleep)
                    NavigationStack { HeartDetailView().routeDestinations() }.tabItem { Label("Corazón", systemImage: "heart.fill") }.tag(Tab.heart)
                    NavigationStack { ActivityView().routeDestinations() }.tabItem { Label("Actividad", systemImage: "flame.fill") }.tag(Tab.activity)
                    NavigationStack { CoachView().routeDestinations() }.tabItem { Label("Coach", systemImage: "sparkles") }.tag(Tab.coach)
                }
            } else {
                LoginView()
            }
        }
        .environment(\.locale, esES)
        .environment(\.calendar, esCalendar)
        .environment(\.liveHeart, live)
        .environment(\.openCoach) { tab = .coach }
        .task { if Demo.on { tab = [.today, .sleep, .heart, .activity, .coach][Demo.tab] } }
        .task { if model.auth.signedIn { await model.refresh(force: false) } }
        .task(id: model.auth.signedIn) {
            guard model.auth.signedIn else { return }
            await CoachAuto.scheduleNotifications()
            #if DEBUG
            await coach.launchTest(model: model)
            #endif
        }
        // Cada lectura nueva o cada vuelta a la app puede dejar un mensaje del Coach pendiente de generar.
        .onChange(of: model.lastRefresh) { _, _ in Task { await coach.catchUp(model: model) } }
        .onChange(of: phase) { _, p in if p == .active { Task { await coach.catchUp(model: model) } } }
        // Pulso en directo por Bluetooth solo con la app a la vista y la sesión iniciada.
        .onChange(of: phase, initial: true) { _, _ in syncLive() }
        .onChange(of: model.auth.signedIn) { _, signedIn in
            syncLive()
            if !signedIn { coach.clear(); chat.reset(); tab = .today }
        }
        .onChange(of: phase) { _, p in
            // Al volver a la app, refresca si los datos tienen más de 5 minutos.
            guard p == .active, model.auth.signedIn, Date().timeIntervalSince(model.lastRefresh ?? .distantPast) > 300 else { return }
            Task { await model.refresh(force: false) }
        }
    }

    private func syncLive() {
        guard !model.isPreview else { return }
        if phase == .active && model.auth.signedIn { live.start() } else { live.stop() }
    }
}

#if DEBUG
#Preview("Sin sesión") { RootView().previewEnvironment() }
#endif
