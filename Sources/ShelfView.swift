import SwiftUI

/// State shared between the shelf window (AppKit) and its SwiftUI content.
final class ShelfModel: ObservableObject {
    @Published var items: [MenuExtra] = []
    /// What the search box shows (assembled Hangul syllables).
    @Published var query = ""
    /// What was actually typed, key by key (jamo for Korean). Search matches on this, so the
    /// in-between states of Hangul composition (a syllable briefly absorbing the next consonant
    /// as its final) never hide the right result.
    var keys: [String] = [] { didSet { query = Hangul.compose(keys) } }
    var searchKey: String { keys.joined() }
    @Published var selectedID: String?
    @Published var open = false
    @Published var iconsVersion = 0
    /// Icon images frozen when the shelf opens: a capture landing mid-session must not change tile
    /// sizes under the user (it applies from the next opening).
    var iconSnapshot: [String: IconImage] = [:]
    @Published var contentSize: CGSize = .zero
    /// Size of the notch (or a thin sliver on screens without one): where the panel grows from.
    @Published var closedSize = CGSize(width: 180, height: 32)
    /// Height covered by the notch / menu bar; content starts below it.
    @Published var topInset: CGFloat = 32
    @Published var glass = false
    /// Tiles start hidden and are revealed one after another (only in the full animation mode).
    @Published var revealed = true
    /// The shelf has the keyboard (its window is key): the search box shows a blinking caret.
    @Published var searchFocused = false
    /// Last keystroke: the caret stays solid while typing and blinks from here on, like a text field.
    @Published var lastTyped = Date()
    var onFocusSearch: (() -> Void)?
    /// The size the shelf opened with. While searching the content is pinned to it, so typing
    /// never makes the panel shrink and grow (results change *inside* a fixed frame).
    @Published var lockedSize: CGSize?

    var isSearching: Bool { !query.isEmpty }

    func matches(_ item: MenuExtra) -> Bool {
        Hangul.matches(item.searchText, searchKey) || Hangul.matches(item.searchText, query)
    }

    /// Grid search: non-matching tiles stay where they are, dimmed (spatial memory is kept).
    func isDimmed(_ item: MenuExtra) -> Bool {
        isSearching && Settings.shared.layout == .grid && !matches(item)
    }

    var onPick: ((MenuExtra) -> Void)?
    var onSettings: (() -> Void)?
    /// Last known frame of each tile in the hosting view (SwiftUI global space, top-left origin).
    /// Plain storage, not published: it only feeds the fly-to animation.
    var tileFrames: [String: CGRect] = [:]

    struct Section: Identifiable {
        let id: String
        let title: String?
        let items: [MenuExtra]
    }

    var sections: [Section] {
        let st = Settings.shared
        let visible = st.ordered(items.filter { !st.hiddenKeys.contains($0.cacheKey) })
        // List search: matches gather at the top (the rest of the fixed-size shelf stays empty).
        // Grid search keeps every section as is and dims the tiles that don't match.
        if isSearching && st.layout == .list {
            let hits = visible.filter(matches)
            return hits.isEmpty ? [] : [Section(id: "results", title: nil, items: hits)]
        }
        let pinned = visible.filter { st.pinnedKeys.contains($0.cacheKey) }
        var rest = visible.filter { !st.pinnedKeys.contains($0.cacheKey) }
        var out: [Section] = []
        if !pinned.isEmpty { out.append(Section(id: "pinned", title: L("Pinned"), items: pinned)) }
        if st.groupHidden {
            let hidden = rest.filter(\.hiddenHere)
            rest = rest.filter { !$0.hiddenHere }
            if !hidden.isEmpty { out.append(Section(id: "hidden", title: L("Hidden in the menu bar"), items: hidden)) }
        }
        if !rest.isEmpty { out.append(Section(id: "rest", title: out.isEmpty ? nil : L("Menu bar"), items: rest)) }
        return out
    }

    /// What the keyboard moves through: only matches while searching (dimmed tiles are skipped).
    var flat: [MenuExtra] {
        let all = sections.flatMap(\.items)
        return isSearching ? all.filter(matches) : all
    }
    var selected: MenuExtra? { flat.first { $0.id == selectedID } }

