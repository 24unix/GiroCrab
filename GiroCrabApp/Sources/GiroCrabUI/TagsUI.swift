import SwiftUI
import GiroCrabCore

// Booking tags (#228): free labels across categories ("für wen?", "welcher Urlaub?").
// Tag names often name people ("Sohn", "Frau"), so they are hidden like other
// personal data in bug report screenshots (`.sensitive()`, not `.labels`).

/// Left-to-right rows that wrap, for tag chips.
struct TagFlow: Layout {
    var spacing: CGFloat = 6
    /// Wraps at this width even when the container offers more (or nothing, as a
    /// popover does); the flow is only as wide as its longest row.
    var maxLineWidth: CGFloat = .infinity

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let maxWidth = min(proposal.width ?? .infinity, maxLineWidth)
        let rows = arrange(width: maxWidth, subviews)
        let width = rows.map { $0.width }.max() ?? 0
        let height = rows.reduce(0) { $0 + $1.height } + spacing * CGFloat(max(rows.count - 1, 0))
        return CGSize(width: min(width, maxWidth), height: height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var y = bounds.minY
        let width = min(bounds.width, maxLineWidth)
        for row in arrange(width: width, subviews) {
            var x = bounds.minX
            for i in row.items {
                let size = Self.size(of: subviews[i], maxWidth: width)
                subviews[i].place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(size))
                x += size.width + spacing
            }
            y += row.height + spacing
        }
    }

    /// The item's own width, but never wider than the container: a long tag
    /// name wraps (or is cut with „…“) instead of widening the inspector.
    private static func size(of s: LayoutSubview, maxWidth: CGFloat) -> CGSize {
        let ideal = s.sizeThatFits(.unspecified)
        guard ideal.width > maxWidth else { return ideal }
        return s.sizeThatFits(ProposedViewSize(width: maxWidth, height: nil))
    }

    private struct Row { var items: [Int] = []; var width: CGFloat = 0; var height: CGFloat = 0 }

    private func arrange(width: CGFloat, _ subviews: Subviews) -> [Row] {
        var rows: [Row] = []
        var row = Row()
        for (i, s) in subviews.enumerated() {
            let size = Self.size(of: s, maxWidth: width)
            let needed = row.items.isEmpty ? size.width : row.width + spacing + size.width
            if !row.items.isEmpty, needed > width {
                rows.append(row)
                row = Row()
            }
            row.width = row.items.isEmpty ? size.width : row.width + spacing + size.width
            row.height = max(row.height, size.height)
            row.items.append(i)
        }
        if !row.items.isEmpty { rows.append(row) }
        return rows
    }
}

/// One tag: colour dot and name; with `onRemove` an ✕, with `onTap` the chip is a button.
/// `partial` (multiple selection): only some of the bookings carry it.
struct TagChip: View {
    let name: String
    let colorHex: String
    var partial = false
    /// The suggestion Return would add (it matches the typed name).
    var highlighted = false
    var onTap: (() -> Void)?
    var onRemove: (() -> Void)?

    var body: some View {
        HStack(spacing: 4) {
            if let onTap {
                Button(action: onTap) { label }
                    .buttonStyle(.plain)
            } else {
                label
            }
            if let onRemove {
                Button(action: onRemove) {
                    Image(systemName: "xmark").font(.system(size: 8, weight: .bold))
                }
                .buttonStyle(.plain)
                .foregroundStyle(Theme.secondary)
                .layoutPriority(1)
                .accessibilityLabel(Text("„\(name)“ entfernen"))
            }
        }
        .padding(.horizontal, 7).padding(.vertical, 3)
        .background(shape.fill(tint.opacity(partial ? 0.06 : 0.14)))
        .overlay {
            if partial {
                shape.strokeBorder(tint.opacity(0.35), style: StrokeStyle(lineWidth: 1, dash: [3, 2]))
            } else {
                shape.strokeBorder(tint.opacity(highlighted ? 1 : 0.5), lineWidth: highlighted ? 2 : 1)
            }
        }
        .clipShape(shape)
    }

    /// A capsule on one line; stays round-cornered when a long name takes two.
    private var shape: RoundedRectangle { RoundedRectangle(cornerRadius: 10, style: .continuous) }

    private var tint: Color { colorHex.isEmpty ? Theme.secondary : Color(hex: colorHex) }

