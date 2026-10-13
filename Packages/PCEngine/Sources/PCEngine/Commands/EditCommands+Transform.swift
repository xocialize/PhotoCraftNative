// Port of photocraft-engine (crates/engine/src/edit_cmds.rs: `transform_again`, `transform_again_copy`, `transform_again_params`), MIT OR Apache-2.0, © ArtCraft Team and the PhotoCraft contributors.
//
// Edit › Transform › Again (⇧⌘T) replays the last `edit.transform` of the journal on the active
// layer; Transform Again on a Copy (⌥⇧⌘T) duplicates the active layer first and repeats the
// transform on the copy as one history step (step and repeat, #352). A transform given as a quad
// is re-expressed on the active layer's own frame.

import Foundation
import PCAlgo
import PCDocument
import PCFoundation

extension EditCommands {
    /// Edit › Transform › Again: replay the last `edit.transform` on the active layer.
    static func transformAgain(_ s: Session) throws -> JSONValue {
        try s.execute("edit.transform", transformAgainParams(s))
    }

    /// Transform Again on a copy (no menu item): duplicates the active layer and repeats the last
    /// transform on the copy, as one history step, so pressing it again steps and repeats. The
    /// transform is worked out before anything changes, so a refusal leaves no copy.
    static func transformAgainCopy(_ s: Session) throws -> JSONValue {
        let p = try transformAgainParams(s)
        let id = try activeId(s)
        let journal = s.journal.count
        // The steps are recorded (Again on a Copy is not replayable itself): with one layer
        // selected, "duplicate the current layer" plays back on any document, a layer id only on
        // this one.
        let dup: JSONValue = LayerMulti.multi(s, .null) ? ["layer": .id(id)] : [:]
        try s.execute("layer.duplicate", dup)
        do {
            let r = try s.execute("edit.transform", p)
            try s.updateActive { st in
                st.history.purgeLast()
                st.history.setCurrentLabel("Transform Again")
            }
            return r
        } catch {
            // The copy (e.g. of a layer whose position is locked) couldn't be transformed: take it
            // back, leaving nothing to redo and no Duplicate step to record.
            _ = s.undo()
            if journal <= s.journal.count { s.journal.removeSubrange(journal...) }
            try? s.updateActive { $0.history.clearRedo() }
            throw error
        }
    }

    /// The `edit.transform` params that repeat the last transform on the active layer.
    static func transformAgainParams(_ s: Session) throws -> JSONValue {
        guard let last = s.journal.last(where: { $0.id == "edit.transform" })?.params else {
            throw EngineError.other("there is no transform to repeat")
        }
        var p: JSONValue = ["interpolation": last["interpolation"] ?? "bicubic"]
        let cannot = EngineError.other("the last transform can't be repeated")
        if let rv = last["rect"], let qv = last["quad"] {
            func nums(_ x: JSONValue) -> [Double] { x.arrayValue?.compactMap(\.doubleValue) ?? [] }
            let r = nums(rv)
            let q = (qv.arrayValue ?? []).map(nums)
            guard r.count == 4, q.count == 4, q.allSatisfy({ $0.count >= 2 }),
                  let h = Homography.rectToQuad(r, q.map { SIMD2($0[0], $0[1]) }) else { throw cannot }
            guard let d = s.active else { throw EngineError.noDocument }
            guard let l = d.doc.layer(try activeId(s)) else { throw EngineError.other("no active layer") }
            let b = TransformCommands.transformBounds(d.doc, l)
            if b.isEmpty { throw EngineError.other("nothing to transform") }
            let nr = [Double(b.x0), Double(b.y0), Double(b.x1), Double(b.y1)]
            let corners = [(nr[0], nr[1]), (nr[2], nr[1]), (nr[2], nr[3]), (nr[0], nr[3])].map { h.apply($0.0, $0.1) }
            p = p.setting("rect", .doubles(nr)).setting("quad", .array(corners.map { [.number($0.0), .number($0.1)] }))
        } else if let mv = last["matrix"] {
            p = p.setting("matrix", mv)
        } else {
            throw cannot
        }
        return p
    }
}
