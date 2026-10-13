// ping: is Photoshop answering scripts? Reports the version and how many documents are open.
PSO.main(function () {
    var docs = [];
    for (var i = 0; i < app.documents.length; i++) {
        var d = app.documents[i], p = null;
        try { p = d.fullName.fsName; } catch (e) {}
        docs.push({ name: d.name, path: p });
    }
    return { ok: true, version: app.version, documents: docs };
});
