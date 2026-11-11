import Foundation
import CoreImage
import CoreImage.CIFilterBuiltins

/// EPC QR code ("GiroCode", EPC069-12 v002) for a SEPA credit transfer, for
/// accounts GiroCrab cannot send from (e.g. PSD2 / Enable Banking banks like
/// C24): the user scans it with the bank's app ("Fotoüberweisung").
enum GiroCode {
    /// Max. lengths from EPC069-12.
    static let maxName = 70
    static let maxRemittance = 140
    /// Max. amount: EUR 999,999,999.99.
    static let maxCents: Int64 = 99_999_999_999

    /// The QR payload, or nil when IBAN, name or amount are unusable.
    static func payload(name: String, iban: String, bic: String = "", amountCents: Int64, purpose: String) -> String? {
        let iban = iban.uppercased().filter { $0.isASCII && ($0.isLetter || $0.isNumber) }
        let bic = bic.uppercased().filter { $0.isASCII && ($0.isLetter || $0.isNumber) }
        let name = String(oneLine(name).prefix(maxName))
        let remittance = String(oneLine(purpose).prefix(maxRemittance))
        guard iban.count >= 15, iban.count <= 34, !name.isEmpty,
              amountCents >= 1, amountCents <= maxCents else { return nil }
        let amount = String(format: "EUR%lld.%02lld", amountCents / 100, amountCents % 100)
        return [
            "BCD",      // service tag
            "002",      // version (BIC optional within the EEA)
            "1",        // character set: UTF-8
            "SCT",      // SEPA credit transfer
            bic,
            name,
            iban,
            amount,
            "",         // purpose code
            "",         // structured creditor reference (unused: free text below)
            remittance,
        ].joined(separator: "\n")
    }

    /// QR image (error correction "M", as the EPC guideline requires), one
    /// pixel per module – scale it up without interpolation.
    static func image(for payload: String) -> CGImage? {
        let filter = CIFilter.qrCodeGenerator()
        filter.message = Data(payload.utf8)
        filter.correctionLevel = "M"
        guard let output = filter.outputImage else { return nil }
        // a little quiet zone around the code
        let padded = output.transformed(by: CGAffineTransform(translationX: 4, y: 4))
            .composited(over: CIImage(color: .white).cropped(to: output.extent.insetBy(dx: -4, dy: -4).offsetBy(dx: 4, dy: 4)))
        return CIContext().createCGImage(padded, from: padded.extent)
    }

    private static func oneLine(_ s: String) -> String {
        s.components(separatedBy: .newlines)
            .joined(separator: " ")
            .trimmingCharacters(in: .whitespaces)
    }
}
