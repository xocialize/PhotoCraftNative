// lut-probe: ONE new RGB 8-bit document with a Color Lookup layer loading ARGS.lut by
// LUT3DFileName + LUTFormat (Photoshop reads the file itself). Reads the layer back (key names,
// types, scalar values; raw data as byte counts only). Saves nothing unless asked: ARGS.psd
// (Maximize Compatibility) and ARGS.tif (flattened composite).
PSO.main(function () {
    if (app.documents.length !== 0) throw new Error('ps-oracle: documents open (' + app.documents.length + ')');
    var doc = null;
    try {
        doc = C.newDoc('lut-probe', 'RGB', 8, { width: 96, height: 64 });
        C.base();
        var got = C.colorLookupFile(ARGS.lut);
        var res = { ok: true, lut: ARGS.lut, keys: C.keyNames(got),
                    storesTable: got.hasKey(sTID('LUT3DFileData')) || got.hasKey(sTID('profile')) };
        if (ARGS.psd) { PSO.checkPath(ARGS.psd); C.save(doc, ARGS.psd, 'psd'); res.psd = ARGS.psd; }
        if (ARGS.tif) { PSO.checkPath(ARGS.tif); res.composite = PSO.flattenedComposite(doc, ARGS.tif); }
        return res;
    } finally { PSO.close(doc); }
});
