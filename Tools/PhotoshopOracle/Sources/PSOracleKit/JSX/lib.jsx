// ps-oracle ExtendScript library (ES3). The Swift runner prepends `var ARGS = {...};` and this file
// to every command script, and sends the result to Photoshop with `do javascript`.
//
// Rules every script follows:
//   * PSO.main(fn) runs a command with app.displayDialogs = NO, restores the previous value, catches
//     every error and returns JSON (the script's last expression is what osascript prints).
//   * Only paths under ARGS.allowedRoots are opened or written (PSO.checkPath).
//   * Every document a script opens or creates is closed with DONOTSAVECHANGES before it returns.
//   * No preference, colour setting or preset is changed: sizes and coordinates always carry explicit
//     pixel units, so the ruler-unit preference never matters.

function sTID(s) { return stringIDToTypeID(s); }
function cTID(c) { return charIDToTypeID(c); }
function t2s(t) {
    try { var s = typeIDToStringID(t); if (s) return s; } catch (e) {}
    try { var c = typeIDToCharID(t); if (c) return c; } catch (e2) {}
    return String(t);
}

var PSO = {};

// ---------------------------------------------------------------- JSON (ExtendScript has none)

PSO.quote = function (s) {
    s = String(s);
    var r = '"';
    for (var i = 0; i < s.length; i++) {
        var ch = s.charAt(i), code = s.charCodeAt(i);
        if (ch === '"') r += '\\"';
        else if (ch === '\\') r += '\\\\';
        else if (code < 0x20 || code > 0x7e) {
            var h = code.toString(16);
            while (h.length < 4) h = '0' + h;
            r += '\\u' + h;
        } else r += ch;
    }
    return r + '"';
};

PSO.json = function (v) {
    if (v === null || v === undefined) return 'null';
    var t = typeof v;
    if (t === 'number') return isFinite(v) ? String(v) : 'null';
    if (t === 'boolean') return v ? 'true' : 'false';
    if (t === 'string') return PSO.quote(v);
    if (v instanceof Array) {
        var a = [];
        for (var i = 0; i < v.length; i++) a.push(PSO.json(v[i]));
        return '[' + a.join(',') + ']';
    }
    if (t === 'object') {
        var o = [];
        for (var k in v) { if (v.hasOwnProperty(k) && typeof v[k] !== 'function') o.push(PSO.quote(k) + ':' + PSO.json(v[k])); }
        return '{' + o.join(',') + '}';
    }
    return PSO.quote(String(v));
};

PSO.errorText = function (e) {
    if (e === null || e === undefined) return 'unknown error';
    var t = (e.message !== undefined) ? String(e.message) : String(e);
    return t;
};

PSO.errorObject = function (e) {
    var o = { ok: false, error: PSO.errorText(e) };
    try { if (e.number !== undefined) o.errorNumber = e.number; } catch (x) {}
    try { if (e.line !== undefined) o.errorLine = e.line; } catch (x2) {}
    return o;
};

// Runs a command: dialogs off, every error caught, JSON out.
PSO.main = function (fn) {
    var saved = null;
    try { saved = app.displayDialogs; } catch (e) {}
    app.displayDialogs = DialogModes.NO;
    var result;
    try { result = fn(); } catch (e2) { result = PSO.errorObject(e2); }
    try { if (saved !== null) app.displayDialogs = saved; } catch (e3) {}
    return PSO.json(result);
};

// ---------------------------------------------------------------- paths and documents

PSO.checkPath = function (p) {
    var roots = (ARGS && ARGS.allowedRoots) ? ARGS.allowedRoots : [];
    for (var i = 0; i < roots.length; i++) {
        if (String(p).indexOf(roots[i]) === 0 && String(p).indexOf('..') < 0) return;
    }
    throw new Error('ps-oracle refuses a path outside its allowed roots: ' + p);
};

PSO.open = function (path) {
    PSO.checkPath(path);
    // Every open starts from a Photoshop with no documents open.
    if (app.documents.length !== 0) throw new Error('ps-oracle: documents open (' + app.documents.length + ') before opening ' + path);
    var f = new File(path);
    if (!f.exists) throw new Error('no such file: ' + path);
    return app.open(f);
};