    func move(_ delta: Int) {
        let f = flat
        guard !f.isEmpty else { return }
        let i = f.firstIndex { $0.id == selectedID } ?? (delta > 0 ? -1 : f.count)
        selectedID = f[max(0, min(f.count - 1, i + delta))].id
    }
}

struct SizeKey: PreferenceKey {
    static var defaultValue: CGSize = .zero
    static func reduce(value: inout CGSize, nextValue: () -> CGSize) { value = nextValue() }
}

/// A shape that hangs from the top edge like the notch: concave flares where it meets
/// the screen edge, rounded bottom corners. Both radii animate, so it can morph out of the notch.
struct NotchShape: Shape {
    var topRadius: CGFloat
    var bottomRadius: CGFloat

    var animatableData: AnimatablePair<CGFloat, CGFloat> {
        get { AnimatablePair(topRadius, bottomRadius) }
        set { topRadius = newValue.first; bottomRadius = newValue.second }
    }

    func path(in r: CGRect) -> Path {
        let t = min(topRadius, r.width / 4), b = min(bottomRadius, (r.width - 2 * t) / 2, r.height / 2)
        var p = Path()
        p.move(to: CGPoint(x: r.minX, y: r.minY))
        p.addQuadCurve(to: CGPoint(x: r.minX + t, y: r.minY + t), control: CGPoint(x: r.minX + t, y: r.minY))
        p.addLine(to: CGPoint(x: r.minX + t, y: r.maxY - b))
        p.addQuadCurve(to: CGPoint(x: r.minX + t + b, y: r.maxY), control: CGPoint(x: r.minX + t, y: r.maxY))
        p.addLine(to: CGPoint(x: r.maxX - t - b, y: r.maxY))
        p.addQuadCurve(to: CGPoint(x: r.maxX - t, y: r.maxY - b), control: CGPoint(x: r.maxX - t, y: r.maxY))
        p.addLine(to: CGPoint(x: r.maxX - t, y: r.minY + t))
        p.addQuadCurve(to: CGPoint(x: r.maxX, y: r.minY), control: CGPoint(x: r.maxX - t, y: r.minY))
        p.closeSubpath()
        return p
    }
}

/// Outline of the shelf, shared by the live panel (Core Animation) and previews (SwiftUI):
/// a "neck" exactly as wide as the notch fills the menu bar height, and the body widens only
/// *below* the menu bar, so the shelf never sits on top of real menu bar items. Smooth concave
/// shoulders join neck and body. Coordinates are y-down. The path always has the same elements,
/// so Core Animation can interpolate between the closed (just the notch) and open outlines.
enum ShelfPath {
    static func make(cx: CGFloat, top: CGFloat = 0, neckWidth: CGFloat, neckHeight: CGFloat,
                     bodyWidth: CGFloat, bodyBottom: CGFloat,
                     shoulder: CGFloat = 12, topCorner: CGFloat = 18, bottomCorner: CGFloat = 26) -> CGPath {
        let nw = max(neckWidth, 0)
        let nl = cx - nw / 2, nr = cx + nw / 2
        let bt = top + neckHeight
        let bb = max(bodyBottom, bt)
        let bodyH = bb - bt
        let bw = max(bodyWidth, nw)
        let minX = cx - bw / 2, maxX = cx + bw / 2
        let side = max(nl - minX, 0)
        let s = nw > 0 ? max(0, min(shoulder, bodyH / 2, side / 2)) : 0
        let tc = max(0, min(topCorner, bodyH / 2, side - s))
        let bc = max(0, min(bottomCorner, bodyH - tc, bw / 2))
        let p = CGMutablePath()
        p.move(to: CGPoint(x: nl, y: top))
        p.addLine(to: CGPoint(x: nl, y: bt - s))
        p.addQuadCurve(to: CGPoint(x: nl - s, y: bt), control: CGPoint(x: nl, y: bt))
        p.addLine(to: CGPoint(x: minX + tc, y: bt))
        p.addQuadCurve(to: CGPoint(x: minX, y: bt + tc), control: CGPoint(x: minX, y: bt))
        p.addLine(to: CGPoint(x: minX, y: bb - bc))
        p.addQuadCurve(to: CGPoint(x: minX + bc, y: bb), control: CGPoint(x: minX, y: bb))
        p.addLine(to: CGPoint(x: maxX - bc, y: bb))
        p.addQuadCurve(to: CGPoint(x: maxX, y: bb - bc), control: CGPoint(x: maxX, y: bb))
        p.addLine(to: CGPoint(x: maxX, y: bt + tc))
        p.addQuadCurve(to: CGPoint(x: maxX - tc, y: bt), control: CGPoint(x: maxX, y: bt))
        p.addLine(to: CGPoint(x: nr + s, y: bt))
        p.addQuadCurve(to: CGPoint(x: nr, y: bt - s), control: CGPoint(x: nr, y: bt))
        p.addLine(to: CGPoint(x: nr, y: top))
        p.closeSubpath()
        return p
    }
}

