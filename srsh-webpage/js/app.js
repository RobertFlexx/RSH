// the uh *burp* java script file for the other shit

(function () {
  const pages = new Map();
  document.querySelectorAll(".page").forEach((el) => {
    pages.set(el.getAttribute("data-page"), el);
  });

  const navLinks = Array.from(document.querySelectorAll(".nav__link"));
  const sideLinks = Array.from(document.querySelectorAll(".side__link"));
  const toast = document.querySelector("[data-toast]");
  const toastWrap = document.querySelector(".toast");

  function showToast(msg) {
    if (!toast || !toastWrap) return;
    toast.textContent = msg || "Copied.";
    toastWrap.hidden = false;
    clearTimeout(showToast._t);
    showToast._t = setTimeout(() => { toastWrap.hidden = true; }, 1100);
  }

  function setActiveNav(route) {
    navLinks.forEach((a) => {
      const href = a.getAttribute("href") || "";
      const is = href === "#/" + route || (route === "" && href === "#/");
      a.classList.toggle("is-active", is);
    });
  }

  function setActiveSide(hash) {
    if (!hash) {
      sideLinks.forEach((a) => a.classList.remove("is-active"));
      return;
    }
    sideLinks.forEach((a) => {
      const href = a.getAttribute("href") || "";
      a.classList.toggle("is-active", href.endsWith("#" + hash));
    });
  }

  function parseRoute() {
    // "#/docs#themes" or "#/download"
    const raw = (location.hash || "#/").slice(1); // remove leading '#'
    const parts = raw.split("#");
    const left = parts[0] || "/";
    const anchor = parts[1] || "";
    const page = left.startsWith("/") ? left.slice(1) : left;
    return { page: page || "", anchor };
  }

  function showPage(name) {
    // name "" maps to home
    const key = name === "" ? "home" : name;
    let el = pages.get(key);
    if (!el) el = pages.get("home");

    pages.forEach((node) => node.classList.remove("is-active"));
    el.classList.add("is-active");

    setActiveNav(key === "home" ? "" : key);

    // Update title in a dumb-simple way (cuz ez)
    const titles = {
      home: "srsh — a tiny Ruby shell with RSH scripting",
      docs: "srsh docs — RSH scripting",
      download: "srsh download",
      about: "About srsh",
      ruby: "About Ruby",
      github: "srsh on GitHub",
    };
    document.title = titles[key] || "srsh";

    return el;
  }

  function scrollToAnchor(anchor) {
    if (!anchor) return;
    const target = document.getElementById(anchor);
    if (!target) return;
    setTimeout(() => {
      target.scrollIntoView({ behavior: "smooth", block: "start" });
    }, 0);
  }

  function router() {
    const { page, anchor } = parseRoute();
    showPage(page);

    if ((page || "") === "docs") setActiveSide(anchor);
    else setActiveSide("");

    if (anchor) scrollToAnchor(anchor);
  }

  window.addEventListener("hashchange", router);
  router();

  // copy butttons
  document.addEventListener("click", (ev) => {
    const btn = ev.target.closest("[data-copy]");
    if (!btn) return;
    const text = btn.getAttribute("data-copy") || "";
    if (!text) return;

    if (navigator.clipboard && navigator.clipboard.writeText) {
      navigator.clipboard.writeText(text).then(() => showToast("Copied.")).catch(() => fallbackCopy(text));
    } else {
      fallbackCopy(text);
    }
  });

  function fallbackCopy(text) {
    const ta = document.createElement("textarea");
    ta.value = text;
    ta.setAttribute("readonly", "readonly");
    ta.style.position = "fixed";
    ta.style.left = "-9999px";
    document.body.appendChild(ta);
    ta.select();
    try { document.execCommand("copy"); showToast("Copied."); }
    catch (_) { showToast("Couldn't copy"); }
    document.body.removeChild(ta);
  }

  // home search, routes to docs and highlights matches
  const searchForm = document.querySelector("[data-search-form]");
  if (searchForm) {
    searchForm.addEventListener("submit", (ev) => {
      ev.preventDefault();
      const input = searchForm.querySelector("input[type='search']");
      const q = (input && input.value || "").trim();
      if (!q) { location.hash = "#/docs"; return; }
      location.hash = "#/docs";
      setTimeout(() => highlightDocs(q), 60);
    });
  }

  function highlightDocs(q) {
    const docs = pages.get("docs");
    if (!docs) return;
    const needle = q.toLowerCase();

    // cklear old marks
    docs.querySelectorAll("mark[data-hit]").forEach((m) => {
      const text = document.createTextNode(m.textContent || "");
      m.replaceWith(text);
    });

    const nodes = docs.querySelectorAll("p, li, code, h2, h1");
    let firstHit = null;

    nodes.forEach((n) => {
      const t = n.textContent || "";
      if (!t.toLowerCase().includes(needle)) return;

      const htmlSafe = escapeHtml(t);
      const rx = new RegExp("(" + escapeRegExp(q) + ")", "ig");
      const marked = htmlSafe.replace(rx, "<mark data-hit>$1</mark>");
      n.innerHTML = marked;

      if (!firstHit) firstHit = n;
    });

    if (firstHit) {
      firstHit.scrollIntoView({ behavior: "smooth", block: "center" });
      showToast("Found matches in docs");
    } else {
      showToast("No matches");
    }
  }

  function escapeRegExp(s) {
    return s.replace(/[.*+?^${}()|[\]\\]/g, "\\$&");
  }

  function escapeHtml(s) {
    return s.replace(/&/g, "&amp;")
            .replace(/</g, "&lt;")
            .replace(/>/g, "&gt;")
            .replace(/"/g, "&quot;")
            .replace(/'/g, "&#039;");
  }
})();
