import SwiftUI

// Zellen einer `Table`, die erst beim Rollen entstehen, bekommen unter macOS 15 die Umgebungsobjekte nicht mit:
// `@Environment(AppModel.self)` bricht dort mit „No Observable object of type AppModel found“ ab (Absturz beim
// Rollen jeder längeren Titelliste). Deshalb lesen alle Mac-Ansichten die Modelle über `@AppEnv` / `@MacEnv`:
// zuerst aus der Umgebung, sonst das eine Modell der App (es gibt je genau eins).

@MainActor @propertyWrapper
struct AppEnv: DynamicProperty {
    @Environment(AppModel.self) private var value: AppModel?
    var wrappedValue: AppModel { value ?? MacAppDelegate.shared!.app }
}

@MainActor @propertyWrapper
struct MacEnv: DynamicProperty {
    @Environment(MacModel.self) private var value: MacModel?
    var wrappedValue: MacModel { value ?? MacAppDelegate.shared!.mac }
}
