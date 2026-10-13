// builders: helpers that build content in new Photoshop documents (documents, selections, fills,
// gradients, fill/shape/adjustment layers, layer styles, text, smart objects, channels, mode
// changes). Prepended after lib.jsx to corpus.jsx and the measurement scripts. Everything is in
// pixels with explicit units; nothing is added to the user's presets.

var C = {};
C.items = [];
C.W = 96;
C.H = 64;

// A 4-character key is a charID, anything longer a stringID.
C.key = function (k) { return k.length === 4 ? cTID(k) : sTID(k); };

C.shortError = function (e) {
    var t = PSO.errorText(e).replace('General Photoshop error occurred. This functionality may not be available in this version of Photoshop.', '').replace(/^\s*-\s*/, '').replace(/\n/g, ' ');
    return t || 'refused';
};

C.add = function (name, features, description, build, ext) {
    C.items.push({ name: name, features: features, description: description, build: build, ext: ext || 'psd' });
};

// ------------------------------------------------------------------ documents

C.newDoc = function (name, mode, bits, opts) {
    opts = opts || {};
    var modes = { RGB: NewDocumentMode.RGB, CMYK: NewDocumentMode.CMYK, Lab: NewDocumentMode.LAB, Grayscale: NewDocumentMode.GRAYSCALE, Bitmap: NewDocumentMode.BITMAP };
    var depth = { 1: BitsPerChannelType.ONE, 8: BitsPerChannelType.EIGHT, 16: BitsPerChannelType.SIXTEEN, 32: BitsPerChannelType.THIRTYTWO };
    var fill = opts.transparent ? DocumentFill.TRANSPARENT : DocumentFill.WHITE;
    var w = opts.width || C.W, h = opts.height || C.H;
    var doc;
    if (mode === 'RGB' && !opts.profile) doc = app.documents.add(UnitValue(w, 'px'), UnitValue(h, 'px'), 72, 'pso_' + name, modes[mode], fill, 1, depth[bits], 'sRGB IEC61966-2.1');
    else if (opts.profile) doc = app.documents.add(UnitValue(w, 'px'), UnitValue(h, 'px'), 72, 'pso_' + name, modes[mode], fill, 1, depth[bits], opts.profile);
    else doc = app.documents.add(UnitValue(w, 'px'), UnitValue(h, 'px'), 72, 'pso_' + name, modes[mode], fill, 1, depth[bits]);
    app.activeDocument = doc;
    return doc;
};

C.save = function (doc, path, ext) {
    PSO.checkPath(path);
    app.activeDocument = doc;
    var d = new ActionDescriptor();
    var fmt = new ActionDescriptor();
    fmt.putBoolean(sTID('maximizeCompatibility'), true);
    d.putObject(cTID('As  '), ext === 'psb' ? sTID('largeDocumentFormat') : cTID('Pht3'), fmt);
    d.putPath(cTID('In  '), new File(path));
    d.putBoolean(cTID('Cpy '), true);
    d.putBoolean(cTID('AlpC'), true);
    d.putBoolean(cTID('SpcC'), true);
    d.putBoolean(sTID('embedProfiles'), true);
    d.putBoolean(cTID('LwCs'), true);
    executeAction(cTID('save'), d, DialogModes.NO);
};

// ------------------------------------------------------------------ descriptors

C.rgb = function (c) {
    var d = new ActionDescriptor();
    d.putDouble(cTID('Rd  '), c[0]);
    d.putDouble(cTID('Grn '), c[1]);
    d.putDouble(cTID('Bl  '), c[2]);
    return d;
};

C.target = function () {
    var r = new ActionReference();
    r.putEnumerated(cTID('Lyr '), cTID('Ordn'), cTID('Trgt'));
    return r;
};

C.setLayer = function (v) {
    var d = new ActionDescriptor();
    d.putReference(cTID('null'), C.target());
    d.putObject(cTID('T   '), cTID('Lyr '), v);
    executeAction(cTID('setd'), d, DialogModes.NO);
};

C.layerProps = function (o) {
    var v = new ActionDescriptor();
    if (o.name !== undefined) v.putString(cTID('Nm  '), o.name);
    if (o.mode !== undefined) v.putEnumerated(cTID('Md  '), cTID('BlnM'), sTID(o.mode));
    if (o.opacity !== undefined) v.putUnitDouble(cTID('Opct'), cTID('#Prc'), o.opacity);
    if (o.fill !== undefined) v.putUnitDouble(sTID('fillOpacity'), cTID('#Prc'), o.fill);
    if (o.knockout !== undefined) v.putEnumerated(sTID('knockout'), sTID('knockout'), sTID(o.knockout));
    var flags = ['blendInterior', 'blendClipped', 'transparencyShapesLayer', 'layerMaskAsGlobalMask', 'vectorMaskAsGlobalMask'];
    for (var i = 0; i < flags.length; i++) if (o[flags[i]] !== undefined) v.putBoolean(sTID(flags[i]), o[flags[i]]);
    if (o.channels !== undefined) {
        var l = new ActionList();
        for (var k = 0; k < o.channels.length; k++) l.putEnumerated(cTID('Chnl'), cTID(o.channels[k]));
        v.putList(sTID('channelRestrictions'), l);
    }
    if (o.blendIf !== undefined) {
        var bl = new ActionList();
        for (var j = 0; j < o.blendIf.length; j++) {
            var b = o.blendIf[j], e = new ActionDescriptor(), cr = new ActionReference();
            cr.putEnumerated(cTID('Chnl'), cTID('Chnl'), cTID(b.channel));
            e.putReference(cTID('Chnl'), cr);
            e.putInteger(cTID('SrcB'), b.src[0]); e.putInteger(cTID('Srcl'), b.src[1]); e.putInteger(cTID('SrcW'), b.src[2]); e.putInteger(cTID('Srcm'), b.src[3]);
            e.putInteger(cTID('DstB'), b.dst[0]); e.putInteger(cTID('Dstl'), b.dst[1]); e.putInteger(cTID('DstW'), b.dst[2]); e.putInteger(cTID('Dstt'), b.dst[3]);
            bl.putObject(cTID('Blnd'), e);
        }
        v.putList(cTID('Blnd'), bl);
    }
    if (o.userMaskDensity !== undefined) v.putUnitDouble(sTID('userMaskDensity'), cTID('#Prc'), o.userMaskDensity);
    if (o.userMaskFeather !== undefined) v.putUnitDouble(sTID('userMaskFeather'), cTID('#Pxl'), o.userMaskFeather);
    if (o.userMaskEnabled !== undefined) v.putBoolean(sTID('userMaskEnabled'), o.userMaskEnabled);
    if (o.vectorMaskDensity !== undefined) v.putUnitDouble(sTID('vectorMaskDensity'), cTID('#Prc'), o.vectorMaskDensity);
    if (o.vectorMaskFeather !== undefined) v.putUnitDouble(sTID('vectorMaskFeather'), cTID('#Pxl'), o.vectorMaskFeather);
    return v;
};

C.set = function (o) { C.setLayer(C.layerProps(o)); };

// ------------------------------------------------------------------ selections and painting

C.selShape = function (cls, t, l, b, r) {
    var d = new ActionDescriptor();
    var ref = new ActionReference();
    ref.putProperty(cTID('Chnl'), cTID('fsel'));
    d.putReference(cTID('null'), ref);
    var rd = new ActionDescriptor();
    rd.putUnitDouble(cTID('Top '), cTID('#Pxl'), t);
    rd.putUnitDouble(cTID('Left'), cTID('#Pxl'), l);
    rd.putUnitDouble(cTID('Btom'), cTID('#Pxl'), b);
    rd.putUnitDouble(cTID('Rght'), cTID('#Pxl'), r);
    d.putObject(cTID('T   '), cTID(cls), rd);
    d.putBoolean(cTID('AntA'), true);
    executeAction(cTID('setd'), d, DialogModes.NO);
};
C.selRect = function (t, l, b, r) { C.selShape('Rctn', t, l, b, r); };
C.selEllipse = function (t, l, b, r) { C.selShape('Elps', t, l, b, r); };

