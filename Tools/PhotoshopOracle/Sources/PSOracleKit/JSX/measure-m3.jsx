// measure-m3: Photoshop 27's Light-mode Brightness/Contrast (brightnessMode = brightnessModeLight:
// Exposure, Contrast, Whites, Blacks, Highlights, Shadows) on the M1 identity lattice and ramp.
// Shared helpers and M.main are in measure-common.jsx. Photoshop only creates documents or opens
// ps-oracle's PNG inputs. Every job reads its layer back and fails unless the mode is Light and
// every control is stored as asked.
//
// ARGS.exposureSteps (from op "light-defaults") sets the Exposure sweep.

M.LIGHT_INTS = ['Cntr', 'brightnessWhites', 'brightnessBlacks', 'brightnessHighlights', 'brightnessShadows'];

// Light-mode settings: o.exposure (double) and the integer controls by key.
C.lightSettings = function (o) {
    var d = new ActionDescriptor();
    d.putEnumerated(sTID('brightnessMode'), sTID('brightnessModeType'), sTID('brightnessModeLight'));
    d.putDouble(sTID('brightnessExposure'), o.exposure || 0);
    for (var i = 0; i < M.LIGHT_INTS.length; i++) {
        var k = M.LIGHT_INTS[i];
        d.putInteger(C.key(k), o[k] || 0);
    }
    d.putBoolean(sTID('useLegacy'), false);
    return d;
};

// Every key of a descriptor with its type and value (scalars), for the manifest.
M.describe = function (d) {
    var out = [];
    for (var i = 0; i < d.count; i++) {
        var k = d.getKey(i), t = d.getType(k), e = { key: t2s(k), charID: null, type: String(t).replace('DescValueType.', '') };
        try { e.charID = typeIDToCharID(k) || null; } catch (x) {}
        if (C.isNumType(t)) e.value = C.num(d, k);
        else if (t === DescValueType.BOOLEANTYPE) e.value = d.getBoolean(k);
        else if (t === DescValueType.ENUMERATEDTYPE) { e.enumType = t2s(d.getEnumerationType(k)); e.value = t2s(d.getEnumerationValue(k)); }
        else if (t === DescValueType.STRINGTYPE) e.value = d.getString(k);
        out.push(e);
    }
    return out;
};

// The default B/C layer in a new RGB 8-bit document (no mode asked for), and how each Light
// control responds to values from inside to beyond plausible limits: stored as asked, clamped,
// or refused. One document; nothing is saved.
M.ops['light-defaults'] = function () {
    var doc = null;
    try {
        doc = C.newDoc('m3-defaults', 'RGB', 8, { width: 64, height: 64 });
        C.makeAdjustment('BrgC', null);
        var def = M.describe(C.readAdjustment());
        var probes = {};
        var cands = {
            brightnessExposure: [-25, -20, -10, -6, -5, -4, -2, -1, -0.5, 0.25, 0.5, 1, 2, 4, 5, 6, 10, 20, 25],
            Cntr: [-150, -101, -100, -51, -50, 50, 100, 101, 150],
            brightnessWhites: [-150, -101, -100, 100, 101, 150],
            brightnessBlacks: [-150, -101, -100, 100, 101, 150],
            brightnessHighlights: [-150, -101, -100, 100, 101, 150],
            brightnessShadows: [-150, -101, -100, 100, 101, 150]
        };
        for (var key in cands) {
            if (!cands.hasOwnProperty(key)) continue;
            probes[key] = [];
            for (var i = 0; i < cands[key].length; i++) {
                var v = cands[key][i], o = {}, rec = { asked: v };
                if (key === 'brightnessExposure') o.exposure = v; else o[key] = v;
                try {
                    C.setAdjustment('BrgC', C.lightSettings(o));
                    var got = C.readAdjustment();
                    rec.stored = C.num(got, C.key(key));
                    rec.mode = t2s(got.getEnumerationValue(sTID('brightnessMode')));
                } catch (e) { rec.error = PSO.errorText(e).replace(/\n/g, ' '); }
                probes[key].push(rec);
            }
        }
        C.setAdjustment('BrgC', C.lightSettings({}));
        return { defaultDescriptor: def, probes: probes, afterReset: M.describe(C.readAdjustment()) };
    } finally { PSO.close(doc); }
};

M.light = function (o) {
    return function () {
        C.makeAdjustment('BrgC', C.lightSettings(o));
        var got = C.readAdjustment();
        M.expect('brightnessMode', 'brightnessModeLight', t2s(got.getEnumerationValue(sTID('brightnessMode'))));
        return { stored: M.scalars(got), descriptor: M.describe(got) };
    };
};

// ------------------------------------------------------------------ catalogue

(function () {
    function job(id, o, input) {
        input = input || 'identity-rgb8.png';
        var p = { brightnessMode: 'brightnessModeLight', exposure: o.exposure || 0, input: input };
        for (var i = 0; i < M.LIGHT_INTS.length; i++) p[M.LIGHT_INTS[i]] = o[M.LIGHT_INTS[i]] || 0;
        M.add(id, o.group || 'light', p, function () { return M.adjustJob(id, input, M.light(o)); });
    }
    function num(v) { return String(v).replace('-', 'm').replace('.', 'p'); }
    M.add('identity-rgb8', 'identity', { input: 'identity-rgb8.png' }, function () { return M.identityJob('identity-rgb8', 'identity-rgb8.png'); });
    M.add('identity-rgb16', 'identity', { input: 'identity-rgb16.png' }, function () { return M.identityJob('identity-rgb16', 'identity-rgb16.png'); });
    job('light-default-rgb8', { group: 'light-default' });

    var steps = (ARGS && ARGS.exposureSteps) ? ARGS.exposureSteps : [-4, -2, -1, 1, 2, 4];
    for (var s = 0; s < steps.length; s++) job('light-exposure-' + num(steps[s]) + '-rgb8', { exposure: steps[s], group: 'light-exposure' });
    var tone = [['brightnessWhites', 'whites'], ['brightnessBlacks', 'blacks'], ['brightnessHighlights', 'highlights'], ['brightnessShadows', 'shadows']];
    var amounts = [-100, -50, 50, 100];
    for (var t = 0; t < tone.length; t++) {
        for (var a = 0; a < amounts.length; a++) {
            var o = { group: 'light-' + tone[t][1] };
            o[tone[t][0]] = amounts[a];
            job('light-' + tone[t][1] + '-' + num(amounts[a]) + '-rgb8', o);
        }
    }
    var cs = [-50, 50, 100];
    for (var c = 0; c < cs.length; c++) job('light-contrast-' + num(cs[c]) + '-rgb8', { Cntr: cs[c], group: 'light-contrast' });

    var mid = steps[Math.floor(steps.length / 2)];
    job('light-combo-exposure' + num(mid) + '-contrast50-rgb8', { exposure: mid, Cntr: 50, group: 'light-combination' });
    job('light-combo-highlights-m50-shadows50-rgb8', { brightnessHighlights: -50, brightnessShadows: 50, group: 'light-combination' });
    job('light-combo-five-rgb8', { exposure: mid / 2, brightnessWhites: 25, brightnessBlacks: -25, brightnessHighlights: -30, brightnessShadows: 30, group: 'light-combination' });
    job('light-exposure-' + num(mid) + '-rgb16', { exposure: mid, group: 'light-exposure-16' }, 'identity-rgb16.png');
})();

M.main();
