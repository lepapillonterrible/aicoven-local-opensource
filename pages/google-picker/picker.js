// AICoven Local's Google Drive picker page.
//
// The app opens this page in the system's browser (where the person is
// signed in to Google, which Google allows nowhere else) with what the
// Picker needs in the fragment, which the browser never sends to a server:
//
//   #token=<Google access token>&app_id=<Cloud project number>&state=<random>
//
// The page shows Google's Picker and gives the app the files chosen, by
// sending the browser to aicoven-local://google-picker, which the app's
// browser session takes:
//
//   ?state=<the same>&status=picked&files=<base64url of [{id,name,mimeType}]>
//   ?state=<the same>&status=cancel
//
// Nothing is stored and nothing is sent anywhere but to Google and back to
// the app. The token is dropped from the address as soon as it is read.
(function () {
    "use strict";

    var CALLBACK = "aicoven-local://google-picker";
    var MOST_FILES = 25;
    var LONGEST_NAME = 200;

    var spinner = document.getElementById("spinner");
    var title = document.getElementById("title");
    var detail = document.getElementById("detail");
    var again = document.getElementById("again");
    var back = document.getElementById("back");

    function show(heading, words, options) {
        options = options || {};
        spinner.hidden = !options.working;
        title.textContent = heading;
        detail.textContent = words;
        detail.className = options.problem ? "problem" : "";
        again.hidden = !options.again;
        if (options.back) {
            back.href = options.back;
            back.hidden = false;
        } else {
            back.hidden = true;
            back.removeAttribute("href");
        }
    }

    // Read once, then take the fragment out of the address and the history.
    var params = new URLSearchParams(window.location.hash.slice(1));
    if (window.location.hash) {
        window.history.replaceState(null, "", window.location.pathname);
    }
    var token = params.get("token") || "";
    var appId = params.get("app_id") || "";
    var state = params.get("state") || "";

    var tokenReads = token.length > 0 && token.length <= 4096 && /^[\x21-\x7e]+$/.test(token);
    var appIdReads = /^[0-9]{1,20}$/.test(appId);
    var stateReads = /^[A-Za-z0-9_-]{16,128}$/.test(state);

    if (!stateReads) {
        show("This page is opened by AICoven Local",
            "Choose Browse beside Google in AICoven Local's Connected Apps.",
            { problem: true });
        return;
    }

    function answer(query) {
        return CALLBACK + "?state=" + encodeURIComponent(state) + "&" + query;
    }

    function finish(query, heading, words) {
        var url = answer(query);
        show(heading, words, { back: url });
        window.location.replace(url);
    }

    if (!tokenReads || !appIdReads) {
        show("Google Drive couldn't open",
            "AICoven Local didn't send what Google needs. Close this page and try again.",
            { problem: true, back: answer("status=error") });
        return;
    }

    function base64url(text) {
        var bytes = new TextEncoder().encode(text);
        var binary = "";
        for (var i = 0; i < bytes.length; i++) binary += String.fromCharCode(bytes[i]);
        return btoa(binary).replace(/\+/g, "-").replace(/\//g, "_").replace(/=+$/, "");
    }

    var picker = null;

    function picked(data) {
        var google = window.google;
        if (data.action === google.picker.Action.PICKED) {
            var files = (data.docs || []).slice(0, MOST_FILES).map(function (doc) {
                return {
                    id: String(doc.id || ""),
                    name: String(doc.name || "").slice(0, LONGEST_NAME),
                    mimeType: String(doc.mimeType || "")
                };
            }).filter(function (file) { return file.id.length > 0; });
            if (files.length === 0) {
                finish("status=cancel", "Nothing chosen", "You can return to AICoven Local.");
                return;
            }
            finish("status=picked&files=" + base64url(JSON.stringify(files)),
                files.length === 1 ? "1 item chosen" : files.length + " items chosen",
                "Returning to AICoven Local…");
        } else if (data.action === google.picker.Action.CANCEL) {
            finish("status=cancel", "Nothing chosen", "You can return to AICoven Local.");
        }
    }

    function build() {
        try {
            var google = window.google;
            // One view of Drive, its folders shown and chosen like files.
            var files = new google.picker.DocsView(google.picker.ViewId.DOCS)
                .setIncludeFolders(true)
                .setSelectFolderEnabled(true)
                .setMode(google.picker.DocsViewMode.LIST);
            picker = new google.picker.PickerBuilder()
                .setAppId(appId)
                .setOAuthToken(token)
                .addView(files)
                .enableFeature(google.picker.Feature.MULTISELECT_ENABLED)
                .setMaxItems(MOST_FILES)
                .setTitle("Choose files or folders for AICoven Local")
                .setCallback(picked)
                .build();
            show("Choose files or folders in Google Drive",
                "AICoven Local's agents can open only what you choose here, and what AICoven Local made. A folder you choose is theirs to find and put files in; the files already in it are not.",
                { again: true });
            picker.setVisible(true);
        } catch (error) {
            show("Google Drive couldn't open",
                "Google's picker didn't start. Close this page and try again.",
                { problem: true, back: answer("status=error") });
        }
    }

    again.addEventListener("click", function () {
        if (picker) picker.setVisible(true);
    });

    var script = document.createElement("script");
    script.src = "https://apis.google.com/js/api.js";
    script.onload = function () {
        window.gapi.load("picker", { callback: build });
    };
    script.onerror = function () {
        show("Google Drive couldn't open",
            "Google's picker couldn't be loaded. Check the connection, then try again.",
            { problem: true, back: answer("status=error") });
    };
    document.body.appendChild(script);
})();
