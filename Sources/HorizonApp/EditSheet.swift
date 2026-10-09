import SwiftUI
import AppKit
import HorizonCore

struct EditSheet: View {
    @EnvironmentObject private var model: AppModel
    let action: EditAction
    @State private var name = ""
    @State private var oldPassword = ""
    @State private var password = ""
    @State private var confirm = ""
    @State private var code = ""
    @State private var useRecovery = false
    @State private var destination = ""
    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            HStack { Text(title).font(.system(size: 25, weight: .light)); Spacer(); Button { if !model.busy { model.edit = nil } } label: { Image(systemName: "xmark") }.buttonStyle(.plain).disabled(model.busy) }
            content
            if model.busy {
                ProgressView(value: model.progress?.fraction).tint(Theme.amber)
                HStack { Text(model.progress?.phase ?? "Выполняется…").font(.system(size: 12)).foregroundStyle(Theme.muted); Spacer(); if model.operationName == "Восстановление" { Button("Отменить операцию") { model.cancelOperation() }.buttonStyle(.plain) } }
            }
            if case .settings = action {} else {
                HStack { Spacer(); Button("Отмена") { model.edit = nil }.buttonStyle(HorizonButtonStyle()).disabled(model.busy); Button(submitTitle) { Task { await submit() } }.buttonStyle(HorizonButtonStyle(primary: true)).disabled(model.busy) }
            }
        }.padding(30).frame(width: 520).background(Theme.background).foregroundStyle(Theme.text).tint(Theme.amber).preferredColorScheme(.dark)
            .interactiveDismissDisabled(model.busy)
            .onAppear { if case .rename(let item) = action { name = item.name }; if case .move(let item) = action { destination = item.parent?.uuidString ?? "" } }
    }
    private var title: String {
        switch action { case .folder: "Новая папка"; case .note: "Новая заметка"; case .rename: "Переименовать"; case .move: "Переместить"; case .settings: "Настройки Horizon"; case .password: "Сменить пароль"; case .recovery: "Вернуть доступ"; case .restore: "Восстановить копию" }
    }
    private var submitTitle: String { switch action { case .folder, .note: "Создать"; case .rename, .move: "Сохранить"; case .password: "Сменить пароль"; default: "Восстановить" } }
    @ViewBuilder private var content: some View {
        switch action {
        case .folder, .note, .rename:
            FieldBox { TextField("Название", text: $name).onSubmit { Task { await submit() } } }
        case .move(let item):
            Text(item.name).foregroundStyle(Theme.muted).lineLimit(2)
            Picker("Папка", selection: $destination) {
                Text("Корень пространства").tag("")
                ForEach(model.items.filter { $0.isFolder && !$0.isTrashed && $0.id != item.id }.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }) { folder in Text(folder.name).tag(folder.id.uuidString) }
            }.pickerStyle(.menu)
        case .password:
            FieldBox { SecureField("Текущий пароль", text: $oldPassword) }
            newPasswordFields
            Text("Старые резервные копии сохранят прежний пароль. Ключ восстановления останется действительным.").font(.system(size: 12)).foregroundStyle(Theme.muted)
        case .recovery:
            Text("Введи ключ, выданный при создании пространства, и назначь новый пароль.").foregroundStyle(Theme.muted)
            recoveryFields
        case .restore(let url):
            Text(url.lastPathComponent).font(.system(size: 12)).foregroundStyle(Theme.muted)
            Text("Копия будет полностью проверена. Текущее хранилище сохранится отдельно и не будет затёрто.").foregroundStyle(Theme.muted)
            Toggle("Использовать ключ восстановления", isOn: $useRecovery).toggleStyle(.checkbox)
            if useRecovery { recoveryFields } else { FieldBox { SecureField("Пароль резервной копии", text: $password) } }
        case .settings: settings
        }
    }
    private var recoveryFields: some View {
        VStack(spacing: 13) { FieldBox { TextField("Ключ восстановления", text: $code).font(.system(size: 12, design: .monospaced)).disableAutocorrection(true) }; newPasswordFields }
    }
    private var newPasswordFields: some View {
        VStack(spacing: 13) { FieldBox { SecureField("Новый пароль · от 12 символов", text: $password) }; FieldBox { SecureField("Повтори новый пароль", text: $confirm) } }
    }
    private var settings: some View {
        VStack(alignment: .leading, spacing: 20) {
            HStack { Text("Автоблокировка"); Spacer(); Picker("Интервал", selection: $model.preferences.idleMinutes) { ForEach([1, 5, 15, 30], id: \.self) { Text("\($0) мин").tag($0) } }.labelsHidden().frame(width: 130) }
            HStack { Text("Размер текста"); Spacer(); Picker("Масштаб", selection: $model.preferences.textScale) { Text("90%").tag(0.9); Text("100%").tag(1.0); Text("115%").tag(1.15); Text("125%").tag(1.25) }.labelsHidden().frame(width: 130) }
            Toggle("Анимации чёрной дыры", isOn: $model.preferences.animationsEnabled)
            Text("Системная настройка уменьшения движения также учитывается.").font(.system(size: 11)).foregroundStyle(Theme.muted)
            Divider()
            HStack { VStack(alignment: .leading, spacing: 5) { Text("Резервная копия"); Text(model.lastBackup.map { $0.formatted(date: .abbreviated, time: .shortened) } ?? "Пока не создана").font(.system(size: 12)).foregroundStyle(Theme.muted) }; Spacer(); Button("Создать…") { Task { await model.backup() } }.buttonStyle(HorizonButtonStyle()).disabled(model.busy) }
            Button("Сменить пароль…") { model.edit = .password }.buttonStyle(HorizonButtonStyle()).disabled(model.busy)
            if model.previousCount > 0 {
                HStack { Text("Предыдущих хранилищ: \(model.previousCount)").font(.system(size: 12)).foregroundStyle(Theme.muted); Spacer(); Button("Удалить…") { removePrevious() }.buttonStyle(.plain).disabled(model.busy) }
            }
            Divider()
            Text("Horizon 0.3 · локальное хранилище").font(.system(size: 12))
            Text("Данные хранятся в Application Support. Удаление приложения не удаляет хранилище.").font(.system(size: 11)).foregroundStyle(Theme.muted)
            Button("Показать папку данных") { NSWorkspace.shared.open(model.root) }.buttonStyle(.plain).foregroundStyle(Theme.amber)
        }
    }
    private func removePrevious() {
        let alert = NSAlert(); alert.messageText = "Удалить предыдущие хранилища?"; alert.informativeText = "Это аварийные копии, сохранённые перед восстановлением. Текущее пространство не изменится."
        alert.addButton(withTitle: "Отмена"); alert.addButton(withTitle: "Удалить")
        if alert.runModal() == .alertSecondButtonReturn { Task { await model.perform { try await $0.removePreviousCopies() } } }
    }
    private func submit() async {
        switch action {
        case .folder: await model.create(kind: .folder, name: name)
        case .note: await model.create(kind: .note, name: name)
        case .rename(let item): await model.rename(item, name: name)
        case .move(let item): await model.move(item, parent: UUID(uuidString: destination))
        case .password: await model.changePassword(old: oldPassword, new: password, confirm: confirm)
        case .recovery: await model.recover(code: code, password: password, confirm: confirm)
        case .restore(let url): await model.restoreBackup(url: url, password: password, code: useRecovery ? code : nil, newPassword: password, confirm: confirm)
        case .settings: break
        }
    }
}
