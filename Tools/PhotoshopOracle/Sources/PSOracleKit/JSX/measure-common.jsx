// measure-common: the shared part of the measurement batches (measure-m1, measure-m2). Photoshop
// only CREATES documents or opens the plain PNG inputs ps-oracle wrote (ARGS.inputs); no PSD is
// ever opened. Prepended after lib.jsx and builders.jsx; each batch adds its catalogue (M.add) and
// calls M.main().
//   ARGS.op = "env"  → Photoshop version, colour settings, ruler units, contour preset names
//   ARGS.op = "list" → the jobs and their parameters
//   ARGS.op = "run", ARGS.job = id → runs one job (0 documents open before and after)

var M = {};
M.jobs = [];
M.add = function (id, group, params, run) { M.jobs.push({ id: id, group: group, params: params, run: run }); };

M.inputPath = function (name) { return ARGS.inputs + '/' + name; };

// Opens one of ps-oracle's PNG inputs (PSO.open checks the path and that no document is open)
// and assigns sRGB, the corpus documents' profile (Photoshop opens these PNGs untagged; assigning
// a profile does not change pixel values).
M.SRGB = 'sRGB IEC61966-2.1';
M.openInput = function (name) {
    var d = PSO.open(M.inputPath(name));
    d.colorProfileName = M.SRGB;
    return d;
};

// A second input while the first is open (blend jobs): same path check, no zero-documents rule.
M.openSecondInput = function (name) {
    var p = M.inputPath(name);
    PSO.checkPath(p);
    var f = new File(p);
    if (!f.exists) throw new Error('no such input: ' + p);
    var d = app.open(f);
    d.colorProfileName = M.SRGB;
    return d;
};

M.saveBoth = function (doc, id) {
    var psd = ARGS.out + '/psd/' + id + '.psd';
    var tif = ARGS.out + '/tif/' + id + '.tif';
    C.save(doc, psd, 'psd');
    var comp = PSO.flattenedComposite(doc, tif);
    app.activeDocument = doc;
    var prof = null;
    try { prof = doc.colorProfileName; } catch (e) {}
    return { psd: psd, tif: tif, width: comp.width, height: comp.height, bits: comp.bits, mode: PSO.modeName(doc.mode), profile: prof };
};

// ------------------------------------------------------------------ satin

M.satinDescriptor = function (p) {
    var e = new ActionDescriptor();
    e.putBoolean(cTID('enab'), true);
    e.putBoolean(sTID('present'), true);
    e.putBoolean(sTID('showInDialog'), true);
    e.putEnumerated(cTID('Md  '), cTID('BlnM'), cTID(p.mode === 'normal' ? 'Nrml' : 'Mltp'));
    e.putObject(cTID('Clr '), cTID('RGBC'), C.rgb(p.color));
    e.putBoolean(cTID('AntA'), p.antialias);
    e.putBoolean(cTID('Invr'), p.invert);
    C.unitP(e, 'Opct', p.opacity);
    e.putUnitDouble(cTID('lagl'), cTID('#Ang'), p.angle);
    C.unitX(e, 'Dstn', p.distance);
    C.unitX(e, 'blur', p.size);
    var c = new ActionDescriptor();
    c.putString(cTID('Nm  '), p.contour);
    e.putObject(cTID('MpgS'), cTID('ShpC'), c);
    var fx = new ActionDescriptor();
    C.unitP(fx, 'Scl ', 100);
    fx.putObject(cTID('ChFX'), cTID('ChFX'), e);
    var d = new ActionDescriptor();
    var ref = new ActionReference();
    ref.putProperty(cTID('Prpr'), cTID('Lefx'));
    ref.putEnumerated(cTID('Lyr '), cTID('Ordn'), cTID('Trgt'));
    d.putReference(cTID('null'), ref);
    d.putObject(cTID('T   '), cTID('Lefx'), fx);
    executeAction(cTID('setd'), d, DialogModes.NO);
};

// A rectangle centred at (cx, cy), w × h, rotated by `deg` counter-clockwise as seen on screen
// (Photoshop's angle convention, y down in pixels): corner list in pixels.
M.rotatedRect = function (cx, cy, w, h, deg) {
    var a = deg * Math.PI / 180, ca = Math.cos(a), sa = Math.sin(a), out = [];
    var corners = [[-w / 2, -h / 2], [w / 2, -h / 2], [w / 2, h / 2], [-w / 2, h / 2]];
    for (var i = 0; i < 4; i++) {
        var x = corners[i][0], y = corners[i][1];
        out.push([cx + x * ca + y * sa, cy - x * sa + y * ca]);
    }
    return out;
};