    private var label: some View {
        HStack(spacing: 4) {
            Circle().fill(tint).frame(width: 6, height: 6)
            // long names: a second line, then „…“ (the inspector keeps its width)
            Text(name).appFont(.caption).lineLimit(2).truncationMode(.tail).sensitive()
        }
        .foregroundStyle(partial ? Theme.secondary : Theme.text)
        .contentShape(Rectangle())
    }
}

/// Text field that adds a tag (an existing one or a new name) plus suggestions:
/// every existing tag matching the text; while empty the first ones and
/// „+n weitere“, which unfolds all of them.
struct TagEntryField: View {
    @Environment(AppModel.self) private var model
    /// Tags already carried by every booking: not suggested.
    let carried: Set<Int64>
    var focused: FocusState<Bool>.Binding
    /// Several bookings: the hint says „bei allen“.
    var multiple = false
    let add: (String) -> Void
    /// The booking the field belongs to: the inspector reuses it for the next one, so what was
    /// typed or unfolded for the previous booking is cleared.
    var owner: Booking.ID?
    @State private var draft = ""
    @State private var showsAll = false
    /// Suggestions shown while the field is empty and folded.
    static let foldedCount = 8

    var body: some View {
        let intent = self.intent
        VStack(alignment: .leading, spacing: 6) {
            TextField("Tag hinzufügen …", text: $draft)
                .textFieldStyle(.roundedBorder)
                .appFont(.callout)
                .focused(focused)
                .sensitive()
                // coloured edge only when something needs a look: orange already set or a
                // look-alike exists, red too long
                .overlay {
                    if let edge = edgeColor(intent) {
                        RoundedRectangle(cornerRadius: 6, style: .continuous).strokeBorder(edge, lineWidth: 1.5)
                    }
                }
                .onSubmit { submit(intent) }
                .onKeyPress(.escape) {
                    draft = ""
                    focused.wrappedValue = false
                    model.focusListToken &+= 1
                    return .handled
                }
            if let hint = hint(intent) {
                // what Return will do, readable at a glance while typing (no tooltip: the mouse is elsewhere)
                hint
                    .appFont(.caption)
                    .foregroundStyle(edgeColor(intent) ?? Theme.secondary)
                    .lineLimit(2).truncationMode(.middle)
                    .fixedSize(horizontal: false, vertical: true)
                    .sensitive()
            }
            if !suggestions.isEmpty {
                TagFlow {
                    ForEach(suggestions, id: \.id) { t in
                        TagChip(name: t.name, colorHex: t.colorHex, highlighted: highlights(t, intent),
                                onTap: { addNow(t.name) })
                            .help(Text("Tag hinzufügen"))
                    }
                    if trimmed.isEmpty, open.count > Self.foldedCount {
                        Button(showsAll ? "Weniger" : "+\(open.count - Self.foldedCount) weitere") {
                            withAnimation(.snappy(duration: 0.2)) { showsAll.toggle() }
                        }
                        .buttonStyle(.plain)
                        .appFont(.caption, weight: .medium)
                        .foregroundStyle(Theme.accent)
                        .padding(.horizontal, 4).padding(.vertical, 3)
                    }
                }
            }
        }
        .onChange(of: owner) {
            draft = ""
            showsAll = false
        }
    }

    private var trimmed: String { AppModel.cleanTagName(draft) }

    private var intent: TagEntryIntent {
        AppModel.tagEntryIntent(draft, tags: model.tags, carried: carried)
    }

    /// Tags that can still be added.
    private var open: [GiroCrabCore.Tag] { model.tags.filter { !carried.contains($0.id) } }

    /// Matching tags; while typing also look-alikes („test 1“ finds „test-1“).
    private var suggestions: [GiroCrabCore.Tag] {
        guard !trimmed.isEmpty else { return showsAll ? open : Array(open.prefix(Self.foldedCount)) }
        let loose = AppModel.tagLookAlikeKey(trimmed)
        return open.filter {
            $0.name.localizedCaseInsensitiveContains(trimmed)
                || (!loose.isEmpty && AppModel.tagLookAlikeKey($0.name).contains(loose))
        }
    }

    /// The chip Return would add, or the look-alike the hint warns about.
    private func highlights(_ t: GiroCrabCore.Tag, _ intent: TagEntryIntent) -> Bool {
        switch intent {
        case .add(let id, _), .similar(_, let id, _): id == t.id
        default: false
        }
    }

