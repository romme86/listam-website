// Shared site chrome: Tailwind tokens (mirroring listam-desktop/app.css),
// theme persistence, and the scroll-reveal observer.
// Loaded synchronously right after the Tailwind CDN script so the theme
// class lands before first paint.
tailwind.config = {
  darkMode: "class",
  theme: {
    extend: {
      colors: {
        "surface-0": "var(--surface-0)",
        "surface-1": "var(--surface-1)",
        "surface-2": "var(--surface-2)",
        "surface-3": "var(--surface-3)",
        card: "var(--card)",
        ink: "var(--ink)",
        "ink-mute": "var(--ink-mute)",
        "ink-faint": "var(--ink-faint)",
        line: "var(--line)",
        inverse: "var(--inverse-surface)",
        "inverse-ink": "var(--inverse-ink)",
        signal: "#c3f400",
        "on-signal": "#161e00",
      },
      fontFamily: {
        sans: ["Geist", "Inter", "system-ui", "sans-serif"],
        mono: ["JetBrains Mono", "ui-monospace", "monospace"],
      },
      borderRadius: {
        DEFAULT: "12px",
      },
    },
  },
};

(function () {
  var stored = null;
  try { stored = localStorage.getItem("listam-theme"); } catch (e) {}
  var dark = stored
    ? stored === "dark"
    : window.matchMedia("(prefers-color-scheme: dark)").matches;
  document.documentElement.classList.toggle("dark", dark);
})();

function listamToggleTheme() {
  var dark = document.documentElement.classList.toggle("dark");
  try { localStorage.setItem("listam-theme", dark ? "dark" : "light"); } catch (e) {}
}

document.addEventListener("DOMContentLoaded", function () {
  var els = Array.prototype.slice.call(document.querySelectorAll(".reveal, .zen-rule"));
  var showAll = function () {
    els.forEach(function (el) { el.classList.add("reveal-instant", "is-inview"); });
  };
  if (!("IntersectionObserver" in window)) { showAll(); return; }

  // Whatever is already on screen settles instantly — anchored links and
  // restored scroll positions must not greet the reader with blank space.
  var vh = window.innerHeight;
  var below = els.filter(function (el) {
    var r = el.getBoundingClientRect();
    var onScreen = r.top < vh && r.bottom > 0;
    if (onScreen) el.classList.add("reveal-instant", "is-inview");
    return !onScreen;
  });
  if (below.length === 0) return;

  // The spec guarantees an initial delivery for every observed element;
  // if none arrives, the observer is broken or throttled — fail open.
  var delivered = false;
  var observer = new IntersectionObserver(
    function (entries) {
      delivered = true;
      entries.forEach(function (entry) {
        if (entry.isIntersecting) {
          entry.target.classList.add("is-inview");
          observer.unobserve(entry.target);
        }
      });
    },
    { threshold: 0.12, rootMargin: "0px 0px -40px 0px" }
  );
  below.forEach(function (el) { observer.observe(el); });
  setTimeout(function () { if (!delivered) showAll(); }, 2500);
});