/// SwiftUI wrapper of ShelfPath (used for off-screen previews).
struct NeckShape: Shape {
    var neckWidth: CGFloat
    var neckHeight: CGFloat
    func path(in r: CGRect) -> Path {
        Path(ShelfPath.make(cx: r.midX, top: r.minY, neckWidth: neckWidth, neckHeight: neckHeight,
                            bodyWidth: r.width, bodyBottom: r.maxY))
    }
}

/// Wraps tiles into rows, centered.
struct FlowLayout: Layout {
    var spacing: CGFloat = 6
    var maxWidth: CGFloat = 520

    private func rows(_ subviews: Subviews, width: CGFloat) -> [[(Int, CGSize)]] {
        var rows: [[(Int, CGSize)]] = [[]]
        var x: CGFloat = 0
        for (i, v) in subviews.enumerated() {
            let s = v.sizeThatFits(.unspecified)
            if x + s.width > width && !rows[rows.count - 1].isEmpty { rows.append([]); x = 0 }
            rows[rows.count - 1].append((i, s)); x += s.width + spacing
        }
        return rows
    }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = min(proposal.width ?? maxWidth, maxWidth)
        let rs = rows(subviews, width: width)
        let w = rs.map { $0.reduce(0) { $0 + $1.1.width } + spacing * CGFloat(max($0.count - 1, 0)) }.max() ?? 0
        let h = rs.map { $0.map(\.1.height).max() ?? 0 }.reduce(0, +) + spacing * CGFloat(max(rs.count - 1, 0))
        return CGSize(width: w, height: h)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var y = bounds.minY
        for row in rows(subviews, width: bounds.width) {
            let rw = row.reduce(0) { $0 + $1.1.width } + spacing * CGFloat(max(row.count - 1, 0))
            let rh = row.map(\.1.height).max() ?? 0
            var x = bounds.minX + (bounds.width - rw) / 2
            for (i, s) in row {
                subviews[i].place(at: CGPoint(x: x, y: y + (rh - s.height) / 2), proposal: ProposedViewSize(s))
                x += s.width + spacing
            }
            y += rh + spacing
        }
    }
}

struct ShelfRoot: View {
    @ObservedObject var model: ShelfModel
    @ObservedObject var settings: Settings

    var body: some View {
        let open = model.open
        let cs = model.contentSize == .zero ? CGSize(width: 320, height: 160) : model.contentSize
        ZStack(alignment: .top) {
            background(open: open, cs: cs)
            ShelfContent(model: model, settings: settings)
                .fixedSize()
                .opacity(open ? 1 : 0)
                .scaleEffect(open ? 1 : 0.9, anchor: .top)
                .blur(radius: open ? 0 : 5)
                .modifier(DarkIf(on: !model.glass))
        }
        .padding(.top, model.glass ? model.topInset + 6 : 0)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }

