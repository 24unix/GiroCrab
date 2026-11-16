import Foundation
import SwiftUI
import GiroCrabCore

extension AppModel {
    // MARK: - Tags (#228)

    /// Colours a new tag gets in turn (the user can change it later).
    static let tagPalette = ["#2E86DE", "#27AE60", "#E67E22", "#8E44AD", "#C0392B", "#16A085", "#D4AC0D", "#7F8C8D"]

    /// The tag list with booking counts: one indexed aggregate, cheap enough for the main thread.
    func reloadTags() {
        guard let vault else { tags = []; return }
        runCore { tags = try vault.listTags() }
    }

    /// Longest tag name the core accepts (characters, after collapsing spaces).
    static let maxTagNameLength = 64

    /// A name as the core stores it: inner runs of spaces collapsed, trimmed.
    static func cleanTagName(_ name: String) -> String {
        name.split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }

    /// The core's key for "the same name" (case-insensitive, spaces collapsed).
    static func tagKey(_ name: String) -> String { cleanTagName(name).lowercased() }

    /// Looser than `tagKey`: only letters and digits, without case and accents, so
    /// „test 1“, „test-1“, „test_1“ and „Test1“ meet („Urlaub 2025“ / „2026“ don't).
    static func tagLookAlikeKey(_ name: String) -> String {
        String(name.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
            .unicodeScalars.filter { CharacterSet.alphanumerics.contains($0) })
    }

    /// What Return in a tag field will do with `text` (shown below the field while typing).
    static func tagEntryIntent(_ text: String, tags: [GiroCrabCore.Tag], carried: Set<Int64>) -> TagEntryIntent {
        let name = cleanTagName(text)
        if name.isEmpty { return .none }
        if name.unicodeScalars.count > maxTagNameLength { return .tooLong }
        let key = tagKey(name)
        if let known = tags.first(where: { tagKey($0.name) == key }) {
            return carried.contains(known.id) ? .already(known.name) : .add(known.id, known.name)
        }
        let loose = tagLookAlikeKey(name)
        if !loose.isEmpty, let alike = tags.first(where: { tagLookAlikeKey($0.name) == loose }) {
            return .similar(new: name, existingID: alike.id, existing: alike.name)
        }
        return .create(name)
    }

    /// The live tag of that name, created (with the next palette colour) if there is none.
    func tag(named name: String) -> GiroCrabCore.Tag? {
        guard let vault else { return nil }
        let trimmed = Self.cleanTagName(name)
        guard !trimmed.isEmpty else { return nil }
        if let known = tags.first(where: { Self.tagKey($0.name) == Self.tagKey(trimmed) }) {
            return known
        }
        do {
            let color = Self.tagPalette[tags.count % Self.tagPalette.count]
            let t = try vault.createTag(name: trimmed, colorHex: color)
            reloadTags()
            return t
        } catch {
            errorMessage = describe(error)
            return nil
        }
    }

    /// Tags that some or all of `bookings` carry, in tag list order.
    func tagUsage(of bookings: [Booking]) -> [(tag: BookingTag, all: Bool)] {
        var count: [Int64: Int] = [:]
        var byID: [Int64: BookingTag] = [:]
        for b in bookings { for t in b.tags { count[t.id, default: 0] += 1; byID[t.id] = t } }
        return byID.values
            .sorted { tagRank($0) < tagRank($1) }
            .map { ($0, count[$0.id] == bookings.count) }
    }

    /// Adds the tag named `name` (created if new) to `bookings`.
    func addTag(named name: String, to bookings: [Booking]) {
        guard let t = tag(named: name) else { return }
        addTag(t.id, to: bookings.map(\.id))
    }

    func addTag(_ tagID: Int64, to bookingIDs: [Int64]) {
        changeTag(tagID, on: bookingIDs, adding: true)
    }

    func removeTag(_ tagID: Int64, from bookingIDs: [Int64]) {
        changeTag(tagID, on: bookingIDs, adding: false)
    }

    /// Context menu: removes the tag when every booking carries it, otherwise adds it to the rest.
    func toggleTag(_ tagID: Int64, on bookings: [Booking]) {
        let all = !bookings.isEmpty && bookings.allSatisfy { $0.tags.contains { $0.id == tagID } }
        changeTag(tagID, on: bookings.map(\.id), adding: !all)
    }

    /// Select the booking and put the cursor into the tag field of its inspector card
    /// (of the multiple-selection card when the booking is part of one).
    func editTags(for booking: Booking) {
        #if os(macOS)
        UserDefaults.standard.set(true, forKey: ViewLayout.inspectorKey)
        #endif
        // a multiple selection that contains the booking stays (its card has the field)
        if !selectedBookingIDs.contains(booking.id) { selectedBookingID = booking.id }
        pendingTagFocus = booking.id
    }

    /// The write is one small transaction; the rows show the change at once
    /// (no list reload), the tag counts follow from `reloadTags`. Undo reverts
    /// exactly the bookings that changed.
    private func changeTag(_ tagID: Int64, on bookingIDs: [Int64], adding: Bool) {
        guard let vault, !bookingIDs.isEmpty else { return }
        let changed: [Int64]
        do {
            changed = adding
                ? try vault.addTagToBookings(bookingIds: bookingIDs, tagId: tagID)
                : try vault.removeTagFromBookings(bookingIds: bookingIDs, tagId: tagID)
        } catch {
            errorMessage = describe(error)
            reloadBookings(); reloadTags()
            return
        }
        guard !changed.isEmpty else { return }
        showTag(tagID, on: Set(changed), adding: adding)
        reloadTags()
        if let um = windowUndoManager {
            um.registerUndo(withTarget: self) { m in m.changeTag(tagID, on: changed, adding: !adding) }
            um.setActionName(adding ? String(localized: "Tag hinzufügen") : String(localized: "Tag entfernen"))
        }
    }

    /// Optimistic update of the loaded rows and a sticky inspector booking.
    private func showTag(_ tagID: Int64, on ids: Set<Booking.ID>, adding: Bool) {
        guard let t = tags.first(where: { $0.id == tagID }) else { reloadBookings(); return }
        let tag = BookingTag(id: t.id, name: t.name, colorHex: t.colorHex)
        func patch(_ b: inout Booking) {
            b.tags.removeAll { $0.id == tagID }
            if adding {
                b.tags.append(tag)
                b.tags.sort { tagRank($0) < tagRank($1) }
            }
        }
        var rows = bookings
        for i in rows.indices where ids.contains(rows[i].id) { patch(&rows[i]) }
        bookings = rows
        if var s = stickyBooking, ids.contains(s.id) { patch(&s); stickyBooking = s }
    }

    /// Position in the tag list (the core's order), unknown tags last.
    private func tagRank(_ t: BookingTag) -> Int {
        tags.firstIndex { $0.id == t.id } ?? Int.max
    }
}
