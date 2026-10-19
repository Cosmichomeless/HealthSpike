import SwiftUI
import WidgetKit

extension HealthModel {
    /// Deja los datos de hoy para los widgets y les pide repintar. Se llama tras cada `refresh`.
    func publishWidget() {
        guard !isPreview, let t = today else { return }
        let d = UserDefaults.standard
        let stepsGoal = d.object(forKey: "stepsGoal") as? Int ?? 10_000
        let sleepGoal = d.object(forKey: "sleepGoalHours") as? Double ?? 8.0
        let caloriesGoal = d.object(forKey: "caloriesGoal") as? Int ?? 2_500
        let score = t.sleep.map { sleepScore($0, goalHours: sleepGoal) }
        let age = d.object(forKey: CardioLoad.ageKey) as? Int ?? CardioLoad.defaultAge
        WidgetStore.save(WidgetData(
            updatedAt: lastRefresh ?? Date(), day: t.midnight,
            steps: Int(t.steps), stepsGoal: stepsGoal,
            sleepScore: score?.value, sleepHours: t.sleep.map { $0.asleep / 60 }, sleepLabel: score?.label,
            calories: t.calories.map { Int($0.rounded()) }, caloriesGoal: caloriesGoal,
            heartBPM: t.lastHR.map { Int($0.value) }, heartTime: t.lastHR?.time, resting: t.resting.map { Int($0.value) }, heartMax: Int(CardioLoad.maxHR(age: age)),
            battery: tracker?.batteryLevel))
        WidgetCenter.shared.reloadAllTimelines()
    }
}