C.deselect = function () {
    var d = new ActionDescriptor();
    var ref = new ActionReference();
    ref.putProperty(cTID('Chnl'), cTID('fsel'));
    d.putReference(cTID('null'), ref);
    d.putEnumerated(cTID('T   '), cTID('Ordn'), cTID('None'));
    executeAction(cTID('setd'), d, DialogModes.NO);
};

C.featherSelection = function (px) {
    var d = new ActionDescriptor();
    d.putUnitDouble(cTID('Rds '), cTID('#Pxl'), px);
    d.putBoolean(sTID('selectionModifyEffectAtCanvasBounds'), false);
    executeAction(cTID('Fthr'), d, DialogModes.NO);
};

// Fill the selection (or the layer) with an RGB colour; mode 'Clar' with an opacity removes coverage.
C.fill = function (c, opacity, mode) {
    var d = new ActionDescriptor();
    d.putEnumerated(cTID('Usng'), cTID('FlCn'), cTID('Clr '));
    d.putObject(cTID('Clr '), cTID('RGBC'), C.rgb(c || [0, 0, 0]));
    d.putUnitDouble(cTID('Opct'), cTID('#Prc'), opacity === undefined ? 100 : opacity);
    d.putEnumerated(cTID('Md  '), cTID('BlnM'), cTID(mode || 'Nrml'));
    executeAction(cTID('Fl  '), d, DialogModes.NO);
};

C.layer = function (name) {
    var L = app.activeDocument.artLayers.add();
    L.name = name;
    return L;
};

C.rect = function (name, box, c, opacity) {
    var L = C.layer(name);
    C.selRect(box[0], box[1], box[2], box[3]);
    C.fill(c, opacity);
    C.deselect();
    return L;
};

C.ellipse = function (name, box, c, opacity) {
    var L = C.layer(name);
    C.selEllipse(box[0], box[1], box[2], box[3]);
    C.fill(c, opacity);
    C.deselect();
    return L;
};

// ------------------------------------------------------------------ gradients and fill layers

// stops: [[location 0…4096, r, g, b]…]; tstops: [[location, opacity %]…]
C.gradient = function (stops, tstops) {
    var g = new ActionDescriptor();
    g.putString(cTID('Nm  '), 'pso gradient');
    g.putEnumerated(cTID('GrdF'), cTID('GrdF'), cTID('CstS'));
    g.putDouble(cTID('Intr'), 4096);
    var cl = new ActionList();
    for (var i = 0; i < stops.length; i++) {
        var s = new ActionDescriptor();
        s.putObject(cTID('Clr '), cTID('RGBC'), C.rgb([stops[i][1], stops[i][2], stops[i][3]]));
        s.putEnumerated(cTID('Type'), cTID('Clry'), cTID('UsrS'));
        s.putInteger(cTID('Lctn'), stops[i][0]);
        s.putInteger(cTID('Mdpn'), 50);
        cl.putObject(cTID('Clrt'), s);
    }
    g.putList(cTID('Clrs'), cl);
    var tl = new ActionList();
    tstops = tstops || [[0, 100], [4096, 100]];
    for (var j = 0; j < tstops.length; j++) {
        var t = new ActionDescriptor();
        t.putUnitDouble(cTID('Opct'), cTID('#Prc'), tstops[j][1]);
        t.putInteger(cTID('Lctn'), tstops[j][0]);
        t.putInteger(cTID('Mdpn'), 50);
        tl.putObject(cTID('TrnS'), t);
    }
    g.putList(cTID('Trns'), tl);
    return g;
};

C.gradientSettings = function (stops, tstops, angle, type) {
    var g = new ActionDescriptor();
    g.putBoolean(cTID('Dthr'), false);
    g.putUnitDouble(cTID('Angl'), cTID('#Ang'), angle || 0);
    g.putEnumerated(cTID('Type'), cTID('GrdT'), cTID(type || 'Lnr '));
    g.putObject(cTID('Grad'), cTID('Grdn'), C.gradient(stops, tstops));
    return g;
};

C.makeContentLayer = function (typeKey, typeDesc, shape, stroke) {
    var d = new ActionDescriptor();
    var ref = new ActionReference();
    ref.putClass(sTID('contentLayer'));
    d.putReference(cTID('null'), ref);
    var cl = new ActionDescriptor();
    cl.putObject(cTID('Type'), sTID(typeKey), typeDesc);
    if (shape) cl.putObject(cTID('Shp '), cTID(shape.cls), shape.desc);
    if (stroke) cl.putObject(sTID('strokeStyle'), sTID('strokeStyle'), stroke);
    d.putObject(cTID('Usng'), sTID('contentLayer'), cl);
    executeAction(cTID('Mk  '), d, DialogModes.NO);
    return app.activeDocument.activeLayer;
};

C.solidLayer = function (name, c) {
    var t = new ActionDescriptor();
    t.putObject(cTID('Clr '), cTID('RGBC'), C.rgb(c));
    var L = C.makeContentLayer('solidColorLayer', t);
    L.name = name;
    return L;
};

C.gradientLayer = function (name, stops, tstops, angle, type) {
    var L = C.makeContentLayer('gradientLayer', C.gradientSettings(stops, tstops, angle, type));
    L.name = name;
    return L;
};

// Removes the target layer's user mask (fill layers get an empty one by default; it survives rasterising).
C.deleteMask = function () {
    if (!PSO.getBool(PSO.layerInfoDesc(), 'hasUserMask')) return;
    var d = new ActionDescriptor();
    var r = new ActionReference();
    r.putEnumerated(cTID('Chnl'), cTID('Chnl'), cTID('Msk '));
    d.putReference(cTID('null'), r);
    executeAction(cTID('Dlt '), d, DialogModes.NO);
};

C.rasterize = function () {
    var d = new ActionDescriptor();
    d.putReference(cTID('null'), C.target());
    executeAction(sTID('rasterizeLayer'), d, DialogModes.NO);
};

// A pixel layer holding a gradient (a rasterised gradient fill layer: deterministic, undithered).
C.ramp = function (name, stops, tstops, angle, type) {
    var L = C.gradientLayer(name, stops, tstops, angle, type);
    C.rasterize();
    C.deleteMask();
    L = app.activeDocument.activeLayer;
    L.name = name;
    return L;
};

C.rainbow = [[0, 255, 0, 0], [820, 255, 220, 0], [1640, 0, 200, 40], [2460, 0, 220, 230], [3280, 30, 40, 255], [4096, 230, 0, 200]];

C.mergeDown = function () { executeAction(cTID('Mrg2'), new ActionDescriptor(), DialogModes.NO); };

// The standard colourful base: a horizontal rainbow darkened towards the bottom, one pixel layer.
C.base = function () {
    C.ramp('Base', C.rainbow, null, 0);
    C.ramp('Shade', [[0, 0, 0, 0], [4096, 0, 0, 0]], [[0, 0], [4096, 85]], -90);
    C.mergeDown();
    var L = app.activeDocument.activeLayer;
    L.name = 'Base';
    return L;
};

// A blend source: vertical ramp, opaque on the left three quarters, 50 % coverage on the right.
C.blendSource = function (name, box) {
    var doc = app.activeDocument;
    var L = C.ramp(name, [[0, 20, 30, 120], [1400, 240, 120, 30], [2800, 250, 240, 200], [4096, 60, 200, 90]], null, -90);
    var W = doc.width.as('px'), H = doc.height.as('px');
    box = box || [0, 0, H, W];
    // Keep only `box`. (Inverting a full-canvas selection leaves no selection, and a fill without a
    // selection clears the whole layer — so only clear outside a box smaller than the canvas.)
    if (box[0] > 0 || box[1] > 0 || box[2] < H || box[3] < W) {
        C.selRect(box[0], box[1], box[2], box[3]);
        executeAction(cTID('Invs'), new ActionDescriptor(), DialogModes.NO);
        C.fill([0, 0, 0], 100, 'Clar');
    }
    var x = box[1] + Math.round((box[3] - box[1]) * 0.75);
    C.selRect(box[0], x, box[2], box[3]);
    C.fill([0, 0, 0], 50, 'Clar');
    C.deselect();
    return L;
};

// ------------------------------------------------------------------ groups, clipping, masks

