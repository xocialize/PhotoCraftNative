// measure-m2: measurement batch M2 for PCRender phase 5 (modern Brightness/Contrast and its pivot,
// Satin without anti-aliasing, Dissolve coverage, Vibrance hold-outs, Luminosity at 50 %, and the
// 12 default contour presets rendered through Outer Glow). Shared helpers and M.main are in
// measure-common.jsx. Photoshop only creates documents or opens ps-oracle's PNG inputs.
//
// Contour presets (group "contour-presets"): only the preset NAME is set and read back; the
// curve Photoshop stores for a preset is never read, and these jobs save no PSD.

// ------------------------------------------------------------------ satin with read-back

M.satinJob2 = function (id, p) {
    var doc = null;
    try {
        doc = C.newDoc(id, 'RGB', 8, { width: 512, height: 384 });
        C.fill(p.raw ? [0, 0, 0] : [128, 128, 128]);
        M.drawShapes(doc);
        if (p.raw) C.set({ fill: 0 });
        M.satinDescriptor(p);
        var e = M.readEffect('ChFX');
        var stored = { contour: M.contourName(e, 'MpgS'), antialias: e.getBoolean(cTID('AntA')), invert: e.getBoolean(cTID('Invr')),
                       angle: e.getUnitDoubleValue(cTID('lagl')), distance: e.getUnitDoubleValue(cTID('Dstn')), size: e.getUnitDoubleValue(cTID('blur')) };
        M.expect('Satin contour', p.contour, stored.contour);
        M.expect('Satin anti-aliased', p.antialias, stored.antialias);
        M.expect('Satin invert', p.invert, stored.invert);
        M.expect('Satin angle', p.angle, stored.angle);
        M.expect('Satin distance', p.distance, stored.distance);
        M.expect('Satin size', p.size, stored.size);
        var out = M.saveBoth(doc, id);
        out.shapes = M.SHAPES;
        out.stored = stored;
        return out;
    } finally { PSO.close(doc); }
};

// ------------------------------------------------------------------ dissolve coverage

// A reveal-all user mask on the target layer, filled with Photoshop's own 50 % grey.
M.halfGreyMask = function () {
    var d = new ActionDescriptor();
    d.putClass(cTID('Nw  '), cTID('Chnl'));
    var r = new ActionReference();
    r.putEnumerated(cTID('Chnl'), cTID('Chnl'), cTID('Msk '));
    d.putReference(cTID('At  '), r);
    d.putEnumerated(cTID('Usng'), cTID('UsrM'), cTID('RvlA'));
    executeAction(cTID('Mk  '), d, DialogModes.NO);
    var s = new ActionDescriptor(), m = new ActionReference();
    m.putEnumerated(cTID('Chnl'), cTID('Chnl'), cTID('Msk '));
    s.putReference(cTID('null'), m);
    s.putBoolean(cTID('MkVs'), false);
    executeAction(cTID('slct'), s, DialogModes.NO);
    var f = new ActionDescriptor();
    f.putEnumerated(cTID('Usng'), cTID('FlCn'), cTID('Gry '));
    f.putUnitDouble(cTID('Opct'), cTID('#Prc'), 100);
    f.putEnumerated(cTID('Md  '), cTID('BlnM'), cTID('Nrml'));
    executeAction(cTID('Fl  '), f, DialogModes.NO);
    var b = new ActionDescriptor(), c = new ActionReference();
    c.putEnumerated(cTID('Chnl'), cTID('Chnl'), cTID('RGB '));
    b.putReference(cTID('null'), c);
    b.putBoolean(cTID('MkVs'), false);
    executeAction(cTID('slct'), b, DialogModes.NO);
};

