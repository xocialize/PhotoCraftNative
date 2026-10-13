// cleanup: closes, without saving, only the documents ps-oracle owns — files under the allowed
// roots and untitled documents whose name starts with "pso_". Everything else is left alone.
PSO.main(function () {
    var closed = [], kept = [];
    for (var i = app.documents.length - 1; i >= 0; i--) {
        var d = app.documents[i], p = null, ours = false;
        try { p = d.fullName.fsName; } catch (e) {}
        if (p) {
            var roots = ARGS.allowedRoots || [];
            for (var k = 0; k < roots.length; k++) if (p.indexOf(roots[k]) === 0) ours = true;
        } else if (String(d.name).indexOf('pso_') === 0) ours = true;
        if (ours) { closed.push(d.name); PSO.close(d); } else kept.push(d.name);
    }
    return { ok: true, closed: closed, kept: kept };
});