C.group = function (name, layers, opts) {
    var doc = app.activeDocument;
    var g = (opts && opts.parent) ? opts.parent.layerSets.add() : doc.layerSets.add();
    g.name = name;
    // `layers` bottom to top; PLACEATEND puts each below the previous, so move the top one first.
    for (var i = layers.length - 1; i >= 0; i--) layers[i].move(g, ElementPlacement.PLACEATEND);
    if (opts && opts.blendMode) g.blendMode = opts.blendMode;
    if (opts && opts.opacity !== undefined) g.opacity = opts.opacity;
    doc.activeLayer = g;
    return g;
};

// Selects layers by name (the first replaces the selection, the rest are added).
C.selectLayers = function (names) {
    for (var i = 0; i < names.length; i++) {
        var d = new ActionDescriptor(), r = new ActionReference();
        r.putName(cTID('Lyr '), names[i]);
        d.putReference(cTID('null'), r);
        if (i > 0) d.putEnumerated(sTID('selectionModifier'), sTID('selectionModifierType'), sTID('addToSelection'));
        d.putBoolean(cTID('MkVs'), false);
        executeAction(cTID('slct'), d, DialogModes.NO);
    }
};

// An artboard made from the selected layers, at rect [left, top, right, bottom] (pixels).
C.artboardFromSelected = function (name, rect) {
    var d = new ActionDescriptor(), ref = new ActionReference();
    ref.putClass(sTID('artboardSection'));
    d.putReference(cTID('null'), ref);
    var from = new ActionReference();
    from.putEnumerated(cTID('Lyr '), cTID('Ordn'), cTID('Trgt'));
    d.putReference(cTID('From'), from);
    d.putString(cTID('Nm  '), name);
    var ab = new ActionDescriptor(), r = new ActionDescriptor();
    r.putDouble(cTID('Top '), rect[1]);
    r.putDouble(cTID('Left'), rect[0]);
    r.putDouble(cTID('Btom'), rect[3]);
    r.putDouble(cTID('Rght'), rect[2]);
    ab.putObject(sTID('artboardRect'), sTID('classFloatRect'), r);
    d.putObject(sTID('artboard'), sTID('artboard'), ab);
    executeAction(cTID('Mk  '), d, DialogModes.NO);
    var L = app.activeDocument.activeLayer;
    L.name = name;
    return L;
};

// Every layer's name, blend mode, layerKind, section and artboard state, top to bottom, as
// Photoshop reports them.
C.layerStates = function () {
    var out = [];
    var dr = new ActionReference();
    dr.putProperty(cTID('Prpr'), sTID('numberOfLayers'));
    dr.putEnumerated(cTID('Dcmn'), cTID('Ordn'), cTID('Trgt'));
    var n = executeActionGet(dr).getInteger(sTID('numberOfLayers'));
    for (var i = n; i >= 1; i--) {
        var r = new ActionReference();
        r.putIndex(sTID('layer'), i);
        var d;
        try { d = executeActionGet(r); } catch (e) { continue; }
        var o = { index: i, name: d.getString(cTID('Nm  ')), mode: t2s(d.getEnumerationValue(cTID('Md  '))), layerKind: d.getInteger(sTID('layerKind')),
                  section: d.hasKey(sTID('layerSection')) ? t2s(d.getEnumerationValue(sTID('layerSection'))) : null,
                  artboardEnabled: d.hasKey(sTID('artboardEnabled')) ? d.getBoolean(sTID('artboardEnabled')) : null };
        if (d.hasKey(sTID('artboard'))) {
            var ar = d.getObjectValue(sTID('artboard')).getObjectValue(sTID('artboardRect'));
            o.artboardRect = [ar.getDouble(cTID('Left')), ar.getDouble(cTID('Top ')), ar.getDouble(cTID('Rght')), ar.getDouble(cTID('Btom'))];
        }
        out.push(o);
    }
    return out;
};

C.clip = function () {
    var d = new ActionDescriptor();
    d.putReference(cTID('null'), C.target());
    executeAction(cTID('GrpL'), d, DialogModes.NO);
};

C.maskFromSelection = function () {
    var d = new ActionDescriptor();
    d.putClass(cTID('Nw  '), cTID('Chnl'));
    var r = new ActionReference();
    r.putEnumerated(cTID('Chnl'), cTID('Chnl'), cTID('Msk '));
    d.putReference(cTID('At  '), r);
    d.putEnumerated(cTID('Usng'), cTID('UsrM'), cTID('RvlS'));
    executeAction(cTID('Mk  '), d, DialogModes.NO);
};

C.vectorMaskFromSelection = function () {
    var doc = app.activeDocument;
    doc.selection.makeWorkPath(0.5);
    var d = new ActionDescriptor();
    var r = new ActionReference();
    r.putClass(cTID('Path'));
    d.putReference(cTID('null'), r);
    var a = new ActionReference();
    a.putEnumerated(cTID('Path'), cTID('Path'), sTID('vectorMask'));
    d.putReference(cTID('At  '), a);
    var u = new ActionReference();
    u.putEnumerated(cTID('Path'), cTID('Ordn'), cTID('Trgt'));
    d.putReference(cTID('Usng'), u);
    executeAction(cTID('Mk  '), d, DialogModes.NO);
    try { doc.pathItems.getByName('Work Path').remove(); } catch (e) {}
};

// ------------------------------------------------------------------ layer styles

C.unitP = function (d, k, v) { d.putUnitDouble(cTID(k), cTID('#Prc'), v); };
C.unitX = function (d, k, v) { d.putUnitDouble(cTID(k), cTID('#Pxl'), v); };
C.contour = function () { var c = new ActionDescriptor(); c.putString(cTID('Nm  '), 'Linear'); return c; };

C.fxCommon = function (mode, color, opacity, enabled) {
    var e = new ActionDescriptor();
    e.putBoolean(cTID('enab'), enabled === undefined ? true : enabled);
    e.putBoolean(sTID('present'), true);
    e.putBoolean(sTID('showInDialog'), true);
    e.putEnumerated(cTID('Md  '), cTID('BlnM'), cTID(mode));
    if (color) e.putObject(cTID('Clr '), cTID('RGBC'), C.rgb(color));
    C.unitP(e, 'Opct', opacity);
    return e;
};

