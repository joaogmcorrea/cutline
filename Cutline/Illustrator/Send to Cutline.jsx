/*
    Send to Cutline, a script for Adobe Illustrator.

    Sends the selection to Cutline in one click. With nothing selected, it sends the active artboard.
    Cutline opens it as a new document: the artboard keeps its size and the artwork keeps its place on it.
    As with File > Import and Paste in Cutline, a stroke becomes a cut line and a fill without a stroke only prints.

    Your document is never changed: the script copies the artwork into a new document, converts the text
    to outlines there, saves that copy as a PDF in the temporary folder and opens it in Cutline (which then
    deletes it). Images go in the PDF too.

    Install: in Cutline, choose Help > Install Illustrator Script..., or copy this file to
    /Applications/Adobe Illustrator <year>/Presets/<language>/Scripts/ and restart Illustrator.
    Then choose File > Scripts > Send to Cutline. To run it from anywhere: File > Scripts > Other Script...

    Cutline: https://cutline.joaocorrea.design
    Copyright (C) 2026 Joao Correa. License: GPL-2.0 (https://github.com/joaogmcorrea/cutline).
*/
#target illustrator

(function () {
    // The file type Cutline declares and opens (Cutline-Info.plist): a PDF under a name of its own, so that
    // File.execute() opens it in Cutline and not in the PDF app.
    var EXTENSION = "cutlinesend";
    var TITLE = "Send to Cutline";

    var TEXT = {
        noDocument: {
            en: "Open a document in Illustrator first.",
            pt: "Abra um documento no Illustrator primeiro.",
            es: "Abre primero un documento en Illustrator."
        },
        emptyArtboard: {
            en: "The active artboard is empty. Select something, or pick an artboard with artwork.",
            pt: "A prancheta ativa est\u00e1 vazia. Selecione algo ou escolha uma prancheta com arte.",
            es: "La mesa de trabajo activa est\u00e1 vac\u00eda. Selecciona algo o elige una mesa de trabajo con arte."
        },
        noCutline: {
            en: "Cutline didn\u2019t open. Install the latest version from cutline.joaocorrea.design and try again.",
            pt: "O Cutline n\u00e3o abriu. Instale a vers\u00e3o mais recente em cutline.joaocorrea.design e tente de novo.",
            es: "Cutline no se abri\u00f3. Instala la versi\u00f3n m\u00e1s reciente desde cutline.joaocorrea.design y vuelve a intentarlo."
        },
        failed: {
            en: "Couldn\u2019t send to Cutline: %1",
            pt: "N\u00e3o deu para enviar para o Cutline: %1",
            es: "No se pudo enviar a Cutline: %1"
        }
    };

    /// Illustrator's language (English, Portuguese or Spanish, as Cutline).
    var language = (function () {
        var code = String(app.locale || $.locale || "en").substr(0, 2).toLowerCase();
        return code === "pt" || code === "es" ? code : "en";
    })();

    function say(key, detail) {
        alert(TEXT[key][language].replace("%1", detail || ""), TITLE);
    }

    // MARK: What goes

    /// A key for an item, to skip the ones already on the list (uuid exists from Illustrator 2020 on).
    function keyOf(item) {
        try { return item.uuid ? "u" + item.uuid : null; } catch (e) { return null; }
    }

    /// The selected items, top first. A path of a compound path goes as the whole compound path (with its holes), an
    /// item inside a selected group goes with the group, and while typing, the text being edited goes.
    function selectedItems(doc) {
        var selection = doc.selection, list = [], seen = {};
        if (!selection) return list;
        if (selection.typename === "TextRange") {
            try {
                var frames = selection.story.textFrames;
                for (var f = 0; f < frames.length; f++) list.push(frames[f]);
            } catch (e) {}
            return list;
        }
        for (var i = 0; i < selection.length; i++) {
            var item = selection[i];
            if (item.parent && item.parent.typename === "CompoundPathItem") item = item.parent;
            var key = keyOf(item);
            if (key) {
                if (seen[key]) continue;
                seen[key] = true;
            }
            list.push(item);
        }
        var kept = [];
        for (var j = 0; j < list.length; j++) {
            if (!insideOneOf(list[j], seen)) kept.push(list[j]);
        }
        return kept;
    }

    function insideOneOf(item, keys) {
        var parent = item.parent;
        while (parent && parent.typename !== "Layer" && parent.typename !== "Document") {
            var key = keyOf(parent);
            if (key && keys[key]) return true;
            parent = parent.parent;
        }
        return false;
    }

    /// Everything visible on the artboard (locked items too, and the layers that don't print: a cut line often sits
    /// on one), top first across layers and sublayers.
    function itemsOn(doc, rect) {
        var found = [];
        function walk(layer) {
            if (!layer.visible) return;
            for (var i = 0; i < layer.pageItems.length; i++) {
                var item = layer.pageItems[i];
                if (item.hidden) continue;
                if (item.typename === "PathItem" && item.guides) continue;
                if (!overlaps(item.visibleBounds, rect)) continue;
                var z = 0;
                try { z = item.absoluteZOrderPosition; } catch (e) {}
                found.push({ item: item, z: z, order: found.length });
            }
            for (var j = 0; j < layer.layers.length; j++) walk(layer.layers[j]);
        }
        for (var k = 0; k < doc.layers.length; k++) walk(doc.layers[k]);
        found.sort(function (a, b) { return b.z - a.z || a.order - b.order; });
        var items = [];
        for (var n = 0; n < found.length; n++) items.push(found[n].item);
        return items;
    }

    /// Bounds and rectangles are [left, top, right, bottom], with y going up.
    function overlaps(bounds, rect) {
        return bounds[0] < rect[2] && bounds[2] > rect[0] && bounds[3] < rect[1] && bounds[1] > rect[3];
    }

    /// The artboard under the middle of the selection; the active one if none is.
    function artboardFor(doc, items) {
        var b = items[0].visibleBounds, left = b[0], top = b[1], right = b[2], bottom = b[3];
        for (var i = 1; i < items.length; i++) {
            b = items[i].visibleBounds;
            left = Math.min(left, b[0]); top = Math.max(top, b[1]);
            right = Math.max(right, b[2]); bottom = Math.min(bottom, b[3]);
        }
        var x = (left + right) / 2, y = (top + bottom) / 2;
        for (var a = 0; a < doc.artboards.length; a++) {
            var r = doc.artboards[a].artboardRect;
            if (x >= r[0] && x <= r[2] && y <= r[1] && y >= r[3]) return doc.artboards[a];
        }
        return doc.artboards[doc.artboards.getActiveArtboardIndex()];
    }

    // MARK: The copy

    /// The document's name without the extension: the name of the document in Cutline.
    function titleOf(doc) {
        var name = String(doc.name).replace(/\.(ai|ait|pdf|eps|svg|svgz)$/i, "");
        // ExtendScript reads %xx in file names as an encoded character.
        name = name.replace(/[\/:\\%]/g, "-").replace(/^\.+/, "");
        return name || "Illustrator";
    }

    /// Symbols become plain artwork (their text too) and text becomes outlines: Cutline doesn't read text from a PDF.
    function flattenText(copy) {
        for (var round = 0; round < 10 && copy.symbolItems.length > 0; round++) {
            for (var s = copy.symbolItems.length - 1; s >= 0; s--) {
                try { copy.symbolItems[s].breakLink(); } catch (e) {}
            }
        }
        for (var t = copy.textFrames.length - 1; t >= 0; t--) {
            var frame = copy.textFrames[t];
            try {
                frame.locked = false;
                if (frame.hidden) frame.remove();
                else frame.createOutline();
            } catch (e) {}
        }
    }

    /// The PDF: the artwork as it is (colors untouched, live transparency), the images without loss, nothing else.
    function pdfOptions() {
        var options = new PDFSaveOptions();
        options.compatibility = PDFCompatibility.ACROBAT7;
        options.preserveEditability = false;
        options.generateThumbnails = false;
        options.optimization = false;
        options.viewAfterSaving = false;
        options.acrobatLayers = false;
        options.artboardRange = "1";
        options.colorConversionID = ColorConversion.None;
        options.colorDownsamplingMethod = DownsampleMethod.NODOWNSAMPLE;
        options.grayscaleDownsamplingMethod = DownsampleMethod.NODOWNSAMPLE;
        options.monochromeDownsamplingMethod = DownsampleMethod.NODOWNSAMPLE;
        options.colorCompression = CompressionQuality.ZIP8BIT;
        options.grayscaleCompression = CompressionQuality.ZIP8BIT;
        options.monochromeCompression = MonochromeCompression.MONOZIP;
        options.trimMarks = false;
        options.registrationMarks = false;
        options.colorBars = false;
        options.pageInformation = false;
        options.bleedOffsetRect = [0, 0, 0, 0];
        return options;
    }

    /// Copies the items into a new document the size of the artboard, at the same place on it, and saves the copy
    /// as a PDF in a folder of its own in the temporary folder. Returns that file, named for Cutline.
    function exportCopy(doc, items, rect) {
        var title = titleOf(doc);
        var folder = new Folder(Folder.temp.fsName + "/Send to Cutline " + new Date().getTime());
        if (!folder.create()) throw new Error(folder.error || folder.fsName);
        var pdf = new File(folder.fsName + "/" + title + ".pdf");

        var level = app.userInteractionLevel, coordinates = app.coordinateSystem;
        app.userInteractionLevel = UserInteractionLevel.DONTDISPLAYALERTS;
        app.coordinateSystem = CoordinateSystem.DOCUMENTCOORDINATESYSTEM;
        var copy = null;
        try {
            var width = rect[2] - rect[0], height = rect[1] - rect[3];
            copy = app.documents.add(doc.documentColorSpace, width, height);
            // Into the layer: a duplicate into a group of another document fails ("PARM").
            var copies = [];
            for (var i = 0; i < items.length; i++) copies.push(items[i].duplicate(copy.layers[0], ElementPlacement.PLACEATEND));
            // The copies keep the original's coordinates, which may not be the copy's: move them so the 1st sits on
            // the copy's artboard where the original sits on its own.
            var page = copy.artboards[0].artboardRect;
            var original = items[0].geometricBounds, copied = copies[0].geometricBounds;
            var dx = page[0] + (original[0] - rect[0]) - copied[0];
            var dy = page[1] + (original[1] - rect[1]) - copied[1];
            for (var c = 0; c < copies.length; c++) {
                copies[c].locked = false;
                if (dx !== 0 || dy !== 0) copies[c].translate(dx, dy, true, true, true, true);
            }
            flattenText(copy);
            copy.saveAs(pdf, pdfOptions());
        } finally {
            if (copy) copy.close(SaveOptions.DONOTSAVECHANGES);
            try { doc.activate(); } catch (e) {}
            app.userInteractionLevel = level;
            app.coordinateSystem = coordinates;
        }

        var sent = new File(folder.fsName + "/" + title + "." + EXTENSION);
        if (sent.exists) sent.remove();
        if (!pdf.rename(sent.name)) throw new Error(pdf.error || pdf.fsName);
        return sent;
    }

    // MARK: Send

    function send() {
        if (app.documents.length === 0) return say("noDocument");
        var doc = app.activeDocument;
        var items = selectedItems(doc), artboard;
        if (items.length > 0) {
            artboard = artboardFor(doc, items);
        } else {
            artboard = doc.artboards[doc.artboards.getActiveArtboardIndex()];
            items = itemsOn(doc, artboard.artboardRect);
            if (items.length === 0) return say("emptyArtboard");
        }
        var file = exportCopy(doc, items, artboard.artboardRect);
        // Opens the file in the app that owns its type: Cutline, wherever it's installed.
        if (!file.execute()) say("noCutline");
    }

    try {
        send();
    } catch (error) {
        say("failed", error.message || String(error));
    }
})();
