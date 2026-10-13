// blend-table: which layer blend modes Photoshop allows per colour mode and depth. Creates small
// untitled documents only (no file is opened): a pixel layer and a group in each, then tries every
// mode on both through Action Manager and records which settings Photoshop refuses.
PSO.main(function () {
    var modes = ['normal', 'dissolve', 'darken', 'multiply', 'colorBurn', 'linearBurn', 'darkerColor', 'lighten', 'screen', 'colorDodge',
                 'linearDodge', 'lighterColor', 'overlay', 'softLight', 'hardLight', 'vividLight', 'linearLight', 'pinLight', 'hardMix',
                 'difference', 'exclusion', 'blendSubtraction', 'blendDivide', 'hue', 'saturation', 'color', 'luminosity', 'passThrough'];
    var combos = [['RGB', 8], ['RGB', 16], ['RGB', 32], ['Grayscale', 8], ['Grayscale', 16], ['Grayscale', 32], ['CMYK', 8], ['CMYK', 16], ['Lab', 8], ['Lab', 16]];
    var newModes = { RGB: NewDocumentMode.RGB, CMYK: NewDocumentMode.CMYK, Lab: NewDocumentMode.LAB, Grayscale: NewDocumentMode.GRAYSCALE };
    var depth = { 8: BitsPerChannelType.EIGHT, 16: BitsPerChannelType.SIXTEEN, 32: BitsPerChannelType.THIRTYTWO };
    function setMode(m) {
        var d = new ActionDescriptor();
        var r = new ActionReference();
        r.putEnumerated(cTID('Lyr '), cTID('Ordn'), cTID('Trgt'));
        d.putReference(cTID('null'), r);
        var v = new ActionDescriptor();
        v.putEnumerated(cTID('Md  '), cTID('BlnM'), sTID(m));
        d.putObject(cTID('T   '), cTID('Lyr '), v);
        executeAction(cTID('setd'), d, DialogModes.NO);
    }
    function current() { return PSO.getEnum(PSO.layerInfoDesc(), 'mode'); }
    var out = { ok: true, table: [] };
    for (var c = 0; c < combos.length; c++) {
        var doc = null, row = { mode: combos[c][0], bits: combos[c][1], layer: {}, group: {} };
        try {
            doc = app.documents.add(UnitValue(8, 'px'), UnitValue(8, 'px'), 72, 'pso_blendprobe', newModes[combos[c][0]], DocumentFill.WHITE, 1, depth[combos[c][1]]);
            var L = doc.artLayers.add();
            var G = doc.layerSets.add();
            var targets = [['layer', L], ['group', G]];
            for (var t = 0; t < targets.length; t++) {
                doc.activeLayer = targets[t][1];
                for (var i = 0; i < modes.length; i++) {
                    var ok;
                    try { setMode(modes[i]); ok = current() === modes[i]; } catch (e) { ok = false; }
                    row[targets[t][0]][modes[i]] = ok;
                    try { setMode(targets[t][0] === 'group' ? 'passThrough' : 'normal'); } catch (e2) {}
                }
            }
        } catch (e3) { row.error = PSO.errorText(e3); }
        PSO.close(doc);
        out.table.push(row);
    }
    // Modes without layers: can a layer exist at all?
    var flat = [['Bitmap', function (d) { d.flatten(); var o = new BitmapConversionOptions(); o.method = BitmapConversionType.HALFTHRESHOLD; o.resolution = 72; d.changeMode(ChangeMode.BITMAP, o); }, 'Grayscale'],
                ['Indexed', function (d) { d.flatten(); var o = new IndexedConversionOptions(); o.palette = Palette.LOCALSELECTIVE; o.colors = 16; o.dither = Dither.NONE; o.forced = ForcedColors.NONE; o.transparency = false; d.changeMode(ChangeMode.INDEXEDCOLOR, o); }, 'RGB'],
                ['Multichannel', function (d) { d.flatten(); d.changeMode(ChangeMode.MULTICHANNEL); }, 'RGB']];
    out.layerless = {};
    for (var f = 0; f < flat.length; f++) {
        var fd = null;
        try {
            fd = app.documents.add(UnitValue(8, 'px'), UnitValue(8, 'px'), 72, 'pso_blendprobe', newModes[flat[f][2]], DocumentFill.WHITE, 1, BitsPerChannelType.EIGHT);
            flat[f][1](fd);
            try { fd.artLayers.add(); out.layerless[flat[f][0]] = 'a layer can be added'; } catch (e4) { out.layerless[flat[f][0]] = 'no layers: ' + PSO.errorText(e4).replace(/\n/g, ' '); }
        } catch (e5) { out.layerless[flat[f][0]] = 'probe failed: ' + PSO.errorText(e5); }
        PSO.close(fd);
    }
    return out;
});