C.fx = {
    dropShadow: function (o) {
        o = o || {};
        var e = C.fxCommon('Mltp', o.color || [10, 10, 40], o.opacity || 75, o.enabled);
        e.putBoolean(cTID('uglg'), false);
        e.putUnitDouble(cTID('lagl'), cTID('#Ang'), o.angle || 120);
        C.unitX(e, 'Dstn', o.distance || 5); C.unitP(e, 'Ckmt', o.spread || 10); C.unitX(e, 'blur', o.size || 6); C.unitP(e, 'Nose', 0);
        e.putBoolean(cTID('AntA'), false);
        e.putObject(cTID('TrnS'), cTID('ShpC'), C.contour());
        e.putBoolean(sTID('layerConceals'), true);
        return ['DrSh', e];
    },
    innerShadow: function (o) {
        o = o || {};
        var e = C.fxCommon('Mltp', [80, 0, 0], 80, o.enabled);
        e.putBoolean(cTID('uglg'), false);
        e.putUnitDouble(cTID('lagl'), cTID('#Ang'), 45);
        C.unitX(e, 'Dstn', 4); C.unitP(e, 'Ckmt', 0); C.unitX(e, 'blur', 5); C.unitP(e, 'Nose', 0);
        e.putBoolean(cTID('AntA'), false);
        e.putObject(cTID('TrnS'), cTID('ShpC'), C.contour());
        return ['IrSh', e];
    },
    outerGlow: function (o) {
        o = o || {};
        var e = C.fxCommon('Scrn', [255, 240, 120], 85, o.enabled);
        e.putEnumerated(cTID('GlwT'), cTID('BETE'), cTID('SfBL'));
        C.unitP(e, 'Ckmt', 10); C.unitX(e, 'blur', 8); C.unitP(e, 'Nose', 0); C.unitP(e, 'ShdN', 0);
        e.putBoolean(cTID('AntA'), false);
        e.putObject(cTID('TrnS'), cTID('ShpC'), C.contour());
        C.unitP(e, 'Inpr', 50);
        return ['OrGl', e];
    },
    innerGlow: function (o) {
        o = o || {};
        var e = C.fxCommon('Scrn', [255, 255, 200], 80, o.enabled);
        e.putEnumerated(cTID('GlwT'), cTID('BETE'), cTID('SfBL'));
        C.unitP(e, 'Ckmt', 0); C.unitX(e, 'blur', 7); C.unitP(e, 'Nose', 0); C.unitP(e, 'ShdN', 0);
        e.putBoolean(cTID('AntA'), false);
        e.putObject(cTID('TrnS'), cTID('ShpC'), C.contour());
        C.unitP(e, 'Inpr', 50);
        e.putEnumerated(cTID('glwS'), cTID('IGSr'), cTID('SrcE'));
        return ['IrGl', e];
    },
    bevelEmboss: function (o) {
        o = o || {};
        var e = new ActionDescriptor();
        e.putBoolean(cTID('enab'), o.enabled === undefined ? true : o.enabled);
        e.putBoolean(sTID('present'), true);
        e.putBoolean(sTID('showInDialog'), true);
        e.putEnumerated(cTID('hglM'), cTID('BlnM'), cTID('Scrn'));
        e.putObject(cTID('hglC'), cTID('RGBC'), C.rgb([255, 255, 255]));
        C.unitP(e, 'hglO', 75);
        e.putEnumerated(cTID('sdwM'), cTID('BlnM'), cTID('Mltp'));
        e.putObject(cTID('sdwC'), cTID('RGBC'), C.rgb([0, 0, 0]));
        C.unitP(e, 'sdwO', 75);
        e.putEnumerated(cTID('bvlT'), cTID('bvlT'), cTID('SfBL'));
        e.putEnumerated(cTID('bvlS'), cTID('BESl'), cTID('InrB'));
        e.putBoolean(cTID('uglg'), false);
        e.putUnitDouble(cTID('lagl'), cTID('#Ang'), 120);
        e.putUnitDouble(cTID('Lald'), cTID('#Ang'), 30);
        C.unitP(e, 'srgR', 100); C.unitX(e, 'blur', 5);
        e.putEnumerated(cTID('bvlD'), cTID('BESs'), cTID('In  '));
        e.putObject(cTID('TrnS'), cTID('ShpC'), C.contour());
        e.putBoolean(sTID('antialiasGloss'), false);
        C.unitX(e, 'Sftn', 0);
        e.putBoolean(sTID('useShape'), false);
        e.putBoolean(sTID('useTexture'), false);
        return ['ebbl', e];
    },
    satin: function (o) {
        o = o || {};
        var e = C.fxCommon('Mltp', [20, 0, 60], 50, o.enabled);
        e.putBoolean(cTID('AntA'), true);
        e.putBoolean(cTID('Invr'), true);
        e.putUnitDouble(cTID('lagl'), cTID('#Ang'), 19);
        C.unitX(e, 'Dstn', 6); C.unitX(e, 'blur', 8);
        var c = new ActionDescriptor(); c.putString(cTID('Nm  '), 'Gaussian');
        e.putObject(cTID('MpgS'), cTID('ShpC'), c);
        return ['ChFX', e];
    },
    colorOverlay: function (o) {
        o = o || {};
        return ['SoFi', C.fxCommon('Nrml', o.color || [40, 160, 255], o.opacity || 60, o.enabled)];
    },
    gradientOverlay: function (o) {
        o = o || {};
        var e = C.fxCommon('Nrml', null, 80, o.enabled);
        e.putObject(cTID('Grad'), cTID('Grdn'), C.gradient([[0, 255, 0, 120], [4096, 0, 120, 255]]));
        e.putUnitDouble(cTID('Angl'), cTID('#Ang'), 45);
        e.putEnumerated(cTID('Type'), cTID('GrdT'), cTID('Lnr '));
        e.putBoolean(cTID('Rvrs'), false);
        e.putBoolean(cTID('Dthr'), false);
        e.putBoolean(cTID('Algn'), true);
        C.unitP(e, 'Scl ', 100);
        var p = new ActionDescriptor(); C.unitP(p, 'Hrzn', 0); C.unitP(p, 'Vrtc', 0);
        e.putObject(cTID('Ofst'), cTID('Pnt '), p);
        return ['GrFl', e];
    },
    patternOverlay: function (o) {
        var e = C.fxCommon('Nrml', null, 90, o.enabled);
        e.putObject(cTID('Ptrn'), cTID('Ptrn'), C.patternRef(o.pattern));
        C.unitP(e, 'Scl ', 100);
        e.putBoolean(cTID('Algn'), true);
        return ['patternFill', e];
    },
    stroke: function (o) {
        o = o || {};
        var e = new ActionDescriptor();
        e.putBoolean(cTID('enab'), o.enabled === undefined ? true : o.enabled);
        e.putBoolean(sTID('present'), true);
        e.putBoolean(sTID('showInDialog'), true);
        e.putEnumerated(cTID('Styl'), cTID('FStl'), cTID(o.position || 'OutF'));
        e.putEnumerated(cTID('PntT'), cTID('FrFl'), cTID('SClr'));
        e.putEnumerated(cTID('Md  '), cTID('BlnM'), cTID('Nrml'));
        C.unitP(e, 'Opct', 100);
        C.unitX(e, 'Sz  ', o.size || 3);
        e.putObject(cTID('Clr '), cTID('RGBC'), C.rgb(o.color || [20, 20, 20]));
        e.putBoolean(sTID('overprint'), false);
        return ['FrFX', e];
    }
};

// effects: [['dropShadow', opts], …]; multi: { dropShadow: [opts, opts] } for the multi-instance lists.
C.setEffects = function (effects, multi) {
    var fx = new ActionDescriptor();
    C.unitP(fx, 'Scl ', 100);
    for (var i = 0; i < effects.length; i++) {
        var r = C.fx[effects[i][0]](effects[i][1]);
        fx.putObject(C.key(r[0]), C.key(r[0]), r[1]);
    }
    if (multi) {
        var keys = { dropShadow: 'dropShadowMulti', stroke: 'frameFXMulti', colorOverlay: 'solidFillMulti', innerShadow: 'innerShadowMulti', gradientOverlay: 'gradientFillMulti' };
        for (var k in multi) {
            if (!multi.hasOwnProperty(k)) continue;
            var l = new ActionList();
            for (var j = 0; j < multi[k].length; j++) { var rr = C.fx[k](multi[k][j]); l.putObject(C.key(rr[0]), rr[1]); }
            fx.putList(sTID(keys[k]), l);
        }
    }
    var d = new ActionDescriptor();
    var ref = new ActionReference();
    ref.putProperty(cTID('Prpr'), cTID('Lefx'));
    ref.putEnumerated(cTID('Lyr '), cTID('Ordn'), cTID('Trgt'));
    d.putReference(cTID('null'), ref);
    d.putObject(cTID('T   '), cTID('Lefx'), fx);
    executeAction(cTID('setd'), d, DialogModes.NO);
};

// ------------------------------------------------------------------ patterns (read-only use of the user's presets)

C.patternNames = function () {
    var r = new ActionReference();
    r.putProperty(cTID('Prpr'), sTID('presetManager'));
    r.putEnumerated(cTID('capp'), cTID('Ordn'), cTID('Trgt'));
    var pm = executeActionGet(r).getList(sTID('presetManager'));
    for (var i = 0; i < pm.count; i++) {
        var o = pm.getObjectValue(i);
        var cls = t2s(pm.getObjectType(i));
        if (cls === 'PttR' || cls === 'pattern' || cls === 'Ptrn') {
            var names = o.getList(cTID('Nm  ')), out = [];
            for (var j = 0; j < names.count; j++) out.push(names.getString(j));
            return out;
        }
    }
    return [];
};

C.patternRef = function (name) {
    var p = new ActionDescriptor();
    p.putString(cTID('Nm  '), name);
    return p;
};

C.firstPattern = function () {
    var n = C.patternNames();
    if (!n.length) throw new Error('no pattern presets available (patterns are never created, to leave the preset library untouched)');
    return n[0];
};