// A layer of solid red over the white background, Dissolve, at p.opacity / p.fill (percent),
// optionally under a 50 %-grey mask. Saves the composite (and the PSD only for the mask job, to
// check the mask value offline).
M.dissolveCoverageJob = function (id, p) {
    var doc = null;
    try {
        doc = C.newDoc(id, 'RGB', 8, { width: p.width, height: p.height });
        C.layer('Dissolve');
        C.selRect(0, 0, p.height, p.width);
        C.fill([255, 0, 0]);
        C.deselect();
        if (p.mask) M.halfGreyMask();
        C.set({ mode: 'dissolve', opacity: p.opacity, fill: p.fill });
        var info = PSO.layerInfoDesc();
        var stored = { mode: t2s(info.getEnumerationValue(cTID('Md  '))), opacity: C.num(info, cTID('Opct')),
                       fillOpacity: C.num(info, sTID('fillOpacity')), hasUserMask: PSO.getBool(info, 'hasUserMask') };
        M.expect('Dissolve blend mode', 'dissolve', stored.mode);
        var out = p.mask ? M.saveBoth(doc, id) : M.saveComposite(doc, id);
        out.stored = stored;
        return out;
    } finally { PSO.close(doc); }
};

// ------------------------------------------------------------------ contour presets via Outer Glow

M.CONTOUR_CANVAS = 640;
M.CONTOUR_SQUARE = { offset: 192, size: 256 };

M.outerGlowJob = function (id, p) {
    var doc = null;
    try {
        doc = C.newDoc(id, 'RGB', 8, { width: M.CONTOUR_CANVAS, height: M.CONTOUR_CANVAS });
        C.fill([0, 0, 0]);
        C.layer('Square');
        var o = M.CONTOUR_SQUARE.offset, s = M.CONTOUR_SQUARE.size;
        C.selRect(o, o, o + s, o + s);
        C.fill([255, 255, 255]);
        C.deselect();
        C.set({ fill: 0 });
        var e = C.fxCommon('Nrml', [255, 255, 255], 100);
        e.putEnumerated(cTID('GlwT'), cTID('BETE'), cTID('PrBL'));
        C.unitP(e, 'Ckmt', 0);
        C.unitX(e, 'blur', p.size);
        C.unitP(e, 'Nose', 0);
        C.unitP(e, 'ShdN', 0);
        e.putBoolean(cTID('AntA'), p.antialias);
        var c = new ActionDescriptor();
        c.putString(cTID('Nm  '), p.contour);
        e.putObject(cTID('TrnS'), cTID('ShpC'), c);
        C.unitP(e, 'Inpr', p.range);
        var fx = new ActionDescriptor();
        C.unitP(fx, 'Scl ', 100);
        fx.putObject(cTID('OrGl'), cTID('OrGl'), e);
        var d = new ActionDescriptor(), ref = new ActionReference();
        ref.putProperty(cTID('Prpr'), cTID('Lefx'));
        ref.putEnumerated(cTID('Lyr '), cTID('Ordn'), cTID('Trgt'));
        d.putReference(cTID('null'), ref);
        d.putObject(cTID('T   '), cTID('Lefx'), fx);
        executeAction(cTID('setd'), d, DialogModes.NO);
        // Read back the settings and the preset's NAME (never its curve).
        var g = M.readEffect('OrGl');
        M.expect('Outer Glow contour preset', p.contour, M.contourName(g, 'TrnS'));
        M.expect('Outer Glow technique precise', true, g.getEnumerationValue(cTID('GlwT')) === cTID('PrBL'));
        M.expect('Outer Glow anti-aliased', p.antialias, g.getBoolean(cTID('AntA')));
        M.expect('Outer Glow size', p.size, g.getUnitDoubleValue(cTID('blur')));
        M.expect('Outer Glow range', p.range, g.getUnitDoubleValue(cTID('Inpr')));
        M.expect('Outer Glow spread', 0, g.getUnitDoubleValue(cTID('Ckmt')));
        M.expect('Outer Glow jitter', 0, g.getUnitDoubleValue(cTID('ShdN')));
        M.expect('Outer Glow opacity', 100, g.getUnitDoubleValue(cTID('Opct')));
        var out = M.saveComposite(doc, id);
        out.square = M.CONTOUR_SQUARE;
        return out;
    } finally { PSO.close(doc); }
};

// ------------------------------------------------------------------ the one-document B/C check

