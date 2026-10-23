import SwiftUI

@main
struct HealthSpikeApp: App {
    @StateObject private var model: HealthModel
    @StateObject private var logs: LogStore
    @StateObject private var coach: CoachStore
    @StateObject private var chat = CoachChat()
    @Environment(\.scenePhase) private var phase

    init() {
        #if DEBUG
        // `-demo`: la app real con datos de muestra y sin sesión ni red (capturas de la web).
        if Demo.on {
            _model = StateObject(wrappedValue: HealthModel.preview)
            _logs = StateObject(wrappedValue: LogStore.preview)
            _coach = StateObject(wrappedValue: CoachStore.preview)
            return
        }
        #endif
        _model = StateObject(wrappedValue: HealthModel())
        _logs = StateObject(wrappedValue: LogStore())
        _coach = StateObject(wrappedValue: CoachStore())
    }

    var body: some Scene {
        WindowGroup {
            RootView().environmentObject(model).environmentObject(logs).environmentObject(coach).environmentObject(chat)
                .preferredColorScheme(.dark)
        }
        .onChange(of: phase) { _, p in if p != .active, model.auth.signedIn { BackgroundRefresh.schedule() } }
        // iOS lo lanza de vez en cuando con la app cerrada: lee lo nuevo y deja los widgets al día.
        .backgroundTask(.appRefresh(BackgroundRefresh.id)) {
            let start = ContinuousClock.now
            let lm = await SystemLM.status
            CoachLog.add("Refresco lanzado por iOS", "\(await CoachLog.context)\nModelo: \(lm.text)", background: true)
            await model.refresh(force: false, widgetOnly: true)
            let read = CoachLog.seconds(ContinuousClock.now - start)
            await coach.catchUp(model: model)
            let cut = Task.isCancelled
            CoachLog.add(cut ? "Refresco cortado por iOS" : "Refresco terminado",
                         "Lectura de datos: \(read) s · total: \(CoachLog.seconds(ContinuousClock.now - start)) s", background: true, ok: !cut)
            BackgroundRefresh.schedule()
        }
    }
}
