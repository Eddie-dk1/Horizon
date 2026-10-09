import SwiftUI
import AppKit

@MainActor final class AppDelegate: NSObject, NSApplicationDelegate {
    weak var model: AppModel?
    private var notifications: [NSObjectProtocol] = []
    private var pendingBackup: URL?
    func attach(_ model: AppModel) async {
        self.model = model; await model.start()
        if let pendingBackup { self.pendingBackup = nil; routeBackup(pendingBackup) }
    }
    func application(_ application: NSApplication, open urls: [URL]) {
        guard let url = urls.first(where: { $0.pathExtension.lowercased() == "horizonbackup" }) else { return }
        if model == nil || model?.phase == .boot { pendingBackup = url }
        else { routeBackup(url) }
    }
    private func routeBackup(_ url: URL) {
        guard let model else { pendingBackup = url; return }
        if model.phase != .locked {
            let alert = NSAlert(); alert.messageText = "Открыть резервную копию?"
            alert.informativeText = "Для восстановления нужно закрыть пространство. Текущее хранилище сохранится отдельно."
            alert.addButton(withTitle: "Отмена"); alert.addButton(withTitle: "Закрыть и продолжить")
            guard alert.runModal() == .alertSecondButtonReturn else { return }
        }
        Task { @MainActor in
            if model.phase != .locked { await model.lock() }
            model.edit = .restore(url)
            NSApp.windows.first(where: { $0.identifier?.rawValue == "horizon-main" })?.makeKeyAndOrderFront(nil)
            NSApp.activate()
        }
    }
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        let workspace = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.willSleepNotification, NSWorkspace.sessionDidResignActiveNotification] {
            notifications.append(workspace.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor in await self?.model?.lock() }
            })
        }
        notifications.append(NotificationCenter.default.addObserver(forName: NSApplication.didHideNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in await self?.model?.lock() }
        })
    }
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard let model else { return .terminateNow }
        Task { @MainActor in
            await model.lock()
            if model.hasRetainedDraft {
                let alert = NSAlert(); alert.messageText = "Черновик не сохранён на диск"
                alert.informativeText = "Не удалось сохранить заметку. При выходе черновик в памяти будет потерян. Откройте пространство и попробуйте сохранить его ещё раз."
                alert.addButton(withTitle: "Остаться"); alert.addButton(withTitle: "Выйти без черновика")
                NSApp.reply(toApplicationShouldTerminate: alert.runModal() == .alertSecondButtonReturn)
            } else { NSApp.reply(toApplicationShouldTerminate: true) }
        }
        return .terminateLater
    }
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag { sender.windows.first(where: { $0.identifier?.rawValue == "horizon-main" })?.makeKeyAndOrderFront(nil) }
        return true
    }
}

@main struct HorizonApplication: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @StateObject private var model = AppModel()
    var body: some Scene {
        Window("Horizon", id: "horizon") {
            RootView().environmentObject(model)
                .task { await delegate.attach(model) }
        }
        .defaultSize(width: 1180, height: 780)
        .windowStyle(.hiddenTitleBar)
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("Добавить файлы…") { model.chooseFiles() }.keyboardShortcut("o").disabled(model.phase != .unlocked || model.busy)
                Button("Новая заметка") { model.edit = .note }.keyboardShortcut("n").disabled(model.phase != .unlocked || model.busy)
                Button("Новая папка") { model.edit = .folder }.keyboardShortcut("n", modifiers: [.command, .shift]).disabled(model.phase != .unlocked || model.busy)
            }
            CommandGroup(replacing: .saveItem) {
                Button("Сохранить заметку") { Task { await model.saveCurrentNote() } }.keyboardShortcut("s").disabled(model.currentDraft == nil)
            }
            CommandMenu("Space") {
                Button("Закрыть Space") { Task { await model.lock() } }.keyboardShortcut("l").disabled(model.phase == .locked)
                Button("Резервная копия…") { Task { await model.backup() } }.disabled(model.phase != .unlocked || model.busy)
                Button("Настройки…") { model.edit = .settings }.keyboardShortcut(",").disabled(model.phase != .unlocked)
            }
        }
    }
}