    private func hint(_ intent: TagEntryIntent) -> Text? {
        switch intent {
        case .none: nil
        case .create(let name): Text("↩ legt „\(name)“ neu an")
        case .add(_, let name): Text("↩ fügt „\(name)“ hinzu")
        case .already(let name):
            multiple ? Text("„\(name)“ ist schon bei allen gesetzt") : Text("„\(name)“ ist schon gesetzt")
        case .similar(_, _, let existing): Text("Ähnlich wie „\(existing)“ – ↩ legt trotzdem neu an")
        case .tooLong: Text("Höchstens \(AppModel.maxTagNameLength) Zeichen")
        }
    }

    private func edgeColor(_ intent: TagEntryIntent) -> Color? {
        switch intent {
        case .already, .similar: Theme.warning
        case .tooLong: Theme.negative
        default: nil
        }
    }

    /// Return: only when it creates or adds something; otherwise the text and the hint stay.
    private func submit(_ intent: TagEntryIntent) {
        switch intent {
        case .create(let name), .add(_, let name), .similar(let name, _, _): addNow(name)
        case .none, .already, .tooLong: break
        }
    }

    private func addNow(_ name: String) {
        add(name)
        draft = ""
    }
}

/// Inspector card of one booking.
struct TagsCard: View {
    @Environment(AppModel.self) private var model
    let booking: Booking
    @FocusState private var focused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Label("Tags", systemImage: "number").appFont(.subheadline, weight: .semibold).foregroundStyle(Theme.text)
                Spacer()
                #if os(macOS)
                // the tag sheet (rename, merge, delete); also Konten › Tags verwalten …
                Button("Verwalten …") { model.showTagManager = true }
                    .buttonStyle(.link)
                    .appFont(.caption)
                #endif
            }
            if !booking.tags.isEmpty {
                TagFlow {
                    ForEach(booking.tags, id: \.id) { t in
                        TagChip(name: t.name, colorHex: t.colorHex,
                                onRemove: { model.removeTag(t.id, from: [booking.id]) })
                    }
                }
            }
            TagEntryField(carried: Set(booking.tags.map(\.id)), focused: $focused, add: { name in
                model.addTag(named: name, to: [booking])
            }, owner: booking.id)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .card()
        .onAppear(perform: claimFocus)
        // Reused for the next selected booking (no `.id`: rebuilding the text field on every
        // selection was a large part of the inspector's update): leave the field, as a new card
        // would, then take a focus requested for the new booking.
        .onChange(of: booking.id) {
            focused = false
            claimFocus()
        }
        .onChange(of: model.pendingTagFocus) { _, _ in claimFocus() }
    }

    private func claimFocus() {
        guard model.pendingTagFocus == booking.id else { return }
        model.pendingTagFocus = nil
        DispatchQueue.main.async { focused = true }
    }
}

/// Tags section of the multiple-selection card: dashed chips are carried by only
/// some of the bookings (click: give it to all), ✕ removes a tag from all.
struct MultiSelectionTags: View {
    @Environment(AppModel.self) private var model
    let bookings: [Booking]
    @FocusState private var focused: Bool

    var body: some View {
        let usage = model.tagUsage(of: bookings)
        let ids = bookings.map(\.id)
        VStack(alignment: .leading, spacing: 8) {
            Label("Tags", systemImage: "number").appFont(.subheadline, weight: .semibold).foregroundStyle(Theme.text)
            if !usage.isEmpty {
                TagFlow {
                    ForEach(usage, id: \.tag.id) { u in
                        TagChip(name: u.tag.name, colorHex: u.tag.colorHex, partial: !u.all,
                                onTap: u.all ? nil : { model.addTag(u.tag.id, to: ids) },
                                onRemove: { model.removeTag(u.tag.id, from: ids) })
                            .help(u.all ? Text("Bei allen ausgewählten Buchungen")
                                        : Text("Nur bei einigen – klicken, um ihn allen zu geben"))
                    }
                }
            }
            TagEntryField(carried: Set(usage.filter(\.all).map(\.tag.id)), focused: $focused, multiple: true) { name in
                model.addTag(named: name, to: bookings)
            }
        }
        .onAppear(perform: claimFocus)
        .onChange(of: model.pendingTagFocus) { _, _ in claimFocus() }
    }