PSO.close = function (doc) {
    if (!doc) return;
    try { doc.close(SaveOptions.DONOTSAVECHANGES); } catch (e) {}
};

PSO.activeDocDesc = function () {
    var r = new ActionReference();
    r.putEnumerated(cTID('Dcmn'), cTID('Ordn'), cTID('Trgt'));
    return executeActionGet(r);
};

PSO.modeName = function (m) {
    var s = String(m).replace('DocumentMode.', '');
    var map = { RGB: 'RGB', CMYK: 'CMYK', LAB: 'Lab', GRAYSCALE: 'Grayscale', BITMAP: 'Bitmap', INDEXEDCOLOR: 'Indexed', DUOTONE: 'Duotone', MULTICHANNEL: 'Multichannel' };
    return map[s] || s;
};

PSO.bits = function (b) {
    var s = String(b);
    if (s.indexOf('ONE') >= 0) return 1;
    if (s.indexOf('EIGHT') >= 0) return 8;
    if (s.indexOf('SIXTEEN') >= 0) return 16;
    if (s.indexOf('THIRTYTWO') >= 0) return 32;
    return null;
};

// ---------------------------------------------------------------- descriptor getters

PSO.has = function (d, k) { try { return d.hasKey(sTID(k)); } catch (e) { return false; } };
PSO.getInt = function (d, k) { try { return d.hasKey(sTID(k)) ? d.getInteger(sTID(k)) : null; } catch (e) { return null; } };
PSO.getNum = function (d, k) {
    try {
        if (!d.hasKey(sTID(k))) return null;
        var ty = d.getType(sTID(k));
        if (ty === DescValueType.UNITDOUBLE) return d.getUnitDoubleValue(sTID(k));
        if (ty === DescValueType.INTEGERTYPE) return d.getInteger(sTID(k));
        return d.getDouble(sTID(k));
    } catch (e) { return null; }
};
PSO.getBool = function (d, k) { try { return d.hasKey(sTID(k)) ? d.getBoolean(sTID(k)) : null; } catch (e) { return null; } };
PSO.getStr = function (d, k) { try { return d.hasKey(sTID(k)) ? d.getString(sTID(k)) : null; } catch (e) { return null; } };
PSO.getEnum = function (d, k) { try { return d.hasKey(sTID(k)) ? t2s(d.getEnumerationValue(sTID(k))) : null; } catch (e) { return null; } };
PSO.getObj = function (d, k) { try { return (d.hasKey(sTID(k)) && d.getType(sTID(k)) === DescValueType.OBJECTTYPE) ? d.getObjectValue(sTID(k)) : null; } catch (e) { return null; } };
PSO.getList = function (d, k) { try { return (d.hasKey(sTID(k)) && d.getType(sTID(k)) === DescValueType.LISTTYPE) ? d.getList(sTID(k)) : null; } catch (e) { return null; } };

// ---------------------------------------------------------------- layer and document facts

PSO.layerKinds = { 0: 'any', 1: 'pixel', 2: 'adjustment', 3: 'text', 4: 'shape', 5: 'smartObject', 6: 'video', 7: 'group', 8: '3d',
                   9: 'gradientFill', 10: 'patternFill', 11: 'solidFill', 12: 'pixel', 13: 'groupEnd' };

PSO.effectsOf = function (fx) {
    var out = [];
    for (var i = 0; i < fx.count; i++) {
        var k = fx.getKey(i), ty = fx.getType(k), key = t2s(k);
        if (ty === DescValueType.OBJECTTYPE) {
            var e = fx.getObjectValue(k);
            if (PSO.has(e, 'enabled')) out.push({ type: key, enabled: e.getBoolean(sTID('enabled')), present: PSO.getBool(e, 'present') });
        } else if (ty === DescValueType.LISTTYPE) {
            var l = fx.getList(k);
            for (var j = 0; j < l.count; j++) {
                if (l.getType(j) !== DescValueType.OBJECTTYPE) continue;
                var m = l.getObjectValue(j);
                out.push({ type: key, enabled: PSO.getBool(m, 'enabled'), present: PSO.getBool(m, 'present') });
            }
        }
    }
    return out;
};