    @ViewBuilder
    private func background(open: Bool, cs: CGSize) -> some View {
        if model.glass {
            let shape = RoundedRectangle(cornerRadius: 22, style: .continuous)
            GlassFill(shape: shape)
                .overlay(shape.strokeBorder(Color.white.opacity(0.18), lineWidth: 0.5))
                .frame(width: open ? cs.width : cs.width * 0.7, height: open ? cs.height : cs.height * 0.3)
                .opacity(open ? 1 : 0)
                .shadow(color: .black.opacity(0.22), radius: 18, y: 8)
        } else {
            NeckShape(neckWidth: model.closedSize.width, neckHeight: model.topInset)
                .fill(Color.black)
                .frame(width: open ? cs.width : model.closedSize.width,
                       height: open ? cs.height : model.topInset)
                .shadow(color: .black.opacity(open ? 0.4 : 0), radius: 22, y: 10)
        }
    }
}

struct GlassFill<S: Shape>: View {
    let shape: S
    var body: some View {
        if #available(macOS 26.0, *) {
            Color.clear.glassEffect(.regular, in: shape)
        } else {
            shape.fill(.ultraThinMaterial)
        }
    }
}

struct DarkIf: ViewModifier {
    let on: Bool
    func body(content: Content) -> some View {
        if on { content.environment(\.colorScheme, .dark) } else { content }
    }
}

struct ShelfContent: View {
    @ObservedObject var model: ShelfModel
    @ObservedObject var settings: Settings
    @Namespace private var selection

    /// Center-out cascade: tiles nearest the notch (horizontal middle, top row) appear first.
    private func revealDelay(_ item: MenuExtra, index: Int) -> Double {
        guard let f = model.tileFrames[item.id], model.contentSize.width > 0 else { return min(0.3, 0.02 * Double(index)) }
        let dx = abs(f.midX - model.contentSize.width / 2) / 46
        let row = Double(Int(max(f.minY - 60, 0) / 46))
        return min(0.3, 0.035 + 0.022 * Double(dx) + 0.045 * row)
    }

