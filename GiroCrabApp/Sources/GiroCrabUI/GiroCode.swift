import Foundation
import CoreGraphics
import GiroCrabCore

/// EPC QR code ("GiroCode", EPC069-12 v002) for a SEPA credit transfer, for
/// accounts GiroCrab cannot send from (e.g. PSD2 / Enable Banking banks like
/// C24): the user scans it with the bank's app ("Fotoüberweisung").
/// Payload and modules come from the core (`payment_input.rs`).
enum GiroCode {
    /// The QR payload, or nil when IBAN, name or amount are unusable.
    static func payload(name: String, iban: String, bic: String = "", amountCents: Int64, purpose: String) -> String? {
        girocodePayload(name: name, iban: iban, bic: bic, amountCents: amountCents, purpose: purpose)
    }

    /// QR image (error correction "M", as the EPC guideline requires), quiet zone
    /// included, `pixelsPerModule` pixels per module: drawn at about its own size,
    /// the code stays sharp even where `.interpolation(.none)` is ignored
    /// (screenshots, bug report capture, printing).
    static func image(for payload: String, pixelsPerModule: Int = 10) -> CGImage? {
        guard let m = girocodeMatrix(payload: payload), pixelsPerModule > 0 else { return nil }
        let n = Int(m.width), scale = pixelsPerModule, side = n * scale
        var pixels = [UInt8](repeating: 255, count: side * side)
        for y in 0..<n {
            for x in 0..<n where m.modules[y * n + x] {
                for row in (y * scale)..<((y + 1) * scale) {
                    pixels.replaceSubrange((row * side + x * scale)..<(row * side + (x + 1) * scale),
                                           with: repeatElement(0, count: scale))
                }
            }
        }
        guard let provider = CGDataProvider(data: Data(pixels) as CFData) else { return nil }
        return CGImage(width: side, height: side, bitsPerComponent: 8, bitsPerPixel: 8, bytesPerRow: side,
                       space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.none.rawValue),
                       provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent)
    }
}