// Makes one modern B/C layer (Brightness 25, Contrast 35) in a new 64 × 64 document and reads
// it back; nothing is saved.
M.ops['probe-bc'] = function () {
    var doc = null;
    try {
        doc = C.newDoc('probe-bc', 'RGB', 8, { width: 64, height: 64 });
        C.makeAdjustment('BrgC', C.bcSettings(25, 35));
        return { stored: M.scalars(C.readAdjustment()) };
    } finally { PSO.close(doc); }
};

// ------------------------------------------------------------------ catalogue

M.slug = function (s) { return s.toLowerCase().replace(/ - /g, '-').replace(/ /g, '-'); };

(function () {
    M.add('identity-rgb8', 'identity', { input: 'identity-rgb8.png' }, function () { return M.identityJob('identity-rgb8', 'identity-rgb8.png'); });
    M.add('identity-rgb16', 'identity', { input: 'identity-rgb16.png' }, function () { return M.identityJob('identity-rgb16', 'identity-rgb16.png'); });

    // 1. Modern Brightness/Contrast
    function bc(id, b, c, input, group) {
        M.add(id, group || 'brightness-contrast', { brightness: b, contrast: c, brightnessMode: 'brightnessModeModern', useLegacy: false, input: input },
              function () { return M.adjustJob(id, input, M.brightnessContrast(b, c)); });
    }
    var bs = [-150, -50, 50, 150], cs = [-50, 0, 50, 100];
    for (var i = 0; i < bs.length; i++) for (var j = 0; j < cs.length; j++) bc('bcm-b' + bs[i] + '-c' + cs[j] + '-rgb8', bs[i], cs[j], 'identity-rgb8.png');
    var c0 = [-50, -25, 0, 25, 50, 75, 100];
    for (var k = 0; k < c0.length; k++) bc('bcm-b0-c' + c0[k] + '-rgb8', 0, c0[k], 'identity-rgb8.png');
    bc('bcm-b50-c50-rgb16', 50, 50, 'identity-rgb16.png');

    // 2. B/C pivot: Contrast 50 over inputs with different statistics
    var pivots = ['flat-032', 'flat-064', 'flat-096', 'flat-128', 'flat-160', 'flat-192', 'flat-224', 'lattice-half', 'lattice-left-black'];
    for (var q = 0; q < pivots.length; q++) bc('bcm-pivot-' + pivots[q] + '-b0-c50', 0, 50, pivots[q] + '-rgb8.png', 'brightness-contrast-pivot');

    // 3. Satin: anti-aliased off; Linear at another angle and sizes
    var base = { angle: 19, distance: 11, size: 14, color: [0, 0, 0], mode: 'multiply', opacity: 50 };
    var sv = [
        { contour: 'Cone', antialias: false, angle: 19, size: 14 },
        { contour: 'Ring', antialias: false, angle: 19, size: 14 },
        { contour: 'Gaussian', antialias: false, angle: 19, size: 14 },
        { contour: 'Linear', antialias: true, angle: 30, size: 14 },
        { contour: 'Linear', antialias: true, angle: 19, size: 7 },
        { contour: 'Linear', antialias: true, angle: 19, size: 15 }
    ];
    for (var v = 0; v < sv.length; v++) {
        (function (vv) {
            var slug = 'satin2-' + M.slug(vv.contour) + (vv.antialias ? '' : '-noaa') + '-a' + vv.angle + '-d' + base.distance + '-s' + vv.size;
            var p = { contour: vv.contour, invert: false, angle: vv.angle, distance: base.distance, size: vv.size, color: base.color, mode: base.mode,
                      opacity: base.opacity, antialias: vv.antialias, raw: false, background: [128, 128, 128] };
            M.add(slug, 'satin', p, function () { return M.satinJob2(slug, p); });
            var r = { contour: vv.contour, invert: false, angle: vv.angle, distance: base.distance, size: vv.size, color: [255, 255, 255], mode: 'normal',
                      opacity: 100, antialias: vv.antialias, raw: true, background: [0, 0, 0], layerFill: 0 };
            M.add(slug + '-raw', 'satin-raw', r, function () { return M.satinJob2(slug + '-raw', r); });
        })(sv[v]);
    }

    // 4. Dissolve coverage (aggregate coverage only)
    var ops = [1, 5, 10, 20, 25, 30, 35, 40, 45, 50, 55, 60, 65, 70, 75, 80, 85, 90, 95, 99];
    function dz(id, p) { M.add(id, 'dissolve-coverage', p, function () { return M.dissolveCoverageJob(id, p); }); }
    for (var o = 0; o < ops.length; o++) {
        dz('dissolve-o' + (ops[o] < 10 ? '0' : '') + ops[o], { width: 512, height: 512, opacity: ops[o], fill: 100, mask: false, color: [255, 0, 0], background: [255, 255, 255] });
    }
    dz('dissolve-fill50', { width: 512, height: 512, opacity: 100, fill: 50, mask: false, color: [255, 0, 0], background: [255, 255, 255] });
    dz('dissolve-mask50', { width: 512, height: 512, opacity: 100, fill: 100, mask: true, maskContent: "Photoshop's 50 % Gray fill", color: [255, 0, 0], background: [255, 255, 255] });
    dz('dissolve-long-4096x64-o50', { width: 4096, height: 64, opacity: 50, fill: 100, mask: false, color: [255, 0, 0], background: [255, 255, 255] });

    // 5. Vibrance hold-outs
    var vs = [-75, -25, 25, 75];
    for (var a = 0; a < vs.length; a++) {
        (function (va) {
            var id = 'vib2-v' + va + '-s0-rgb8';
            M.add(id, 'vibrance', { vibrance: va, saturation: 0, input: 'identity-rgb8.png' }, function () { return M.adjustJob(id, 'identity-rgb8.png', M.vibrance(va, 0)); });
        })(vs[a]);
    }
    M.add('vib2-v100-s0-rgb16', 'vibrance', { vibrance: 100, saturation: 0, input: 'identity-rgb16.png' },
          function () { return M.adjustJob('vib2-v100-s0-rgb16', 'identity-rgb16.png', M.vibrance(100, 0)); });

    // 6. Luminosity at 50 % opacity
    var perms = ['a', 'b'];
    for (var pq = 0; pq < perms.length; pq++) {
        (function (pp) {
            var id = 'blend2-luminosity-o50-perm' + pp + '-rgb8';
            M.add(id, 'blend', { mode: 'luminosity', opacity: 50, base: 'identity-rgb8.png', top: 'perm-' + pp + '-rgb8.png' },
                  function () { return M.blendJob(id, 'identity-rgb8.png', 'perm-' + pp + '-rgb8.png', 'luminosity', 50); });
        })(perms[pq]);
    }

    // 7. The 12 default contour presets through Outer Glow (preset names only)
    var presets = ['Linear', 'Cone', 'Cone - Inverted', 'Cove - Deep', 'Cove - Shallow', 'Gaussian', 'Half Round', 'Ring', 'Ring - Double',
                   'Rolling Slope - Descending', 'Rounded Steps', 'Sawtooth 1'];
    function glow(id, name, aa, range) {
        var p = { contour: name, antialias: aa, technique: 'precise', size: 120, spread: 0, range: range, jitter: 0, color: [255, 255, 255],
                  mode: 'normal', opacity: 100, canvas: [M.CONTOUR_CANVAS, M.CONTOUR_CANVAS], background: [0, 0, 0], square: M.CONTOUR_SQUARE, layerFill: 0 };
        M.add(id, 'contour-presets', p, function () { return M.outerGlowJob(id, p); });
    }
    for (var aa = 0; aa < 2; aa++) {
        for (var n = 0; n < presets.length; n++) glow('contour-' + M.slug(presets[n]) + (aa ? '-aa' : '-noaa'), presets[n], aa === 1, 100);
    }
    glow('contour-linear-noaa-range50', 'Linear', false, 50);
})();

M.main();
