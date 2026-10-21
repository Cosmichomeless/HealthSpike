import SwiftUI

struct SettingsView: View {
    @EnvironmentObject var model: HealthModel
    @AppStorage("stepsGoal") private var stepsGoal = 10_000
    @AppStorage("sleepGoalHours") private var sleepGoal = 8.0
    @AppStorage("caloriesGoal") private var caloriesGoal = 2_500
    @AppStorage(CardioLoad.goalKey) private var cardioGoal = 0
    @AppStorage(CardioLoad.ageKey) private var age = CardioLoad.defaultAge
    private enum Goal { case steps, sleep, calories, cardio, age }
    @State private var open: Goal?
    @State private var confirm: Confirm?
    private enum Confirm: Identifiable { case clear, signOut; var id: Self { self } }
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Picker("Fuente", selection: $model.airOnly) {
                        Text("Solo Air").tag(true)
                        Text("Todas").tag(false)
                    }.pickerStyle(.segmented)
                } header: { Text("Fuente de los datos") } footer: {
                    Text(model.airOnly
                         ? "Se ignoran los puntos de Apple Health que Google mezcla en las mismas listas."
                         : "Suma Air + Apple Health: pasos y distancia pueden salir duplicados.")
                }

                Section("Objetivos") {
                    DisclosureGroup(isExpanded: Binding(get: { open == .steps }, set: { open = $0 ? .steps : nil })) {
                        Picker("Pasos", selection: $stepsGoal) {
                            ForEach(Array(stride(from: 2_000, through: 40_000, by: 500)), id: \.self) { Text($0.formatted()).tag($0) }
                        }.pickerStyle(.wheel).labelsHidden().frame(height: 140)
                    } label: { LabeledContent("Pasos", value: stepsGoal.formatted()) }

                    DisclosureGroup(isExpanded: Binding(get: { open == .sleep }, set: { open = $0 ? .sleep : nil })) {
                        HStack(spacing: 0) {
                            Picker("Horas", selection: Binding(get: { Int(sleepGoal) }, set: { sleepGoal = Double($0) + sleepGoal.truncatingRemainder(dividingBy: 1) })) {
                                ForEach(4...12, id: \.self) { Text("\($0) h").tag($0) }
                            }.pickerStyle(.wheel).frame(maxWidth: .infinity)
                            Picker("Minutos", selection: Binding(get: { Int((sleepGoal.truncatingRemainder(dividingBy: 1) * 60).rounded()) },
                                                                 set: { sleepGoal = Double(Int(sleepGoal)) + Double($0) / 60 })) {
                                ForEach([0, 15, 30, 45], id: \.self) { Text("\($0) min").tag($0) }
                            }.pickerStyle(.wheel).frame(maxWidth: .infinity)
                        }.labelsHidden().frame(height: 140)
                    } label: { LabeledContent("Sueño", value: hoursText(sleepGoal)) }

                    DisclosureGroup(isExpanded: Binding(get: { open == .calories }, set: { open = $0 ? .calories : nil })) {
                        Picker("Calorías", selection: $caloriesGoal) {
                            ForEach(Array(stride(from: 1_000, through: 6_000, by: 50)), id: \.self) { Text("\($0.formatted()) kcal").tag($0) }
                        }.pickerStyle(.wheel).labelsHidden().frame(height: 140)
                    } label: { LabeledContent("Calorías", value: "\(caloriesGoal.formatted()) kcal") }

                    DisclosureGroup(isExpanded: Binding(get: { open == .cardio }, set: { open = $0 ? .cardio : nil })) {
                        Picker("Carga cardio", selection: $cardioGoal) {
                            Text("Automático").tag(0)
                            ForEach(Array(stride(from: 100, through: 2000, by: 25)), id: \.self) { Text("\($0)").tag($0) }
                        }.pickerStyle(.wheel).labelsHidden().frame(height: 140)
                    } label: { LabeledContent("Carga cardio semanal", value: cardioGoal == 0 ? "Automático" : "\(cardioGoal)") }
                }

                Section {
                    DisclosureGroup(isExpanded: Binding(get: { open == .age }, set: { open = $0 ? .age : nil })) {
                        Picker("Edad", selection: $age) {
                            ForEach(14...100, id: \.self) { Text("\($0) años").tag($0) }
                        }.pickerStyle(.wheel).labelsHidden().frame(height: 140)
                    } label: { LabeledContent("Edad", value: "\(age) años") }
                } header: { Text("Perfil") } footer: {
                    Text("FC máxima estimada: 220 − edad = \(Int(CardioLoad.maxHR(age: age))) lpm. Se usa para calcular la carga cardiovascular.")
                }

                CoachSettingsSection()

                Section("Cuenta") {
                    LabeledContent("Google Health", value: "Conectado")
                    if let t = model.lastRefresh { LabeledContent("Última lectura", value: t.formatted(Date.FormatStyle(date: .abbreviated, time: .shortened).locale(esES))) }
                    Button("Actualizar ahora") { Task { await model.refresh() } }.disabled(model.loading)
                    Button("Borrar histórico guardado") { confirm = .clear }.disabled(model.loading || model.longLoading)
                    Button("Cerrar sesión", role: .destructive) { confirm = .signOut }
                }

                Section("Para depurar") {
                    NavigationLink("Datos de la API") { ApiDataView() }
                    NavigationLink("Bluetooth de la pulsera") { BluetoothProbeView() }
                    NavigationLink("Resumen con IA local (prueba)") { LocalAIView() }
                }

                Section {
                    Text("Solo lectura. Los datos se piden directamente a Google Health API v4 desde el móvil, sin servidores intermedios. Los días ya cerrados se guardan en el móvil y solo se vuelven a pedir los últimos tres. En modo pruebas Google caduca la sesión a los 7 días y hay que volver a iniciarla.")
                        .font(.footnote).foregroundStyle(.secondary)
                } header: { Text("Acerca de") }
            }
            .navigationTitle("Ajustes")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .topBarTrailing) { Button("Listo") { dismiss() } } }
            // Alerta y no `confirmationDialog`: en iOS 26 este último sale como popover anclado arriba y su botón no llegaba a ejecutarse.
            .alert(confirm == .clear ? "¿Borrar el histórico guardado?" : "¿Cerrar sesión?", isPresented: Binding(get: { confirm != nil }, set: { if !$0 { confirm = nil } }),
                   presenting: confirm) { c in
                Button("Cancelar", role: .cancel) {}
                if c == .clear {
                    Button("Borrar y volver a descargar", role: .destructive) { model.clearCache(); Task { await model.refresh() } }
                } else {
                    Button("Cerrar sesión", role: .destructive) { model.signOut(); dismiss() }
                }
            } message: { c in
                Text(c == .clear ? "Se vuelve a pedir todo a Google, hasta un año de datos."
                                 : "Se borran los datos guardados en el móvil y habrá que volver a iniciar sesión.")
            }
            .onChange(of: model.airOnly) { _, _ in model.publishWidget() }
            // Los widgets leen los objetivos y la edad: se les avisa al cerrar, no en cada vuelta de la rueda.
            .onDisappear { model.publishWidget() }
        }
    }
}