    var body: some View {
        let sections = model.sections
        VStack(alignment: .leading, spacing: 10) {
            if !model.glass { Color.clear.frame(width: 1, height: model.topInset + 2) }
            header
            if model.isSearching && model.flat.isEmpty && settings.layout == .list {
                VStack(spacing: 6) {
                    Image(systemName: "magnifyingglass").font(.system(size: 20, weight: .light))
                    Text(L("Nothing matches “%@”", model.query)).font(.system(size: 12))
                }
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 14)
            }
            ForEach(sections) { s in
                VStack(alignment: .leading, spacing: 6) {
                    if let t = s.title {
                        HStack(spacing: 5) {
                            if s.id == "hidden" { Circle().fill(Color.orange).frame(width: 5, height: 5) }
                            if s.id == "pinned" { Image(systemName: "star.fill").font(.system(size: 8)) }
                            Text(t)
                        }
                        .font(.system(size: 10.5, weight: .semibold))
                        .foregroundStyle(.secondary)
                        .padding(.leading, 2)
                    }
                    if settings.layout == .list {
                        VStack(spacing: 2) {
                            ForEach(s.items) { item in
                                ListRow(model: model,
                                        selectionNS: selection,
                                        revealed: model.revealed,
                                        revealDelay: min(0.3, 0.03 + 0.022 * Double(model.flat.firstIndex { $0.id == item.id } ?? 0)),
                                        item: item,
                                        icon: icon(item),
                                        selected: model.selectedID == item.id,
                                        pinned: settings.pinnedKeys.contains(item.cacheKey),
                                        forceMono: settings.iconStyle == .monochrome,
                                        onPick: { model.onPick?(item) },
                                        onHover: { inside in if inside { model.selectedID = item.id } })
                                .transition(.opacity)
                            }
                        }
                        // Matches slide up into place as the search narrows; misses fade out.
                        .animation(settings.effectiveAnimation == .full ? .spring(response: 0.3, dampingFraction: 0.86) : nil,
                                   value: model.query)
                    } else {
                    FlowLayout(spacing: 6, maxWidth: 520) {
                        ForEach(Array(s.items.enumerated()), id: \.element.id) { index, item in
                            TileView(model: model,
                                     selectionNS: selection,
                                     dimmed: model.isDimmed(item),
                                     revealed: model.revealed,
                                     revealDelay: revealDelay(item, index: index),
                                     item: item,
                                     icon: icon(item),
                                     selected: model.selectedID == item.id,
                                     showLabel: settings.showLabels,
                                     forceMono: settings.iconStyle == .monochrome,
                                     onPick: { model.onPick?(item) },
                                     onHover: { inside in if inside { model.selectedID = item.id } })
                        }
                    }
                    }
                }
            }
            // Keeps the footer at the bottom of the fixed-size shelf while search results are fewer
            // (adds nothing when the content has its natural size).
            Spacer(minLength: 0)
            footer
        }
        .padding(.horizontal, 16)
        .padding(.top, model.glass ? 12 : 0)
        .padding(.bottom, 12)
        .frame(minWidth: 340, alignment: .leading)
        // While open, the content keeps the size it opened with (see ShelfModel.lockedSize).
        .frame(width: model.lockedSize?.width, height: model.lockedSize?.height, alignment: .top)
        // The selection highlight is one shape that glides between tiles.
        .animation(settings.effectiveAnimation == .full ? .spring(response: 0.3, dampingFraction: 0.8) : nil, value: model.selectedID)
    }

    private func icon(_ item: MenuExtra) -> IconImage? {
        if let frozen = model.iconSnapshot[item.id] { return frozen }
        return IconCache.shared.cached(item) ?? IconCache.fallback(item)
    }

    private var header: some View {
        HStack(spacing: 8) {
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                // Text and caret sit flush, like a real text field (no stack spacing between them).
                HStack(spacing: 0) {
                    if !model.query.isEmpty { Text(model.query).foregroundStyle(.primary) }
                    if model.searchFocused {
                        Caret(since: model.lastTyped).padding(.leading, model.query.isEmpty ? 0 : 1)
                    }
                    if model.query.isEmpty {
                        Text(L("Type to search")).foregroundStyle(.tertiary)
                            .padding(.leading, model.searchFocused ? 2 : 0)
                    }
                }
                Spacer(minLength: 0)
            }
            .font(.system(size: 12))
            .padding(.horizontal, 10)
            .frame(height: 28)
            .background(Capsule().fill(Color.primary.opacity(model.searchFocused ? 0.11 : 0.08)))
            .overlay(Capsule().strokeBorder(Color.accentColor.opacity(model.searchFocused ? 0.45 : 0), lineWidth: 1))
            .contentShape(Capsule())
            .onTapGesture { model.onFocusSearch?() }

            Button { model.onSettings?() } label: {
                Image(systemName: "gearshape.fill")
                    .font(.system(size: 12))
                    .frame(width: 28, height: 28)
                    .background(Circle().fill(Color.primary.opacity(0.08)))
                    .contentShape(Circle())
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .help(L("Settings (⌘,)"))
        }
    }

    private var footer: some View {
        HStack(spacing: 10) {
            if model.isSearching && model.flat.isEmpty {
                // The list says it in the middle of the shelf; the grid keeps its tiles, so it says it here.
                Text(settings.layout == .grid ? L("Nothing matches “%@”", model.query) : "")
                    .lineLimit(1).truncationMode(.middle)
            } else if let s = model.selected {
                Text(s.displayName + (s.hiddenHere ? L(" · hidden in the menu bar") : ""))
                    .lineLimit(1).truncationMode(.middle)
            } else {
                let hidden = model.items.filter(\.hiddenHere).count
                Text(hidden > 0 ? L("Hidden in the menu bar: %2$ld of %1$ld", model.items.count, hidden) : L("%ld items", model.items.count))
            }
            Spacer(minLength: 12)
            KeyHint(key: settings.layout == .list ? "↑↓" : "←→", label: L("Move"))
            KeyHint(key: "⏎", label: L("Open"))
            KeyHint(key: "esc", label: L("Close"))
        }
        .font(.system(size: 10.5))
        .foregroundStyle(.secondary)
        .padding(.top, 2)
    }
}

