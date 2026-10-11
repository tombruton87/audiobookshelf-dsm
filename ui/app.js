// Audiobookshelf's tabs on the chassis window: Libraries, Phones, Users, and the newer-release part of Updates.
(function (P) {
  "use strict";
  var $ = function (id) { return document.getElementById(id); };
  function absUrl(st) { return ((st.app || {}).url || "").replace(/\/$/, ""); }
  function n(v) { return (v || 0).toLocaleString(); }
  function keyNote(a) {
    var k = $("lb-key"); k.hidden = a.key_ok !== false;
    k.textContent = "The package's key for Audiobookshelf isn't working (it may have been removed or turned off in Audiobookshelf → Settings → API Keys). The package makes itself a new one within ten minutes; until then, libraries and users can't be changed here.";
  }

  // ---------------------------------------------------------------- Libraries
  var STATE = { there: "", waiting: "isn't there yet — Audiobookshelf sees it as empty until it is", outside: "not one of the package's shared folders" };
  P.register("libraries", {
    render: function (st) {
      var a = st.app || {}, libs = a.libraries || [], t = $("lb-tiles"), books = 0, pods = 0, eps = 0, hours = 0;
      document.querySelectorAll(".abs-link").forEach(function (x) { x.href = absUrl(st) || "#"; });
      keyNote(a);
      libs.forEach(function (l) { if (l.type === "podcast") { pods += l.items || 0; eps += l.files || 0; } else books += l.items || 0; hours += l.hours || 0; });
      P.clear(t); P.tile(t, n(books), books === 1 ? "audiobook" : "audiobooks"); P.tile(t, n(pods), pods === 1 ? "podcast" : "podcasts"); P.tile(t, n(eps), "episodes"); P.tile(t, n(Math.round(hours)), "hours to listen to");
      var free = a.free || {};
      $("la-free").textContent = "Places left: " + (free.book == null ? "–" : free.book) + " for audiobook folders, " + (free.podcast == null ? "–" : free.podcast) + " for podcast folders (a folder inside one already in use needs no place of its own).";
      var tb = $("lb-list"), sig = JSON.stringify(libs) + "|" + P.busy + "|" + P.role; if (tb.dataset.sig === sig) return; tb.dataset.sig = sig; P.clear(tb);
      if (!libs.length) { var r0 = P.el("tr"), c0 = P.cell("No libraries yet. Add one below: a shared folder with your audiobooks or podcasts.", "empty"); c0.colSpan = 5; r0.appendChild(c0); tb.appendChild(r0); }
      libs.forEach(function (l) {
        var who = P.el("div"), acts = P.el("span", null, "row nowrap");
        who.appendChild(P.el("b", l.name)); who.appendChild(P.el("div", (l.type === "podcast" ? "podcasts" : "audiobooks") + " · " + n(l.files) + " files" + (l.hours ? " · " + n(Math.round(l.hours)) + " h" : ""), "muted small"));
        (l.folders || []).forEach(function (f) { var d = P.el("div", f.path, "lib-folders"); if (STATE[f.state]) { d.appendChild(document.createTextNode(" ")); d.appendChild(P.chip(STATE[f.state], f.state === "waiting" ? "warn" : "")); } who.appendChild(d); });
        acts.appendChild(P.btn("Scan", "", function () { P.act("scan", { id: l.id, full: 0 }); }));
        acts.appendChild(P.btn("Read again", "", function () { P.act("scan", { id: l.id, full: 1 }, "Read every file in " + l.name + " again? On a big library this takes a while; a scan already finds new and changed files."); }));
        acts.appendChild(P.btn("Remove", "danger", function () { P.act("libdel", { id: l.id }, "Remove the library " + l.name + " from Audiobookshelf?\n\nThe files in the folder stay as they are, but listening progress, bookmarks and collections for its " + (l.type === "podcast" ? "podcasts" : "books") + " go with it."); }));
        P.row(tb, [P.cell(who, "lib-who"), P.cell(l.scanning ? P.chip("scanning", "warn") : n(l.items), "n"), P.cell(P.bytes(l.size || 0), "n"), P.cell(l.last_scan ? P.ago(l.last_scan) : "never", "nw"), P.cell(acts, "n")]);
      });
    },
    tiles: function (t, st) {
      var libs = (st.app || {}).libraries || [], books = 0, pods = 0;
      libs.forEach(function (l) { if (l.type === "podcast") pods += l.items || 0; else books += l.items || 0; });
      P.tile(t, n(books), books === 1 ? "audiobook" : "audiobooks"); if (pods) P.tile(t, n(pods), pods === 1 ? "podcast" : "podcasts");
    }
  });
  $("lb-scan-all").onclick = function () { P.act("scan", { full: 0 }); };
  $("la-type").addEventListener("change", function () { var pod = $("la-type").value === "podcast"; $("la-dir").placeholder = pod ? "/volume1/podcasts" : "/volume1/audiobooks"; $("la-name").placeholder = pod ? "Podcasts" : "Audiobooks"; });
  $("la-add").onclick = function () {
    var name = $("la-name").value.trim() || $("la-name").placeholder, dir = $("la-dir").value.trim(), pod = $("la-type").value === "podcast";
    P.act("libadd", { name: name, type: $("la-type").value, dir: dir }, "Add " + name + ", reading " + dir + (pod ? " (writable, for new episodes)" : " (read-only)") + "? Audiobookshelf restarts for a moment if the folder is new to it.")
      .then(function () { $("la-name").value = ""; $("la-dir").value = ""; });
  };

  // ---------------------------------------------------------------- Phones
  P.register("phones", {
    render: function (st) {
      var a = st.app || {};
      if (a.qr && $("ph-qr").dataset.qr !== a.qr) { $("ph-qr").src = "data:image/png;base64," + a.qr; $("ph-qr").dataset.qr = a.qr; }
      $("ph-url").textContent = a.url || "";
      $("ph-reach").textContent = /^https?:\/\/(10\.|192\.168\.|172\.(1[6-9]|2\d|3[01])\.|127\.)/.test(a.url || "")
        ? "An address on your own network: phones play at home, and downloaded books play anywhere. To listen away from home, give Audiobookshelf an address reachable from outside on the Site address tab."
        : "Phones can reach this from anywhere it resolves.";
    }
  });

  // ---------------------------------------------------------------- Users
  var ROLE = { root: ["administrator", "ok"], admin: ["administrator", "ok"], user: ["listener", ""], guest: ["guest", ""] };
  P.register("users", {
    render: function (st) {
      var a = st.app || {}, users = a.users || [], tb = $("users");
      var sig = JSON.stringify(users) + "|" + P.busy + "|" + P.role; if (tb.dataset.sig === sig) return; tb.dataset.sig = sig; P.clear(tb);
      users.forEach(function (u) {
        var root = u.type === "root", who = P.el("div"), acts = P.el("span", null, "row nowrap"), r = ROLE[u.type] || [u.type, ""];
        who.appendChild(P.el("b", u.user)); if (root) who.appendChild(P.el("div", "you (the main account)", "muted small")); else if (u.active === false) who.appendChild(P.el("div", "turned off in Audiobookshelf", "muted small"));
        acts.appendChild(P.btn("New password", "", function () { P.act("userpw", { id: u.id }, "Make a new password for " + u.user + "? Their apps sign in again with it."); }));
        if (!root) {
          acts.appendChild(u.type === "admin" ? P.btn("Listener only", "", function () { P.act("setadmin", { id: u.id, role: "user" }); }) : P.btn("Make admin", "", function () { P.act("setadmin", { id: u.id, role: "admin" }, "Make " + u.user + " an administrator? They can change libraries, users and settings in Audiobookshelf."); }));
          acts.appendChild(P.btn("Remove", "danger", function () { P.act("userdel", { id: u.id }, "Remove " + u.user + "? Their listening progress, bookmarks and playlists go too."); }));
        }
        if (u.listening != null) who.appendChild(P.el("div", u.listening + " in progress · " + u.finished + " finished", "muted small"));
        var tr = P.row(tb, [P.cell(who), P.chip(r[0], r[1]), u.last_listened ? P.ago(u.last_listened) : "never", P.cell(acts, "n")]);
        if (u.active === false) tr.className = "muted-row";
      });
    }
  });
  P.register("secretNote", function (s) { return s.kind === "users" ? "Use it in Audiobookshelf and in its phone app, then keep it in your password manager." : ""; });
  $("nu-add").onclick = function () { P.act("useradd", { user: $("nu-name").value.trim(), role: $("nu-role").value }).then(function () { $("nu-name").value = ""; }); };

  // ---------------------------------------------------------------- Updates: a newer Audiobookshelf release
  P.register("updates", {
    render: function (st) {
      var iu = st.image_update || {}, box = $("upd-app"), old = $("abs-release"); if (old) old.remove();
      if (!iu.release_newer) return;
      var d = P.el("div"); d.id = "abs-release";
      d.appendChild(P.el("p", "Audiobookshelf " + iu.release + " is out (this is " + (st.version || "?") + "). Updating backs everything up first, downloads it and restarts Audiobookshelf — away for a few minutes.", "muted small"));
      var l = P.el("a", "What's new"); l.href = "https://github.com/advplyr/audiobookshelf/releases/tag/v" + iu.release; l.target = "_blank"; l.rel = "noopener"; d.appendChild(l); d.appendChild(P.el("span", " "));
      d.appendChild(P.btn("Update to " + iu.release, "primary", function () { P.act("absupdate", null, "Update Audiobookshelf to " + iu.release + " now? A backup is made first; it's away for a few minutes."); }));
      box.appendChild(d);
    },
    badge: function (st) { var iu = st.image_update || {}; if (iu.release_newer) { $("badge-updates").hidden = false; $("badge-updates").textContent = "1"; } }
  });

  // ---------------------------------------------------------------- Storage
  P.register("storage", { render: function (app, st, box) {
    P.clear(box); var c = P.el("div", null, "card"); c.appendChild(P.el("h2", "Inside the volumes")); var tbl = P.el("table"), tb = P.el("tbody"); tbl.appendChild(tb); c.appendChild(tbl);
    [["Database: listening progress, users, settings (config)", app.database], ["Covers and item details (metadata/items)", app.items], ["Author pictures (metadata/authors)", app.authors],
     ["Cache (made again when needed)", app.cache], ["Audiobookshelf's own backups (Settings → Backups)", app.backups], ["Audiobookshelf's logs", app.logs]].forEach(function (p) { P.kv(tb, p[0], P.mb(p[1] || 0), true); });
    c.appendChild(P.el("p", "Your audiobooks and podcasts aren't in here: they stay in your shared folders.", "muted small")); box.appendChild(c);
  } });
})(window.Panel);