// ------------------------------------------------------------------ adjustments

C.makeAdjustment = function (cls, params) {
    var d = new ActionDescriptor();
    var ref = new ActionReference();
    ref.putClass(cTID('AdjL'));
    d.putReference(cTID('null'), ref);
    var a = new ActionDescriptor();
    var t = new ActionDescriptor();
    if (cls === 'Lvls' || cls === 'Crvs' || cls === 'HStr' || cls === 'ChnM' || cls === 'SlcC' || cls === 'blackAndWhite' || cls === 'exposure') {
        t.putEnumerated(sTID('presetKind'), sTID('presetKindType'), sTID('presetKindDefault'));
    }
    // Brightness/Contrast: the mode must be chosen when the layer is made. Photoshop 27 makes
    // RGB 8/16-bit B/C layers in "Light" mode (brightnessModeLight: Exposure, Whites, Blacks,
    // Highlights, Shadows), where Brgh is ignored and stored as 0.
    if (cls === 'BrgC' && params && params.hasKey(sTID('brightnessMode'))) {
        t.putEnumerated(sTID('brightnessMode'), sTID('brightnessModeType'), params.getEnumerationValue(sTID('brightnessMode')));
    }
    a.putObject(cTID('Type'), C.key(cls), t);
    d.putObject(cTID('Usng'), cTID('AdjL'), a);
    executeAction(cTID('Mk  '), d, DialogModes.NO);
    if (params) {
        var s = new ActionDescriptor();
        var r = new ActionReference();
        r.putEnumerated(cTID('AdjL'), cTID('Ordn'), cTID('Trgt'));
        s.putReference(cTID('null'), r);
        s.putObject(cTID('T   '), C.key(cls), params);
        executeAction(cTID('setd'), s, DialogModes.NO);
        // Standing assertion: what Photoshop stored must be what was asked for.
        var bad = C.storedMismatches(params, C.readAdjustment(), cls);
        if (bad.length) throw new Error('ps-oracle: adjustment ' + cls + ' did not store what was asked: ' + bad.join('; '));
    }
    return app.activeDocument.activeLayer;
};

// The target adjustment layer's settings as Photoshop holds them.
C.readAdjustment = function () {
    var d = executeActionGet(C.target());
    if (!d.hasKey(sTID('adjustment'))) throw new Error('ps-oracle: the target layer has no adjustment to read back');
    var l = d.getList(sTID('adjustment'));
    if (l.getType(0) !== DescValueType.OBJECTTYPE) throw new Error('ps-oracle: the adjustment has no settings to read back');
    return l.getObjectValue(0);
};

// Keys a document may legitimately not store: brightnessMode exists only where Photoshop offers
// Light mode (RGB 8/16-bit); presetKind is normalised by Photoshop.
C.optionalKeys = { brightnessMode: true, presetKind: true };

C.num = function (d, k) {
    var t = d.getType(k);
    if (t === DescValueType.INTEGERTYPE) return d.getInteger(k);
    if (t === DescValueType.DOUBLETYPE) return d.getDouble(k);
    if (t === DescValueType.UNITDOUBLE) return d.getUnitDoubleValue(k);
    if (t === DescValueType.LARGEINTEGERTYPE) return d.getLargeInteger(k);
    return null;
};

C.isNumType = function (t) { return t === DescValueType.INTEGERTYPE || t === DescValueType.DOUBLETYPE || t === DescValueType.UNITDOUBLE || t === DescValueType.LARGEINTEGERTYPE; };

C.sameNumber = function (a, b) { return a !== null && b !== null && Math.abs(a - b) <= 1e-3 * Math.max(1, Math.abs(a)); };

// Every value in `want` (recursively; references skipped) must be in `got`, equal.
C.storedMismatches = function (want, got, path) {
    var out = [];
    for (var i = 0; i < want.count; i++) {
        var k = want.getKey(i), t = want.getType(k), name = path + '.' + t2s(k);
        if (t === DescValueType.REFERENCETYPE) continue;
        if (!got.hasKey(k)) { if (!C.optionalKeys[t2s(k)]) out.push(name + ' missing'); continue; }
        var gt = got.getType(k);
        if (C.isNumType(t)) {
            var a = C.num(want, k), b = C.isNumType(gt) ? C.num(got, k) : null;
            if (!C.sameNumber(a, b)) out.push(name + ' ' + a + ' stored as ' + b);
        } else if (t === DescValueType.BOOLEANTYPE) {
            if (gt !== t || want.getBoolean(k) !== got.getBoolean(k)) out.push(name + ' ' + want.getBoolean(k) + ' stored differently');
        } else if (t === DescValueType.ENUMERATEDTYPE) {
            if (gt !== t || want.getEnumerationValue(k) !== got.getEnumerationValue(k)) {
                if (!(C.optionalKeys[t2s(k)] && t2s(k) === 'presetKind')) out.push(name + ' ' + t2s(want.getEnumerationValue(k)) + ' stored as ' + (gt === t ? t2s(got.getEnumerationValue(k)) : '?'));
            }
        } else if (t === DescValueType.STRINGTYPE) {
            if (gt !== t || want.getString(k) !== got.getString(k)) out.push(name + ' "' + want.getString(k) + '" stored differently');
        } else if (t === DescValueType.OBJECTTYPE) {
            if (gt !== t) out.push(name + ' not an object'); else out = out.concat(C.storedMismatches(want.getObjectValue(k), got.getObjectValue(k), name));
        } else if (t === DescValueType.LISTTYPE) {
            if (gt !== t) { out.push(name + ' not a list'); continue; }
            var wl = want.getList(k), gl = got.getList(k);
            if (wl.count !== gl.count) { out.push(name + ' has ' + gl.count + ' entries, asked ' + wl.count); continue; }
            for (var j = 0; j < wl.count; j++) {
                var wt = wl.getType(j);
                if (wt === DescValueType.OBJECTTYPE && gl.getType(j) === wt) out = out.concat(C.storedMismatches(wl.getObjectValue(j), gl.getObjectValue(j), name + '[' + j + ']'));
                else if (wt === DescValueType.INTEGERTYPE && gl.getType(j) === wt && wl.getInteger(j) !== gl.getInteger(j)) out.push(name + '[' + j + '] ' + wl.getInteger(j) + ' stored as ' + gl.getInteger(j));
            }
        }
    }
    return out;
};

// Sets the target adjustment layer's settings (no read-back).
C.setAdjustment = function (cls, params) {
    var s = new ActionDescriptor(), r = new ActionReference();
    r.putEnumerated(cTID('AdjL'), cTID('Ordn'), cTID('Trgt'));
    s.putReference(cTID('null'), r);
    s.putObject(cTID('T   '), C.key(cls), params);
    executeAction(cTID('setd'), s, DialogModes.NO);
};

// A Color Lookup layer loading a 3DLUT file by name and format: Photoshop reads the file itself
// and builds its own table data and profile. The file must be inside the allowed roots (the
// bundled presets are read from read-only copies in <data root>/ps-presets). Returns the layer's
// settings as Photoshop holds them.
C.lutFormats = { cube: 'LUTFormatCUBE', '3dl': 'LUTFormat3DL', look: 'LUTFormatLOOK' };
C.colorLookupFile = function (path) {
    PSO.checkPath(path);
    var f = new File(path);
    if (!f.exists) throw new Error('ps-oracle: no LUT file ' + path);
    var ext = decodeURI(f.name).replace(/^.*\./, '').toLowerCase();
    if (!C.lutFormats[ext]) throw new Error('ps-oracle: unknown LUT format ' + ext);
    var d = new ActionDescriptor();
    d.putEnumerated(sTID('lookupType'), sTID('colorLookupType'), sTID('3DLUT'));
    d.putString(cTID('Nm  '), decodeURI(f.name));
    d.putBoolean(sTID('dither'), false);
    d.putEnumerated(sTID('LUTFormat'), sTID('LUTFormatType'), sTID(C.lutFormats[ext]));
    d.putString(sTID('LUT3DFileName'), f.fsName);
    C.makeAdjustment('colorLookup', null);
    C.setAdjustment('colorLookup', d);
    return C.readAdjustment();
};