// The target layer's descriptor.
PSO.layerInfoDesc = function () {
    var r = new ActionReference();
    r.putEnumerated(cTID('Lyr '), cTID('Ordn'), cTID('Trgt'));
    return executeActionGet(r);
};

PSO.layerInfo = function (i) {
    var r = new ActionReference();
    r.putIndex(sTID('layer'), i);
    var d = executeActionGet(r);
    var o = {};
    o.index = i;
    o.id = PSO.getInt(d, 'layerID');
    o.name = PSO.getStr(d, 'name');
    o.layerKind = PSO.getInt(d, 'layerKind');
    o.kind = PSO.layerKinds[o.layerKind] || ('kind' + o.layerKind);
    o.section = PSO.getEnum(d, 'layerSection');
    o.background = PSO.getBool(d, 'background');
    o.visible = PSO.getBool(d, 'visible');
    o.blendMode = PSO.getEnum(d, 'mode');
    o.opacity = PSO.getInt(d, 'opacity');
    o.fillOpacity = PSO.getInt(d, 'fillOpacity');
    o.clipped = PSO.getBool(d, 'group');
    o.parentLayerID = PSO.getInt(d, 'parentLayerID');
    var b = PSO.getObj(d, 'bounds');
    if (b) o.bounds = [PSO.getNum(b, 'left'), PSO.getNum(b, 'top'), PSO.getNum(b, 'right'), PSO.getNum(b, 'bottom')];
    o.userMask = PSO.getBool(d, 'hasUserMask') ? { enabled: PSO.getBool(d, 'userMaskEnabled'), density: PSO.getInt(d, 'userMaskDensity'), feather: PSO.getNum(d, 'userMaskFeather') } : null;
    o.vectorMask = PSO.getBool(d, 'hasVectorMask') ? { enabled: PSO.getBool(d, 'vectorMaskEnabled'), density: PSO.getInt(d, 'vectorMaskDensity'), feather: PSO.getNum(d, 'vectorMaskFeather'), empty: PSO.getBool(d, 'vectorMaskEmpty') } : null;
    o.filterMask = PSO.getBool(d, 'hasFilterMask');
    var adj = PSO.getList(d, 'adjustment');
    if (adj && adj.count > 0) {
        var ty = adj.getType(0);
        if (ty === DescValueType.OBJECTTYPE) o.adjustment = t2s(adj.getObjectType(0));
        else if (ty === DescValueType.CLASSTYPE) o.adjustment = t2s(adj.getClass(0));
    }
    var fx = PSO.getObj(d, 'layerEffects');
    if (fx) { o.effectsVisible = PSO.getBool(d, 'layerFXVisible'); o.effects = PSO.effectsOf(fx); }
    var tk = PSO.getObj(d, 'textKey');
    if (tk) {
        o.text = { contents: PSO.getStr(tk, 'textKey') };
        var shapes = PSO.getList(tk, 'textShape');
        if (shapes && shapes.count > 0) o.text.shape = PSO.getEnum(shapes.getObjectValue(0), 'char');
        var warp = PSO.getObj(tk, 'warp');
        if (warp) o.text.warp = PSO.getEnum(warp, 'warpStyle');
    }
    var so = PSO.getObj(d, 'smartObject');
    if (so) {
        o.smartObject = { linked: PSO.getBool(so, 'linked'), fileReference: PSO.getStr(so, 'fileReference'), placed: PSO.getEnum(so, 'placed'), filters: [] };
        var ff = PSO.getList(so, 'filterFX');
        if (ff) for (var j = 0; j < ff.count; j++) {
            var f = ff.getObjectValue(j);
            var filt = PSO.getObj(f, 'filter');
            o.smartObject.filters.push({ name: PSO.getStr(f, 'name'), enabled: PSO.getBool(f, 'enabled'), filter: filt ? t2s(ff.getObjectValue(j).getObjectType(sTID('filter'))) : null });
        }
    }
    if (PSO.has(d, 'knockout')) o.knockout = PSO.getEnum(d, 'knockout');
    var br = PSO.getList(d, 'blendRange');
    if (br) {
        o.blendIf = [];
        for (var k = 0; k < br.count; k++) {
            var e = br.getObjectValue(k);
            o.blendIf.push([PSO.getInt(e, 'srcBlackMin'), PSO.getInt(e, 'srcBlackMax'), PSO.getInt(e, 'srcWhiteMin'), PSO.getInt(e, 'srcWhiteMax'),
                            PSO.getInt(e, 'destBlackMin'), PSO.getInt(e, 'destBlackMax'), PSO.getInt(e, 'destWhiteMin'), PSO.getInt(e, 'destWhiteMax')]);
        }
    }
    var flags = ['blendInterior', 'blendClipped', 'transparencyShapesLayer', 'layerMaskAsGlobalMask', 'vectorMaskAsGlobalMask'];
    for (var q = 0; q < flags.length; q++) { var v = PSO.getBool(d, flags[q]); if (v !== null) o[flags[q]] = v; }
    var cr = PSO.getList(d, 'channelRestrictions');
    if (cr) o.channelRestrictions = cr.count;
    return o;
};

