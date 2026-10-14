# CameraRawFit — fitting PCAlgo's Camera Raw sliders to Photoshop's (AB-T-0241)

PCAlgo's Camera Raw white balance, Exposure, Contrast, Highlights, Shadows, Whites, Blacks, Saturation, Vibrance,
parametric curve, Color Mixer, Calibration and Color Grading are Photoshop's Camera Raw Filter's behaviour, fitted
(AB-D-0139): `Packages/PCAlgo/Sources/PCAlgo/Tone/CameraRawModel.swift` is the model, `CameraRawModel.json` its fitted
parameters. This folder is how the parameters were made and measured, so they can be refitted or checked.

**No Photoshop data lives here** (AB-D-0130). The fitting reference was Compositor's Photoshop-captured Camera Raw
tables (763 tables of a 17³ grid, one slider at one stop each), which PixelAgencyEditor dropped; take a copy from its
history and point `CRFIT_TABLES` at it:

```bash
git -C ../PixelAgencyEditor show 4e33e99:Sources/PixelAgencyEditorKit/Resources/CameraRawTables.bin > /tmp/CameraRawTables.bin
```

## The model

Each slider stop is one stage on linear ProPhoto RGB (sRGB in and out, clipped to sRGB, as the tables were captured):
a 3×3 matrix, a grey curve per channel, a hue map (hue shift, saturation and value scales at 24 hues weighted by
saturation, the DNG HueSatMap's form), a tone stage (one grey curve through the DNG SDK's hue-preserving RGB tone, per
channel and as a luminance gain with a saturation exponent, mixed) and a tint keyed by lightness. Each family uses the
blocks `fit.py`'s `BLOCKS` names, or the ones its refit gave it (below); CameraRawModel.json records them.
Between stops a slider blends the two stops' results; Temperature/Tint and the adaptive Contrast, Highlights and
Shadows blend four (the adaptive ones by the picture's brightness, `CameraRawStatistics`).

What the fitting found about Photoshop: its Camera Raw works in linear ProPhoto; Exposure, Contrast, Whites and the
parametric curve follow the hue-preserving RGB tone; Highlights and Shadows act on luminance (they are local in
Photoshop, so a per-pixel model is an approximation); Color Grading's luminance sliders are per channel. Saturated
colours near the sRGB gamut's edge are where every slider's error concentrates (AB-L-0271 found the same).

## Running it

Python 3 with numpy and scipy (a venv is fine), and the harness built at the repository root:

```bash
swift build -c release --product cr-measure
cd Tools/CameraRawFit/fit
export CRFIT_TABLES=/tmp/CameraRawTables.bin CRFIT_WORK=$PWD/work
python measure.py before        # the gap per slider, PCAlgo as built vs the tables
python fit.py                   # first pass, every stop (work/fit.json; resumable, PROCS=8 by default)
python refit.py wb matrix,curves,hue            # second pass: full grid, near-neutrals weighted up
python refit.py calibration matrix,curves,hue
python refit.py saturation chroma,hue,tone 1.8 && python refit.py vibrance hue,tone
python export.py ../../../Packages/PCAlgo/Sources/PCAlgo/Tone/CameraRawModel.json
swift build -c release --product cr-measure && python measure.py after
```

The first pass fits the many-parameter families (white balance, Saturation, Vibrance, Color Grading) on a 1,500-colour
subsample of the grid, for time; the second pass refits the ones that needed it on the whole grid, with greys weighted
three times (they are most of a photograph, and the first pass let white balance's greys drift by up to 90 levels).
White balance and Calibration needed a grey curve per channel (Photoshop's Temperature lifts red, green and blue along
different curves), and Saturation a plain chroma scale under its hue map (Photoshop's +100 nearly doubles a dull
colour's chroma in linear light), which is why their blocks changed between the passes.

`stage.py` is the model in Python, the reference `CameraRawModel.swift` follows; `grid.py` lists every table stop with
its slider settings and, for the adaptive sliders, the grid-on-background picture (4×4 patches 20 px apart on a grey
solved so the picture's brightness is the table's).

Receipts: AB-R-0532 (the gap before fitting) and AB-R-0538 (after).