/// One row of the list layout: icon, name, owning app, hidden/pinned badges.
struct ListRow: View {
    let model: ShelfModel
    let selectionNS: Namespace.ID
    let revealed: Bool
    let revealDelay: Double
    let item: MenuExtra
    let icon: IconImage?
    let selected: Bool
    let pinned: Bool
    let forceMono: Bool
    let onPick: () -> Void
    let onHover: (Bool) -> Void
    @State private var hover = false
    private var motion: Bool { Settings.shared.effectiveAnimation == .full }

    private var secondary: String {
        if item.shortName != item.appName { return item.appName }
        let d = !item.title.isEmpty && item.title != item.shortName ? item.title : item.detail
        return d == "StatusItem" ? "" : d
    }

    /// Text-like icons (the clock, timers, "35%") are too wide for the icon column: show a symbol
    /// there and the captured content on the right, at its real size, like a value.
    private var isWide: Bool {
        guard let s = icon?.image.size, s.height > 0 else { return false }
        return s.width / s.height > 1.9
    }
    /// Wide icons: a symbol (system items) or the app's own icon in the icon column.
    private var leadingIcon: IconImage? { isWide ? (DemoContent.listSymbol(for: item) ?? IconCache.fallback(item) ?? icon) : icon }

    var body: some View {
        HStack(spacing: 12) {
            IconView(icon: leadingIcon, forceMono: forceMono, maxWidth: 28)
                .frame(width: 34)
                .background(GeometryReader { g in
                    Color.clear
                        .onAppear { model.tileFrames[item.id] = g.frame(in: .global) }
                        .onChange(of: g.frame(in: .global)) { _, f in model.tileFrames[item.id] = f }
                })
            VStack(alignment: .leading, spacing: 1) {
                Text(item.shortName).font(.system(size: 13, weight: .medium)).foregroundStyle(.primary)
                if !secondary.isEmpty {
                    Text(secondary).font(.system(size: 11)).foregroundStyle(.secondary)
                }
            }
            .lineLimit(1)
            Spacer(minLength: 8)
            if isWide {
                IconView(icon: icon, forceMono: forceMono, maxWidth: 170).opacity(0.85)
            }
            if pinned { Image(systemName: "star.fill").font(.system(size: 10)).foregroundStyle(.yellow) }
            if item.hiddenHere {
                Text(L("Hidden"))
                    .font(.system(size: 10, weight: .semibold))
                    .padding(.horizontal, 7).padding(.vertical, 2)
                    .background(Capsule().fill(Color.orange.opacity(0.2)))
                    .foregroundStyle(.orange)
            }
        }
        .padding(.horizontal, 10)
        .frame(width: 420, height: 38)
        .background {
            ZStack {
                RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Color.primary.opacity(hover ? 0.1 : 0))
                if selected {
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .fill(Color.accentColor.opacity(0.3))
                        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous)
                            .strokeBorder(Color.accentColor.opacity(0.85), lineWidth: 1.5))
                        .matchedGeometryEffect(id: "selection", in: selectionNS)
                }
            }
        }
        .contentShape(RoundedRectangle(cornerRadius: 10))
        .opacity(revealed ? 1 : 0)
        .offset(y: revealed ? 0 : -8)
        .animation(revealed && motion ? .spring(response: 0.38, dampingFraction: 0.78).delay(revealDelay) : nil, value: revealed)
        .onHover { hover = $0; onHover($0) }
        .onTapGesture(perform: onPick)
        .help(item.displayName)
    }
}

/// A text-field caret: solid right after a keystroke, then blinking on/off every 0.53 s (the macOS rate).
struct Caret: View {
    let since: Date
    var body: some View {
        TimelineView(.periodic(from: since, by: 0.53)) { ctx in
            let phase = Int(max(ctx.date.timeIntervalSince(since), 0) / 0.53) % 2
            RoundedRectangle(cornerRadius: 0.75)
                .fill(Color.accentColor)
                .frame(width: 1.5, height: 15)
                .opacity(phase == 0 ? 1 : 0)
        }
    }
}