PSO.docInfo = function (doc) {
    app.activeDocument = doc;
    var d = PSO.activeDocDesc();
    var info = { mode: PSO.modeName(doc.mode), bits: PSO.bits(doc.bitsPerChannel), width: doc.width.as('px'), height: doc.height.as('px'),
                 resolution: doc.resolution, profile: null, profileType: null, hasBackground: PSO.getBool(d, 'hasBackgroundLayer'),
                 channels: [], layers: [], warnings: [] };
    try { info.profileType = String(doc.colorProfileType).replace('ColorProfileType.', ''); } catch (e) { info.warnings.push('colorProfileType: ' + PSO.errorText(e)); }
    try { if (info.profileType !== 'NONE') info.profile = doc.colorProfileName; } catch (e2) { info.profile = null; info.untagged = true; }
    try {
        for (var c = 0; c < doc.channels.length; c++) info.channels.push({ name: doc.channels[c].name, kind: String(doc.channels[c].kind).replace('ChannelType.', '') });
    } catch (e3) { info.warnings.push('channels: ' + PSO.errorText(e3)); }
    var n = PSO.getInt(d, 'numberOfLayers') || 0;
    for (var i = info.hasBackground ? 0 : 1; i <= n; i++) {
        try { info.layers.push(PSO.layerInfo(i)); } catch (e4) { info.warnings.push('layer ' + i + ': ' + PSO.errorText(e4)); }
    }
    return info;
};

// ---------------------------------------------------------------- composites

PSO.tiffOptions = function (transparency) {
    var o = new TiffSaveOptions();
    o.imageCompression = TIFFEncoding.NONE;
    o.byteOrder = ByteOrder.MACOS;
    o.layers = false;
    o.alphaChannels = false;
    o.spotColors = false;
    o.embedColorProfile = true;
    o.transparency = transparency;
    o.interleaveChannels = true;
    o.annotations = false;
    o.saveImagePyramid = false;
    return o;
};

// TIFF cannot hold Duotone or Multichannel; Photoshop Raw (interleaved, no header) can.
PSO.compositeFormat = function (doc) {
    var m = PSO.modeName(doc.mode);
    return (m === 'Multichannel' || m === 'Duotone') ? 'raw' : 'tiff';
};

PSO.saveAsCopy = function (doc, path, format, transparency) {
    PSO.checkPath(path);
    var f = new File(path);
    if (format === 'raw') {
        // Multichannel colour channels are spot channels: keep them.
        var r = new RawSaveOptions();
        r.alphaChannels = PSO.modeName(doc.mode) === 'Multichannel';
        r.spotColors = PSO.modeName(doc.mode) === 'Multichannel';
        doc.saveAs(f, r, true, Extension.LOWERCASE);
    } else {
        doc.saveAs(f, PSO.tiffOptions(transparency), true, Extension.LOWERCASE);
    }
};

