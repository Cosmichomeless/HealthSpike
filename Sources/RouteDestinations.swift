import SwiftUI

/// El pulso en directo es único para toda la app: lo crea `RootView` y lo leen Hoy y Corazón.
/// Crear un `LiveHeart` no toca Bluetooth (el gestor y el permiso nacen en `start()`), así que el valor por defecto es inocuo.
private struct LiveHeartKey: EnvironmentKey {
    static let defaultValue = LiveHeart()
}

extension EnvironmentValues {
    var liveHeart: LiveHeart {
        get { self[LiveHeartKey.self] }
        set { self[LiveHeartKey.self] = newValue }
    }
}

/// Pantallas a las que se llega con `NavigationLink(value:)`.
enum Route: Hashable { case heart, sleep, activity, weight, mood, sleepAdvice, vitals, recovery, resilience, bedtime, sleepWeek }

extension View {
    /// Destinos de todas las rutas. Cada `NavigationStack` (una por pestaña) necesita aplicarlo una vez en su raíz.
    func routeDestinations() -> some View {
        navigationDestination(for: Route.self) { route in
            switch route {
            case .heart: HeartDetailView()
            case .sleep: SleepDetailView()
            case .activity: ActivityView()
            case .weight: WeightView()
            case .mood: MoodView()
            case .recovery: RecoveryView()
            case .resilience: ResilienceView()
            case .sleepAdvice: SleepAdviceView()
            case .vitals: VitalsView()
            case .bedtime: BedtimeView()
            case .sleepWeek: SleepWeekView()
            }
        }
    }
}
