// corpus: the catalogue of Photoshop-authored oracle files. `ARGS.op`:
//   "list"  → { items: [{ name, ext, features, description }] }
//   "build" → builds ARGS.name in a new untitled document (named pso_<name>), saves it to ARGS.out
//             (PSD or PSB, Maximize Compatibility on, ICC profile embedded), closes it.
// Builders use the DOM where it can and Action Manager where it can't (fill/adjustment layers,
// styles, blend-if, masks, smart filters). Everything is in pixels with explicit units; nothing is
// added to the user's presets (no Define Pattern, no saved styles).
// The helpers (C.*) live in builders.jsx, prepended by the runner.

// ------------------------------------------------------------------ catalogue

(function () {
    // Colour modes × depths
    var modeDepths = [['RGB', 8], ['RGB', 16], ['RGB', 32], ['Grayscale', 8], ['Grayscale', 16], ['Grayscale', 32], ['CMYK', 8], ['CMYK', 16], ['Lab', 8], ['Lab', 16]];
    for (var i = 0; i < modeDepths.length; i++) {
        (function (m, b) {
            C.add('mode-' + m.toLowerCase() + '-' + b, ['mode:' + m, 'depth:' + b, 'layers', 'partial-alpha-layer', 'blend:multiply', 'opacity'],
                  m + ' ' + b + '-bit: white background, rainbow base, a 60 % multiply ellipse and a soft-edged transparent ramp',
                  function (notes) {
                      var doc = C.newDoc('mode-' + m + b, m, b);
                      C.base();
                      C.ellipse('Ellipse', [8, 20, 56, 70], [40, 200, 90]);
                      C.set({ mode: 'multiply', opacity: 60 });
                      C.ramp('Fade', [[0, 250, 250, 255], [4096, 20, 20, 60]], [[0, 0], [1600, 100], [4096, 0]], 30);
                      return doc;
                  });
        })(modeDepths[i][0], modeDepths[i][1]);
    }
    C.add('mode-rgb-8-flat', ['mode:RGB', 'depth:8', 'background-only'], 'RGB 8-bit, background only (no layer records)', function () {
        var doc = C.newDoc('flat8', 'RGB', 8); C.base(); C.flatten(); return doc;
    });
    C.add('mode-rgb-32-flat', ['mode:RGB', 'depth:32', 'background-only'], 'RGB 32-bit, background only (merged image only)', function () {
        var doc = C.newDoc('flat32', 'RGB', 32); C.base(); C.flatten(); return doc;
    });
    C.add('mode-gray-32-flat', ['mode:Grayscale', 'depth:32', 'background-only'], 'Grayscale 32-bit, background only', function () {
        var doc = C.newDoc('flatg32', 'Grayscale', 32); C.base(); C.flatten(); return doc;
    });
    C.add('mode-bitmap-1', ['mode:Bitmap', 'depth:1'], 'Bitmap (50 % threshold of the gray base)', function () {
        var doc = C.newDoc('bitmap', 'Grayscale', 8); C.base(); C.ellipse('E', [10, 10, 54, 86], [255, 255, 255]); C.flatten(); C.toBitmap(); return doc;
    });
    C.add('mode-indexed-8', ['mode:Indexed', 'depth:8'], 'Indexed, 64-colour local selective palette, no dither', function () {
        var doc = C.newDoc('indexed', 'RGB', 8); C.base(); C.flatten(); C.toIndexed(64, false); return doc;
    });
    C.add('mode-indexed-8-transparent', ['mode:Indexed', 'depth:8', 'transparent-index'], 'Indexed with a transparent index (resource 1047)', function () {
        var doc = C.newDoc('indexedt', 'RGB', 8, { transparent: true });
        C.ellipse('Disc', [6, 10, 58, 86], [220, 60, 30]);
        C.rect('Bar', [24, 0, 40, 96], [30, 90, 220]);
        doc.mergeVisibleLayers();
        C.toIndexed(32, true);
        return doc;
    });
    C.add('mode-duotone-8', ['mode:Duotone', 'depth:8'], 'Duotone (two inks, linear curves) from the gray base', function () {
        var doc = C.newDoc('duotone', 'Grayscale', 8); C.base(); C.flatten(); C.toDuotone([['Black', [0, 0, 0]], ['PSO Orange', [240, 120, 20]]]); return doc;
    });
    C.add('mode-duotone-8-layers', ['mode:Duotone', 'depth:8', 'layers'], 'Duotone with layers', function () {
        var doc = C.newDoc('duotonel', 'Grayscale', 8); C.base(); C.ellipse('Ellipse', [8, 20, 56, 70], [90, 90, 90]); C.set({ opacity: 70 });
        C.toDuotone([['Black', [0, 0, 0]], ['PSO Teal', [0, 140, 150]]]); return doc;
    });
    C.add('mode-duotone-16', ['mode:Duotone', 'depth:16'], 'Duotone at 16 bits (if Photoshop allows it)', function () {
        var doc = C.newDoc('duotone16', 'Grayscale', 16); C.base(); C.flatten(); C.toDuotone([['Black', [0, 0, 0]], ['PSO Orange', [240, 120, 20]]]); return doc;
    });
    C.add('mode-multichannel-8', ['mode:Multichannel', 'depth:8'], 'Multichannel (from RGB: three spot channels)', function () {
        var doc = C.newDoc('multi8', 'RGB', 8); C.base(); C.flatten(); doc.changeMode(ChangeMode.MULTICHANNEL); return doc;
    });
    C.add('mode-multichannel-16', ['mode:Multichannel', 'depth:16'], 'Multichannel 16-bit', function () {
        var doc = C.newDoc('multi16', 'RGB', 16); C.base(); C.flatten(); doc.changeMode(ChangeMode.MULTICHANNEL); return doc;
    });
    C.add('mode-cmyk-32', ['mode:CMYK', 'depth:32'], 'CMYK 32-bit (Photoshop should refuse)', function () {
        var doc = C.newDoc('cmyk32', 'CMYK', 32); C.base(); return doc;
    });
    C.add('mode-lab-32', ['mode:Lab', 'depth:32'], 'Lab 32-bit (Photoshop should refuse)', function () {
        var doc = C.newDoc('lab32', 'Lab', 32); C.base(); return doc;
    });

    // Transparency / matte
    var tr = [['RGB', 8], ['RGB', 16], ['RGB', 32], ['Grayscale', 16], ['CMYK', 8]];
    for (var t = 0; t < tr.length; t++) {
        (function (m, b) {
            C.add('transparent-' + m.toLowerCase() + '-' + b, ['mode:' + m, 'depth:' + b, 'no-background', 'merged-alpha', 'matte'],
                  m + ' ' + b + '-bit without a background: partially transparent merged image (white matte)', function () {
                      var doc = C.newDoc('transp' + m + b, m, b, { transparent: true });
                      C.ellipse('Disc', [4, 8, 60, 70], [220, 60, 30], 100);
                      C.ramp('Glass', [[0, 30, 90, 220], [4096, 30, 200, 120]], [[0, 90], [4096, 10]], 0);
                      return doc;
                  });
        })(tr[t][0], tr[t][1]);
    }

    // Blend modes
    for (var bm = 0; bm < C.blendModes.length; bm++) {
        (function (mode) {
            C.add('blend-' + mode, ['blend:' + mode, 'mode:RGB', 'depth:8'], 'RGB 8-bit, vertical ramp in ' + mode + ' over the rainbow base (right quarter at 50 % coverage)',
                  function () { return C.blendScene('blend-' + mode, mode); });
        })(C.blendModes[bm]);
    }
    var bands = [['RGB', 16], ['RGB', 32], ['CMYK', 8], ['Lab', 8], ['Grayscale', 8]];
    for (var bb = 0; bb < bands.length; bb++) {
        (function (m, b) {
            C.add('blend-bands-' + m.toLowerCase() + '-' + b, ['blend:all', 'mode:' + m, 'depth:' + b], m + ' ' + b + '-bit: 27 bands, one layer per blend mode',
                  function (notes) { return C.blendBands('bands-' + m + b, m, b, notes); });
        })(bands[bb][0], bands[bb][1]);
    }

    // Groups
    function groupScene(name, passThrough, opacity) {
        var doc = C.newDoc(name, 'RGB', 8);
        C.base();
        var a = C.ellipse('Multiply disc', [6, 6, 50, 50], [250, 120, 30]); C.set({ mode: 'multiply' });
        var b = C.rect('Screen bar', [20, 30, 44, 92], [40, 80, 220]); C.set({ mode: 'screen', opacity: 80 });
        C.group('Group', [a, b], { blendMode: passThrough ? BlendMode.PASSTHROUGH : BlendMode.NORMAL, opacity: opacity === undefined ? 100 : opacity });
        return doc;
    }
    C.add('group-passthrough', ['group', 'group:pass-through'], 'Group in Pass Through holding a multiply and a screen layer', function () { return groupScene('gpass', true); });
    C.add('group-normal', ['group', 'group:normal'], 'Same group in Normal (isolated)', function () { return groupScene('gnorm', false); });
    C.add('group-opacity', ['group', 'group:normal', 'group:opacity'], 'Normal group at 60 % opacity', function () { return groupScene('gop', false, 60); });
    C.add('group-nested', ['group', 'group:nested', 'group:pass-through', 'group:normal', 'group:hidden-child'], 'Nested groups (pass-through inside normal at 85 %), a hidden layer, a second top-level group', function () {
        var doc = C.newDoc('gnest', 'RGB', 8);
        C.base();
        var h = C.rect('Hidden', [0, 0, 64, 96], [0, 0, 0]); h.visible = false;
        var c = C.rect('Outer C', [10, 60, 30, 92], [250, 250, 30]); C.set({ mode: 'multiply' });
        var outer = C.group('Outer', [h, c], { blendMode: BlendMode.NORMAL, opacity: 85 });
        var a = C.ellipse('Inner A', [4, 4, 40, 40], [250, 20, 120]); C.set({ mode: 'overlay' });
        var b = C.rect('Inner B', [30, 40, 60, 90], [20, 220, 120]); C.set({ mode: 'difference' });
        C.group('Inner', [a, b], { blendMode: BlendMode.PASSTHROUGH, parent: outer });
        var e = C.rect('In second group', [44, 4, 60, 30], [90, 40, 10]);
        C.group('Second', [e], {});
        return doc;
    });

    // Clipping
    C.add('clipping-basic', ['clipping'], 'An ellipse base with two clipped layers (normal ramp, multiply)', function () {
        var doc = C.newDoc('clip', 'RGB', 8);
        C.base();
        C.ellipse('Clip base', [6, 14, 58, 82], [200, 200, 200]);
        C.ramp('Clipped ramp', [[0, 255, 0, 80], [4096, 0, 80, 255]], null, 45); C.clip();
        C.rect('Clipped multiply', [0, 40, 64, 70], [250, 200, 0]); C.set({ mode: 'multiply' }); C.clip();
        return doc;
    });
    C.add('clipping-adjustment', ['clipping', 'adjustment:hue2'], 'A clipped Hue/Saturation adjustment', function () {
        var doc = C.newDoc('clipadj', 'RGB', 8);
        C.base();
        C.ellipse('Clip base', [6, 14, 58, 82], [200, 60, 60]);
        C.adjust.hueSaturation(); C.clip();
        return doc;
    });
    C.add('clipping-blend-clipped-off', ['clipping', 'advanced:blendClipped'], 'Clipping group with "Blend Clipped Layers as Group" off on a multiply base', function () {
        var doc = C.newDoc('clipbc', 'RGB', 8);
        C.base();
        C.ellipse('Clip base', [6, 14, 58, 82], [180, 220, 255]); C.set({ mode: 'multiply', blendClipped: false });
        C.rect('Clipped', [0, 30, 64, 80], [255, 120, 0]); C.clip();
        return doc;
    });

    // Masks
    function maskScene(name, props, soft) {
        var doc = C.newDoc(name, 'RGB', 8);
        C.base();
        C.ramp('Masked', [[0, 250, 250, 40], [4096, 40, 20, 160]], null, 90);
        C.selEllipse(8, 16, 56, 80);
        if (soft) C.featherSelection(soft);
        C.maskFromSelection();
        C.deselect();
        if (props) C.set(props);
        return doc;
    }
    C.add('mask-raster', ['mask:raster'], 'Raster layer mask from an elliptical selection', function () { return maskScene('mraster'); });
    C.add('mask-soft', ['mask:raster', 'mask:gray-values'], 'Raster mask from a feathered selection (gray mask values)', function () { return maskScene('msoft', null, 6); });
    C.add('mask-density', ['mask:raster', 'mask:density'], 'Raster mask at 55 % density', function () { return maskScene('mdens', { userMaskDensity: 55 }); });
    C.add('mask-feather', ['mask:raster', 'mask:feather'], 'Raster mask with 4.5 px feather', function () { return maskScene('mfeat', { userMaskFeather: 4.5 }); });
    C.add('mask-disabled', ['mask:raster', 'mask:disabled'], 'Raster mask present but disabled', function () { return maskScene('mdis', { userMaskEnabled: false }); });
    C.add('mask-vector', ['mask:vector'], 'Vector mask (ellipse path) on a pixel layer', function () {
        var doc = C.newDoc('mvec', 'RGB', 8);
        C.base();
        C.ramp('Vector masked', [[0, 250, 250, 40], [4096, 40, 20, 160]], null, 90);
        C.selEllipse(8, 16, 56, 80); C.vectorMaskFromSelection(); C.deselect();
        return doc;
    });
    C.add('mask-vector-feather', ['mask:vector', 'mask:density', 'mask:feather'], 'Vector mask with 3 px feather and 70 % density', function () {
        var doc = C.newDoc('mvecf', 'RGB', 8);
        C.base();
        C.ramp('Vector masked', [[0, 250, 250, 40], [4096, 40, 20, 160]], null, 90);
        C.selRect(10, 12, 54, 84); C.vectorMaskFromSelection(); C.deselect();
        C.set({ vectorMaskFeather: 3 });
        C.set({ vectorMaskDensity: 70 });
        return doc;
    });
    C.add('mask-both', ['mask:raster', 'mask:vector'], 'Raster and vector mask on the same layer', function () {
        var doc = C.newDoc('mboth', 'RGB', 8);
        C.base();
        C.ramp('Both masks', [[0, 250, 250, 40], [4096, 40, 20, 160]], null, 90);
        C.selEllipse(4, 4, 60, 60); C.featherSelection(3); C.maskFromSelection(); C.deselect();
        C.selRect(10, 20, 54, 92); C.vectorMaskFromSelection(); C.deselect();
        return doc;
    });
    C.add('mask-group', ['mask:raster', 'group', 'mask:on-group'], 'Raster mask on a group', function () {
        var doc = C.newDoc('mgroup', 'RGB', 8);
        C.base();
        var a = C.ramp('In group', [[0, 250, 250, 40], [4096, 40, 20, 160]], null, 90);
        C.group('Masked group', [a], {});
        C.selEllipse(8, 16, 56, 80); C.maskFromSelection(); C.deselect();
        return doc;
    });

    // Adjustment layers
    for (var ad = 0; ad < C.adjustmentNames.length; ad++) {
        (function (k) {
            C.add('adj-' + k, ['adjustment:' + k, 'mode:RGB', 'depth:8'], k + ' adjustment layer (non-default settings) over the rainbow base', function () {
                var doc = C.newDoc('adj-' + k, 'RGB', 8);
                C.base();
                C.ellipse('Gray disc', [16, 30, 48, 66], [128, 128, 128]);
                C.adjust[k]();
                return doc;
            });
        })(C.adjustmentNames[ad]);
    }
    // The brightness the 2026-10-12 adj-brightnessContrast asked for but did not get (Photoshop
    // made the layer in Light mode and stored Brgh 0): the same document with Brightness 25 applied.
    C.add('adj-brightnessContrast-b25c35', ['adjustment:brightnessContrast', 'mode:RGB', 'depth:8'],
          'Brightness/Contrast (modern mode, Brightness 25, Contrast 35) over the rainbow base', function () {
        var doc = C.newDoc('adj-bc-b25c35', 'RGB', 8);
        C.base();
        C.ellipse('Gray disc', [16, 30, 48, 66], [128, 128, 128]);
        C.adjust.brightnessContrast();
        return doc;
    });
    // Color Lookups with a table, made by Photoshop's own 3DLUT File route from read-only copies
    // of its bundled presets (<data root>/ps-presets/3DLUTs; not in the fixtures root). The notes
    // record the layer's key names (raw data as byte counts only). The LUT data stays out of the
    // port and its fixtures (AB-D-0130).
    function lutItem(name, file, bits) {
        C.add(name, ['adjustment:colorLookup', 'mode:RGB', 'depth:' + bits],
              'Color Lookup loading Photoshop\'s bundled ' + file + ' (3DLUT File, dither off) over the rainbow base', function (notes) {
            var doc = C.newDoc(name, 'RGB', bits);
            C.base();
            C.ellipse('Gray disc', [16, 30, 48, 66], [128, 128, 128]);
            var presets = String(ARGS.out).replace(/\/[^\/]+\/[^\/]+$/, '') + '/ps-presets/3DLUTs/';
            var got = C.colorLookupFile(presets + file);
            if (!got.hasKey(sTID('LUT3DFileData')) && !got.hasKey(sTID('profile'))) throw new Error('ps-oracle: the Color Lookup stored no table');
            notes.push('colorLookup keys: ' + C.keyNames(got).join('; '));
            return doc;
        });
    }
    lutItem('adj-colorLookup-cube', 'Candlelight.CUBE', 8);
    lutItem('adj-colorLookup-3dl', 'FoggyNight.3DL', 8);
    lutItem('adj-colorLookup-look', 'Crisp_Warm.look', 8);
    lutItem('adj-colorLookup-cube-16', 'Candlelight.CUBE', 16);
    function adjStack(name, mode, bits, kinds) {
        return function (notes) {
            var doc = C.newDoc(name, mode, bits);
            C.base();
            for (var i = 0; i < kinds.length; i++) {
                try { C.adjust[kinds[i]](); C.set({ opacity: 70 }); } catch (e) {
                    if (PSO.errorText(e).indexOf('did not store') >= 0) throw e;
                    notes.push(kinds[i] + ' unavailable (' + C.shortError(e) + ')');
                }
            }
            return doc;
        };
    }
    C.add('adj-stack-rgb-16', ['adjustment:stack', 'mode:RGB', 'depth:16'], 'RGB 16-bit: every adjustment kind stacked at 70 %', adjStack('adj16', 'RGB', 16, C.adjustmentNames));
    C.add('adj-stack-rgb-32', ['adjustment:stack', 'mode:RGB', 'depth:32'], 'RGB 32-bit: the adjustment kinds 32-bit allows', adjStack('adj32', 'RGB', 32, C.adjustmentNames));
    C.add('adj-stack-cmyk-8', ['adjustment:stack', 'mode:CMYK', 'depth:8'], 'CMYK 8-bit: the adjustment kinds CMYK allows', adjStack('adjcmyk', 'CMYK', 8, C.adjustmentNames));
    C.add('adj-stack-lab-8', ['adjustment:stack', 'mode:Lab', 'depth:8'], 'Lab 8-bit: the adjustment kinds Lab allows', adjStack('adjlab', 'Lab', 8, C.adjustmentNames));
    C.add('adj-stack-gray-16', ['adjustment:stack', 'mode:Grayscale', 'depth:16'], 'Grayscale 16-bit: the adjustment kinds Grayscale allows', adjStack('adjgray', 'Grayscale', 16, C.adjustmentNames));

    // Fill layers
    C.add('fill-solid', ['fill:solid'], 'Solid colour fill layer at 70 % over the base', function () {
        var doc = C.newDoc('fsolid', 'RGB', 8); C.base(); C.solidLayer('Solid', [30, 120, 230]); C.set({ opacity: 70 }); return doc;
    });
    C.add('fill-solid-masked', ['fill:solid', 'mask:raster'], 'Solid fill layer with an elliptical mask', function () {
        var doc = C.newDoc('fsolidm', 'RGB', 8); C.base(); C.selEllipse(8, 16, 56, 80); C.solidLayer('Solid', [230, 40, 90]); C.deselect(); return doc;
    });
    C.add('fill-gradient-linear', ['fill:gradient', 'gradient:linear', 'gradient:transparency'], 'Linear gradient fill, four colour stops, transparency stops', function () {
        var doc = C.newDoc('fglin', 'RGB', 8); C.base();
        C.gradientLayer('Gradient', [[0, 255, 255, 255], [1200, 255, 0, 80], [2900, 0, 0, 160], [4096, 0, 0, 0]], [[0, 100], [2048, 40], [4096, 100]], 30);
        return doc;
    });
    C.add('fill-gradient-radial', ['fill:gradient', 'gradient:radial'], 'Radial gradient fill', function () {
        var doc = C.newDoc('fgrad', 'RGB', 8); C.base(); C.gradientLayer('Radial', [[0, 255, 250, 200], [4096, 40, 0, 90]], [[0, 100], [4096, 60]], 0, 'Rdl '); return doc;
    });
    C.add('fill-gradient-angle', ['fill:gradient', 'gradient:angle'], 'Angle gradient fill', function () {
        var doc = C.newDoc('fgang', 'RGB', 8); C.base(); C.gradientLayer('Angle', [[0, 255, 0, 0], [2048, 0, 255, 0], [4096, 255, 0, 0]], null, 45, 'Angl'); return doc;
    });
    C.add('fill-pattern', ['fill:pattern'], 'Pattern fill layer (first pattern preset, by name)', function () {
        var doc = C.newDoc('fpat', 'RGB', 8); C.base();
        var p = new ActionDescriptor();
        p.putObject(cTID('Ptrn'), cTID('Ptrn'), C.patternRef(C.firstPattern()));
        C.makeContentLayer('patternLayer', p);
        C.set({ opacity: 80, name: 'Pattern' });
        return doc;
    });

    // Layer styles
    var effectFiles = [['dropShadow', 'drop-shadow'], ['innerShadow', 'inner-shadow'], ['outerGlow', 'outer-glow'], ['innerGlow', 'inner-glow'],
                       ['bevelEmboss', 'bevel-emboss'], ['satin', 'satin'], ['colorOverlay', 'color-overlay'], ['gradientOverlay', 'gradient-overlay'],
                       ['patternOverlay', 'pattern-overlay'], ['stroke', 'stroke']];
    function styleTarget(name) {
        var doc = C.newDoc(name, 'RGB', 8);
        C.base();
        C.ellipse('Styled', [12, 18, 52, 78], [240, 200, 60]);
        return doc;
    }
    for (var ef = 0; ef < effectFiles.length; ef++) {
        (function (k, f) {
            C.add('fx-' + f, ['effect:' + k], k + ' on an ellipse layer', function () {
                var doc = styleTarget('fx-' + f);
                var o = {};
                if (k === 'patternOverlay') o.pattern = C.firstPattern();
                C.setEffects([[k, o]]);
                return doc;
            });
        })(effectFiles[ef][0], effectFiles[ef][1]);
    }
    C.add('fx-all', ['effect:dropShadow', 'effect:innerShadow', 'effect:outerGlow', 'effect:innerGlow', 'effect:bevelEmboss', 'effect:satin', 'effect:colorOverlay', 'effect:gradientOverlay', 'effect:stroke'],
          'Every effect except pattern overlay on one layer', function () {
              var doc = styleTarget('fx-all');
              C.setEffects([['dropShadow'], ['innerShadow'], ['outerGlow'], ['innerGlow'], ['bevelEmboss'], ['satin'], ['colorOverlay', { opacity: 30 }], ['gradientOverlay'], ['stroke']]);
              return doc;
          });
    C.add('fx-multi', ['effect:multi', 'effect:dropShadow', 'effect:stroke', 'effect:colorOverlay'], 'Multiple drop shadows and strokes (multi-instance effects, lmfx/lfx2 lists)', function () {
        var doc = styleTarget('fx-multi');
        C.setEffects([], { dropShadow: [{ color: [200, 0, 0], distance: 4, angle: 30 }, { color: [0, 0, 200], distance: 7, angle: 150 }],
                           stroke: [{ size: 2, color: [0, 0, 0] }, { size: 5, color: [255, 255, 255], position: 'InsF' }],
                           colorOverlay: [{ color: [255, 0, 0], opacity: 30 }] });
        return doc;
    });
    C.add('fx-disabled', ['effect:disabled', 'effect:stroke'], 'A disabled drop shadow next to an enabled stroke', function () {
        var doc = styleTarget('fx-dis');
        C.setEffects([['dropShadow', { enabled: false }], ['stroke']]);
        return doc;
    });
    C.add('fx-hidden', ['effect:hidden-all'], 'Effects present but hidden for the layer (layerFXVisible off)', function () {
        var doc = styleTarget('fx-hid');
        C.setEffects([['dropShadow'], ['stroke']]);
        PSO.hideEffects();
        return doc;
    });
    C.add('fx-group', ['effect:on-group', 'effect:stroke', 'effect:dropShadow', 'group'], 'Effects on a group (lfxs)', function () {
        var doc = C.newDoc('fx-group', 'RGB', 8);
        C.base();
        var a = C.ellipse('A', [10, 10, 40, 40], [250, 200, 0]);
        var b = C.rect('B', [24, 40, 54, 84], [0, 160, 250]);
        C.group('Styled group', [a, b], {});
        C.setEffects([['dropShadow'], ['stroke', { size: 2 }]]);
        return doc;
    });
    C.add('fx-cmyk', ['effect:dropShadow', 'effect:outerGlow', 'effect:stroke', 'mode:CMYK', 'depth:8'], 'Effects in a CMYK document', function () {
        var doc = C.newDoc('fx-cmyk', 'CMYK', 8);
        C.base();
        C.ellipse('Styled', [12, 18, 52, 78], [240, 200, 60]);
        C.setEffects([['dropShadow'], ['outerGlow'], ['stroke']]);
        return doc;
    });
    C.add('fx-rgb-16', ['effect:dropShadow', 'effect:bevelEmboss', 'effect:gradientOverlay', 'mode:RGB', 'depth:16'], 'Effects in a 16-bit document', function () {
        var doc = C.newDoc('fx-16', 'RGB', 16);
        C.base();
        C.ellipse('Styled', [12, 18, 52, 78], [240, 200, 60]);
        C.setEffects([['dropShadow'], ['bevelEmboss'], ['gradientOverlay']]);
        return doc;
    });

    // Fill vs opacity, knockout, blend-if, advanced blending
    C.add('fill-vs-opacity', ['fill-opacity', 'opacity', 'effect:dropShadow', 'effect:stroke'], 'Two styled layers: 40 % opacity vs 40 % fill', function () {
        var doc = C.newDoc('fillop', 'RGB', 8);
        C.base();
        C.ellipse('Opacity 40', [8, 4, 56, 46], [240, 60, 60]); C.setEffects([['dropShadow'], ['stroke', { size: 3 }]]); C.set({ opacity: 40 });
        C.ellipse('Fill 40', [8, 50, 56, 92], [240, 60, 60]); C.setEffects([['dropShadow'], ['stroke', { size: 3 }]]); C.set({ fill: 40 });
        return doc;
    });
    C.add('fill-special-modes', ['fill-opacity', 'blend:colorBurn', 'blend:linearDodge', 'blend:vividLight', 'blend:hardMix', 'blend:difference'],
          'The special-eight modes at 50 % fill (fill and opacity differ for them)', function () {
              var doc = C.newDoc('fillspec', 'RGB', 8, { width: 100 });
              C.base();
              var modes = ['colorBurn', 'linearDodge', 'vividLight', 'hardMix', 'difference'];
              for (var i = 0; i < modes.length; i++) {
                  C.rect(modes[i] + ' fill 50', [4, i * 20, 30, i * 20 + 18], [120, 180, 250]); C.set({ mode: modes[i], fill: 50 });
                  C.rect(modes[i] + ' opacity 50', [34, i * 20, 60, i * 20 + 18], [120, 180, 250]); C.set({ mode: modes[i], opacity: 50 });
              }
              return doc;
          });
    C.add('knockout-shallow', ['knockout:shallow', 'fill-opacity', 'group'], 'Shallow knockout layer (fill 0) in a group above a second layer', function () {
        var doc = C.newDoc('knock', 'RGB', 8);
        C.base();
        var a = C.rect('Group fill', [6, 6, 58, 90], [250, 230, 80]);
        var k = C.ellipse('Knockout', [12, 20, 52, 76], [0, 0, 0]);
        C.set({ fill: 0, knockout: 'shallow' });
        C.group('Knockout group', [a, k], {});
        return doc;
    });
    C.add('knockout-deep', ['knockout:deep', 'fill-opacity', 'group:nested'], 'Deep knockout through nested groups', function () {
        var doc = C.newDoc('knockd', 'RGB', 8);
        C.base();
        var a = C.rect('Outer fill', [4, 4, 60, 92], [60, 200, 250]);
        var outer = C.group('Outer', [a], {});
        var b = C.rect('Inner fill', [10, 10, 54, 86], [250, 120, 60]);
        var k = C.ellipse('Deep knockout', [16, 24, 48, 72], [0, 0, 0]);
        C.set({ fill: 0, knockout: 'deep' });
        C.group('Inner', [b, k], { parent: outer });
        return doc;
    });
    C.add('blendif-gray', ['blend-if', 'blend-if:gray', 'blend-if:split'], 'Blend If on the gray channel with split sliders (this layer and underlying)', function () {
        var doc = C.blendScene('bif', 'normal');
        C.set({ blendIf: [{ channel: 'Gry ', src: [30, 90, 170, 230], dst: [0, 60, 200, 255] }] });
        return doc;
    });
    C.add('blendif-channels', ['blend-if', 'blend-if:channels'], 'Blend If on the red and blue channels', function () {
        var doc = C.blendScene('bifc', 'normal');
        C.set({ blendIf: [{ channel: 'Gry ', src: [0, 0, 255, 255], dst: [0, 0, 255, 255] }, { channel: 'Rd  ', src: [40, 120, 255, 255], dst: [0, 0, 255, 255] },
                          { channel: 'Grn ', src: [0, 0, 255, 255], dst: [0, 0, 255, 255] }, { channel: 'Bl  ', src: [0, 0, 255, 255], dst: [0, 0, 150, 220] }] });
        return doc;
    });
    C.add('advanced-channels', ['advanced:channels', 'brst'], 'Advanced blending: red channel unchecked', function () {
        var doc = C.blendScene('advch', 'normal');
        C.set({ channels: ['Grn ', 'Bl  '] });
        return doc;
    });
    C.add('advanced-flags', ['advanced:blendInterior', 'advanced:transparencyShapes', 'advanced:layerMaskAsGlobal', 'mask:raster', 'effect:innerGlow'],
          'Blend Interior Effects as Group on, Transparency Shapes Layer off, Layer Mask Hides Effects on', function () {
              var doc = C.newDoc('advfl', 'RGB', 8);
              C.base();
              C.ellipse('Advanced', [8, 12, 56, 84], [250, 220, 40]);
              C.setEffects([['innerGlow'], ['colorOverlay', { opacity: 40 }]]);
              C.selRect(0, 0, 64, 60); C.maskFromSelection(); C.deselect();
              C.set({ fill: 50, blendInterior: true, transparencyShapesLayer: false, layerMaskAsGlobalMask: true });
              return doc;
          });

    // Text
    C.add('text-point', ['text:point'], 'Point text, Arial 20 pt', function () {
        var doc = C.newDoc('tpoint', 'RGB', 8); C.base(); C.pointText('Point text', 'Oracle 27', 6, 40, 20, [255, 255, 255]); return doc;
    });
    C.add('text-paragraph', ['text:paragraph'], 'Paragraph (box) text, centred, wrapping over three lines', function () {
        var doc = C.newDoc('tpara', 'RGB', 8, { height: 80 }); C.base();
        C.paragraphText('Paragraph text', 'Paragraph text wraps inside its box and is centred in it.', [6, 6, 74, 90], 11);
        return doc;
    });
    C.add('text-styled', ['text:point', 'text:styled-runs'], 'Point text with three style runs (size and colour)', function () {
        var doc = C.newDoc('tstyle', 'RGB', 8); C.base(); C.styledText('Styled text', [['Red ', 14, [220, 0, 0]], ['Big ', 22, [0, 0, 0]], ['blue', 12, [0, 60, 230]]], 4, 40); return doc;
    });
    C.add('text-warp', ['text:point', 'text:warp'], 'Point text with an Arc warp', function () {
        var doc = C.newDoc('twarp', 'RGB', 8); C.base();
        var L = C.pointText('Warped text', 'ARC WARP', 8, 40, 18, [0, 0, 0]);
        L.textItem.warpStyle = WarpStyle.ARC;
        L.textItem.warpBend = 40;
        return doc;
    });
    C.add('text-effects', ['text:point', 'effect:stroke', 'effect:dropShadow'], 'Point text with a stroke and drop shadow', function () {
        var doc = C.newDoc('tfx', 'RGB', 8); C.base(); C.pointText('Styled type', 'FX', 20, 50, 40, [255, 220, 0]);
        C.setEffects([['stroke', { size: 2 }], ['dropShadow']]);
        return doc;
    });
    C.add('text-vertical', ['text:point', 'text:vertical'], 'Vertical point text', function () {
        var doc = C.newDoc('tvert', 'RGB', 8, { width: 48, height: 96 }); C.base();
        var L = C.pointText('Vertical text', 'TOP', 24, 10, 16, [0, 0, 0]);
        L.textItem.direction = Direction.VERTICAL;
        return doc;
    });
    C.add('text-cmyk', ['text:point', 'mode:CMYK', 'depth:8'], 'Point text in a CMYK document', function () {
        var doc = C.newDoc('tcmyk', 'CMYK', 8); C.base(); C.pointText('CMYK text', 'CMYK', 6, 40, 22, [0, 0, 0]); return doc;
    });

    // Shapes
    C.add('shape-rect', ['shape', 'shape:rectangle', 'live-shape'], 'Live rectangle shape layer, solid fill', function () {
        var doc = C.newDoc('srect', 'RGB', 8); C.base(); C.shape('Rectangle', 'Rctn', C.box(10, 14, 50, 80), [30, 160, 90]); return doc;
    });
    C.add('shape-rounded-stroke', ['shape', 'shape:rounded-rectangle', 'shape:stroke', 'live-shape'], 'Rounded rectangle with a 4 px centred stroke', function () {
        var doc = C.newDoc('srnd', 'RGB', 8); C.base(); C.shape('Rounded', 'Rctn', C.box(10, 14, 50, 80, 9), [250, 250, 250], C.strokeStyle(4, [20, 20, 120])); return doc;
    });
    C.add('shape-ellipse-gradient', ['shape', 'shape:ellipse', 'shape:gradient-fill', 'live-shape'], 'Ellipse shape with a gradient fill', function () {
        var doc = C.newDoc('sell', 'RGB', 8); C.base(); C.shape('Ellipse', 'Elps', C.box(6, 20, 58, 76), null, null, 'gradient'); return doc;
    });
    C.add('shape-stroke-only', ['shape', 'shape:stroke', 'shape:no-fill', 'live-shape'], 'Ellipse shape, stroke only (fill disabled), outside alignment', function () {
        var doc = C.newDoc('sstr', 'RGB', 8); C.base();
        var ss = C.strokeStyle(3, [0, 0, 0], 'strokeStyleAlignOutside');
        ss.putBoolean(sTID('fillEnabled'), false);
        C.shape('Outline', 'Elps', C.box(10, 20, 54, 76), [255, 0, 0], ss);
        return doc;
    });
    C.add('shape-cmyk', ['shape', 'mode:CMYK', 'depth:8'], 'Shape layer in CMYK', function () {
        var doc = C.newDoc('scmyk', 'CMYK', 8); C.base(); C.shape('Rectangle', 'Rctn', C.box(10, 14, 50, 80, 6), [30, 160, 90]); return doc;
    });

    // Smart objects
    C.add('smart-object', ['smart-object:embedded'], 'Embedded smart object (converted pixel layer)', function () {
        var doc = C.newDoc('so', 'RGB', 8); C.base(); C.ellipse('Smart', [10, 14, 54, 82], [250, 80, 30]); C.toSmartObject(); return doc;
    });
    C.add('smart-object-transformed', ['smart-object:embedded', 'smart-object:transform'], 'Embedded smart object scaled 70 % × 55 % and rotated 20°', function () {
        var doc = C.newDoc('sot', 'RGB', 8); C.base(); C.rect('Smart', [10, 14, 54, 82], [30, 80, 250]); C.toSmartObject(); C.transform(70, 55, 20); return doc;
    });
    C.add('smart-filter-blur', ['smart-object:embedded', 'smart-filter:gaussianBlur', 'smart-filter:mask'], 'Smart object with a Gaussian Blur smart filter', function () {
        var doc = C.newDoc('sfblur', 'RGB', 8); C.base(); C.ellipse('Smart', [10, 14, 54, 82], [250, 80, 30]); C.toSmartObject(); C.filter.gaussianBlur(3); return doc;
    });
    C.add('smart-filter-stack', ['smart-object:embedded', 'smart-filter:unsharpMask', 'smart-filter:motionBlur', 'smart-filter:minimum', 'smart-filter:mask'],
          'Smart object with three smart filters', function () {
              var doc = C.newDoc('sfstack', 'RGB', 8); C.base(); C.rect('Smart', [12, 16, 52, 80], [250, 230, 40]); C.toSmartObject();
              C.filter.minimum(); C.filter.motionBlur(); C.filter.unsharpMask();
              return doc;
          });
    C.add('smart-filter-emboss-16', ['smart-object:embedded', 'smart-filter:emboss', 'mode:RGB', 'depth:16'], '16-bit smart object with an Emboss smart filter', function () {
        var doc = C.newDoc('sfemb', 'RGB', 16); C.base(); C.ellipse('Smart', [10, 14, 54, 82], [250, 80, 30]); C.toSmartObject(); C.filter.emboss(); return doc;
    });
    C.add('smart-object-nested', ['smart-object:embedded', 'smart-object:nested'], 'Smart object made from a group containing a smart object', function () {
        var doc = C.newDoc('sonest', 'RGB', 8); C.base();
        var a = C.ellipse('Inner', [10, 14, 54, 82], [250, 80, 30]); C.toSmartObject();
        var b = C.rect('Bar', [24, 0, 40, 96], [30, 90, 220]); C.set({ mode: 'multiply' });
        C.group('To convert', [doc.layers[1], doc.layers[0]], {});
        C.toSmartObject();
        return doc;
    });

    // Extra channels
    C.add('channels-alpha-spot', ['channel:alpha', 'channel:spot'], 'RGB with a saved-selection alpha channel and a spot colour channel', function () {
        var doc = C.newDoc('chan', 'RGB', 8); C.base();
        C.selEllipse(8, 16, 56, 80); C.alphaChannelFromSelection('Selection'); C.deselect();
        C.spotChannel('PSO Spot', [255, 0, 140], 40);
        return doc;
    });
    C.add('channels-spot-cmyk', ['channel:spot', 'mode:CMYK', 'depth:8'], 'CMYK with a spot channel', function () {
        var doc = C.newDoc('chancmyk', 'CMYK', 8); C.base(); C.spotChannel('PSO Spot', [0, 160, 80], 70); return doc;
    });

    // Hidden and locked
    C.add('hidden-and-locked', ['visibility:hidden', 'lock:transparency', 'lock:all'], 'A hidden layer, a transparency-locked layer and a fully locked layer', function () {
        var doc = C.newDoc('hid', 'RGB', 8); C.base();
        var h = C.ellipse('Hidden', [8, 8, 56, 56], [0, 0, 0]); h.visible = false;
        var t = C.rect('Locked transparency', [10, 40, 30, 90], [250, 250, 0]); t.transparentPixelsLocked = true;
        var a = C.rect('Locked all', [36, 40, 56, 90], [0, 250, 250]); a.allLocked = true;
        return doc;
    });

    // PSB
    C.add('psb-rgb-8-layers', ['format:psb', 'mode:RGB', 'depth:8', 'layers', 'mask:raster', 'text:point', 'group'], 'PSB: layers, a masked layer, text and a group', function () {
        var doc = C.newDoc('psb8', 'RGB', 8); C.base();
        var a = C.ellipse('Disc', [6, 6, 50, 50], [250, 120, 30]); C.set({ mode: 'multiply' });
        C.selRect(0, 0, 40, 96); C.maskFromSelection(); C.deselect();
        C.group('Group', [a], {});
        C.pointText('PSB text', 'PSB', 50, 50, 20, [255, 255, 255]);
        return doc;
    }, 'psb');
    C.add('psb-rgb-16-adjust', ['format:psb', 'mode:RGB', 'depth:16', 'adjustment:curves', 'adjustment:hueSaturation'], 'PSB 16-bit with adjustment layers', function () {
        var doc = C.newDoc('psb16', 'RGB', 16); C.base(); C.adjust.curves(); C.adjust.hueSaturation(); return doc;
    }, 'psb');
    C.add('psb-smart-filter', ['format:psb', 'smart-object:embedded', 'smart-filter:gaussianBlur'], 'PSB with a smart object and smart filter', function () {
        var doc = C.newDoc('psbso', 'RGB', 8); C.base(); C.ellipse('Smart', [10, 14, 54, 82], [250, 80, 30]); C.toSmartObject(); C.filter.gaussianBlur(2); return doc;
    }, 'psb');
    C.add('psb-cmyk-8', ['format:psb', 'mode:CMYK', 'depth:8', 'layers'], 'PSB CMYK with layers', function () {
        var doc = C.newDoc('psbcmyk', 'CMYK', 8); C.base(); C.ellipse('Disc', [6, 6, 50, 50], [250, 120, 30]); C.set({ opacity: 60 }); return doc;
    }, 'psb');
    C.add('psb-rgb-32', ['format:psb', 'mode:RGB', 'depth:32', 'layers'], 'PSB 32-bit with layers', function () {
        var doc = C.newDoc('psb32', 'RGB', 32); C.base(); C.ellipse('Disc', [6, 6, 50, 50], [250, 120, 30]); C.set({ opacity: 60 }); return doc;
    }, 'psb');

    // Combined
    // Photoshop's own artboards (C′: PCIO writes Pass Through on artboards and Photoshop reads them
    // back as Normal). Notes record mode, layerKind and artboardEnabled per layer as Photoshop
    // reports them.
    C.add('artboard-blend', ['artboard', 'group', 'group:pass-through', 'blend:multiply', 'mode:RGB', 'depth:8'],
          'Two artboards (default; blend set to Normal) and a Pass Through group outside them', function (notes) {
        // An artboard made from layers takes their bounds (the rect asked for, or a later
        // editArtboardEvent, lands offset), so "Red" and "Blue" fill their artboards exactly. An
        // artboard document's canvas is the bounding box of its content, so "Gray" spans the
        // bottom of the 300 × 200 canvas.
        var doc = C.newDoc('artboard-blend', 'RGB', 8, { width: 300, height: 200, transparent: true });
        C.rect('Gray', [120, 0, 200, 300], [150, 150, 150]);
        doc.layers.getByName('Layer 1').remove();
        C.rect('Blue', [0, 150, 100, 250], [40, 80, 220]);
        C.rect('Red', [0, 0, 100, 100], [220, 30, 30]);
        C.rect('Mul', [40, 40, 95, 95], [90, 160, 255]);
        C.set({ mode: 'multiply' });
        C.selectLayers(['Red', 'Mul']);
        C.artboardFromSelected('Artboard 1', [0, 0, 100, 100]);
        C.selectLayers(['Blue']);
        C.artboardFromSelected('Artboard 2', [150, 0, 250, 100]);
        C.selectLayers(['Artboard 2']);
        try { C.set({ mode: 'normal' }); } catch (e) { notes.push('Artboard 2: blend Normal refused (' + C.shortError(e) + ')'); }
        C.selectLayers(['Gray']);
        C.group('Group', [doc.activeLayer], {});
        notes.push('canvas ' + doc.width.as('px') + ' x ' + doc.height.as('px'));
        var st = C.layerStates();
        for (var i = 0; i < st.length; i++) notes.push('layer ' + PSO.json(st[i]));
        return doc;
    });
    C.add('combined-kitchen-sink', ['combined', 'group', 'group:pass-through', 'clipping', 'mask:raster', 'mask:vector', 'adjustment:curves', 'adjustment:hueSaturation',
                                    'effect:dropShadow', 'effect:stroke', 'text:point', 'shape', 'smart-object:embedded', 'smart-filter:gaussianBlur', 'fill:gradient', 'blend:multiply', 'blend:overlay'],
          'Everything together in RGB 8-bit', function () {
              var doc = C.newDoc('sink', 'RGB', 8, { width: 128, height: 96 });
              C.base();
              var g1 = C.gradientLayer('Gradient fill', [[0, 255, 255, 255], [4096, 0, 0, 0]], [[0, 0], [4096, 60]], 90); C.set({ mode: 'overlay' });
              var e = C.ellipse('Clip base', [8, 8, 60, 60], [240, 240, 240]);
              C.setEffects([['dropShadow'], ['stroke', { size: 2 }]]);
              C.ramp('Clipped ramp', C.rainbow, null, 135); C.clip();
              var s = C.shape('Shape', 'Rctn', C.box(50, 60, 90, 120, 6), [40, 90, 200]); C.set({ mode: 'multiply' });
              var so = C.ellipse('Smart', [30, 70, 80, 120], [250, 60, 60]); C.toSmartObject(); C.filter.gaussianBlur(2);
              so = doc.activeLayer;
              C.selRect(30, 70, 80, 100); C.maskFromSelection(); C.deselect();
              C.group('Pass group', [so], { blendMode: BlendMode.PASSTHROUGH });
              C.adjust.curves();
              var hs = C.adjust.hueSaturation(); C.selEllipse(0, 64, 64, 128); C.vectorMaskFromSelection(); C.deselect();
              C.pointText('Title', 'Oracle', 6, 90, 16, [255, 255, 255]);
              return doc;
          });
    C.add('combined-cmyk', ['combined', 'mode:CMYK', 'depth:8', 'mask:raster', 'adjustment:levels', 'effect:dropShadow', 'text:point', 'group', 'clipping'], 'Combined features in CMYK 8-bit', function () {
        var doc = C.newDoc('sinkcmyk', 'CMYK', 8); C.base();
        var a = C.ellipse('Disc', [6, 6, 58, 58], [250, 120, 30]); C.setEffects([['dropShadow']]);
        var cl = C.rect('Clipped', [0, 30, 64, 70], [0, 160, 220]); C.set({ mode: 'multiply' }); C.clip();
        C.group('Group', [a, cl], {});
        // Moving a clipped layer into a group ahead of its base releases the clip: clip it again.
        doc.activeLayer = cl;
        if (!cl.grouped) C.clip();
        C.selRect(0, 48, 64, 96); C.adjust.levels(); C.deselect();
        C.pointText('CMYK', 'CMYK', 50, 58, 14, [255, 255, 255]);
        return doc;
    });
    C.add('combined-rgb-16', ['combined', 'mode:RGB', 'depth:16', 'mask:raster', 'adjustment:levels', 'effect:stroke', 'blend:softLight', 'clipping'], 'Combined features in RGB 16-bit', function () {
        var doc = C.newDoc('sink16', 'RGB', 16); C.base();
        C.ellipse('Disc', [6, 6, 58, 58], [250, 120, 30]); C.set({ mode: 'softLight' }); C.setEffects([['stroke']]);
        C.selEllipse(0, 0, 40, 40); C.featherSelection(4); C.maskFromSelection(); C.deselect();
        C.rect('Clipped', [0, 30, 64, 70], [0, 160, 220]); C.clip();
        C.adjust.levels();
        return doc;
    });
    C.add('combined-rgb-32', ['combined', 'mode:RGB', 'depth:32', 'adjustment:exposure', 'smart-object:embedded', 'mask:raster'], 'Combined features in RGB 32-bit', function () {
        var doc = C.newDoc('sink32', 'RGB', 32); C.base();
        C.ellipse('Disc', [6, 6, 58, 58], [250, 120, 30]); C.set({ opacity: 70 });
        C.selRect(0, 0, 64, 50); C.maskFromSelection(); C.deselect();
        C.rect('Smart', [20, 40, 60, 90], [30, 200, 90]); C.toSmartObject();
        C.adjust.exposure();
        return doc;
    });
})();

