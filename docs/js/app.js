(function () {
  "use strict";

  const repository = "https://github.com/RobertFlexx/RSH";
  const api = "https://api.github.com/repos/RobertFlexx/RSH/releases/latest";
  const pages = new Map();

  document.querySelectorAll("[data-page]").forEach(function (page) {
    pages.set(page.getAttribute("data-page"), page);
  });

  function routeFromHash() {
    const raw = (window.location.hash || "#/").slice(1);
    const pieces = raw.split("#");
    const path = (pieces[0] || "/").replace(/^\//, "");
    return {
      page: path || "home",
      anchor: pieces[1] || ""
    };
  }

  function showRoute() {
    const route = routeFromHash();
    const pageName = pages.has(route.page) ? route.page : "home";

    pages.forEach(function (page, name) {
      page.classList.toggle("active", name === pageName);
    });

    document.querySelectorAll("[data-route]").forEach(function (link) {
      const current = link.getAttribute("data-route") === pageName;
      link.classList.toggle("current", current);
      if (current) link.setAttribute("aria-current", "page");
      else link.removeAttribute("aria-current");
    });

    const titles = {
      home: "SRSH 1.0: Simple Ruby Shell",
      manual: "RSH language manual | SRSH 1.0",
      download: "Download SRSH 1.0",
      examples: "RSH examples | SRSH 1.0",
      project: "Project information | SRSH 1.0"
    };
    document.title = titles[pageName] || titles.home;

    document.querySelectorAll(".toc a").forEach(function (link) {
      link.classList.toggle("current", Boolean(route.anchor) && link.getAttribute("href").endsWith("#" + route.anchor));
    });

    if (route.anchor) {
      window.setTimeout(function () {
        const target = document.getElementById(route.anchor);
        if (target) target.scrollIntoView({ block: "start" });
      }, 0);
    } else {
      window.scrollTo(0, 0);
    }
  }

  window.addEventListener("hashchange", showRoute);
  showRoute();

  const notice = document.querySelector("[data-copy-notice]");
  let noticeTimer;

  function showNotice(message) {
    if (!notice) return;
    notice.textContent = message;
    notice.hidden = false;
    window.clearTimeout(noticeTimer);
    noticeTimer = window.setTimeout(function () {
      notice.hidden = true;
    }, 1400);
  }

  function fallbackCopy(text) {
    const field = document.createElement("textarea");
    field.value = text;
    field.setAttribute("readonly", "");
    field.style.position = "fixed";
    field.style.left = "-10000px";
    document.body.appendChild(field);
    field.select();

    try {
      document.execCommand("copy");
      showNotice("Copied.");
    } catch (error) {
      showNotice("Copy failed.");
    }

    field.remove();
  }

  document.addEventListener("click", function (event) {
    const button = event.target.closest("[data-copy-target]");
    if (!button) return;

    const target = document.getElementById(button.getAttribute("data-copy-target"));
    if (!target) return;
    const text = target.textContent.replace(/\n$/, "");

    if (navigator.clipboard && window.isSecureContext) {
      navigator.clipboard.writeText(text).then(function () {
        showNotice("Copied.");
      }).catch(function () {
        fallbackCopy(text);
      });
    } else {
      fallbackCopy(text);
    }
  });

  const searchForm = document.querySelector("[data-doc-search]");
  const searchResults = document.querySelector("[data-search-results]");

  if (searchForm && searchResults) {
    searchForm.addEventListener("submit", function (event) {
      event.preventDefault();
      const input = searchForm.querySelector("input[type='search']");
      const query = input ? input.value.trim().toLowerCase() : "";
      searchResults.replaceChildren();

      if (!query) {
        window.location.hash = "#/manual";
        searchResults.hidden = true;
        return;
      }

      const matches = Array.from(document.querySelectorAll("[data-doc-section]")).filter(function (section) {
        return section.textContent.toLowerCase().includes(query);
      }).slice(0, 10);

      const heading = document.createElement("strong");
      heading.textContent = matches.length ? "Manual entries:" : "No manual entries found.";
      searchResults.appendChild(heading);

      if (matches.length) {
        const list = document.createElement("ul");
        matches.forEach(function (section) {
          const item = document.createElement("li");
          const link = document.createElement("a");
          link.href = "#/manual#" + section.id;
          link.textContent = section.getAttribute("data-title") || section.id;
          item.appendChild(link);
          list.appendChild(item);
        });
        searchResults.appendChild(list);
      }

      searchResults.hidden = false;
    });
  }

  function findAsset(release, preferredName, pattern) {
    const assets = Array.isArray(release.assets) ? release.assets : [];
    return assets.find(function (asset) {
      return asset.name === preferredName;
    }) || assets.find(function (asset) {
      return pattern.test(asset.name);
    });
  }

  function setDownload(kind, url) {
    if (!url) return;
    document.querySelectorAll("[data-download='" + kind + "']").forEach(function (link) {
      link.href = url;
    });
  }

  fetch(api, {
    headers: { "Accept": "application/vnd.github+json" }
  }).then(function (response) {
    if (!response.ok) throw new Error("No published release");
    return response.json();
  }).then(function (release) {
    const tag = String(release.tag_name || "1.0.1");
    const version = tag.replace(/^v/, "");
    const gem = findAsset(release, "srsh.gem", /^srsh-[0-9].*\.gem$/);
    const source = findAsset(release, "srsh-source.tar.gz", /^srsh-[0-9].*\.tar\.gz$/);
    const checksums = findAsset(release, "SHA256SUMS", /^SHA256SUMS$/);

    document.querySelectorAll("[data-latest-version]").forEach(function (element) {
      element.textContent = version;
    });

    setDownload("gem", gem && gem.browser_download_url);
    setDownload("source", source && source.browser_download_url);
    setDownload("checksums", checksums && checksums.browser_download_url);

    const date = release.published_at ? new Date(release.published_at).toLocaleDateString() : "";
    document.querySelectorAll("[data-release-status]").forEach(function (element) {
      element.textContent = date ? "Published " + date + "." : "Published on GitHub.";
    });
  }).catch(function () {
    document.querySelectorAll("[data-release-status]").forEach(function (element) {
      element.textContent = "Release details are available from the GitHub release page.";
    });
    setDownload("gem", repository + "/releases/latest/download/srsh.gem");
    setDownload("source", repository + "/releases/latest/download/srsh-source.tar.gz");
    setDownload("checksums", repository + "/releases/latest/download/SHA256SUMS");
  });
})();
