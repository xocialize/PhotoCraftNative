// probe: one open per file for the acceptance sweep — the info report, the flattened composite
// (ARGS.out), the transparent composite (ARGS.alphaOut, documents without a background only) and,
// for ARGS.layerPrefix, every pixel layer exported on its own (PSO.exportLayer).
PSO.main(function () {
    var doc;
    try { doc = PSO.open(ARGS.path); } catch (e) { var o = PSO.errorObject(e); o.opened = false; return o; }
    try {
        var info = PSO.docInfo(doc);
        info.ok = true;
        info.opened = true;
        info.file = ARGS.path;
        info.steps = {};
        if (ARGS.out) {
            try { info.composite = PSO.flattenedComposite(doc, ARGS.out); } catch (e1) { info.steps.composite = PSO.errorText(e1); }
        }
        if (ARGS.alphaOut && !info.hasBackground && PSO.compositeFormat(doc) === 'tiff') {
            try { info.alphaComposite = PSO.transparentComposite(doc, ARGS.alphaOut); } catch (e2) { info.steps.alphaComposite = PSO.errorText(e2); }
        }
        if (ARGS.layerPrefix) {
            info.layerExports = [];
            for (var i = 0; i < info.layers.length; i++) {
                var L = info.layers[i];
                if (L.kind !== 'pixel') continue;
                try { info.layerExports.push(PSO.exportLayer(doc, L.index, ARGS.layerPrefix + '-' + L.index)); }
                catch (e3) { info.layerExports.push({ index: L.index, error: PSO.errorText(e3) }); }
            }
        }
        return info;
    } finally { PSO.close(doc); }
});
