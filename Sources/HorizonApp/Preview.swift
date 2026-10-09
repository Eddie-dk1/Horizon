import SwiftUI
import PDFKit
import ImageIO
import UniformTypeIdentifiers
import HorizonCore

final class FittingPDFView: PDFView {
    private var fittedSize = CGSize.zero
    var fitMultiplier = 1.0 { didSet { fitPage() } }
    private func fitPage() {
        guard bounds.width > 24, bounds.height > 24, let page = document?.page(at: 0) else { return }
        var pageSize = page.bounds(for: .cropBox).size
        if abs(page.rotation) % 180 == 90 { pageSize = CGSize(width: pageSize.height, height: pageSize.width) }
        guard pageSize.width > 0, pageSize.height > 0 else { return }
        scaleFactor = min((bounds.width - 24) / pageSize.width, (bounds.height - 24) / pageSize.height) * fitMultiplier
    }
    override func layout() {
        super.layout()
        if bounds.size != fittedSize, bounds.width > 0, bounds.height > 0 {
            fittedSize = bounds.size
            fitPage()
        }
    }
}
struct PDFPreview: NSViewRepresentable {
    let data: Data
    let zoom: Double
    func makeNSView(context: Context) -> FittingPDFView {
        let view = FittingPDFView(); view.autoScales = false; view.minScaleFactor = 0.01; view.maxScaleFactor = 20
        view.displayMode = .singlePageContinuous; view.backgroundColor = NSColor(Theme.surface)
        view.document = PDFDocument(data: data); view.fitMultiplier = zoom; return view
    }
    func updateNSView(_ view: FittingPDFView, context: Context) { if view.fitMultiplier != zoom { view.fitMultiplier = zoom } }
    static func dismantleNSView(_ view: FittingPDFView, coordinator: ()) { view.document = nil }
}
struct PDFReader: View {
    let data: Data
    @State private var zoom = 1.0
    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 16) {
                Spacer()
                Button { zoom = max(0.25, zoom / 1.25) } label: { Image(systemName: "minus.magnifyingglass") }.accessibilityLabel("Уменьшить PDF").disabled(zoom <= 0.25)
                Button("По размеру окна") { zoom = 1 }
                Button { zoom = min(8, zoom * 1.25) } label: { Image(systemName: "plus.magnifyingglass") }.accessibilityLabel("Увеличить PDF").disabled(zoom >= 8)
            }.buttonStyle(.plain).font(.system(size: 12)).foregroundStyle(Theme.muted).padding(12)
            PDFPreview(data: data, zoom: zoom)
        }
    }
}
struct PreviewOverlay: View {
    @EnvironmentObject private var model: AppModel
    let item: VaultItem
    var body: some View {
        ZStack {
            Color.black.opacity(0.7).ignoresSafeArea()
            VStack(spacing: 0) {
                HStack {
                    Image(systemName: itemSymbol(item)).foregroundStyle(Theme.amber)
                    Text(item.isNote ? "Заметка" : item.name).lineLimit(1)
                    Spacer()
                    if item.isNote { Text(model.noteStatus).font(.system(size: 11)).foregroundStyle(model.dirtyNote ? Theme.amber : Theme.muted) }
                    Button("Сохранить копию…") { Task { await model.export(item) } }.buttonStyle(HorizonButtonStyle()).disabled(model.busy || model.previewLoading)
                    Button { Task { await model.closePreview() } } label: { Image(systemName: "xmark").padding(8) }.buttonStyle(.plain).help("Закрыть просмотр")
                }.padding(20)
                Rectangle().fill(Theme.line).frame(height: 1)
                if model.previewLoading { ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity) }
                else if item.isNote { note }
                else { content }
            }.background(Theme.surface, in: RoundedRectangle(cornerRadius: 18)).overlay(RoundedRectangle(cornerRadius: 18).stroke(Theme.line)).padding(40)
        }.accessibilityAddTraits(.isModal)
    }
    private var note: some View {
        VStack(alignment: .leading, spacing: 15) {
            TextField("Название", text: $model.noteTitle).textFieldStyle(.plain).font(.system(size: 28, weight: .light)).onChange(of: model.noteTitle) { _, _ in model.noteChanged() }
            TextEditor(text: $model.noteText).scrollContentBackground(.hidden).font(.system(size: 16 * model.preferences.textScale)).disableAutocorrection(true)
                .onChange(of: model.noteText) { old, new in
                    if new.utf8.count > VaultService.noteLimit {
                        model.noteText = old
                        model.error = "Лимит заметки — 1 МиБ. Предыдущий текст сохранён. Более крупный материал можно добавить как файл."
                        return
                    }
                    model.noteChanged()
                }
            HStack { Text("Текст сохраняется автоматически"); Spacer(); Text(ByteCountFormatter.string(fromByteCount: Int64(model.noteText.utf8.count), countStyle: .memory) + " / 1 МиБ") }.font(.system(size: 10)).foregroundStyle(Theme.muted)
        }.padding(26)
    }
    @ViewBuilder private var content: some View {
        if let data = model.previewData {
            if let image = safeImage(data) { Image(nsImage: image).resizable().scaledToFit().padding(24).frame(maxWidth: .infinity, maxHeight: .infinity) }
            else if data.starts(with: Data("%PDF-".utf8)), PDFDocument(data: data) != nil { PDFReader(data: data) }
            else if let text = textPrefix(data) {
                ScrollView { Text(text).font(.system(size: 14 * model.preferences.textScale, design: .monospaced)).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading).padding(26) }
                if data.count > 1024 * 1024 { Text("Показан первый 1 МиБ текста.").font(.system(size: 11)).foregroundStyle(Theme.muted).padding(12) }
            } else { unsupported("Для этого формата доступен экспорт.") }
        } else { unsupported("Файл больше 32 МиБ. Сохрани копию для открытия в другой программе.") }
    }
    private func unsupported(_ description: String) -> some View {
        VStack(spacing: 16) { Image(systemName: itemSymbol(item)).font(.system(size: 56, weight: .ultraLight)).foregroundStyle(Theme.amber); Text(item.name).font(.system(size: 22, weight: .light)); Text(sizeLabel(item)).foregroundStyle(Theme.muted); Text(description).foregroundStyle(Theme.muted).multilineTextAlignment(.center).frame(maxWidth: 440) }.frame(maxWidth: .infinity, maxHeight: .infinity)
    }
    private func safeImage(_ data: Data) -> NSImage? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? Int, let height = properties[kCGImagePropertyPixelHeight] as? Int,
              width > 0, height > 0, UInt64(width) <= 40_000_000 / UInt64(height),
              let image = CGImageSourceCreateImageAtIndex(source, 0, [kCGImageSourceShouldCache: false] as CFDictionary) else { return nil }
        return NSImage(cgImage: image, size: NSSize(width: width, height: height))
    }
    private func textPrefix(_ data: Data) -> String? {
        var prefix = Data(data.prefix(1024 * 1024))
        guard !prefix.contains(0) else { return nil }
        for _ in 0..<4 { if let string = String(data: prefix, encoding: .utf8) { return string }; if prefix.isEmpty { break }; prefix.removeLast() }
        return nil
    }
}
