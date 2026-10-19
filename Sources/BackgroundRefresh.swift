import BackgroundTasks

/// Actualización en segundo plano para que los widgets no dependan de abrir la app.
/// iOS decide cuándo la lanza (según el uso que haces de la app y la batería), así que es irregular: no se puede fijar a un intervalo.
enum BackgroundRefresh {
    static let id = "dev.cosmichomeless.healthspike.refresh"
    /// Lo más pronto que se pide; iOS puede tardar más.
    private static let earliest: TimeInterval = 15 * 60

    /// Pide la siguiente ejecución. Se llama al pasar a segundo plano y al terminar cada ejecución.
    static func schedule() {
        let request = BGAppRefreshTaskRequest(identifier: id)
        request.earliestBeginDate = Date(timeIntervalSinceNow: earliest)
        do {
            try BGTaskScheduler.shared.submit(request)
            print("BackgroundRefresh: pedida la próxima ejecución")
        } catch {
            // Sin permiso (Actualización en segundo plano desactivada), identificador sin declarar, etc.
            print("BackgroundRefresh: no se pudo pedir (\(error))")
            CoachLog.add("No se pudo pedir el próximo refresco", error.localizedDescription, background: false, ok: false)
        }
    }
}