/// Todo lo recibido de Google Health y la cobertura de los tipos que no encajan en ninguna pantalla.
struct ApiDataView: View {
    var body: some View {
        ScrollView {
            VStack(spacing: 16) {
                CoverageSection()
                RawDataSection()
            }.padding(.horizontal, 16).padding(.bottom, 24)
        }
        .background(Theme.background)
        .navigationTitle("Datos de la API")
        .navigationBarTitleDisplayMode(.inline)
    }
}

#if DEBUG
#Preview("Ajustes") { SettingsView().previewScreen() }
#Preview("Datos de la API") { ApiDataView().previewScreen() }
#endif

/// Cuándo salen solos los mensajes del Coach.
private struct CoachSettingsSection: View {
    @AppStorage(CoachAuto.enabledKey) private var enabled = true
    @AppStorage(CoachAuto.dayKey) private var dayMinutes = CoachAuto.defaultDay

    private func time(_ minutes: Binding<Int>) -> Binding<Date> {
        Binding(get: { Calendar.current.startOfDay(for: Date()).addingTimeInterval(TimeInterval(minutes.wrappedValue * 60)) },
                set: { let c = Calendar.current.dateComponents([.hour, .minute], from: $0); minutes.wrappedValue = (c.hour ?? 0) * 60 + (c.minute ?? 0) })
    }

    var body: some View {
        Section {
            Toggle("Mensajes automáticos", isOn: $enabled)
            if enabled {
                DatePicker("Resumen del día", selection: time($dayMinutes), displayedComponents: .hourAndMinute)
                NavigationLink("Registro del Coach") { CoachLogView() }
            }
        } header: { Text("Coach") } footer: {
            Text("El resumen del día llega a esa hora: el aviso sale puntual y el mensaje se genera al abrir la app (o antes, si iOS deja trabajar a la app en segundo plano). El del sueño, el de cada siesta y el de cada entreno se generan en cuanto la app recibe el dato nuevo. Pide Apple Intelligence.")
        }
        .onChange(of: enabled) { _, _ in Task { await CoachAuto.scheduleNotifications() } }
        .onChange(of: dayMinutes) { _, _ in Task { await CoachAuto.scheduleNotifications() } }
    }
}