PSO.main(function () {
    if (ARGS.op === 'list') {
        var items = [];
        for (var i = 0; i < C.items.length; i++) items.push({ name: C.items[i].name, ext: C.items[i].ext, features: C.items[i].features, description: C.items[i].description });
        return { ok: true, items: items };
    }
    if (ARGS.op === 'build') {
        var item = null;
        for (var j = 0; j < C.items.length; j++) if (C.items[j].name === ARGS.name) item = C.items[j];
        if (!item) return { ok: false, error: 'no corpus item ' + ARGS.name };
        PSO.checkPath(ARGS.out);
        var notes = [], doc = null, before = app.documents.length;
        try {
            doc = item.build(notes);
            C.save(doc, ARGS.out, item.ext);
            return { ok: true, notes: notes, file: ARGS.out, compositeFormat: PSO.compositeFormat(doc), maximizeCompatibility: true, mode: PSO.modeName(doc.mode), bits: PSO.bits(doc.bitsPerChannel) };
        } finally {
            PSO.close(doc);
            // Anything else the builder left open (only our untitled pso_ documents).
            for (var k = app.documents.length - 1; k >= 0 && app.documents.length > before; k--) {
                var d = app.documents[k], p = null;
                try { p = d.fullName.fsName; } catch (e) {}
                if (!p && String(d.name).indexOf('pso_') === 0) PSO.close(d);
            }
        }
    }
    return { ok: false, error: 'unknown op ' + ARGS.op };
});
