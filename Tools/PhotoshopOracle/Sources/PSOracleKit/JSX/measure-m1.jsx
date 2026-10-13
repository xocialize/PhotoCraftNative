// measure-m1: Photoshop as a function oracle for PCRender's remaining ps-corpus failures. Shared
// helpers and M.main are in measure-common.jsx. Each job saves its document as PSD (Maximize
// Compatibility) and its flattened composite as TIFF, then closes everything without saving.

// ------------------------------------------------------------------ catalogue

(function () {
    M.add('identity-rgb8', 'identity', { input: 'identity-rgb8.png' }, function () { return M.identityJob('identity-rgb8', 'identity-rgb8.png'); });
    M.add('identity-rgb16', 'identity', { input: 'identity-rgb16.png' }, function () { return M.identityJob('identity-rgb16', 'identity-rgb16.png'); });

    // 1. Satin
    var base = { angle: 19, distance: 11, size: 14, color: [0, 0, 0], mode: 'multiply', opacity: 50, antialias: true };
    var contours = ['Linear', 'Gaussian', 'Cone', 'Cone - Inverted', 'Ring'];
    var variants = [];
    for (var i = 0; i < contours.length; i++) {
        for (var inv = 0; inv < 2; inv++) {
            variants.push({ contour: contours[i], invert: inv === 1, angle: 19, distance: 11, size: 14 });
        }
    }
    var extra = ['Linear', 'Cone'];
    for (var j = 0; j < extra.length; j++) {
        variants.push({ contour: extra[j], invert: false, angle: 90, distance: 11, size: 14 });
        variants.push({ contour: extra[j], invert: false, angle: 19, distance: 30, size: 5 });
    }
    for (var v = 0; v < variants.length; v++) {
        (function (vv) {
            var slug = 'satin-' + vv.contour.toLowerCase().replace(/ - /g, '-').replace(/ /g, '-') + (vv.invert ? '-inv' : '') + '-a' + vv.angle + '-d' + vv.distance + '-s' + vv.size;
            var p = { contour: vv.contour, invert: vv.invert, angle: vv.angle, distance: vv.distance, size: vv.size,
                      color: base.color, mode: base.mode, opacity: base.opacity, antialias: base.antialias, raw: false, background: [128, 128, 128] };
            M.add(slug, 'satin', p, function () { return M.satinJob(slug, p); });
            var r = { contour: vv.contour, invert: vv.invert, angle: vv.angle, distance: vv.distance, size: vv.size,
                      color: [255, 255, 255], mode: 'normal', opacity: 100, antialias: base.antialias, raw: true, background: [0, 0, 0], layerFill: 0 };
            M.add(slug + '-raw', 'satin-raw', r, function () { return M.satinJob(slug + '-raw', r); });
        })(variants[v]);
    }

    // 2. Brightness/Contrast (modern)
    var bs = [-150, -50, 0, 50, 150], cs = [-50, 0, 50, 100];
    for (var b = 0; b < bs.length; b++) {
        for (var c = 0; c < cs.length; c++) {
            (function (bb, cc) {
                var id = 'bc-b' + bb + '-c' + cc + '-rgb8';
                M.add(id, 'brightness-contrast', { brightness: bb, contrast: cc, useLegacy: false, input: 'identity-rgb8.png' },
                      function () { return M.adjustJob(id, 'identity-rgb8.png', M.brightnessContrast(bb, cc)); });
            })(bs[b], cs[c]);
        }
    }
    M.add('bc-b50-c0-rgb16', 'brightness-contrast', { brightness: 50, contrast: 0, useLegacy: false, input: 'identity-rgb16.png' },
          function () { return M.adjustJob('bc-b50-c0-rgb16', 'identity-rgb16.png', M.brightnessContrast(50, 0)); });

    // 3. Vibrance
    var vs = [-100, -50, 50, 100], ss = [-50, 0, 50];
    for (var a = 0; a < vs.length; a++) {
        for (var s = 0; s < ss.length; s++) {
            (function (va, sa) {
                var id = 'vib-v' + va + '-s' + sa + '-rgb8';
                M.add(id, 'vibrance', { vibrance: va, saturation: sa, input: 'identity-rgb8.png' },
                      function () { return M.adjustJob(id, 'identity-rgb8.png', M.vibrance(va, sa)); });
            })(vs[a], ss[s]);
        }
    }

    // 4. Luminosity / Color / Hue / Saturation over lattice pairs
    var modes = ['luminosity', 'color', 'hue', 'saturation'], perms = ['a', 'b'];
    for (var m = 0; m < modes.length; m++) {
        for (var q = 0; q < perms.length; q++) {
            (function (mm, pp) {
                var id = 'blend-' + mm + '-perm' + pp + '-rgb8';
                M.add(id, 'blend', { mode: mm, opacity: 100, base: 'identity-rgb8.png', top: 'perm-' + pp + '-rgb8.png' },
                      function () { return M.blendJob(id, 'identity-rgb8.png', 'perm-' + pp + '-rgb8.png', mm); });
            })(modes[m], perms[q]);
        }
    }
    for (var q2 = 0; q2 < perms.length; q2++) {
        (function (pp) {
            var id = 'blend-luminosity-perm' + pp + '-rgb16';
            M.add(id, 'blend', { mode: 'luminosity', opacity: 100, base: 'identity-rgb16.png', top: 'perm-' + pp + '-rgb16.png' },
                  function () { return M.blendJob(id, 'identity-rgb16.png', 'perm-' + pp + '-rgb16.png', 'luminosity'); });
        })(perms[q2]);
    }

    // 5. Dissolve determinism
    M.add('dissolve-a', 'dissolve', { canvas: 256, offset: [0, 0], opacity: 50, color: [255, 0, 0], background: [255, 255, 255] }, function () { return M.dissolveJob('dissolve-a', 256, [0, 0]); });
    M.add('dissolve-b', 'dissolve', { canvas: 256, offset: [0, 0], opacity: 50, color: [255, 0, 0], background: [255, 255, 255] }, function () { return M.dissolveJob('dissolve-b', 256, [0, 0]); });
    M.add('dissolve-offset', 'dissolve', { canvas: 320, offset: [37, 53], opacity: 50, color: [255, 0, 0], background: [255, 255, 255] }, function () { return M.dissolveJob('dissolve-offset', 320, [37, 53]); });
})();

M.main();
