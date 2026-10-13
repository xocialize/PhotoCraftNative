// SVG parsing for the import: the XML tree (Foundation `XMLParser`), presentation attributes,
// CSS (`style` attributes and simple `<style>` sheets), inheritance, `use`/`symbol` expansion and
// lengths. Native replacement for the usvg front end photocraft-io (crates/io/src/svg.rs) relies
// on, MIT OR Apache-2.0, © ArtCraft Team and the PhotoCraft contributors.
//
// Supported CSS: rules whose selectors are type, `.class`, `#id`, `*` and compounds of them,
// joined by descendant or child combinators; declarations of presentation properties, with
// `!important`. Other selectors (attributes, pseudo-classes, siblings) and at-rules are skipped.

import Foundation
import PCIOCore

extension SVGImport {
    /// An element (or a character-data node, `name == "#text"`).
    final class Node {
        var name: String
        /// Attributes that are not presentation properties (geometry, ids, references).
        var attrs: [String: String]
        /// Specified presentation properties: attributes, then CSS rules, then `style`.
        var props: [String: String]
        var children: [Node]
        /// Character data of a `#text` node.
        var text: String
        /// A `g` made from a `use`: its `x`/`y` attributes translate the content.
        var fromUse = false

        init(name: String, attrs: [String: String] = [:], props: [String: String] = [:], children: [Node] = [], text: String = "") {
            self.name = name; self.attrs = attrs; self.props = props; self.children = children; self.text = text
        }

        var id: String { attrs["id"] ?? "" }
        var isText: Bool { name == "#text" }

        /// A `g` without any attribute: it changes nothing (usvg drops such groups while
        /// parsing), so it costs no nesting.
        var isTrivialGroup: Bool {
            name == "g" && !fromUse && props.isEmpty && attrs.keys.allSatisfy { $0 == "class" || $0 == "style" }
        }

        func copy() -> Node {
            let n = Node(name: name, attrs: attrs, props: props, children: children.map { $0.copy() }, text: text)
            n.fromUse = fromUse
            return n
        }

        /// Every element node of the subtree (iterative).
        func elementCount(limit: Int) -> Int {
            var n = 0
            var stack: [Node] = [self]
            while let x = stack.popLast() {
                if x.isText { continue }
                n += 1
                if n > limit { return n }
                stack += x.children
            }
            return n
        }
    }

    /// Presentation properties (SVG 1.1 presentation attributes plus `mix-blend-mode`,
    /// `isolation` and `paint-order`).
    static let presentationProperties: Set<String> = [
        "alignment-baseline", "baseline-shift", "clip", "clip-path", "clip-rule", "color", "color-interpolation",
        "color-interpolation-filters", "color-rendering", "direction", "display", "dominant-baseline", "fill",
        "fill-opacity", "fill-rule", "filter", "flood-color", "flood-opacity", "font", "font-family", "font-size",
        "font-size-adjust", "font-stretch", "font-style", "font-variant", "font-weight", "image-rendering", "isolation",
        "letter-spacing", "lighting-color", "marker", "marker-end", "marker-mid", "marker-start", "mask", "mix-blend-mode",
        "opacity", "overflow", "paint-order", "shape-rendering", "stop-color", "stop-opacity", "stroke", "stroke-dasharray",
        "stroke-dashoffset", "stroke-linecap", "stroke-linejoin", "stroke-miterlimit", "stroke-opacity", "stroke-width",
        "text-anchor", "text-decoration", "text-rendering", "unicode-bidi", "visibility", "word-spacing", "writing-mode",
    ]