struct KeyHint: View {
    let key: String
    let label: String
    var body: some View {
        HStack(spacing: 3) {
            Text(key)
                .font(.system(size: 9.5, weight: .semibold, design: .rounded))
                .padding(.horizontal, 4).padding(.vertical, 1)
                .background(RoundedRectangle(cornerRadius: 4).fill(Color.primary.opacity(0.1)))
            Text(label)
        }
    }
}

struct TileView: View {
    let model: ShelfModel
    let selectionNS: Namespace.ID
    let dimmed: Bool
    let revealed: Bool
    let revealDelay: Double
    let item: MenuExtra
    let icon: IconImage?
    let selected: Bool
    let showLabel: Bool
    let forceMono: Bool
    let onPick: () -> Void
    let onHover: (Bool) -> Void
    @State private var hover = false
    private var motion: Bool { Settings.shared.effectiveAnimation == .full }

    var body: some View {
        VStack(spacing: 4) {
            IconView(icon: icon, forceMono: forceMono)
            if showLabel {
                Text(item.shortName)
                    .font(.system(size: 10, weight: .medium))
                    .lineLimit(1).truncationMode(.tail)
                    .frame(maxWidth: 76)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, showLabel ? 8 : 9)
        .frame(minWidth: 42, minHeight: 38)
        .background {
            ZStack {
                RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Color.primary.opacity(hover ? 0.14 : 0.06))
                if selected {
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .fill(Color.accentColor.opacity(0.3))
                        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous)
                            .strokeBorder(Color.accentColor.opacity(0.85), lineWidth: 1.5))
                        .matchedGeometryEffect(id: "selection", in: selectionNS)
                }
            }
        }
        .overlay(alignment: .topTrailing) {
            if item.hiddenHere {
                Circle().fill(Color.orange).frame(width: 6, height: 6).padding(5)
            }
        }
        .scaleEffect(hover && motion && !dimmed ? 1.07 : 1)
        // Search: non-matches fade back in place and can't be hovered or clicked.
        .saturation(dimmed ? 0 : 1)
        .opacity(dimmed ? 0.22 : 1)
        .animation(motion ? .easeOut(duration: 0.16) : nil, value: dimmed)
        .allowsHitTesting(!dimmed)
        // Staggered entrance: drift down out of the notch, fade and settle.
        .opacity(revealed ? 1 : 0)
        .scaleEffect(revealed ? 1 : 0.86, anchor: .top)
        .offset(y: revealed ? 0 : -10)
        .animation(revealed && motion ? .spring(response: 0.42, dampingFraction: 0.72).delay(revealDelay) : nil, value: revealed)
        .animation(motion ? .spring(response: 0.22, dampingFraction: 0.65) : nil, value: hover)
        .animation(motion ? .easeOut(duration: 0.12) : nil, value: selected)
        .contentShape(RoundedRectangle(cornerRadius: 12))
        .background(GeometryReader { g in
            Color.clear
                .onAppear { model.tileFrames[item.id] = g.frame(in: .global) }
                .onChange(of: g.frame(in: .global)) { _, f in model.tileFrames[item.id] = f }
        })
        .onHover { hover = $0; onHover($0) }
        .onTapGesture(perform: onPick)
        .help(item.displayName)
    }

}

struct IconView: View {
    let icon: IconImage?
    let forceMono: Bool
    var maxWidth: CGFloat = 170

    /// Natural menu bar size (capped at 20pt tall), shrunk to fit `maxWidth`.
    private func fit(_ s: CGSize) -> (CGFloat, CGFloat) {
        var h = min(s.height, 20)
        var w = s.height > 0 ? s.width * h / s.height : h
        if w > maxWidth { h *= maxWidth / w; w = maxWidth }
        return (w, h)
    }

    var body: some View {
        if let icon {
            let (w, h) = fit(icon.image.size)
            Image(nsImage: icon.image)
                .renderingMode(icon.mono || forceMono ? .template : .original)
                .resizable()
                .interpolation(.high)
                .frame(width: w, height: h)
                .foregroundStyle(.primary)
        } else {
            Image(systemName: "app.dashed").font(.system(size: 16)).foregroundStyle(.secondary)
        }
    }
}
