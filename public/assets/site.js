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
  var revealed = document.querySelectorAll(".reveal, .zen-rule");
  if (!("IntersectionObserver" in window)) {
    revealed.forEach(function (el) { el.classList.add("is-inview"); });
    return;
  }
  var observer = new IntersectionObserver(
    function (entries) {
      entries.forEach(function (entry) {
        if (entry.isIntersecting) {
          entry.target.classList.add("is-inview");
          observer.unobserve(entry.target);
        }
      });
    },
    { threshold: 0.12, rootMargin: "0px 0px -40px 0px" }
  );
  revealed.forEach(function (el) { observer.observe(el); });
});