// The shared shape geometry (pixels; 512×384 canvas, 72 ppi).
// Apart by at least 48 px (more than distance 30 + size 14), so no shape enters another's Satin.
M.SHAPES = {
    circle: { centre: [110, 105], radius: 55 },
    parallelRect: { centre: [350, 105], size: [150, 90], rotation: 19 },
    rotatedRect: { centre: [256, 285], size: [120, 80], rotation: 30 }
};

M.drawShapes = function (doc) {
    var L = C.layer('Shapes');
    var c = M.SHAPES.circle;
    C.selEllipse(c.centre[1] - c.radius, c.centre[0] - c.radius, c.centre[1] + c.radius, c.centre[0] + c.radius);
    C.fill([255, 255, 255]);
    var rects = [M.SHAPES.parallelRect, M.SHAPES.rotatedRect];
    for (var i = 0; i < rects.length; i++) {
        var r = rects[i];
        var pts = M.rotatedRect(r.centre[0], r.centre[1], r.size[0], r.size[1], r.rotation);
        doc.selection.select(pts, SelectionType.REPLACE, 0, true);
        C.fill([255, 255, 255]);
    }
    C.deselect();
    return L;
};

M.satinJob = function (id, p) {
    var doc = null;
    try {
        doc = C.newDoc(id, 'RGB', 8, { width: 512, height: 384 });
        C.fill(p.raw ? [0, 0, 0] : [128, 128, 128]);
        M.drawShapes(doc);
        if (p.raw) C.set({ fill: 0 });
        M.satinDescriptor(p);
        var out = M.saveBoth(doc, id);
        out.shapes = M.SHAPES;
        return out;
    } finally { PSO.close(doc); }
};

// ------------------------------------------------------------------ adjustments on the identity input

M.adjustJob = function (id, input, make) {
    var doc = null;
    try {
        doc = M.openInput(input);
        var extra = make() || {};
        var out = M.saveBoth(doc, id);
        for (var k in extra) if (extra.hasOwnProperty(k)) out[k] = extra[k];
        return out;
    } finally { PSO.close(doc); }
};

// Modern Brightness/Contrast (brightnessModeModern, set when the layer is made). M1 ran before
// this fix: its bc-* jobs got Photoshop 27's Light mode, Brgh stored 0 (RESULTS.md §5c).
// C.makeAdjustment reads the stored settings back and fails the job if they differ.
M.brightnessContrast = function (b, c, mode) {
    return function () {
        C.makeAdjustment('BrgC', C.bcSettings(b, c, mode));
        return { stored: M.scalars(C.readAdjustment()) };
    };
};

M.vibrance = function (v, s) {
    return function () {
        var d = new ActionDescriptor();
        d.putInteger(sTID('vibrance'), v);
        if (s !== 0) d.putInteger(cTID('Strt'), s); // Photoshop stores no Strt at 0
        C.makeAdjustment('vibrance', d);
        return { stored: M.scalars(C.readAdjustment()) };
    };
};

// ------------------------------------------------------------------ blend modes on lattice pairs

M.blendJob = function (id, base, top, mode, opacity) {
    var doc = null, topDoc = null;
    try {
        doc = M.openInput(base);
        topDoc = M.openSecondInput(top);
        var src = topDoc.layers[topDoc.layers.length - 1];
        src.duplicate(doc, ElementPlacement.PLACEATBEGINNING);
        PSO.close(topDoc);
        topDoc = null;
        app.activeDocument = doc;
        doc.activeLayer = doc.layers[0];
        doc.activeLayer.name = 'Top';
        C.set({ mode: mode, opacity: opacity === undefined ? 100 : opacity });
        var info = PSO.layerInfoDesc();
        var out = M.saveBoth(doc, id);
        out.stored = { mode: t2s(info.getEnumerationValue(cTID('Md  '))), opacity: C.num(info, cTID('Opct')) };
        return out;
    } finally { PSO.close(topDoc); PSO.close(doc); }
};

// ------------------------------------------------------------------ dissolve

M.dissolveJob = function (id, canvas, offset) {
    var doc = null;
    try {
        doc = C.newDoc(id, 'RGB', 8, { width: canvas, height: canvas });
        C.layer('Dissolve');
        C.selRect(offset[1], offset[0], offset[1] + 256, offset[0] + 256);
        C.fill([255, 0, 0]);
        C.deselect();
        C.set({ mode: 'dissolve', opacity: 50 });
        var out = M.saveBoth(doc, id);
        out.square = { offset: offset, size: 256 };
        return out;
    } finally { PSO.close(doc); }
};

M.identityJob = function (id, input) {
    var doc = null;
    try {
        doc = M.openInput(input);
        return M.saveBoth(doc, id);
    } finally { PSO.close(doc); }
};


