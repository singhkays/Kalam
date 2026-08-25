import AppKit
import CoreText

// v1.3.1 weight/registration probe (K-32): verifies the exact claims the mockup
// agent demanded — nsWeight(400) == 0, book(19,400) == New York Regular,
// Instrument Serif registered (hero does NOT fall back), mono(11,500) == Medium.

func nsWeight(_ w: CGFloat) -> CGFloat {
    let clamped = min(900, max(100, w))
    switch clamped {
    case ..<350: return -0.4 // Font.Weight.light.rawValue — exact SFNS-Light (wght 300, Part 21)
    case ..<400: return 0.0
    case ..<500: return 0.23 * (clamped - 400) / 100
    case ..<600: return 0.23 + 0.07 * (clamped - 500) / 100
    case ..<700: return 0.30 + 0.10 * (clamped - 600) / 100
    case ..<800: return 0.40 + 0.16 * (clamped - 700) / 100
    case ..<900: return 0.56 + 0.06 * (clamped - 800) / 100
    default: return 0.62
    }
}

print("== nsWeight anchors ==")
for w in [CGFloat(300), 400, 500, 600, 640, 700] {
    print("nsWeight(\(Int(w))) = \(nsWeight(w))")
}

print("\n== Instrument Serif registration (bundle: \(Bundle.main.bundlePath)) ==")
for name in ["InstrumentSerif-Regular", "InstrumentSerif-Italic"] {
    let url = Bundle.main.url(forResource: name, withExtension: "ttf")
    var error: Unmanaged<CFError>?
    let ok = url != nil && CTFontManagerRegisterFontsForURL(url! as CFURL, .process, &error)
    let resolved = NSFont(name: name, size: 36)
    print("\(name): url=\(url != nil) register=\(ok) resolved=\(resolved?.fontName ?? "NIL")")
}

print("\n== book(19, weight 400) — New York instance ==")
func book(_ size: CGFloat, weight: CGFloat) -> NSFont? {
    let base = NSFont.systemFont(ofSize: size)
    guard var desc = base.fontDescriptor.withDesign(.serif) else { return nil }
    var attrs: [NSFontDescriptor.AttributeName: Any] = [
        .traits: [NSFontDescriptor.TraitKey.weight: nsWeight(weight)],
    ]
    attrs[NSFontDescriptor.AttributeName(rawValue: String(kCTFontOpticalSizeAttribute))] = size
    desc = desc.addingAttributes(attrs)
    return NSFont(descriptor: desc, size: size)
}
func opticalInfo(_ f: NSFont) -> String {
    let attrKey = NSFontDescriptor.AttributeName(rawValue: String(kCTFontOpticalSizeAttribute))
    let attrVal = f.fontDescriptor.object(forKey: attrKey) ?? "absent"
    var opsz = "absent"
    // CTFontCopyVariation keys are NSNumber axis tags on this SDK (NOT CFString) —
    // bridging them to String directly crashes ("-[NSConstantIntegerNumber length]").
    if let variation = CTFontCopyVariation(f) as? [AnyHashable: Any] {
        for (k, v) in variation {
            var tag = ""
            if let s = k as? String { tag = s }
            else if let n = k as? NSNumber { tag = String(format: "%08X", n.uint32Value) }
            if tag == "opsz" || tag == "6F70737A" { opsz = "\(v)" }
        }
    }
    return "opszAttr=\(attrVal) opszVariation=\(opsz)"
}
for w in [CGFloat(400), 500, 600] {
    if let f = book(19, weight: w) {
        let trait = f.fontDescriptor.object(forKey: .traits) as? [NSFontDescriptor.TraitKey: Any]
        let wt = trait?[.weight] as? CGFloat ?? -999
        print("book(19, \(Int(w))): name=\(f.fontName) weightTrait=\(wt) [\(opticalInfo(f))]")
    } else { print("book(19, \(Int(w))): NIL") }
}

print("\n== mono(11, weights) — SF Mono instances ==")
func mono(_ size: CGFloat, weight: CGFloat) -> NSFont? {
    let base = NSFont.systemFont(ofSize: size)
    guard var desc = base.fontDescriptor.withDesign(.monospaced) else { return nil }
    desc = desc.addingAttributes([.traits: [NSFontDescriptor.TraitKey.weight: nsWeight(weight)]])
    return NSFont(descriptor: desc, size: size)
}
for w in [CGFloat(300), 400, 500, 600] {
    if let f = mono(11, weight: w) {
        print("mono(11, \(Int(w))): name=\(f.fontName)")
    } else { print("mono(11, \(Int(w))): NIL") }
}

print("\n== body(13.5, 400) — SF Pro instance ==")
if let f = (NSFont.systemFont(ofSize: 13.5).fontDescriptor.withDesign(.default)).flatMap({ NSFont(descriptor: $0, size: 13.5) }) {
    print("body(13.5, 400): name=\(f.fontName)")
}
