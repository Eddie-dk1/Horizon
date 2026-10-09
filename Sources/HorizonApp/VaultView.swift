import SwiftUI
import UniformTypeIdentifiers
import HorizonCore

struct VaultView: View {
    @EnvironmentObject private var model: AppModel
    var body: some View {
        VStack(spacing: 0) {
            toolbar.padding(.horizontal, 32).padding(.top, 30).padding(.bottom, 20)
            if !model.breadcrumbs.isEmpty {
                HStack(spacing: 8) {
                    Button("Space") { model.navigate(nil) }
                    ForEach(model.breadcrumbs) { folder in
                        Text("/").foregroundStyle(Theme.muted)
                        Button(folder.name) { model.navigate(folder.id) }.lineLimit(1)
                    }
                    Spacer()
                }.buttonStyle(.plain).font(.system(size: 12)).padding(.horizontal, 34).padding(.bottom, 14)
            }
            if let banner = model.banner {
                HStack {
                    Text(banner).font(.system(size: 12)).foregroundStyle(Theme.amber)
                    Spacer()
                    Button { model.banner = nil } label: { Image(systemName: "xmark") }.buttonStyle(.plain).accessibilityLabel("Скрыть сообщение")
                }.padding(.horizontal, 34).padding(.vertical, 10)
            }
            SpaceGraph()
            if model.busy { operation }
        }
    }
    private var toolbar: some View {
        HStack(spacing: 20) {
            Menu {
                ForEach(Section.allCases, id: \.self) { section in
                    Button(section.rawValue) { model.select(section) }
                }
            } label: {
                HStack(spacing: 10) {
                    Text(model.section == .all ? "Space" : model.section.rawValue)
                        .font(.system(size: 32, weight: .light)).tracking(-0.8)
                    Image(systemName: "chevron.down").font(.system(size: 10)).foregroundStyle(Theme.muted)
                }
            }.menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize().tint(Theme.text).accessibilityLabel("Раздел Space").help("Space, заметки, папки и Корзина")
            if model.isTestSpace { Text("Тестовый Space").font(.system(size: 11)).foregroundStyle(Theme.amber) }
            Spacer(minLength: 10)
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass").foregroundStyle(Theme.muted)
                TextField("Найти звезду", text: $model.search).textFieldStyle(.plain).accessibilityLabel("Поиск в Space")
                if !model.search.isEmpty {
                    Button { model.search = "" } label: { Image(systemName: "xmark.circle.fill") }.buttonStyle(.plain).foregroundStyle(Theme.muted).accessibilityLabel("Сбросить поиск")
                }
            }.padding(11).frame(width: 230).background(Theme.surface.opacity(0.7), in: RoundedRectangle(cornerRadius: 10))
            if model.section == .trash {
                Button("Очистить") { Task { await model.deleteForever(nil) } }.buttonStyle(HorizonButtonStyle()).disabled(model.busy || model.filtered.isEmpty)
            } else {
                Menu {
                    Button("Добавить файлы…") { model.chooseFiles() }
                    Divider()
                    Button("Новая заметка") { model.edit = .note }
                    Button("Новая папка") { model.edit = .folder }
                } label: { Image(systemName: "plus").font(.system(size: 19, weight: .light)).padding(8) }
                    .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize().disabled(model.busy || model.layoutSaving).accessibilityLabel("Добавить в Space")
            }
            HStack(spacing: 9) {
                Button { model.edit = .settings } label: { Image(systemName: "gearshape").font(.system(size: 16)).padding(8) }
                    .help("Настройки · ⌘,").accessibilityLabel("Настройки")
                Button { Task { await model.lock() } } label: { Image(systemName: "lock").font(.system(size: 16)).padding(8) }
                    .help("Закрыть Space · ⌘L").accessibilityLabel("Закрыть Space")
            }.buttonStyle(.plain).foregroundStyle(Theme.muted)
        }
    }
    private var operation: some View {
        VStack(spacing: 7) {
            HStack {
                Text(model.operationName).lineLimit(1); Spacer()
                Text(model.progress?.phase ?? "Подготовка").foregroundStyle(Theme.muted)
                Button("Отменить") { model.cancelOperation() }.buttonStyle(.plain).foregroundStyle(Theme.amber)
            }
            ProgressView(value: model.progress?.fraction ?? 0).tint(Theme.amber)
        }.font(.system(size: 11)).padding(.horizontal, 34).padding(.vertical, 16).background(Theme.surface)
    }

}

struct StarActions: View {
    @EnvironmentObject private var model: AppModel
    let item: VaultItem
    var body: some View {
        if item.isTrashed {
            Button("Восстановить") { Task { await model.restore(item) } }.disabled(model.busy || model.layoutSaving)
            Button("Удалить окончательно", role: .destructive) { Task { await model.deleteForever(item) } }.disabled(model.busy || model.layoutSaving)
        } else {
            Button(item.isFolder ? "Открыть папку" : "Открыть") { Task { await model.open(item) } }
            if !item.isFolder { Button("Сохранить копию…") { Task { await model.export(item) } }.disabled(model.busy || model.layoutSaving) }
            Button("Переименовать…") { model.edit = .rename(item) }.disabled(model.busy || model.layoutSaving)
            Button("Переместить…") { model.edit = .move(item) }.disabled(model.busy || model.layoutSaving)
            Divider()
            Button("В Корзину", role: .destructive) { Task { await model.trash(item) } }.disabled(model.busy || model.layoutSaving)
        }
    }
}
