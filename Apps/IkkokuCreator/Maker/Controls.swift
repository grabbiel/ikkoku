import SwiftUI
import AppKit
import Character

extension Color {
    init(_ rgb: RGB) { self.init(.sRGB, red: Double(rgb.r), green: Double(rgb.g), blue: Double(rgb.b), opacity: 1) }
}

func rgbBinding(_ b: Binding<RGB>) -> Binding<Color> {
    Binding<Color>(get: { Color(b.wrappedValue) }, set: { c in
        if let comps = NSColor(c).usingColorSpace(.sRGB) {
            b.wrappedValue = RGB(Float(comps.redComponent), Float(comps.greenComponent), Float(comps.blueComponent))
        }
    })
}

struct SliderRow: View {
    let label: String
    @Binding var value: Float
    var range: ClosedRange<Float> = -100...100
    var defaultValue: Float = 0
    var format: String = "%.0f"

    var body: some View {
        HStack(spacing: 8) {
            Text(label).font(.callout).frame(width: 118, alignment: .leading).lineLimit(1)
            Slider(value: $value, in: range)
            TextField("", value: $value, format: .number.precision(.fractionLength(0)))
                .textFieldStyle(.roundedBorder).frame(width: 52).font(.caption).multilineTextAlignment(.trailing)
            Button { value = defaultValue } label: { Image(systemName: "arrow.counterclockwise") }
                .buttonStyle(.borderless).help("Reset")
        }
    }
}

struct FloatRow: View {
    let label: String
    @Binding var value: Float
    var range: ClosedRange<Float> = 0...1
    var body: some View {
        HStack(spacing: 8) {
            Text(label).font(.callout).frame(width: 118, alignment: .leading)
            Slider(value: $value, in: range)
            Text(String(format: "%.2f", value)).font(.caption.monospacedDigit()).frame(width: 40, alignment: .trailing)
        }
    }
}

struct ColorRow: View {
    let label: String
    @Binding var color: RGB
    var body: some View {
        HStack {
            Text(label).font(.callout).frame(width: 118, alignment: .leading)
            ColorPicker("", selection: rgbBinding($color), supportsOpacity: false).labelsHidden()
            Spacer()
            ForEach(ColorRow.swatches, id: \.self) { sw in
                Button { color = RGB(hex: sw) } label: {
                    RoundedRectangle(cornerRadius: 3).fill(Color(RGB(hex: sw))).frame(width: 14, height: 14)
                        .overlay(RoundedRectangle(cornerRadius: 3).stroke(.secondary.opacity(0.4)))
                }.buttonStyle(.plain)
            }
        }
    }
    static let swatches: [UInt32] = [0xFFFFFF, 0x2B2B2B, 0xE04E6B, 0xF2A6B4, 0xF0C36B, 0x5D8C6E, 0x4C7A9D, 0x8D6BC7, 0x6A4A3F]
}

struct ItemGrid: View {
    struct Entry: Identifiable { let id: String; let name: String; var thumb: URL? = nil }
    let entries: [Entry]
    let selected: String?
    let allowNone: Bool
    let onSelect: (String?) -> Void

    private var hasThumbs: Bool { entries.contains { $0.thumb != nil } }

    var body: some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: hasThumbs ? 84 : 96), spacing: 6)], spacing: 6) {
            if allowNone {
                cell(id: nil, name: "None", thumb: nil)
            }
            ForEach(entries) { e in cell(id: e.id, name: e.name, thumb: e.thumb) }
        }
    }

    private func cell(id: String?, name: String, thumb: URL?) -> some View {
        Button { onSelect(id) } label: {
            VStack(spacing: 2) {
                if hasThumbs {
                    Group {
                        if let thumb, let img = NSImage(contentsOf: thumb) {
                            Image(nsImage: img).resizable().aspectRatio(contentMode: .fill)
                        } else {
                            Image(systemName: id == nil ? "nosign" : "photo").foregroundStyle(.secondary)
                        }
                    }
                    .frame(width: 76, height: 76).clipShape(RoundedRectangle(cornerRadius: 5))
                }
                Text(name).font(.caption2).lineLimit(2).multilineTextAlignment(.center).frame(maxWidth: .infinity, minHeight: hasThumbs ? 14 : 34)
            }
            .padding(4)
            .background(RoundedRectangle(cornerRadius: 6).fill(selected == id ? Color.accentColor.opacity(0.35) : Color.secondary.opacity(0.12)))
            .overlay(RoundedRectangle(cornerRadius: 6).stroke(selected == id ? Color.accentColor : .clear))
        }.buttonStyle(.plain)
    }
}

/// Thumbnails rendered by `IKKOKU_RENDER_THUMBS` live in `<assets>/Thumbs/<kind>_<id>.png`.
enum Thumbs {
    nonisolated(unsafe) static var root: URL?
    static func url(_ kind: String, _ id: String) -> URL? {
        guard let root else { return nil }
        let u = root.appendingPathComponent("Thumbs/\(kind)_\(id).png")
        return FileManager.default.fileExists(atPath: u.path) ? u : nil
    }
}

struct SectionBox<Content: View>: View {
    let title: String
    @ViewBuilder var content: () -> Content
    @State private var expanded = true
    var body: some View {
        DisclosureGroup(isExpanded: $expanded) {
            VStack(alignment: .leading, spacing: 6) { content() }.padding(.top, 4)
        } label: { Text(title).font(.headline) }
    }
}

struct StylePicker: View {
    let label: String
    let count: Int
    @Binding var index: Int
    var body: some View {
        HStack {
            Text(label).font(.callout).frame(width: 118, alignment: .leading)
            Picker("", selection: $index) {
                ForEach(0..<max(count, 1), id: \.self) { i in Text("Style \(i + 1)").tag(i) }
            }.labelsHidden()
            Stepper("", value: $index, in: 0...max(count - 1, 0)).labelsHidden()
        }
    }
}
