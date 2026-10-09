import SwiftUI
import HorizonCore
import UniformTypeIdentifiers

struct SpaceGraph: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.scenePhase) private var scenePhase
    @State private var dropTarget = false
    @State private var layout = SpaceLayout()
    @State private var zoom = 1.0
    @State private var offset = CGSize.zero
    @State private var dragBase: CGSize?
    @State private var hovered: UUID?
    @State private var revealed: UUID?
    @State private var revealTask: Task<Void, Never>?
    @State private var viewport = CGSize.zero
    @State private var fitted = false
    @State private var entries: [VaultItem] = []
    @State private var displayedFolder: UUID?
    @State private var layouts: [String: SpaceLayout] = [:]
    @State private var expansion = 1.0
    @State private var mapOpacity = 1.0
    @State private var transitioning = false
    @State private var navigationTask: Task<Void, Never>?
    @State private var dragged: UUID?
    @State private var dragPositions: [UUID: CGPoint] = [:]
    @State private var cancelledGesture = false
    @State private var dragCancellation = 0
    @State private var flights: [UUID: SpaceFlight] = [:]
    @State private var flightTasks: [UUID: Task<Void, Never>] = [:]
    @State private var fading: Set<UUID> = []
    private var contextFolder: UUID? { model.mapFolder }
    private var canMove: Bool { !transitioning && !model.busy && !model.layoutSaving && model.section != .trash }
    private var flyingIDs: Set<UUID> { Set(flights.values.map(\.itemID)) }
    private var movement: Bool { model.preferences.animationsEnabled && !reduceMotion && scenePhase == .active }
    private var orderedIDs: [UUID] {
        model.items.sorted { $0.created == $1.created ? $0.id.uuidString < $1.id.uuidString : $0.created < $1.created }.map(\.id)
    }
    var body: some View {
        GeometryReader { geometry in
            let visible = entries.filter { item in
                let p = point(item.id, size: geometry.size)
                return p.x > -30 && p.x < geometry.size.width + 30 && p.y > -30 && p.y < geometry.size.height + 30
            }
            ZStack {
                backdrop(size: geometry.size, entries: entries)
                Group {
                    if let folder = model.items.first(where: { $0.id == displayedFolder }) {
                        VStack(spacing: 10) {
                            GalaxyGlyph().frame(width: 138, height: 112)
                            Text(folder.name).font(.system(size: 13, weight: .medium)).foregroundStyle(Theme.amber).lineLimit(2)
                        }.frame(width: 210, height: 180)
                    } else {
                        BlackHole(active: movement, stars: false, absorption: 0).frame(width: 270, height: 220)
                    }
                }.scaleEffect(zoom).opacity(mapOpacity)
                    .position(point(nil, size: geometry.size)).allowsHitTesting(false)
                SpaceFlights(flights: Array(flights.values), zoom: zoom, offset: offset, active: movement,
                             connectionOpacity: displayedFolder == nil ? 0.055 : 0.16)
                    .allowsHitTesting(false)
                ForEach(visible.filter { !flyingIDs.contains($0.id) }) { item in
                    StarButton(item: item, emphasized: hovered == item.id || revealed == item.id || dragged == item.id, animate: movement, canMove: canMove, dragCancellation: dragCancellation,
                               open: { if !item.isTrashed { Task { await model.open(item) } } },
                               drag: { translation in drag(item, translation: translation) },
                               endDrag: { finishDrag() }, cancelDrag: { cancelDrag() },
                               nudge: { delta in nudge(item, by: delta) }) { inside in
                        if inside { hovered = item.id }
                        else if hovered == item.id { hovered = nil }
                    }
                    .contextMenu { StarActions(item: item) }
                    .scaleEffect(item.isFolder ? min(2.5, max(0.75, zoom)) : 1)
                    .opacity(mapOpacity * (fading.contains(item.id) ? 0 : 1)).position(point(item.id, size: geometry.size))
                    .zIndex(dragged == item.id ? 1 : 0)
                    .disabled(transitioning)
                }
                if let id = hovered ?? revealed, !flyingIDs.contains(id), let item = entries.first(where: { $0.id == id }) {
                    tooltip(item).position(tooltipPoint(id, size: geometry.size)).allowsHitTesting(false)
                }
                if entries.isEmpty {
                    VStack(spacing: 9) {
                        Text(model.search.isEmpty ? (model.section == .trash ? "Корзина пуста" : "Здесь загораются твои звёзды") : "Звёзды не найдены")
                            .font(.system(size: 17, weight: .light))
                        Text(model.search.isEmpty ? (model.section == .trash ? "Удалённые звёзды хранятся 30 дней" : "Перетащи файл в Space или нажми +") : "Попробуй другое название")
                            .font(.system(size: 12)).foregroundStyle(Theme.muted)
                    }.position(x: geometry.size.width / 2, y: geometry.size.height / 2 + 145)
                }
                if dropTarget {
                    RoundedRectangle(cornerRadius: 20).stroke(Theme.amber.opacity(0.65), style: StrokeStyle(lineWidth: 1, dash: [6, 8])).padding(14).allowsHitTesting(false)
                    Text("Отпусти файлы — они станут звёздами").font(.system(size: 14)).foregroundStyle(Theme.amber)
                        .padding(14).background(Theme.background.opacity(0.9), in: RoundedRectangle(cornerRadius: 10))
                        .position(x: geometry.size.width / 2, y: 35).allowsHitTesting(false)
                }
            }
            .coordinateSpace(name: "SpaceMap")
            .background(SpaceMagnification(changed: { delta, location in magnify(delta, at: location, size: geometry.size) }, escape: escape))
            .onDrop(of: [UTType.fileURL.identifier], isTargeted: $dropTarget) { providers, location in
                acceptDrop(providers, location: location, size: geometry.size)
            }
            .overlay(alignment: .bottom) { controls(size: geometry.size) }
            .clipped()
            .onAppear {
                viewport = geometry.size; displayedFolder = contextFolder
                syncEntries(); fit(size: geometry.size); fitted = !orderedIDs.isEmpty
            }
            .onChange(of: geometry.size) { _, size in viewport = size; if fitted && !transitioning { withAnimation(movement && !flights.isEmpty ? .easeInOut(duration: 0.2) : nil) { fit(size: size) } } }
            .onChange(of: model.filtered) { _, _ in
                guard !transitioning && dragged == nil && !model.layoutSaving && displayedFolder == contextFolder else { return }
                syncEntries()
                if !fitted { fit(size: viewport); fitted = !orderedIDs.isEmpty }
            }
            .onChange(of: contextFolder) { _, folder in cancelDrag(); cancelFlights(); transition(to: folder) }
            .onChange(of: model.busy) { _, busy in if busy { cancelDrag() } }
            .onChange(of: model.layoutSaving) { _, saving in if !saving && !transitioning { syncEntries() } }
            .onChange(of: model.births) { old, new in
                let previous = Set(old.map(\.id))
                for event in new where !previous.contains(event.id) { birth(event) }
            }
            .onChange(of: model.search) { _, _ in
                cancelDrag(); cancelFlights()
                if !transitioning && displayedFolder == contextFolder { syncEntries(); resetCamera(size: viewport) }
            }
            .onChange(of: model.section) { _, _ in
                cancelDrag(); cancelFlights()
                if !transitioning && displayedFolder == contextFolder { syncEntries(); resetCamera(size: viewport) }
            }
            .onChange(of: movement) { _, enabled in
                if !enabled { cancelFlights(); if transitioning { transition(to: contextFolder) } }
            }
            .onChange(of: model.lastAdded) { _, id in reveal(id) }
            .onDisappear { cancelDrag(); cancelFlights(); revealTask?.cancel(); navigationTask?.cancel(); entries = []; layouts = [:] }
        }
    }
    private func point(_ id: UUID?, size: CGSize) -> CGPoint {
        let world = id.flatMap { layout.positions[$0] } ?? .zero
        return SpaceLayout.screenPoint(CGPoint(x: world.x * expansion, y: world.y * expansion), size: size, zoom: zoom, offset: offset)
    }
    private func tooltipPoint(_ id: UUID, size: CGSize) -> CGPoint {
        let p = point(id, size: size)
        return CGPoint(x: min(max(155, p.x), max(155, size.width - 155)), y: p.y < 105 ? p.y + 66 : p.y - 65)
    }
    private func tooltip(_ item: VaultItem) -> some View {
        VStack(spacing: 6) {
            Text(item.name).font(.system(size: 13 * model.preferences.textScale, weight: .medium)).lineLimit(2).multilineTextAlignment(.center)
            HStack(spacing: 7) {
                Image(systemName: itemSymbol(item))
                Text(typeLabel(item))
                if !item.isFolder && !item.isNote { Text("· " + sizeLabel(item)) }
                if item.isTrashed { Text("· в Корзине") }
            }.font(.system(size: 10)).foregroundStyle(Theme.muted)
        }.padding(.horizontal, 15).padding(.vertical, 12).frame(width: 290)
            .background(Theme.surface.opacity(0.97), in: RoundedRectangle(cornerRadius: 12))
            .overlay(RoundedRectangle(cornerRadius: 12).stroke(Theme.line))
    }
    private func backdrop(size: CGSize, entries: [VaultItem]) -> some View {
        SpaceBackdrop(entries: entries, positions: layout.positions, hovered: hovered,
                      folder: displayedFolder, hidden: flyingIDs, zoom: zoom, offset: offset, expansion: expansion)
        .opacity(mapOpacity)
        .contentShape(Rectangle())
        .gesture(DragGesture(minimumDistance: 4).onChanged { value in
            guard !transitioning && dragged == nil else { return }
            model.touch(); hovered = nil
            if dragBase == nil { dragBase = offset }
            offset = CGSize(width: (dragBase?.width ?? 0) + value.translation.width, height: (dragBase?.height ?? 0) + value.translation.height)
        }.onEnded { _ in dragBase = nil })
        .onTapGesture { hovered = nil; revealed = nil }
        .accessibilityHidden(true)
    }
    private func controls(size: CGSize) -> some View {
        let galaxies = entries.filter(\.isFolder).count
        return HStack(alignment: .bottom) {
                VStack(alignment: .leading, spacing: 7) {
                    Text(spaceCountText(stars: entries.count - galaxies, galaxies: galaxies)).font(.system(size: 11)).monospacedDigit()
                    if !model.layoutStatus.isEmpty { Text(model.layoutStatus).font(.system(size: 10)).foregroundStyle(Theme.amber) }
                    Text("Нажми, чтобы открыть · перетащи, чтобы расположить").font(.system(size: 10)).foregroundStyle(Theme.muted)
                }
                Spacer()
                HStack(spacing: 2) {
                    cameraButton("minus", label: "Уменьшить Space") { changeZoom(zoom / 1.2) }
                    Text("\(Int(zoom * 100))%").font(.system(size: 10)).monospacedDigit().frame(width: 38)
                    cameraButton("plus", label: "Увеличить Space") { changeZoom(zoom * 1.2) }
                    Divider().frame(height: 17).padding(.horizontal, 4)
                    cameraButton("arrow.up.left.and.arrow.down.right", label: "Показать все звёзды") { resetCamera(size: size) }
                }.foregroundStyle(Theme.muted).padding(4)
                    .background(Theme.surface.opacity(0.8), in: RoundedRectangle(cornerRadius: 11))
                    .disabled(transitioning)
        }.padding(.horizontal, 34).padding(.bottom, 24)
    }
    private func drag(_ item: VaultItem, translation: CGSize) {
        guard canMove, !cancelledGesture else { return }
        model.touch()
        if dragged == nil {
            dragged = item.id; hovered = nil
            let group: Set<UUID>
            if displayedFolder == nil && item.isFolder {
                let parents = Dictionary(uniqueKeysWithValues: model.items.filter { !$0.isTrashed }.compactMap { child in child.parent.map { (child.id, $0) } })
                group = SpaceLayout.group(item.id, parents: parents)
            } else { group = [item.id] }
            dragPositions = layout.positions.filter { group.contains($0.key) }
        }
        guard dragged == item.id else { return }
        let dx = translation.width / zoom; let dy = translation.height / zoom
        let next = dragPositions.mapValues { CGPoint(x: $0.x + dx, y: $0.y + dy) }
        guard next.values.allSatisfy({ abs($0.x) <= 1_000_000 && abs($0.y) <= 1_000_000 }) else { return }
        // Track in the fixed map coordinate space. A moving node's local coordinates
        // otherwise feed its own displacement back into the next drag event.
        var transaction = Transaction(); transaction.disablesAnimations = true
        withTransaction(transaction) { layout.set(next) }
    }
    private func finishDrag() {
        cancelledGesture = false
        guard dragged != nil else { return }
        let changes = layout.positions.filter { dragPositions[$0.key] != nil }
        let folder = displayedFolder
        dragged = nil; dragPositions = [:]
        Task { await model.saveSpacePositions(changes, folder: folder) }
    }
    private func cancelDrag() {
        if dragged != nil { layout.set(dragPositions) }
        dragged = nil; dragPositions = [:]
        cancelledGesture = false
    }
    private func escape() -> Bool {
        guard model.phase == .unlocked, model.edit == nil, model.preview == nil, model.error == nil else { return false }
        if dragged != nil {
            cancelDrag(); cancelledGesture = true; dragCancellation &+= 1
            return true
        }
        return model.navigateUp()
    }
    private func nudge(_ item: VaultItem, by delta: CGSize) {
        guard canMove else { return }
        drag(item, translation: delta); finishDrag()
    }
    private func acceptDrop(_ providers: [NSItemProvider], location: CGPoint, size: CGSize) -> Bool {
        guard model.phase == .unlocked, !model.busy, !model.layoutSaving, !transitioning, model.section != .trash else { return false }
        let world = SpaceLayout.worldPoint(location, size: size, zoom: zoom, offset: offset)
        let target = SpaceImportDestination(sessionID: model.sessionID, folder: displayedFolder,
            point: SpacePoint(x: world.x, y: world.y), spacing: min(100_000, max(1, 56 / zoom)))
        Task { @MainActor in
            let urls = await DropFiles.urls(from: providers)
            guard model.sessionID == target.sessionID else { return }
            if urls.isEmpty { model.error = "Не удалось прочитать файлы. Попробуй кнопку «Добавить файлы…»." }
            else { await model.importFiles(urls, destination: target) }
        }
        return true
    }
    private func cancelFlights() {
        for task in flightTasks.values { task.cancel() }
        flightTasks = [:]; flights = [:]; fading = []
    }
    private func birth(_ event: SpaceBirth) {
        guard event.sessionID == model.sessionID, event.folder == displayedFolder, !transitioning,
              model.section == .all, model.search.isEmpty,
              let item = model.items.first(where: { $0.id == event.itemID }) else { return }
        syncEntries(); reveal(event.itemID, fitCamera: false)
        let target = CGPoint(x: event.point.x, y: event.point.y)
        let p = point(item.id, size: viewport)
        let needsFit = p.x < 60 || p.x > viewport.width - 60 || p.y < 70 || p.y > viewport.height - 100
        guard movement else { if needsFit { fit(size: viewport) }; return }
        if flights.count >= 3 {
            if needsFit { withAnimation(.easeInOut(duration: 0.45)) { fit(size: viewport) } }
            fading.insert(item.id)
            flightTasks[event.id] = Task { @MainActor in
                do { try await Task.sleep(for: .milliseconds(20)) } catch { return }
                withAnimation(.easeOut(duration: 0.2)) { _ = fading.remove(item.id) }
                flightTasks[event.id] = nil
            }
            return
        }
        flights[event.id] = SpaceFlight(id: event.id, itemID: item.id, target: target,
            style: .resolve(kind: item.kind.rawValue, name: item.name), start: nil)
        if needsFit { withAnimation(.easeInOut(duration: 0.45)) { fit(size: viewport) } }
        flightTasks[event.id] = Task { @MainActor in
            if needsFit { do { try await Task.sleep(for: .milliseconds(450)) } catch { return } }
            guard !Task.isCancelled, model.sessionID == event.sessionID, displayedFolder == event.folder else { return }
            flights[event.id]?.start = Date()
            do { try await Task.sleep(for: .seconds(1)) } catch { return }
            guard !Task.isCancelled else { return }
            flights[event.id] = nil; flightTasks[event.id] = nil
        }
    }
    private func cameraButton(_ symbol: String, label: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol).font(.system(size: 13))
                .frame(width: 40, height: 36).contentShape(Rectangle())
        }.buttonStyle(CameraButtonStyle()).accessibilityLabel(label).help(label)
    }
    private func resetCamera(size: CGSize) {
        model.touch(); hovered = nil; revealed = nil
        withAnimation(movement ? .easeInOut(duration: 0.45) : nil) { fit(size: size) }
    }
    private func syncEntries() {
        entries = model.filtered
        let key = displayedFolder?.uuidString ?? "root"
        var current = layouts[key] ?? SpaceLayout()
        let children = Set(model.items.filter { $0.parent == displayedFolder }.map(\.id))
        let ids = orderedIDs.filter { displayedFolder == nil || children.contains($0) }
        let saved = Dictionary(uniqueKeysWithValues: model.items.compactMap { item -> (UUID, CGPoint)? in
            guard let p = displayedFolder == nil ? item.rootPosition : item.localPosition else { return nil }
            return (item.id, CGPoint(x: p.x, y: p.y))
        })
        current.update(ids, saved: saved); layout = current; layouts[key] = current
    }
    private func transition(to folder: UUID?) {
        navigationTask?.cancel(); revealTask?.cancel()
        hovered = nil; revealed = nil; dragBase = nil
        guard movement, folder != displayedFolder else {
            transitioning = false; displayedFolder = folder; expansion = 1; mapOpacity = 1
            syncEntries(); fit(size: viewport); return
        }
        transitioning = true
        let destination = folder.flatMap { layout.positions[$0] }
        withAnimation(.easeInOut(duration: 0.4)) {
            if let destination {
                zoom = min(4, max(1.8, zoom * 2.2))
                offset = SpaceLayout.centeringOffset(destination, zoom: zoom)
            } else { zoom *= 0.65 }
            mapOpacity = 0.12
        }
        navigationTask = Task { @MainActor in
            do { try await Task.sleep(for: .milliseconds(400)) } catch { return }
            guard !Task.isCancelled, contextFolder == folder else { return }
            // A fresh local constellation grows from the selected galaxy.
            var transaction = Transaction(); transaction.disablesAnimations = true
            withTransaction(transaction) {
                displayedFolder = folder; syncEntries(); fit(size: viewport)
                expansion = 0.08; mapOpacity = 0
            }
            do { try await Task.sleep(for: .milliseconds(25)) } catch { return }
            guard !Task.isCancelled else { return }
            withAnimation(.easeOut(duration: 0.65)) { expansion = 1; mapOpacity = 1 }
            do { try await Task.sleep(for: .milliseconds(650)) } catch { return }
            guard !Task.isCancelled else { return }
            transitioning = false; syncEntries()
        }
    }
    private func changeZoom(_ value: Double) {
        model.touch(); let next = min(4, max(0.0001, value))
        offset = CGSize(width: offset.width * next / zoom, height: offset.height * next / zoom); zoom = next
    }
    private func magnify(_ delta: Double, at location: CGPoint, size: CGSize) {
        guard !transitioning, dragged == nil, model.phase == .unlocked, scenePhase == .active else { return }
        model.touch()
        let next = min(4, max(0.0001, zoom * max(0.01, 1 + delta)))
        let nextOffset = SpaceLayout.zoomOffset(at: location, size: size, oldZoom: zoom, newZoom: next, offset: offset)
        var transaction = Transaction(); transaction.disablesAnimations = true
        withTransaction(transaction) { zoom = next; offset = nextOffset }
    }
    private func fit(size: CGSize) {
        guard size.width > 0 else { return }
        dragBase = nil
        offset = .zero; zoom = layout.fitZoom(ids: entries.map(\.id), size: size)
    }
    private func reveal(_ id: UUID?, fitCamera: Bool = true) {
        guard let id else { return }
        guard !transitioning else { return }
        syncEntries()
        revealed = id; revealTask?.cancel()
        let p = point(id, size: viewport)
        if fitCamera && (p.x < 60 || p.x > viewport.width - 60 || p.y < 80 || p.y > viewport.height - 100) {
            fit(size: viewport)
        }
        revealTask = Task { @MainActor in
            try? await Task.sleep(for: .seconds(3))
            if !Task.isCancelled { revealed = nil }
        }
    }
}