// ------------------------------------------------------------------ read-backs and composites

// The flattened composite only (TIFF), for jobs whose PSD is not wanted.
M.saveComposite = function (doc, id) {
    var tif = ARGS.out + '/tif/' + id + '.tif';
    var comp = PSO.flattenedComposite(doc, tif);
    app.activeDocument = doc;
    var prof = null;
    try { prof = doc.colorProfileName; } catch (e) {}
    return { tif: tif, width: comp.width, height: comp.height, bits: comp.bits, mode: PSO.modeName(doc.mode), profile: prof };
};

// The scalar values of a descriptor by key name (numbers, booleans, enumerations, strings).
M.scalars = function (d) {
    var o = {};
    for (var i = 0; i < d.count; i++) {
        var k = d.getKey(i), t = d.getType(k), n = t2s(k);
        if (C.isNumType(t)) o[n] = C.num(d, k);
        else if (t === DescValueType.BOOLEANTYPE) o[n] = d.getBoolean(k);
        else if (t === DescValueType.ENUMERATEDTYPE) o[n] = t2s(d.getEnumerationValue(k));
        else if (t === DescValueType.STRINGTYPE) o[n] = d.getString(k);
    }
    return o;
};

// The target layer's stored effect (e.g. 'ChFX', 'OrGl').
M.readEffect = function (key) {
    var d = executeActionGet(C.target());
    if (!d.hasKey(sTID('layerEffects'))) throw new Error('ps-oracle: no layer effects stored');
    var fx = d.getObjectValue(sTID('layerEffects'));
    if (!fx.hasKey(cTID(key))) throw new Error('ps-oracle: effect ' + key + ' not stored');
    return fx.getObjectValue(cTID(key));
};

// A stored contour's preset NAME only ("$$$/Contours/Defaults/Cone=Cone" → "Cone"); the curve is
// never read.
M.contourName = function (e, key) {
    var n = e.getObjectValue(cTID(key)).getString(cTID('Nm  '));
    var eq = n.lastIndexOf('=');
    return eq >= 0 ? n.substring(eq + 1) : n;
};

M.expect = function (what, want, got) {
    var same = typeof want === 'number' ? C.sameNumber(want, got) : want === got;
    if (!same) throw new Error('ps-oracle: ' + what + ' asked ' + want + ', stored ' + got);
};

// ------------------------------------------------------------------ main

M.contourPresets = function () {
    var r = new ActionReference();
    r.putProperty(cTID('Prpr'), sTID('presetManager'));
    r.putEnumerated(cTID('capp'), cTID('Ordn'), cTID('Trgt'));
    var pm = executeActionGet(r).getList(sTID('presetManager'));
    var contours = [];
    for (var i = 0; i < pm.count; i++) {
        if (t2s(pm.getObjectType(i)) !== 'shapeCurveType') continue;
        var nl = pm.getObjectValue(i).getList(cTID('Nm  '));
        for (var j = 0; j < nl.count; j++) contours.push(nl.getString(j));
    }
    return contours;
};

// Extra ops a batch handles itself: M.ops[name] = function () { return result; }.
M.ops = {};

M.main = function () {
    return PSO.main(function () {
        if (ARGS.op === 'env') {
            return { ok: true, version: app.version, colorSettings: String(app.colorSettings), rulerUnits: String(app.preferences.rulerUnits),
                     documents: app.documents.length, contourPresets: M.contourPresets() };
        }
        if (ARGS.op === 'list') {
            var out = [];
            for (var k = 0; k < M.jobs.length; k++) out.push({ id: M.jobs[k].id, group: M.jobs[k].group, params: M.jobs[k].params });
            return { ok: true, jobs: out };
        }
        if (ARGS.op === 'run') {
            PSO.checkPath(ARGS.out);
            for (var n = 0; n < M.jobs.length; n++) {
                if (M.jobs[n].id !== ARGS.job) continue;
                if (app.documents.length !== 0) throw new Error('ps-oracle: documents open (' + app.documents.length + ') before job ' + ARGS.job);
                var res = M.jobs[n].run();
                res.ok = true;
                res.id = ARGS.job;
                res.documentsAfter = app.documents.length;
                return res;
            }
            return { ok: false, error: 'no job ' + ARGS.job };
        }
        if (M.ops[ARGS.op]) {
            if (app.documents.length !== 0) throw new Error('ps-oracle: documents open (' + app.documents.length + ') before op ' + ARGS.op);
            var r = M.ops[ARGS.op]();
            r.ok = true;
            r.documentsAfter = app.documents.length;
            return r;
        }
        return { ok: false, error: 'unknown op ' + ARGS.op };
    });
};
