const header = document.querySelector("[data-header]");
const navToggle = document.querySelector(".nav-toggle");
const mainNav = document.querySelector(".main-nav");

const updateHeader = () => header?.classList.toggle("scrolled", window.scrollY > 20);
updateHeader();
window.addEventListener("scroll", updateHeader, { passive: true });

navToggle?.addEventListener("click", () => {
  const open = navToggle.getAttribute("aria-expanded") !== "true";
  navToggle.setAttribute("aria-expanded", String(open));
  mainNav?.classList.toggle("open", open);
});

mainNav?.querySelectorAll("a").forEach((link) => {
  link.addEventListener("click", () => {
    navToggle?.setAttribute("aria-expanded", "false");
    mainNav.classList.remove("open");
  });
});

const reduceMotion = window.matchMedia("(prefers-reduced-motion: reduce)").matches;
const revealItems = document.querySelectorAll(".reveal");
if (reduceMotion || !("IntersectionObserver" in window)) {
  revealItems.forEach((item) => item.classList.add("in-view"));
} else {
  const observer = new IntersectionObserver(
    (entries) => {
      entries.forEach((entry) => {
        if (entry.isIntersecting) {
          entry.target.classList.add("in-view");
          observer.unobserve(entry.target);
        }
      });
    },
    { rootMargin: "0px 0px -8%", threshold: 0.08 },
  );
  revealItems.forEach((item) => observer.observe(item));
}

document.querySelectorAll("[data-year]").forEach((item) => {
  item.textContent = new Date().getFullYear();
});

fetch("https://api.github.com/repos/sschluet/middleai/releases/latest", {
  headers: { Accept: "application/vnd.github+json" },
})
  .then((response) => {
    if (!response.ok) throw new Error("Release unavailable");
    return response.json();
  })
  .then((release) => {
    const asset = release.assets?.find((item) => /macOS-arm64\.zip$/.test(item.name));
    const version = String(release.tag_name || "").replace(/^v/, "");
    if (asset?.browser_download_url) {
      document.querySelectorAll(".download-link").forEach((link) => {
        link.href = asset.browser_download_url;
      });
    }
    if (version) {
      document.querySelectorAll(".version-label").forEach((label) => {
        label.textContent = `Version ${version}`;
      });
    }
  })
  .catch(() => {
    // The static release link remains usable when the GitHub API is unavailable.
  });