struct WindowProbe: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView { NSView() }
    func updateNSView(_ view: NSView, context: Context) {
        DispatchQueue.main.async {
            view.window?.identifier = NSUserInterfaceItemIdentifier("horizon-main")
            view.window?.backgroundColor = NSColor(Theme.background)
            view.window?.title = "Horizon"
        }
    }
}

struct RootView: View {
    @EnvironmentObject private var model: AppModel
    var body: some View {
        ZStack {
            Theme.background.ignoresSafeArea()
            if model.phase == .unlocked { VaultView() }
            else if model.phase == .boot || model.phase == .locking { ProgressView().tint(Theme.amber) }
            else { EntranceView() }
            if model.phase == .unlocked, let item = model.preview { PreviewOverlay(item: item) }
        }
        .foregroundStyle(Theme.text).tint(Theme.amber).preferredColorScheme(.dark)
        .font(.system(size: 14 * model.preferences.textScale))
        .frame(minWidth: 960, minHeight: 640)
        .background(WindowProbe())
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.didMiniaturizeNotification)) { note in
            if (note.object as? NSWindow)?.identifier?.rawValue == "horizon-main" { Task { await model.lock() } }
        }
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.willCloseNotification)) { note in
            if (note.object as? NSWindow)?.identifier?.rawValue == "horizon-main" { Task { await model.lock() } }
        }
        .sheet(item: $model.edit) { action in EditSheet(action: action).environmentObject(model) }
        .alert("Horizon", isPresented: Binding(get: { model.error != nil }, set: { if !$0 { model.error = nil } })) {
            Button("Понятно") { model.error = nil }
        } message: { Text(model.error ?? "") }
    }
}

