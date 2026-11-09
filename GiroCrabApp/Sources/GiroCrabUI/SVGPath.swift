import SwiftUI

/// Renders a simple-icons SVG path ("d" attribute, 24×24 viewBox) as a
/// SwiftUI shape. Supports M L H V C S Q T A Z (absolute + relative),
/// compact numbers ("1.5.5", "-1-2", "1e-3") and compact arc flags ("011").
struct SVGPathShape: Shape {
    let d: String
    var viewBox: CGFloat = 24

    func path(in rect: CGRect) -> Path {
        let base = SVGPathParser.parse(d)
        let scale = min(rect.width, rect.height) / viewBox
        let dx = rect.minX + (rect.width - viewBox * scale) / 2
        let dy = rect.minY + (rect.height - viewBox * scale) / 2
        return base.applying(CGAffineTransform(a: scale, b: 0, c: 0, d: scale, tx: dx, ty: dy))
    }
}

enum SVGPathParser {
    private static var cache: [String: Path] = [:]
    private static let lock = NSLock()

    static func parse(_ d: String) -> Path {
        lock.lock()
        if let p = cache[d] { lock.unlock(); return p }
        lock.unlock()
        let p = build(d)
        lock.lock()
        cache[d] = p
        lock.unlock()
        return p
    }

    private struct Scanner {
        let chars: [Character]
        var i = 0

        init(_ s: String) { chars = Array(s) }

        mutating func skipSeparators() {
            while i < chars.count, chars[i] == " " || chars[i] == "," || chars[i] == "\n" || chars[i] == "\t" || chars[i] == "\r" { i += 1 }
        }

        mutating func command() -> Character? {
            skipSeparators()
            guard i < chars.count, chars[i].isLetter, chars[i] != "e", chars[i] != "E" else { return nil }
            defer { i += 1 }
            return chars[i]
        }

        var hasNumber: Bool {
            var j = i
            while j < chars.count, chars[j] == " " || chars[j] == "," || chars[j] == "\n" || chars[j] == "\t" || chars[j] == "\r" { j += 1 }
            guard j < chars.count else { return false }
            let c = chars[j]
            return c.isNumber || c == "-" || c == "+" || c == "."
        }

        mutating func number() -> CGFloat? {
            skipSeparators()
            guard i < chars.count else { return nil }
            var s = ""
            if chars[i] == "-" || chars[i] == "+" { s.append(chars[i]); i += 1 }
            var seenDot = false, seenExp = false
            while i < chars.count {
                let c = chars[i]
                if c.isNumber {
                    s.append(c)
                } else if c == ".", !seenDot, !seenExp {
                    seenDot = true; s.append(c)
                } else if (c == "e" || c == "E"), !seenExp, !s.isEmpty {
                    seenExp = true; s.append(c)
                    if i + 1 < chars.count, chars[i + 1] == "-" || chars[i + 1] == "+" { i += 1; s.append(chars[i]) }
                } else {
                    break
                }
                i += 1
            }
            return Double(s).map { CGFloat($0) }
        }

        /// Arc flags may be written without separators ("011").
        mutating func flag() -> Bool? {
            skipSeparators()
            guard i < chars.count, chars[i] == "0" || chars[i] == "1" else { return nil }
            defer { i += 1 }
            return chars[i] == "1"
        }
    }