// A descriptor's key names with their types and, for scalars, their values; raw data only as a
// byte count (never its contents).
C.keyNames = function (d) {
    var out = [];
    for (var i = 0; i < d.count; i++) {
        var k = d.getKey(i), t = d.getType(k), e = t2s(k) + ' [' + String(t).replace('DescValueType.', '') + ']';
        if (t === DescValueType.RAWTYPE) e += ' ' + d.getData(k).length + ' bytes';
        else if (t === DescValueType.ENUMERATEDTYPE) e += ' ' + t2s(d.getEnumerationValue(k));
        else if (t === DescValueType.BOOLEANTYPE) e += ' ' + d.getBoolean(k);
        else if (t === DescValueType.STRINGTYPE) e += ' "' + d.getString(k) + '"';
        else if (C.isNumType(t)) e += ' ' + C.num(d, k);
        out.push(e);
    }
    return out;
};

// Brightness/Contrast settings. mode: 'brightnessModeModern' (the classic modern slider pair; the
// default here) or 'brightnessModeLegacy' (with useLegacy). Light mode is never asked for.
C.bcSettings = function (b, c, mode) {
    mode = mode || 'brightnessModeModern';
    var d = new ActionDescriptor();
    d.putEnumerated(sTID('brightnessMode'), sTID('brightnessModeType'), sTID(mode));
    d.putInteger(cTID('Brgh'), b);
    d.putInteger(cTID('Cntr'), c);
    d.putBoolean(sTID('useLegacy'), mode === 'brightnessModeLegacy');
    return d;
};

C.compositeChannelRef = function () {
    var cr = new ActionReference();
    cr.putEnumerated(cTID('Chnl'), cTID('Chnl'), cTID('Cmps'));
    return cr;
};

C.ints = function (a) { var l = new ActionList(); for (var i = 0; i < a.length; i++) l.putInteger(a[i]); return l; };

C.adjust = {
    levels: function () {
        var lv = new ActionDescriptor();
        lv.putEnumerated(sTID('presetKind'), sTID('presetKindType'), sTID('presetKindCustom'));
        var al = new ActionList(), a = new ActionDescriptor();
        a.putReference(cTID('Chnl'), C.compositeChannelRef());
        a.putList(cTID('Inpt'), C.ints([20, 225]));
        a.putDouble(cTID('Gmm '), 1.35);
        a.putList(cTID('Otpt'), C.ints([12, 240]));
        al.putObject(cTID('LvlA'), a);
        lv.putList(cTID('Adjs'), al);
        return C.makeAdjustment('Lvls', lv);
    },
    curves: function () {
        var cv = new ActionDescriptor();
        cv.putEnumerated(sTID('presetKind'), sTID('presetKindType'), sTID('presetKindCustom'));
        var al = new ActionList(), a = new ActionDescriptor();
        a.putReference(cTID('Chnl'), C.compositeChannelRef());
        var pts = new ActionList(), xy = [[0, 0], [64, 38], [190, 220], [255, 255]];
        for (var i = 0; i < xy.length; i++) { var p = new ActionDescriptor(); p.putDouble(cTID('Hrzn'), xy[i][0]); p.putDouble(cTID('Vrtc'), xy[i][1]); pts.putObject(cTID('Pnt '), p); }
        a.putList(cTID('Crv '), pts);
        al.putObject(cTID('CrvA'), a);
        cv.putList(cTID('Adjs'), al);
        return C.makeAdjustment('Crvs', cv);
    },
    // Before 2026-10-13 this asked for Brgh 25 without a mode: Photoshop 27 made RGB 8/16-bit
    // layers in Light mode and stored Brgh 0 (ps-corpus adj-brightnessContrast, adj-stack-rgb-16).
    brightnessContrast: function () { return C.makeAdjustment('BrgC', C.bcSettings(25, 35)); },
    hueSaturation: function () {
        var h = new ActionDescriptor();
        h.putEnumerated(sTID('presetKind'), sTID('presetKindType'), sTID('presetKindCustom'));
        h.putBoolean(cTID('Clrz'), false);
        var l = new ActionList(), a = new ActionDescriptor();
        a.putInteger(cTID('H   '), 35);
        a.putInteger(cTID('Strt'), 25);
        a.putInteger(cTID('Lght'), -10);
        l.putObject(cTID('Hst2'), a);
        h.putList(cTID('Adjs'), l);
        return C.makeAdjustment('HStr', h);
    },
    colorBalance: function () {
        var b = new ActionDescriptor();
        b.putList(cTID('ShdL'), C.ints([10, -5, 0]));
        b.putList(cTID('MdtL'), C.ints([25, 0, -20]));
        b.putList(cTID('HghL'), C.ints([0, 10, 5]));
        b.putBoolean(cTID('PrsL'), true);
        return C.makeAdjustment('ClrB', b);
    },
    blackAndWhite: function () {
        var b = new ActionDescriptor();
        b.putEnumerated(sTID('presetKind'), sTID('presetKindType'), sTID('presetKindCustom'));
        b.putInteger(cTID('Rd  '), 40); b.putInteger(cTID('Yllw'), 60); b.putInteger(cTID('Grn '), 40);
        b.putInteger(cTID('Cyn '), 60); b.putInteger(cTID('Bl  '), 20); b.putInteger(cTID('Mgnt'), 80);
        b.putBoolean(sTID('useTint'), false);
        return C.makeAdjustment('blackAndWhite', b);
    },
    channelMixer: function () {
        var m = new ActionDescriptor();
        m.putEnumerated(sTID('presetKind'), sTID('presetKindType'), sTID('presetKindCustom'));
        m.putBoolean(cTID('Mnch'), false);
        var r = new ActionDescriptor(); C.unitP(r, 'Rd  ', 80); C.unitP(r, 'Grn ', 30); C.unitP(r, 'Bl  ', -10);
        m.putObject(cTID('Rd  '), cTID('ChMx'), r);
        var g = new ActionDescriptor(); C.unitP(g, 'Rd  ', 0); C.unitP(g, 'Grn ', 100); C.unitP(g, 'Bl  ', 0);
        m.putObject(cTID('Grn '), cTID('ChMx'), g);
        var b = new ActionDescriptor(); C.unitP(b, 'Rd  ', 20); C.unitP(b, 'Grn ', 0); C.unitP(b, 'Bl  ', 80);
        m.putObject(cTID('Bl  '), cTID('ChMx'), b);
        return C.makeAdjustment('ChnM', m);
    },
    exposure: function () {
        var e = new ActionDescriptor();
        e.putEnumerated(sTID('presetKind'), sTID('presetKindType'), sTID('presetKindCustom'));
        e.putDouble(sTID('exposure'), 0.6);
        e.putDouble(cTID('Ofst'), -0.03);
        e.putDouble(sTID('gammaCorrection'), 1.15);
        return C.makeAdjustment('exposure', e);
    },
    gradientMap: function () {
        var g = new ActionDescriptor();
        g.putObject(cTID('Grad'), cTID('Grdn'), C.gradient([[0, 30, 0, 80], [2048, 230, 90, 40], [4096, 255, 250, 200]]));
        g.putBoolean(cTID('Rvrs'), false);
        g.putBoolean(cTID('Dthr'), false);
        return C.makeAdjustment('GdMp', g);
    },
    invert: function () { return C.makeAdjustment('Invr', null); },
    photoFilter: function () {
        var p = new ActionDescriptor();
        var lab = new ActionDescriptor();
        lab.putDouble(cTID('Lmnc'), 67); lab.putDouble(cTID('A   '), 32); lab.putDouble(cTID('B   '), 66);
        p.putObject(cTID('Clr '), cTID('LbCl'), lab);
        p.putInteger(cTID('Dnst'), 45);
        p.putBoolean(cTID('PrsL'), true);
        return C.makeAdjustment('photoFilter', p);
    },
    posterize: function () {
        var p = new ActionDescriptor();
        p.putInteger(cTID('Lvls'), 5);
        return C.makeAdjustment('Pstr', p);
    },
    selectiveColor: function () {
        var s = new ActionDescriptor();
        s.putEnumerated(sTID('presetKind'), sTID('presetKindType'), sTID('presetKindCustom'));
        var l = new ActionList();
        var groups = [['Rds ', 20, -10, 0, 5], ['Grns', -15, 10, 25, 0], ['Ntrl', 0, 0, -10, 8]];
        for (var i = 0; i < groups.length; i++) {
            var c = new ActionDescriptor();
            c.putEnumerated(cTID('Clrs'), cTID('Clrs'), cTID(groups[i][0]));
            C.unitP(c, 'Cyn ', groups[i][1]); C.unitP(c, 'Mgnt', groups[i][2]); C.unitP(c, 'Ylw ', groups[i][3]); C.unitP(c, 'Blck', groups[i][4]);
            l.putObject(cTID('ClrC'), c);
        }
        s.putList(cTID('ClrC'), l);
        s.putEnumerated(cTID('Mthd'), cTID('CrcM'), cTID('Absl'));
        return C.makeAdjustment('SlcC', s);
    },
    threshold: function () {
        var t = new ActionDescriptor();
        t.putInteger(cTID('Lvl '), 110);
        return C.makeAdjustment('Thrs', t);
    },
    vibrance: function () {
        var v = new ActionDescriptor();
        v.putInteger(sTID('vibrance'), 45);
        v.putInteger(cTID('Strt'), 15);
        return C.makeAdjustment('vibrance', v);
    },
    colorLookup: function () {
        // Without a LUT: Photoshop refuses the LUT3DFileData form of the descriptor from a script.
        return C.makeAdjustment('colorLookup', null);
    },
    colorLookupWithData: function () {
        // A 2×2×2 .cube LUT built here (no file, no preset): a warm grade.
        var cube = 'TITLE "pso warm"\nLUT_3D_SIZE 2\n0.05 0.0 0.0\n1.0 0.1 0.0\n0.0 0.85 0.05\n1.0 1.0 0.1\n0.05 0.05 0.75\n0.95 0.1 0.8\n0.0 0.85 0.85\n1.0 0.97 0.9\n';
        var c = new ActionDescriptor();
        c.putEnumerated(sTID('lookupType'), sTID('colorLookupType'), sTID('3DLUT'));
        c.putString(cTID('Nm  '), 'pso-warm.cube');
        c.putEnumerated(sTID('dither'), sTID('dither'), cTID('None'));
        c.putEnumerated(sTID('LUTFormat'), sTID('LUTFormatType'), sTID('LUTFormatCUBE'));
        c.putData(sTID('LUT3DFileData'), cube);
        c.putString(sTID('LUT3DFileName'), 'pso-warm.cube');
        return C.makeAdjustment('colorLookup', c);
    }
};