    /// Properties children inherit.
    static let inheritedProperties: Set<String> = [
        "clip-rule", "color", "color-interpolation", "color-interpolation-filters", "color-rendering", "direction", "fill",
        "fill-opacity", "fill-rule", "font-family", "font-size", "font-size-adjust", "font-stretch", "font-style",
        "font-variant", "font-weight", "image-rendering", "letter-spacing", "marker", "marker-end", "marker-mid",
        "marker-start", "paint-order", "shape-rendering", "stroke", "stroke-dasharray", "stroke-dashoffset",
        "stroke-linecap", "stroke-linejoin", "stroke-miterlimit", "stroke-opacity", "stroke-width", "text-anchor",
        "text-rendering", "visibility", "word-spacing", "writing-mode", "xml:space",
    ]

    /// The computed style of an element from its parent's.
    static func computedStyle(_ parent: [String: String], _ node: Node) -> [String: String] {
        var out = parent.filter { inheritedProperties.contains($0.key) }
        for (k, v) in node.props {
            if v.trimmingCharacters(in: .whitespaces) == "inherit" {
                if let p = parent[k] { out[k] = p } else { out.removeValue(forKey: k) }
            } else {
                out[k] = v
            }
        }
        if let s = node.attrs["xml:space"] { out["xml:space"] = s }
        return out
    }

    // MARK: - XML

    /// Parses the XML into a tree rooted at the `<svg>` element.
    static func parseXML(_ data: [UInt8]) throws -> Node {
        let delegate = TreeBuilder()
        let parser = XMLParser(data: Data(data))
        parser.shouldProcessNamespaces = true
        parser.shouldReportNamespacePrefixes = false
        parser.shouldResolveExternalEntities = false
        parser.delegate = delegate
        let ok = parser.parse()
        if let e = delegate.failure { throw PCIOError.format("SVG", e) }
        guard ok, let root = delegate.root else {
            let e = parser.parserError.map { ($0 as NSError).localizedDescription } ?? "malformed XML"
            throw PCIOError.format("SVG", "the XML could not be parsed (line \(parser.lineNumber)): \(e)")
        }
        guard root.name == "svg" else { throw PCIOError.format("SVG", "the root element is <\(root.name)>, not <svg>") }
        return root
    }

    static let svgNamespace = "http://www.w3.org/2000/svg"

    /// Builds the element tree. Elements outside the SVG namespace (Inkscape's, RDF, …) are kept
    /// but never drawn; an element without a namespace is taken as SVG.
    final class TreeBuilder: NSObject, XMLParserDelegate {
        var root: Node?
        var stack: [Node] = []
        var failure: String?
        /// Elements from foreign namespaces get this prefix so they never match an SVG name.
        static let foreign = "foreign:"

        func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?, qualifiedName qName: String?,
                    attributes attributeDict: [String: String] = [:]) {
            var name = elementName
            if let ns = namespaceURI, !ns.isEmpty, ns != SVGImport.svgNamespace { name = TreeBuilder.foreign + elementName }
            let n = Node(name: name)
            for (k0, v) in attributeDict {
                // `xlink:href` and `href` are the same reference.
                let k = k0.hasSuffix(":href") ? "href" : k0
                if k == "href", k0 != "href", attributeDict["href"] != nil { continue }
                if SVGImport.presentationProperties.contains(k) {
                    n.props[k] = v
                } else {
                    n.attrs[k] = v
                }
            }
            if let top = stack.last { top.children.append(n) } else if root == nil { root = n }
            stack.append(n)
        }

        func parser(_ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?, qualifiedName qName: String?) {
            _ = stack.popLast()
        }

        func parser(_ parser: XMLParser, foundCharacters string: String) { appendText(string) }

        func parser(_ parser: XMLParser, foundCDATA CDATABlock: Data) { appendText(String(decoding: CDATABlock, as: UTF8.self)) }

        func appendText(_ s: String) {
            guard let top = stack.last else { return }
            if let last = top.children.last, last.isText {
                last.text += s
            } else {
                top.children.append(Node(name: "#text", text: s))
            }
        }

        func parser(_ parser: XMLParser, foundInternalEntityDeclarationWithName name: String, value: String?) {
            // Entity bombs: refuse documents that declare entities expanding to large text.
            if (value?.utf8.count ?? 0) > 4096 { failure = "an XML entity declaration is too large"; parser.abortParsing() }
        }