    private static func build(_ d: String) -> Path {
        var p = Path()
        var sc = Scanner(d)
        var cur = CGPoint.zero, start = CGPoint.zero
        var lastCtrl: CGPoint?
        var lastCmd: Character = "M"
        var cmd: Character? = sc.command()
        while let c = cmd {
            let rel = c.isLowercase
            let upper = Character(c.uppercased())
            func pt(_ x: CGFloat, _ y: CGFloat) -> CGPoint { rel ? CGPoint(x: cur.x + x, y: cur.y + y) : CGPoint(x: x, y: y) }
            var first = true
            repeat {
                switch upper {
                case "M":
                    guard let x = sc.number(), let y = sc.number() else { break }
                    let q = pt(x, y)
                    if first { p.move(to: q); start = q } else { p.addLine(to: q) }
                    cur = q; lastCtrl = nil
                case "L":
                    guard let x = sc.number(), let y = sc.number() else { break }
                    cur = pt(x, y); p.addLine(to: cur); lastCtrl = nil
                case "H":
                    guard let x = sc.number() else { break }
                    cur = CGPoint(x: rel ? cur.x + x : x, y: cur.y); p.addLine(to: cur); lastCtrl = nil
                case "V":
                    guard let y = sc.number() else { break }
                    cur = CGPoint(x: cur.x, y: rel ? cur.y + y : y); p.addLine(to: cur); lastCtrl = nil
                case "C":
                    guard let x1 = sc.number(), let y1 = sc.number(), let x2 = sc.number(), let y2 = sc.number(), let x = sc.number(), let y = sc.number() else { break }
                    let c1 = pt(x1, y1), c2 = pt(x2, y2), e = pt(x, y)
                    p.addCurve(to: e, control1: c1, control2: c2); cur = e; lastCtrl = c2
                case "S":
                    guard let x2 = sc.number(), let y2 = sc.number(), let x = sc.number(), let y = sc.number() else { break }
                    let c1 = (lastCmd == "C" || lastCmd == "S") ? CGPoint(x: 2 * cur.x - (lastCtrl?.x ?? cur.x), y: 2 * cur.y - (lastCtrl?.y ?? cur.y)) : cur
                    let c2 = pt(x2, y2), e = pt(x, y)
                    p.addCurve(to: e, control1: c1, control2: c2); cur = e; lastCtrl = c2
                case "Q":
                    guard let x1 = sc.number(), let y1 = sc.number(), let x = sc.number(), let y = sc.number() else { break }
                    let c1 = pt(x1, y1), e = pt(x, y)
                    p.addQuadCurve(to: e, control: c1); cur = e; lastCtrl = c1
                case "T":
                    guard let x = sc.number(), let y = sc.number() else { break }
                    let c1 = (lastCmd == "Q" || lastCmd == "T") ? CGPoint(x: 2 * cur.x - (lastCtrl?.x ?? cur.x), y: 2 * cur.y - (lastCtrl?.y ?? cur.y)) : cur
                    let e = pt(x, y)
                    p.addQuadCurve(to: e, control: c1); cur = e; lastCtrl = c1
                case "A":
                    guard let rx = sc.number(), let ry = sc.number(), let rot = sc.number(), let large = sc.flag(), let sweep = sc.flag(),
                          let x = sc.number(), let y = sc.number() else { break }
                    let e = pt(x, y)
                    addArc(&p, from: cur, to: e, rx: rx, ry: ry, rotation: rot, large: large, sweep: sweep)
                    cur = e; lastCtrl = nil
                case "Z":
                    p.closeSubpath(); cur = start; lastCtrl = nil
                default:
                    break
                }
                lastCmd = upper
                first = false
            } while upper != "Z" && sc.hasNumber
            cmd = sc.command()
            if cmd == nil && sc.i < sc.chars.count { sc.i += 1; cmd = sc.command() } // skip garbage
        }
        return p
    }

    /// SVG elliptical arc -> cubic Béziers (W3C implementation notes F.6).
    private static func addArc(_ p: inout Path, from p0: CGPoint, to p1: CGPoint, rx rxIn: CGFloat, ry ryIn: CGFloat, rotation: CGFloat, large: Bool, sweep: Bool) {
        var rx = abs(rxIn), ry = abs(ryIn)
        if rx == 0 || ry == 0 || p0 == p1 { p.addLine(to: p1); return }
        let phi = rotation * .pi / 180
        let cosP = cos(phi), sinP = sin(phi)
        let dx = (p0.x - p1.x) / 2, dy = (p0.y - p1.y) / 2
        let x1p = cosP * dx + sinP * dy
        let y1p = -sinP * dx + cosP * dy
        let lambda = (x1p * x1p) / (rx * rx) + (y1p * y1p) / (ry * ry)
        if lambda > 1 { rx *= sqrt(lambda); ry *= sqrt(lambda) }
        let num = rx * rx * ry * ry - rx * rx * y1p * y1p - ry * ry * x1p * x1p
        let den = rx * rx * y1p * y1p + ry * ry * x1p * x1p
        var coef = den == 0 ? 0 : sqrt(max(0, num / den))
        if large == sweep { coef = -coef }
        let cxp = coef * rx * y1p / ry
        let cyp = -coef * ry * x1p / rx
        let cx = cosP * cxp - sinP * cyp + (p0.x + p1.x) / 2
        let cy = sinP * cxp + cosP * cyp + (p0.y + p1.y) / 2
        func angle(_ ux: CGFloat, _ uy: CGFloat, _ vx: CGFloat, _ vy: CGFloat) -> CGFloat {
            let a = atan2(ux * vy - uy * vx, ux * vx + uy * vy)
            return a
        }
        let theta1 = angle(1, 0, (x1p - cxp) / rx, (y1p - cyp) / ry)
        var dTheta = angle((x1p - cxp) / rx, (y1p - cyp) / ry, (-x1p - cxp) / rx, (-y1p - cyp) / ry)
        if !sweep && dTheta > 0 { dTheta -= 2 * .pi } else if sweep && dTheta < 0 { dTheta += 2 * .pi }
        let segments = max(1, Int(ceil(abs(dTheta) / (.pi / 2))))
        let delta = dTheta / CGFloat(segments)
        let t = 4 / 3 * tan(delta / 4)
        var th = theta1
        for _ in 0..<segments {
            let c1 = cos(th), s1 = sin(th), c2 = cos(th + delta), s2 = sin(th + delta)
            func map(_ x: CGFloat, _ y: CGFloat) -> CGPoint {
                CGPoint(x: cx + rx * x * cosP - ry * y * sinP, y: cy + rx * x * sinP + ry * y * cosP)
            }
            let cp1 = map(c1 - t * s1, s1 + t * c1)
            let cp2 = map(c2 + t * s2, s2 - t * c2)
            let e = map(c2, s2)
            p.addCurve(to: e, control1: cp1, control2: cp2)
            th += delta
        }
    }
}