    private func claimFocus() {
        guard let id = model.pendingTagFocus, model.selectedBookingIDs.contains(id) else { return }
        model.pendingTagFocus = nil
        DispatchQueue.main.async { focused = true }
    }
}

/// „Tags“ submenu of a booking row (and the multiple selection it belongs to):
/// a tick per tag (ticked = every booking carries it), „Neuer Tag …“ focuses the inspector field.
struct TagsMenu: View {
    let model: AppModel
    let booking: Booking

    var body: some View {
        let targets = model.isMultiSelection && model.selectedBookingIDs.contains(booking.id)
            ? model.selectedBookings : [booking]
        Menu {
            ForEach(model.tags, id: \.id) { t in
                Toggle(t.name, isOn: Binding(
                    get: { targets.allSatisfy { b in b.tags.contains { $0.id == t.id } } },
                    set: { _ in model.toggleTag(t.id, on: targets) }
                ))
            }
            if !model.tags.isEmpty { Divider() }
            Button("Neuer Tag …") { model.editTags(for: booking) }
        } label: {
            Label(targets.count > 1 ? "Tags (\(targets.count) Buchungen)" : "Tags", systemImage: "number")
        }
    }
}

/// Up to two tag markers for a booking row, then „+n“.
struct BookingTagMarkers: View {
    let tags: [BookingTag]
    @Environment(\.textScale) private var textScale
    /// A tooltip can't carry `.sensitive()`: no names in it while a bug report is taken.
    @Environment(\.reportRedaction) private var redaction

    var body: some View {
        if !tags.isEmpty {
            HStack(spacing: 4) {
                ForEach(tags.prefix(2), id: \.id) { t in
                    HStack(spacing: 3) {
                        Circle().fill(t.colorHex.isEmpty ? Theme.secondary : Color(hex: t.colorHex))
                            .frame(width: 5, height: 5)
                        // cut with „…“ so a long name can't push the row apart; full name in the tooltip
                        Text(t.name).appFont(.caption2).lineLimit(1).truncationMode(.tail)
                            .frame(maxWidth: 110 * textScale, alignment: .leading)
                    }
                    .help(redaction.contains(.personal) ? "" : t.name)
                    .padding(.horizontal, 5).padding(.vertical, 1)
                    .background(Capsule().fill(Theme.secondary.opacity(0.12)))
                }
                if tags.count > 2 {
                    TagOverflowBadge(tags: tags)
                }
            }
            .foregroundStyle(Theme.secondary)
            .fixedSize()
            .sensitive()
            .accessibilityElement(children: .combine)
            .accessibilityLabel(Text("Tags: \(tags.map(\.name).joined(separator: ", "))"))
        }
    }
}

/// „+n“ behind the two row markers. On macOS a short hover shows every tag of
/// the booking as coloured chips in a popover (a system tooltip can only show
/// plain text). Popovers are never part of a bug report screenshot.
struct TagOverflowBadge: View {
    let tags: [BookingTag]
    @Environment(\.textScale) private var textScale
    #if os(macOS)
    @State private var showsAll = false
    @State private var hoverTask: Task<Void, Never>?
    /// Long enough that brushing over the list shows nothing, short enough to be found.
    static let hoverDelay: Duration = .milliseconds(500)
    #endif

    var body: some View {
        let badge = Text("+\(tags.count - 2)").appFont(.caption2).foregroundStyle(Theme.secondary)
        #if os(macOS)
        badge
            .padding(.horizontal, 2)
            .contentShape(Rectangle())
            .onHover { inside in
                hoverTask?.cancel()
                if inside {
                    hoverTask = Task { @MainActor in
                        try? await Task.sleep(for: Self.hoverDelay)
                        if !Task.isCancelled { showsAll = true }
                    }
                } else {
                    showsAll = false
                }
            }
            .onDisappear { hoverTask?.cancel(); showsAll = false }
            .capturablePopover(isPresented: $showsAll, arrowEdge: .bottom) {
                // only as large as the chips need: one row for a few short tags
                TagFlow(maxLineWidth: 260 * textScale) {
                    ForEach(tags, id: \.id) { t in TagChip(name: t.name, colorHex: t.colorHex) }
                }
                .fixedSize()
                .padding(8)
            }
        #else
        badge
        #endif
    }
}