        func parser(_ parser: XMLParser, parseErrorOccurred parseError: any Error) {
            if failure == nil { failure = "the XML could not be parsed (line \(parser.lineNumber)): \((parseError as NSError).localizedDescription)" }
        }
    }

    // MARK: - CSS

    struct CSSDecl {
        var name: String
        var value: String
        var important: Bool
    }

    struct CSSCompound {
        var type: String?
        var id: String?
        var classes: [String] = []

        func matches(_ n: Node) -> Bool {
            if let t = type, t != n.name { return false }
            if let i = id, i != n.id { return false }
            if !classes.isEmpty {
                let have = Set((n.attrs["class"] ?? "").split(whereSeparator: { $0.isWhitespace }).map(String.init))
                if !classes.allSatisfy(have.contains) { return false }
            }
            return true
        }
    }

    struct CSSRule {
        /// Compounds right to left, each with the combinator joining it to the next one
        /// (`true` = child, `false` = descendant).
        var compounds: [(CSSCompound, child: Bool)]
        var specificity: (Int, Int, Int)
        var decls: [CSSDecl]
        var order: Int

        /// Whether the rule matches `node` with `ancestors` (root first).
        func matches(_ node: Node, _ ancestors: [Node]) -> Bool {
            guard let first = compounds.first, first.0.matches(node) else { return false }
            var i = ancestors.count - 1
            var k = 1
            while k < compounds.count {
                let (c, child) = (compounds[k].0, compounds[k - 1].child)
                if child {
                    guard i >= 0, c.matches(ancestors[i]) else { return false }
                    i -= 1
                } else {
                    while i >= 0, !c.matches(ancestors[i]) { i -= 1 }
                    guard i >= 0 else { return false }
                    i -= 1
                }
                k += 1
            }
            return true
        }
    }

    /// Declarations of a `style` attribute or a rule body.
    static func parseDeclarations(_ s: String) -> [CSSDecl] {
        var out: [CSSDecl] = []
        for part in s.split(separator: ";") {
            guard let colon = part.firstIndex(of: ":") else { continue }
            let name = part[..<colon].trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            var value = part[part.index(after: colon)...].trimmingCharacters(in: .whitespacesAndNewlines)
            var important = false
            if let r = value.range(of: "!important", options: [.caseInsensitive, .backwards]) {
                important = true
                value = value[..<r.lowerBound].trimmingCharacters(in: .whitespacesAndNewlines)
            }
            if !name.isEmpty, !value.isEmpty { out.append(CSSDecl(name: name, value: value, important: important)) }
        }
        return out
    }

    /// Parses a style sheet into rules (unsupported selectors and at-rules are skipped).
    static func parseStyleSheet(_ css0: String, orderBase: Int) -> [CSSRule] {
        // Strip comments.
        var css = ""
        var rest = Substring(css0)
        while let r = rest.range(of: "/*") {
            css += rest[..<r.lowerBound]
            if let e = rest[r.upperBound...].range(of: "*/") { rest = rest[e.upperBound...] } else { rest = "" }
        }
        css += rest
        var rules: [CSSRule] = []
        var i = css.startIndex
        var order = orderBase
        while i < css.endIndex {
            guard let open = css[i...].firstIndex(of: "{") else { break }
            let prelude = css[i ..< open].trimmingCharacters(in: .whitespacesAndNewlines)
            // Find the matching close brace (nested blocks of at-rules are skipped whole).
            var depth = 0
            var j = open
            var close: String.Index?
            while j < css.endIndex {
                if css[j] == "{" { depth += 1 } else if css[j] == "}" {
                    depth -= 1
                    if depth == 0 { close = j; break }
                }
                j = css.index(after: j)
            }
            guard let end = close else { break }
            let body = String(css[css.index(after: open) ..< end])
            i = css.index(after: end)
            if prelude.hasPrefix("@") { continue }
            let decls = parseDeclarations(body)
            for sel in prelude.split(separator: ",") {
                if let r = parseSelector(String(sel)) {
                    rules.append(CSSRule(compounds: r.compounds, specificity: r.specificity, decls: decls, order: order))
                    order += 1
                }
            }
        }
        return rules
    }

    static func parseSelector(_ s: String) -> (compounds: [(CSSCompound, child: Bool)], specificity: (Int, Int, Int))? {
        var compounds: [CSSCompound] = []
        var combinators: [Bool] = []
        var cur: CSSCompound?
        var pendingChild = false
        var spec = (0, 0, 0)
        let chars = Array(s.trimmingCharacters(in: .whitespacesAndNewlines))
        guard !chars.isEmpty else { return nil }
        var i = 0
        func ident() -> String {
            var out = ""
            while i < chars.count, chars[i].isLetter || chars[i].isNumber || chars[i] == "-" || chars[i] == "_" {
                out.append(chars[i])
                i += 1
            }
            return out
        }
        func finish() {
            if let c = cur {
                compounds.append(c)
                combinators.append(pendingChild)
                pendingChild = false
                cur = nil
            }
        }
        while i < chars.count {
            let c = chars[i]
            if c.isWhitespace {
                finish()
                i += 1
            } else if c == ">" {
                finish()
                pendingChild = true
                i += 1
            } else if c == "*" {
                if cur == nil { cur = CSSCompound() }
                i += 1
            } else if c == "." {
                i += 1
                let n = ident()
                if n.isEmpty { return nil }
                if cur == nil { cur = CSSCompound() }
                cur?.classes.append(n)
                spec.1 += 1
            } else if c == "#" {
                i += 1
                let n = ident()
                if n.isEmpty { return nil }
                if cur == nil { cur = CSSCompound() }
                cur?.id = n
                spec.0 += 1
            } else if c.isLetter || c == "_" {
                let n = ident()
                if cur == nil { cur = CSSCompound() }
                cur?.type = n
                spec.2 += 1
            } else {
                return nil // attribute selectors, pseudo-classes, sibling combinators
            }
        }
        finish()
        guard !compounds.isEmpty else { return nil }
        // combinators[k] says how compound k joins the one before it (left side).
        var out: [(CSSCompound, child: Bool)] = []
        for k in stride(from: compounds.count - 1, through: 0, by: -1) {
            out.append((compounds[k], child: combinators[k]))
        }
        return (out, spec)
    }

    /// Folds `<style>` rules and `style` attributes into each element's `props`.
    static func applyStyles(_ root: Node) {
        var sheets = ""
        var stack: [Node] = [root]
        while let n = stack.popLast() {
            if n.name == "style", (n.attrs["type"] ?? "text/css").lowercased().contains("css") {
                sheets += n.children.filter(\.isText).map(\.text).joined() + "\n"
            }
            stack += n.children
        }
        let rules = sheets.isEmpty ? [] : parseStyleSheet(sheets, orderBase: 0).sorted {
            $0.specificity != $1.specificity ? $0.specificity < $1.specificity : $0.order < $1.order
        }
        func visit(_ n: Node, _ ancestors: inout [Node]) {
            guard !n.isText else { return }
            var important: [CSSDecl] = []
            for r in rules where r.matches(n, ancestors) {
                for d in r.decls where presentationProperties.contains(d.name) {
                    if d.important { important.append(d) } else { n.props[d.name] = d.value }
                }
            }
            if let style = n.attrs["style"] {
                for d in parseDeclarations(style) where presentationProperties.contains(d.name) { n.props[d.name] = d.value }
            }
            for d in important { n.props[d.name] = d.value }
            if let font = n.props["font"] { expandFontShorthand(font, into: &n.props) }
            ancestors.append(n)
            for c in n.children { visit(c, &ancestors) }
            ancestors.removeLast()
        }
        var ancestors: [Node] = []
        visit(root, &ancestors)
    }

    /// `font: [style] [variant] [weight] size[/line-height] family` into its longhands.
    static func expandFontShorthand(_ s: String, into props: inout [String: String]) {
        var words = s.split(separator: " ", omittingEmptySubsequences: true).map(String.init)
        while let w = words.first {
            let l = w.lowercased()
            if ["italic", "oblique"].contains(l) { props["font-style"] = l }
            else if ["bold", "bolder", "lighter"].contains(l) || Int(l) != nil { props["font-weight"] = l }
            else if ["normal", "small-caps"].contains(l) {}
            else { break }
            words.removeFirst()
        }
        guard let size = words.first else { return }
        props["font-size"] = String(size.split(separator: "/").first ?? Substring(size))
        let family = words.dropFirst().joined(separator: " ")
        if !family.isEmpty { props["font-family"] = family }
    }

    // MARK: - use / symbol

    /// The id referenced by `url(#id)` or `#id`.
    static func reference(_ s: String?) -> String? {
        guard var t = s?.trimmingCharacters(in: .whitespacesAndNewlines) else { return nil }
        if t.hasPrefix("url(") {
            guard let close = t.firstIndex(of: ")") else { return nil }
            t = String(t[t.index(t.startIndex, offsetBy: 4) ..< close]).trimmingCharacters(in: CharacterSet(charactersIn: " \"'"))
        }
        guard t.hasPrefix("#"), t.count > 1 else { return nil }
        return String(t.dropFirst())
    }

    /// Element ids → nodes (first one wins, as in browsers).
    static func idMap(_ root: Node) -> [String: Node] {
        var map: [String: Node] = [:]
        var stack: [Node] = [root]
        while let n = stack.popLast() {
            if !n.isText, let id = n.attrs["id"], !id.isEmpty, map[id] == nil { map[id] = n }
            stack += n.children.reversed()
        }
        return map
    }

    /// Most nodes `use` expansion may create (references nested in references grow
    /// exponentially).
    static let maxExpandedNodes = 200_000

    /// Replaces every `use` by a `g` holding a copy of what it references (a `symbol` or `svg`
    /// becomes a nested `svg` viewport). Cyclic and dangling references are dropped.
    static func expandUses(_ root: Node, _ ids: [String: Node], _ warnings: inout [String]) {
        var budget = maxExpandedNodes
        var truncated = false
        func expand(_ n: Node, _ active: Set<ObjectIdentifier>) {
            var out: [Node] = []
            for c in n.children {
                guard c.name == "use" else {
                    expand(c, active)
                    out.append(c)
                    continue
                }
                guard let id = reference(c.attrs["href"]), let target = ids[id], !active.contains(ObjectIdentifier(target)) else { continue }
                let cost = target.elementCount(limit: budget + 1)
                if cost > budget {
                    truncated = true
                    continue
                }
                budget -= cost
                let g = Node(name: "g", attrs: c.attrs.filter { !["href", "width", "height"].contains($0.key) }, props: c.props)
                g.fromUse = true
                let inner: Node
                if target.name == "symbol" || target.name == "svg" {
                    inner = target.copy()
                    inner.name = "svg"
                    inner.attrs["id"] = target.attrs["id"]
                    inner.attrs["x"] = nil
                    inner.attrs["y"] = nil
                    if target.name == "symbol" {
                        inner.attrs["width"] = c.attrs["width"] ?? "100%"
                        inner.attrs["height"] = c.attrs["height"] ?? "100%"
                        inner.attrs["pc:symbol"] = "1"
                    } else {
                        if let w = c.attrs["width"] { inner.attrs["width"] = w }
                        if let h = c.attrs["height"] { inner.attrs["height"] = h }
                    }
                } else {
                    inner = target.copy()
                }
                g.children = [inner]
                var next = active
                next.insert(ObjectIdentifier(target))
                expand(inner, next)
                out.append(g)
            }
            n.children = out
        }
        expand(root, [])
        if truncated { warnings.append("SVG: references (<use>) nested too deeply to expand were dropped") }
    }

    // MARK: - Numbers and lengths

    /// Numbers in a list (`1,2 3e2-4`).
    static func numbers(_ s: String?) -> [Double] {
        guard let s else { return [] }
        var out: [Double] = []
        var sc = NumberScanner(Array(s.utf8))
        while let v = sc.number() { out.append(v) }
        return out
    }

    /// A length in user units. `%` is of `percentBase`; `em`/`ex` of `fontSize`.
    static func length(_ s: String?, percentBase: Double, fontSize: Double = 16) -> Double? {
        guard let t0 = s?.trimmingCharacters(in: .whitespacesAndNewlines), !t0.isEmpty else { return nil }
        var sc = NumberScanner(Array(t0.utf8))
        guard let v = sc.number(skipSeparators: false) else { return nil }
        let unit = String(decoding: sc.rest, as: UTF8.self).trimmingCharacters(in: .whitespaces).lowercased()
        let r: Double
        switch unit {
        case "", "px": r = v
        case "pt": r = v * 4 / 3
        case "pc": r = v * 16
        case "mm": r = v * 96 / 25.4
        case "cm": r = v * 96 / 2.54
        case "in": r = v * 96
        case "em": r = v * fontSize
        case "ex": r = v * fontSize / 2
        case "%": r = v / 100 * percentBase
        default: return nil
        }
        return r.isFinite ? r : nil
    }

    /// Scans SVG numbers (`-1.5e3`, `.5.5` = 0.5 0.5) with comma/whitespace separators.
    struct NumberScanner {
        let b: [UInt8]
        var i = 0

        init(_ b: [UInt8]) { self.b = b }

        var rest: ArraySlice<UInt8> { b[min(i, b.count)...] }
        var atEnd: Bool { i >= b.count }

        mutating func skipSeparators() {
            while i < b.count, b[i] == 0x20 || b[i] == 0x09 || b[i] == 0x0A || b[i] == 0x0D || b[i] == 0x2C { i += 1 }
        }

        mutating func skipWhitespace() {
            while i < b.count, b[i] == 0x20 || b[i] == 0x09 || b[i] == 0x0A || b[i] == 0x0D { i += 1 }
        }

        func peek() -> UInt8? { i < b.count ? b[i] : nil }

        /// A flag of an arc command: `0` or `1`, possibly unseparated.
        mutating func flag() -> Bool? {
            skipSeparators()
            guard i < b.count, b[i] == 0x30 || b[i] == 0x31 else { return nil }
            defer { i += 1 }
            return b[i] == 0x31
        }

        mutating func number(skipSeparators skip: Bool = true) -> Double? {
            if skip { skipSeparators() } else { skipWhitespace() }
            let start = i
            var j = i
            if j < b.count, b[j] == 0x2B || b[j] == 0x2D { j += 1 }
            var digits = 0
            while j < b.count, b[j] >= 0x30, b[j] <= 0x39 { j += 1; digits += 1 }
            if j < b.count, b[j] == 0x2E {
                j += 1
                while j < b.count, b[j] >= 0x30, b[j] <= 0x39 { j += 1; digits += 1 }
            }
            guard digits > 0 else { return nil }
            if j < b.count, b[j] == 0x65 || b[j] == 0x45 {
                var k = j + 1
                if k < b.count, b[k] == 0x2B || b[k] == 0x2D { k += 1 }
                var ed = 0
                while k < b.count, b[k] >= 0x30, b[k] <= 0x39 { k += 1; ed += 1 }
                if ed > 0 { j = k }
            }
            guard let v = Double(String(decoding: b[start ..< j], as: UTF8.self)), v.isFinite else { return nil }
            i = j
            return v
        }
    }
}
