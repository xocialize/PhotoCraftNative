// info: opens ARGS.path, reports the document and its full layer tree, closes it.
PSO.main(function () {
    var doc;
    try { doc = PSO.open(ARGS.path); } catch (e) { var o = PSO.errorObject(e); o.opened = false; return o; }
    try {
        var info = PSO.docInfo(doc);
        info.ok = true;
        info.opened = true;
        info.file = ARGS.path;
        return info;
    } finally { PSO.close(doc); }
});