// Flattens a duplicate of `doc` and saves it at the document's own mode and depth.
PSO.flattenedComposite = function (doc, path) {
    var fmt = PSO.compositeFormat(doc);
    var dup = null;
    try {
        dup = doc.duplicate('pso_flat', false);
        dup.flatten();
        PSO.saveAsCopy(dup, path, fmt, false);
        return { path: path, format: fmt, width: dup.width.as('px'), height: dup.height.as('px'), channels: dup.channels.length, bits: PSO.bits(dup.bitsPerChannel) };
    } finally { PSO.close(dup); }
};

// The composite with transparency (TIFF only), saved straight from the layered document.
PSO.transparentComposite = function (doc, path) {
    app.activeDocument = doc;
    PSO.saveAsCopy(doc, path, 'tiff', true);
    return { path: path, format: 'tiff' };
};

PSO.selectLayerIndex = function (i) {
    var r = new ActionReference();
    r.putIndex(sTID('layer'), i);
    var d = new ActionDescriptor();
    d.putReference(cTID('null'), r);
    d.putBoolean(cTID('MkVs'), false);
    executeAction(cTID('slct'), d, DialogModes.NO);
};

PSO.setTargetLayerBool = function (key, value) {
    var d = new ActionDescriptor();
    var r = new ActionReference();
    r.putEnumerated(cTID('Lyr '), cTID('Ordn'), cTID('Trgt'));
    d.putReference(cTID('null'), r);
    var v = new ActionDescriptor();
    v.putBoolean(sTID(key), value);
    d.putObject(cTID('T   '), cTID('Lyr '), v);
    executeAction(cTID('setd'), d, DialogModes.NO);
};

// Hides all effects of the target layer (Layer > Layer Style > Hide All Effects).
PSO.hideEffects = function () {
    var h = new ActionDescriptor();
    var l = new ActionList();
    var r = new ActionReference();
    r.putClass(cTID('Lefx'));
    r.putEnumerated(cTID('Lyr '), cTID('Ordn'), cTID('Trgt'));
    l.putReference(r);
    h.putList(cTID('null'), l);
    executeAction(cTID('Hd  '), h, DialogModes.NO);
};

// Duplicates layer `i` of `doc` into a new document, neutralises its blending (100 % opacity and
// fill, Normal, visible, no effects, mask off) and saves it as a TIFF with transparency; when the
// layer has a user mask, saves a second TIFF with the mask on.
PSO.exportLayer = function (doc, i, base) {
    app.activeDocument = doc;
    PSO.selectLayerIndex(i);
    var info = PSO.layerInfo(i);
    var d = new ActionDescriptor();
    var r = new ActionReference();
    r.putClass(cTID('Dcmn'));
    d.putReference(cTID('null'), r);
    d.putString(cTID('Nm  '), 'pso_layer');
    var u = new ActionReference();
    u.putEnumerated(cTID('Lyr '), cTID('Ordn'), cTID('Trgt'));
    d.putReference(cTID('Usng'), u);
    executeAction(cTID('Mk  '), d, DialogModes.NO);
    var nd = app.activeDocument;
    var out = { index: i, name: info.name, files: {} };
    try {
        var L = nd.artLayers[0];
        if (L.isBackgroundLayer) L.isBackgroundLayer = false;
        L.visible = true;
        L.opacity = 100;
        L.fillOpacity = 100;
        L.blendMode = BlendMode.NORMAL;
        if (info.clipped) { try { L.grouped = false; } catch (eg) {} }
        if (info.effects) { try { PSO.hideEffects(); } catch (e0) {} }
        if (info.userMask) PSO.setTargetLayerBool('userMaskEnabled', false);
        PSO.saveAsCopy(nd, base + '-pixels.tif', 'tiff', true);
        out.files.pixels = base + '-pixels.tif';
        if (info.userMask) {
            PSO.setTargetLayerBool('userMaskEnabled', true);
            PSO.saveAsCopy(nd, base + '-masked.tif', 'tiff', true);
            out.files.masked = base + '-masked.tif';
        }
    } finally { PSO.close(nd); app.activeDocument = doc; }
    return out;
};
