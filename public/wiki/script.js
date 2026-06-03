(function () {
  const navLinks = Array.from(document.querySelectorAll(".nav a"));
  const searchable = Array.from(document.querySelectorAll(".page-searchable"));
  const searchInput = document.getElementById("site-search");
  const currentPage = getPageName(window.location.pathname);

  function getPageName(pathname) {
    const name = pathname.split("/").pop();
    return name || "index.html";
  }

  function isCurrentPageLink(link) {
    const url = new URL(link.getAttribute("href"), window.location.href);
    return getPageName(url.pathname) === currentPage;
  }

  const navTargetIds = new Set(
    navLinks
      .filter((link) => isCurrentPageLink(link))
      .map((link) => new URL(link.getAttribute("href"), window.location.href).hash.slice(1))
      .filter(Boolean),
  );
  const sections = Array.from(document.querySelectorAll("[id]")).filter(
    (section) =>
      navTargetIds.has(section.id) &&
      (section.classList.contains("page") ||
        section.classList.contains("plan-section") ||
        section.hasAttribute("data-nav-section")),
  );

  function openNavAncestors(link) {
    let details = link.closest("details");

    while (details) {
      details.open = true;
      details = details.parentElement?.closest("details");
    }
  }

  function setActiveNav(id) {
    navLinks.forEach((link) => {
      const url = new URL(link.getAttribute("href"), window.location.href);
      const isActive = isCurrentPageLink(link) && url.hash === "#" + id;
      link.classList.toggle("active", isActive);
      if (isActive) openNavAncestors(link);
    });
  }

  function getCurrentSectionId() {
    const marker = window.innerHeight * 0.35;
    let closestId = sections[0]?.id;
    let closestDistance = Infinity;
    let activeId = null;

    for (const section of sections) {
      if (section.closest(".hidden-by-search")) continue;

      const rect = section.getBoundingClientRect();
      if (rect.top <= marker) activeId = section.id;

      const distance = Math.abs(rect.top - marker);
      if (distance < closestDistance) {
        closestDistance = distance;
        closestId = section.id;
      }
    }

    return activeId || closestId;
  }

  function syncActiveNav() {
    const id = getCurrentSectionId();
    if (id) setActiveNav(id);
  }

  function syncActiveNavFromHash() {
    const id = window.location.hash.slice(1);
    if (!id) return;
    if (!sections.some((section) => section.id === id)) return;
    setActiveNav(id);
  }

  const observer = new IntersectionObserver(
    (entries) => {
      const visible = entries
        .filter((entry) => entry.isIntersecting)
        .sort((a, b) => b.intersectionRatio - a.intersectionRatio)[0];

      if (!visible) return;
      syncActiveNav();
    },
    {
      rootMargin: "-20% 0px -65% 0px",
      threshold: [0.1, 0.25, 0.5],
    },
  );

  sections.forEach((section) => observer.observe(section));

  searchInput.addEventListener("input", () => {
    const query = searchInput.value.trim().toLowerCase();

    searchable.forEach((section) => {
      const haystack = section.textContent.toLowerCase();
      const isMatch = !query || haystack.includes(query);
      section.classList.toggle("hidden-by-search", !isMatch);
    });

    if (!query) return;

    const firstMatch = searchable.find(
      (section) => !section.classList.contains("hidden-by-search"),
    );

    if (firstMatch) {
      firstMatch.scrollIntoView({ block: "start", behavior: "smooth" });
    }
  });

  document.addEventListener("keydown", (event) => {
    if ((event.metaKey || event.ctrlKey) && event.key.toLowerCase() === "k") {
      event.preventDefault();
      searchInput.focus();
      searchInput.select();
    }
  });

  window.addEventListener("hashchange", syncActiveNavFromHash);
  window.addEventListener("scroll", () => requestAnimationFrame(syncActiveNav), {
    passive: true,
  });
  requestAnimationFrame(() => {
    if (window.location.hash) syncActiveNavFromHash();
    else syncActiveNav();
  });
})();