private struct StarButton: View {
    let item: VaultItem
    let emphasized: Bool
    let animate: Bool
    let canMove: Bool
    let dragCancellation: Int
    let open: () -> Void
    let drag: (CGSize) -> Void
    let endDrag: () -> Void
    let cancelDrag: () -> Void
    let nudge: (CGSize) -> Void
    let hover: (Bool) -> Void
    @State private var pointer = SpacePointerInteraction()
    @State private var pulsing = false
    @FocusState private var focused: Bool
    private var highlighted: Bool { emphasized || focused }
    private var interactive: some View {
        Group {
            if item.isFolder { GalaxyGlyph().frame(width: highlighted ? 40 : 34, height: highlighted ? 36 : 30) }
            else { StarGlyph(style: .resolve(kind: item.kind.rawValue, name: item.name), emphasized: highlighted) }
        }.scaleEffect(pulsing ? 1.1 : 1).opacity(item.isTrashed ? 0.5 : 1)
            .frame(width: 44, height: 44).contentShape(Circle())
            .overlay { if focused { Circle().stroke(Theme.amber.opacity(0.65), lineWidth: 0.8).frame(width: 36, height: 36) } }
            .focusable().focusEffectDisabled().focused($focused)
            .gesture(DragGesture(minimumDistance: 0, coordinateSpace: .named("SpaceMap")).onChanged { value in
                focused = true
                pointer.update(value.translation)
                if pointer.moved && !pointer.cancelled && canMove { drag(value.translation) }
            }.onEnded { _ in
                switch pointer.finish() {
                case .open: open()
                case .move: endDrag()
                case .cancel: cancelDrag()
                }
            })
            .onKeyPress(.return) { open(); return .handled }
            .onKeyPress(.escape) {
                guard pointer.moved else { return .ignored }
                pointer.cancel(); cancelDrag(); return .handled
            }
            .onKeyPress(phases: .down, action: handleKey)
    }
    private func handleKey(_ press: KeyPress) -> KeyPress.Result {
        guard canMove, press.modifiers.contains(.option) else { return .ignored }
        let delta: CGSize
        switch press.key {
        case .leftArrow: delta = CGSize(width: -20, height: 0)
        case .rightArrow: delta = CGSize(width: 20, height: 0)
        case .upArrow: delta = CGSize(width: 0, height: -20)
        case .downArrow: delta = CGSize(width: 0, height: 20)
        default: return .ignored
        }
        nudge(delta); return .handled
    }
    var body: some View {
        interactive
            .accessibilityElement(children: .ignore).accessibilityAddTraits(.isButton)
            .accessibilityLabel(item.name).accessibilityValue(typeLabel(item) + (item.kind == .file ? ", " + sizeLabel(item) : ""))
            .accessibilityHint(item.isTrashed ? "Контекстное меню для восстановления" : "Нажми для открытия. Перетащи для расположения. Option и стрелки перемещают объект.")
            .accessibilityAction { open() }
            .accessibilityAction(named: Text("Сдвинуть влево")) { if canMove { nudge(CGSize(width: -20, height: 0)) } }
            .accessibilityAction(named: Text("Сдвинуть вправо")) { if canMove { nudge(CGSize(width: 20, height: 0)) } }
            .accessibilityAction(named: Text("Сдвинуть вверх")) { if canMove { nudge(CGSize(width: 0, height: -20)) } }
            .accessibilityAction(named: Text("Сдвинуть вниз")) { if canMove { nudge(CGSize(width: 0, height: 20)) } }
            .onHover(perform: hover).onChange(of: focused) { _, focus in hover(focus); updatePulse() }
            .onAppear { updatePulse() }.onChange(of: animate) { _, _ in updatePulse() }
            .onChange(of: dragCancellation) { _, _ in pointer.cancel() }
            .onChange(of: emphasized) { _, _ in updatePulse() }
            .animation(animate ? .easeOut(duration: 0.2) : nil, value: highlighted)
    }
    private func updatePulse() {
        if animate && highlighted { withAnimation(.easeInOut(duration: 1.4).repeatForever(autoreverses: true)) { pulsing = true } }
        else { withAnimation(.easeOut(duration: 0.15)) { pulsing = false } }
    }
}