C.adjustmentNames = ['levels', 'curves', 'brightnessContrast', 'hueSaturation', 'colorBalance', 'blackAndWhite', 'channelMixer', 'exposure',
                     'gradientMap', 'invert', 'photoFilter', 'posterize', 'selectiveColor', 'threshold', 'vibrance', 'colorLookup'];

// ------------------------------------------------------------------ text

C.font = 'ArialMT';

C.pointText = function (name, contents, x, y, size, color) {
    var L = C.layer(name);
    L.kind = LayerKind.TEXT;
    var t = L.textItem;
    t.contents = contents;
    t.font = C.font;
    t.size = UnitValue(size || 18, 'pt');
    var c = new SolidColor();
    c.rgb.red = (color || [20, 20, 20])[0]; c.rgb.green = (color || [20, 20, 20])[1]; c.rgb.blue = (color || [20, 20, 20])[2];
    t.color = c;
    t.antiAliasMethod = AntiAlias.SHARP;
    t.position = [UnitValue(x, 'px'), UnitValue(y, 'px')];
    L.name = name;
    return L;
};

C.paragraphText = function (name, contents, box, size) {
    var L = C.layer(name);
    L.kind = LayerKind.TEXT;
    var t = L.textItem;
    t.kind = TextType.PARAGRAPHTEXT;
    t.contents = contents;
    t.font = C.font;
    t.size = UnitValue(size || 10, 'pt');
    t.justification = Justification.CENTER;
    t.position = [UnitValue(box[1], 'px'), UnitValue(box[0], 'px')];
    t.width = UnitValue(box[3] - box[1], 'px');
    t.height = UnitValue(box[2] - box[0], 'px');
    t.antiAliasMethod = AntiAlias.SHARP;
    L.name = name;
    return L;
};

// Several styled runs in one layer (Action Manager: per-run font size and colour).
C.styledText = function (name, runs, x, y) {
    var all = '';
    for (var i = 0; i < runs.length; i++) all += runs[i][0];
    var d = new ActionDescriptor();
    var r = new ActionReference();
    r.putClass(cTID('TxLr'));
    d.putReference(cTID('null'), r);
    var t = new ActionDescriptor();
    t.putString(cTID('Txt '), all);
    var pt = new ActionDescriptor();
    pt.putUnitDouble(cTID('Hrzn'), cTID('#Pxl'), x);
    pt.putUnitDouble(cTID('Vrtc'), cTID('#Pxl'), y);
    t.putObject(cTID('TxtC'), cTID('Pnt '), pt);
    var rl = new ActionList(), from = 0;
    for (var k = 0; k < runs.length; k++) {
        var rr = new ActionDescriptor();
        rr.putInteger(cTID('From'), from);
        rr.putInteger(cTID('T   '), from + runs[k][0].length);
        from += runs[k][0].length;
        var st = new ActionDescriptor();
        st.putString(sTID('fontPostScriptName'), runs[k][3] || C.font);
        st.putUnitDouble(cTID('Sz  '), cTID('#Pnt'), runs[k][1]);
        st.putObject(cTID('Clr '), cTID('RGBC'), C.rgb(runs[k][2]));
        rr.putObject(cTID('TxtS'), cTID('TxtS'), st);
        rl.putObject(cTID('Txtt'), rr);
    }
    t.putList(cTID('Txtt'), rl);
    d.putObject(cTID('Usng'), cTID('TxLr'), t);
    executeAction(cTID('Mk  '), d, DialogModes.NO);
    var L = app.activeDocument.activeLayer;
    L.name = name;
    return L;
};

// ------------------------------------------------------------------ shapes

C.box = function (t, l, b, r, radius) {
    var s = new ActionDescriptor();
    C.unitX(s, 'Top ', t); C.unitX(s, 'Left', l); C.unitX(s, 'Btom', b); C.unitX(s, 'Rght', r);
    if (radius) C.unitX(s, 'Rds ', radius);
    return s;
};

C.strokeStyle = function (width, color, align) {
    var ss = new ActionDescriptor();
    ss.putInteger(sTID('strokeStyleVersion'), 2);
    ss.putBoolean(sTID('strokeEnabled'), true);
    ss.putBoolean(sTID('fillEnabled'), true);
    ss.putUnitDouble(sTID('strokeStyleLineWidth'), cTID('#Pxl'), width);
    ss.putUnitDouble(sTID('strokeStyleLineDashOffset'), cTID('#Pnt'), 0);
    ss.putDouble(sTID('strokeStyleMiterLimit'), 100);
    ss.putEnumerated(sTID('strokeStyleLineCapType'), sTID('strokeStyleLineCapType'), sTID('strokeStyleButtCap'));
    ss.putEnumerated(sTID('strokeStyleLineJoinType'), sTID('strokeStyleLineJoinType'), sTID('strokeStyleMiterJoin'));
    ss.putEnumerated(sTID('strokeStyleLineAlignment'), sTID('strokeStyleLineAlignment'), sTID(align || 'strokeStyleAlignCenter'));
    ss.putBoolean(sTID('strokeStyleScaleLock'), false);
    ss.putBoolean(sTID('strokeStyleStrokeAdjust'), false);
    ss.putList(sTID('strokeStyleLineDashSet'), new ActionList());
    ss.putEnumerated(sTID('strokeStyleBlendMode'), cTID('BlnM'), cTID('Nrml'));
    C.unitP(ss, 'Opct', 100);
    ss.putUnitDouble(sTID('strokeStyleOpacity'), cTID('#Prc'), 100);
    var sc = new ActionDescriptor();
    sc.putObject(cTID('Clr '), cTID('RGBC'), C.rgb(color));
    ss.putObject(sTID('strokeStyleContent'), sTID('solidColorLayer'), sc);
    ss.putDouble(sTID('strokeStyleResolution'), 72);
    return ss;
};

