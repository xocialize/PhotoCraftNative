// composite: opens ARGS.path, flattens a duplicate and saves it to ARGS.out at the document's mode
// and depth (TIFF, or Photoshop Raw for Duotone/Multichannel). With ARGS.alphaOut, also saves the
// composite with transparency (when the document has any).
PSO.main(function () {
    var doc;
    try { doc = PSO.open(ARGS.path); } catch (e) { var o = PSO.errorObject(e); o.opened = false; return o; }
    try {
        var res = { ok: true, opened: true, file: ARGS.path, mode: PSO.modeName(doc.mode), bits: PSO.bits(doc.bitsPerChannel) };
        res.composite = PSO.flattenedComposite(doc, ARGS.out);
        if (ARGS.alphaOut && PSO.compositeFormat(doc) === 'tiff') {
            app.activeDocument = doc;
            if (!PSO.getBool(PSO.activeDocDesc(), 'hasBackgroundLayer')) res.alphaComposite = PSO.transparentComposite(doc, ARGS.alphaOut);
        }
        return res;
    } finally { PSO.close(doc); }
});