struct EntranceView: View {
    @EnvironmentObject private var model: AppModel
    @State private var password = ""
    @State private var confirm = ""
    @FocusState private var focusPassword: Bool
    var body: some View {
        GeometryReader { geometry in
            HStack(spacing: 20) {
                VStack(alignment: .leading, spacing: 0) {
                    HStack(spacing: 9) { Image(systemName: "circle.circle").foregroundStyle(Theme.amber); Text("Horizon").font(.system(size: 21, weight: .medium)) }
                    HStack(spacing: 12) {
                        Text(model.isTestSpace ? "Тестовый Space" : "Личный Space").foregroundStyle(model.isTestSpace ? Theme.amber : Theme.muted)
                        Spacer()
                        Button(model.isTestSpace ? "Личный Space" : "Открыть тестовый Space") {
                            Task { await model.switchSpace(test: !model.isTestSpace) }
                        }.buttonStyle(.plain).foregroundStyle(Theme.muted).disabled(model.busy || model.phase == .opening)
                    }.font(.system(size: 11)).padding(.top, 18)
                    Spacer(minLength: 24)
                    if model.phase == .recoveryKey { recovery }
                    else {
                        Text("Всё важное.\nВнутри.").font(.system(size: 52 * model.preferences.textScale, weight: .light)).tracking(-1.8).lineSpacing(-3)
                        Text(model.isTestSpace ? "Space для тестирования" : "Твой личный Space").font(.system(size: 17)).foregroundStyle(Theme.muted).padding(.top, 18)
                        Text(model.exists ? (model.isTestSpace ? "Тестовый пароль: horizon demo password" : "Введи пароль, чтобы открыть своё хранилище.") : "Создай пароль. Файлы и заметки будут храниться зашифрованными на этом Mac.")
                            .foregroundStyle(Theme.muted).lineSpacing(4).padding(.top, 9).padding(.bottom, 27)
                        FieldBox { SecureField(model.exists ? "Пароль" : "Пароль · от 12 символов", text: $password).focused($focusPassword).onSubmit { authenticate() }.accessibilityLabel("Пароль") }
                        if !model.exists { FieldBox { SecureField("Повтори пароль", text: $confirm).onSubmit { authenticate() } }.padding(.top, 10) }
                        Button(action: authenticate) { HStack { Text(model.exists ? "Открыть Space" : "Создать Space"); Spacer(); if model.busy { ProgressView().controlSize(.small) } else { Image(systemName: "arrow.right") } } }
                            .buttonStyle(HorizonButtonStyle(primary: true)).disabled(model.busy || model.service == nil || model.phase == .opening).padding(.top, 16)
                        if model.busy, let progress = model.progress {
                            VStack(alignment: .leading, spacing: 8) {
                                HStack {
                                    Text(progress.phase)
                                    Spacer()
                                    Button("Отменить") { model.cancelOperation() }.buttonStyle(.plain)
                                }
                                ProgressView(value: progress.fraction).tint(Theme.amber)
                            }.font(.system(size: 11)).foregroundStyle(Theme.muted).padding(.top, 12)
                        }
                        HStack {
                            if model.exists { Button("Забыл пароль") { model.edit = .recovery }.buttonStyle(.plain) }
                            Spacer()
                            Button("Восстановить копию") { model.chooseBackup() }.buttonStyle(.plain)
                        }.font(.system(size: 12)).foregroundStyle(Theme.muted).padding(.top, 20).disabled(model.busy)
                    }
                    Spacer(minLength: 24)
                    Label("На твоём Mac. Только для тебя.", systemImage: "lock").font(.system(size: 12)).foregroundStyle(Theme.muted)
                }.frame(width: min(420, geometry.size.width * 0.4)).padding(.vertical, 55).padding(.leading, 64)
                ZStack {
                    BlackHole(lit: model.phase == .opening || model.phase == .recoveryKey, active: model.preferences.animationsEnabled)
                        .scaleEffect(model.phase == .opening ? 1.14 : 1).animation(.easeInOut(duration: 0.85), value: model.phase == .opening)
                    VStack { Spacer(); Text(model.phase == .opening ? "Добро пожаловать внутрь" : "Важному есть место")
                        .font(.system(size: 12)).tracking(1.6).foregroundStyle(Theme.muted).padding(.bottom, 76) }
                }.frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }.onAppear { focusPassword = true }
        .onChange(of: model.root) { _, _ in password = ""; confirm = ""; focusPassword = true }
        .onChange(of: model.phase) { _, phase in if phase == .opening || phase == .recoveryKey { password = ""; confirm = "" } }
    }
    private func authenticate() { Task { await model.authenticate(password: password, confirmation: confirm) } }
    private var recovery: some View {
        VStack(alignment: .leading, spacing: 17) {
            Text("Ключ к твоему\nSpace").font(.system(size: 34, weight: .light)).tracking(-1)
            Text("Сохрани этот ключ отдельно. Он поможет вернуть доступ, если забудешь пароль.").foregroundStyle(Theme.muted).lineSpacing(4)
            Text(model.recoveryCode.replacingOccurrences(of: "-", with: "  ")).font(.system(size: 15, design: .monospaced)).textSelection(.enabled).lineSpacing(8).padding(17).frame(maxWidth: .infinity, alignment: .leading).background(Theme.surface, in: RoundedRectangle(cornerRadius: 12))
            HStack {
                Button("Сохранить в файл") { model.saveRecoveryKey() }.buttonStyle(HorizonButtonStyle())
                Button("Копировать") { NSPasteboard.general.clearContents(); NSPasteboard.general.setString(model.recoveryCode, forType: .string) }.buttonStyle(HorizonButtonStyle())
            }
            Text("Ключ открывает хранилище. Без пароля и ключа восстановить данные невозможно.").font(.system(size: 12)).foregroundStyle(Theme.muted)
            Toggle("Я сохранил ключ отдельно", isOn: $model.acknowledgedRecovery).toggleStyle(.checkbox)
            Button("Войти в Space") { Task { await model.finishRecovery() } }.buttonStyle(HorizonButtonStyle(primary: true)).disabled(!model.acknowledgedRecovery)
        }
    }
}