private struct CameraButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label.foregroundStyle(configuration.isPressed ? Theme.text : Theme.muted)
            .background(configuration.isPressed ? Theme.amber.opacity(0.16) : .clear, in: RoundedRectangle(cornerRadius: 7))
    }
}

/// Two open spiral arms and a luminous core stay legible at folder-node sizes.
private struct GalaxyGlyph: View {
    var body: some View {
        Canvas { context, size in
            let scale = min(size.width, size.height)
            let center = CGPoint(x: size.width / 2, y: size.height / 2)
            for arm in 0..<2 {
                var path = Path()
                for step in 0...64 {
                    let t = Double(step) / 64
                    let radius = scale * (0.035 + t * 0.43)
                    let angle = t * 4.8 + Double(arm) * .pi - 0.7
                    let p = CGPoint(x: center.x + cos(angle) * radius, y: center.y + sin(angle) * radius * 0.72)
                    if step == 0 { path.move(to: p) } else { path.addLine(to: p) }
                    if step > 12 && step % 5 == 0 {
                        let dot = max(0.8, scale * 0.012)
                        context.fill(Path(ellipseIn: CGRect(x: p.x + sin(t * 40) * scale * 0.04, y: p.y + cos(t * 33) * scale * 0.04, width: dot, height: dot)), with: .color(Theme.text.opacity(0.65)))
                    }
                }
                var glow = context; glow.addFilter(.blur(radius: scale * 0.045))
                glow.stroke(path, with: .color(Theme.amber.opacity(0.7)), lineWidth: scale * 0.1)
                context.stroke(path, with: .color(Theme.amber.opacity(0.85)), style: StrokeStyle(lineWidth: max(1, scale * 0.025), lineCap: .round))
            }
            let core = scale * 0.13
            var glow = context; glow.addFilter(.blur(radius: scale * 0.07))
            glow.fill(Path(ellipseIn: CGRect(x: center.x - core, y: center.y - core, width: core * 2, height: core * 2)), with: .color(Theme.amber.opacity(0.65)))
            context.fill(Path(ellipseIn: CGRect(x: center.x - core / 2, y: center.y - core / 2, width: core, height: core)), with: .color(Theme.text))
        }.accessibilityHidden(true)
    }
}