C.shape = function (name, cls, box, color, stroke, fillType) {
    var t;
    var key = 'solidColorLayer';
    if (fillType === 'gradient') { key = 'gradientLayer'; t = C.gradientSettings([[0, 255, 60, 0], [4096, 255, 230, 0]], null, 90); }
    else { t = new ActionDescriptor(); t.putObject(cTID('Clr '), cTID('RGBC'), C.rgb(color)); }
    var L = C.makeContentLayer(key, t, { cls: cls, desc: box }, stroke || null);
    L.name = name;
    return L;
};

// ------------------------------------------------------------------ smart objects and filters

C.toSmartObject = function () {
    executeAction(sTID('newPlacedLayer'), new ActionDescriptor(), DialogModes.NO);
    return app.activeDocument.activeLayer;
};

C.filter = {
    gaussianBlur: function (r) { var d = new ActionDescriptor(); C.unitX(d, 'Rds ', r || 2.5); executeAction(cTID('GsnB'), d, DialogModes.NO); },
    unsharpMask: function () { var d = new ActionDescriptor(); C.unitP(d, 'Amnt', 120); C.unitX(d, 'Rds ', 1.5); d.putInteger(cTID('Thsh'), 0); executeAction(cTID('UnsM'), d, DialogModes.NO); },
    motionBlur: function () { var d = new ActionDescriptor(); d.putInteger(cTID('Angl'), 30); C.unitX(d, 'Dstn', 8); executeAction(cTID('MtnB'), d, DialogModes.NO); },
    minimum: function () { var d = new ActionDescriptor(); C.unitX(d, 'Rds ', 2); executeAction(sTID('minimum'), d, DialogModes.NO); },
    emboss: function () { var d = new ActionDescriptor(); d.putInteger(cTID('Angl'), 135); d.putInteger(cTID('Hght'), 2); d.putInteger(cTID('Amnt'), 100); executeAction(cTID('Embs'), d, DialogModes.NO); }
};

C.transform = function (sx, sy, angle) {
    var d = new ActionDescriptor();
    d.putReference(cTID('null'), C.target());
    d.putEnumerated(cTID('FTcs'), cTID('QCSt'), cTID('Qcsa'));
    C.unitP(d, 'Wdth', sx);
    C.unitP(d, 'Hght', sy);
    d.putUnitDouble(cTID('Angl'), cTID('#Ang'), angle || 0);
    d.putEnumerated(cTID('Intr'), cTID('Intp'), cTID('Bcbc'));
    executeAction(cTID('Trnf'), d, DialogModes.NO);
};

// ------------------------------------------------------------------ extra channels

C.alphaChannelFromSelection = function (name) {
    var doc = app.activeDocument;
    var ch = doc.channels.add();
    ch.name = name;
    ch.kind = ChannelType.SELECTEDAREA;
    doc.selection.store(ch, SelectionType.REPLACE);
    // channels.add() targets the new channel: target the composite again.
    var comps = [];
    for (var i = 0; i < doc.componentChannels.length; i++) comps.push(doc.componentChannels[i]);
    doc.activeChannels = comps;
    return ch;
};

C.spotChannel = function (name, color, solidity) {
    var d = new ActionDescriptor();
    var s = new ActionDescriptor();
    s.putString(cTID('Nm  '), name);
    s.putObject(cTID('Clr '), cTID('RGBC'), C.rgb(color));
    s.putInteger(cTID('Opct'), solidity);
    d.putObject(cTID('Nw  '), cTID('SCch'), s);
    executeAction(cTID('Mk  '), d, DialogModes.NO);
    var doc = app.activeDocument;
    var comps = [];
    for (var i = 0; i < doc.componentChannels.length; i++) comps.push(doc.componentChannels[i]);
    doc.activeChannels = comps;
};

// ------------------------------------------------------------------ mode conversions

C.flatten = function () { app.activeDocument.flatten(); };

C.toIndexed = function (colors, transparency) {
    var o = new IndexedConversionOptions();
    o.palette = Palette.LOCALSELECTIVE;
    o.colors = colors || 64;
    o.dither = Dither.NONE;
    o.forced = ForcedColors.NONE;
    o.matte = MatteType.WHITE;
    o.transparency = !!transparency;
    o.preserveExactColors = false;
    app.activeDocument.changeMode(ChangeMode.INDEXEDCOLOR, o);
};

C.toBitmap = function () {
    var o = new BitmapConversionOptions();
    o.method = BitmapConversionType.HALFTHRESHOLD;
    o.resolution = 72;
    app.activeDocument.changeMode(ChangeMode.BITMAP, o);
};

C.toDuotone = function (inks) {
    // Image > Mode > Duotone with explicit inks (curves left linear).
    var d = new ActionDescriptor();
    var dt = new ActionDescriptor();
    var names = ['monotone', 'duotone', 'tritone', 'quadtone'];
    dt.putEnumerated(sTID('duotoneMode'), sTID('duotoneMode'), sTID(names[inks.length - 1]));
    var keys = ['duotoneInkOne', 'duotoneInkTwo', 'duotoneInkThree', 'duotoneInkFour'];
    for (var i = 0; i < inks.length; i++) {
        var ink = new ActionDescriptor();
        ink.putString(cTID('Nm  '), inks[i][0]);
        ink.putObject(cTID('Clr '), cTID('RGBC'), C.rgb(inks[i][1]));
        var curve = new ActionList();
        var pts = [0, -1, -1, -1, -1, -1, -1, -1, -1, -1, -1, -1, 1000];
        for (var k = 0; k < pts.length; k++) curve.putInteger(pts[k]);
        ink.putList(sTID('duotoneCurve'), curve);
        dt.putObject(sTID(keys[i]), sTID('duotoneInk'), ink);
    }
    d.putObject(cTID('T   '), sTID('duotoneMode'), dt);
    try { executeAction(cTID('CnvM'), d, DialogModes.NO); } catch (e) {
        throw new Error('Image > Mode > Duotone is not scriptable here: Photoshop refused every Convert Mode descriptor tried (31 shapes: mode enum, ink list, RGB/CMYK inks, transfer curves) with "' + PSO.errorText(e).replace(/\n/g, ' ') + '"');
    }
};

// ------------------------------------------------------------------ common scenes

// Base + a blend source in `mode` (+ optional opacity/fill).
C.blendScene = function (name, mode, bits, docMode) {
    var doc = C.newDoc(name, docMode || 'RGB', bits || 8);
    C.base();
    C.blendSource('Blend');
    C.set({ mode: mode });
    return doc;
};

C.blendModes = ['normal', 'dissolve', 'darken', 'multiply', 'colorBurn', 'linearBurn', 'darkerColor', 'lighten', 'screen', 'colorDodge',
                'linearDodge', 'lighterColor', 'overlay', 'softLight', 'hardLight', 'vividLight', 'linearLight', 'pinLight', 'hardMix',
                'difference', 'exclusion', 'blendSubtraction', 'blendDivide', 'hue', 'saturation', 'color', 'luminosity'];

// 27 horizontal bands, one per blend mode, each its own layer over the shared base.
C.blendBands = function (name, docMode, bits, notes) {
    var n = C.blendModes.length, bandH = 4;
    var doc = C.newDoc(name, docMode, bits, { width: 108, height: n * bandH });
    C.base();
    var src = C.blendSource('Source');
    for (var i = 0; i < n; i++) {
        doc.activeLayer = src;
        var dup = src.duplicate();
        dup.name = C.blendModes[i];
        doc.activeLayer = dup;
        C.selRect(0, 0, i * bandH, 108);
        if (i > 0) C.fill([0, 0, 0], 100, 'Clar');
        C.selRect((i + 1) * bandH, 0, n * bandH, 108);
        if (i < n - 1) C.fill([0, 0, 0], 100, 'Clar');
        C.deselect();
        try { C.set({ mode: C.blendModes[i] }); } catch (e) { notes.push(C.blendModes[i] + ' unavailable (' + C.shortError(e) + ')'); }
    }
    src.remove();
    return doc;
};