/// Interpolate Canvas coordinates along with the star buttons during camera travel.
private struct SpaceBackdrop: View, Animatable {
    let entries: [VaultItem]
    let positions: [UUID: CGPoint]
    let hovered: UUID?
    let folder: UUID?
    let hidden: Set<UUID>
    var zoom: Double
    var offset: CGSize
    var expansion: Double
    nonisolated var animatableData: AnimatablePair<AnimatablePair<Double, Double>, AnimatablePair<Double, Double>> {
        get { .init(.init(zoom, expansion), .init(offset.width, offset.height)) }
        set {
            zoom = newValue.first.first; expansion = newValue.first.second
            offset = CGSize(width: newValue.second.first, height: newValue.second.second)
        }
    }
    private func point(_ id: UUID?, size: CGSize) -> CGPoint {
        let world = id.flatMap { positions[$0] } ?? .zero
        return SpaceLayout.screenPoint(CGPoint(x: world.x * expansion, y: world.y * expansion), size: size, zoom: zoom, offset: offset)
    }
    var body: some View {
        Canvas { context, canvas in
            for i in 0..<100 {
                let x = CGFloat((i * 173 + 31) % 997) / 997 * canvas.width
                let y = CGFloat((i * 227 + 71) % 991) / 991 * canvas.height
                context.fill(Path(ellipseIn: CGRect(x: x, y: y, width: 1, height: 1)), with: .color(.white.opacity(i % 7 == 0 ? 0.17 : 0.06)))
            }
            let present = Set(entries.map(\.id))
            for item in entries where !hidden.contains(item.id) {
                let to = point(item.id, size: canvas)
                let from = point(item.parent.flatMap { present.contains($0) ? $0 : nil }, size: canvas)
                // Clip distant connections before drawing; all records retain positions.
                if max(to.x, from.x) < 0 || min(to.x, from.x) > canvas.width || max(to.y, from.y) < 0 || min(to.y, from.y) > canvas.height { continue }
                var path = Path(); path.move(to: from); path.addLine(to: to)
                let highlighted = hovered != nil && (hovered == item.id || hovered == item.parent)
                context.stroke(path, with: .color(Theme.amber.opacity(highlighted ? 0.36 : folder == nil && item.parent == nil ? 0.055 : 0.16)), lineWidth: highlighted ? 1 : 0.65)
            }
        }
    }
}
