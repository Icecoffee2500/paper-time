/* Paper Time — the manual.

   The demonstrations are the same ones the landing page shows, out of the same
   file: a demonstration written twice is a demonstration that goes stale once.
   This file only says where each one goes, keeps the rail pointing at whatever
   you are reading, and wakes a demonstration when it comes into view. */

/* Named apart from the functions `demos.js` already declared in this same
   global scope: two scripts on one page share it, and a `const` that repeats
   a name there stops the page dead. */
const PT = window.PaperTime;
const demos = PT.demos;

/* Which working piece goes in which slot. Everything in `demos` is used
   somewhere on this page; if a slot is missing the demonstration is simply
   not built. */
const PIECES = [
  ["d-kind", demos.paperOrDocument],
  ["d-book", demos.bookMode],
  ["d-pages", demos.pageGrid],
  ["d-panes", demos.panes],
  ["d-split", demos.papersSideBySide],
  ["d-fitted", demos.fittedHighlight],
  ["d-marks", demos.marksJump],
  ["d-draw", demos.figmaDrawing],
  ["d-ultracopy", demos.ultracopy],
  ["d-quote", demos.passageToNote],
  ["d-links", demos.noteLinks],
  ["d-draft", demos.draftToManuscript],
  ["d-search", demos.searchEverything],
  ["d-libraries", demos.manyLibraries],
  ["d-name", demos.fileName],
  ["d-desktops", demos.everyDesktop],
  ["d-devices", demos.threeDevices],
  ["d-locked", demos.lockedPDF],
];

/* Built when the page loads, woken when it is reached. Several of these run a
   little animation of their own once they are awake, and eighteen of them
   running behind the fold is a fan nobody asked for. */
function mountPieces() {
  const woken = new WeakSet();
  const wake = "IntersectionObserver" in window
    ? new IntersectionObserver((entries) => {
        for (const entry of entries) {
          if (!entry.isIntersecting) continue;
          const demo = entry.target.firstElementChild;
          if (demo && !woken.has(demo)) {
            woken.add(demo);
            demo.activate?.();
          }
        }
      }, { rootMargin: "-5% 0px -5% 0px" })
    : null;

  for (const [id, make] of PIECES) {
    const slot = document.getElementById(id);
    if (!slot || !make) continue;
    const demo = make();
    slot.replaceChildren(demo);
    if (wake) wake.observe(slot);
    else demo.activate?.();
  }
}

/* The rail points at the section you are in.
   Whichever heading is highest on the screen but still past the top bar — not
   "the one intersecting", which lights two of them at once on a tall section
   and none at all on a short one. */
function mountRail() {
  const links = [...document.querySelectorAll(".rail a")];
  const sections = links
    .map((link) => document.querySelector(link.getAttribute("href")))
    .filter(Boolean);
  if (sections.length === 0) return;

  let current = null;
  const mark = () => {
    const top = (document.querySelector(".topbar")?.getBoundingClientRect().height || 48) + 24;
    let found = sections[0];
    for (const section of sections) {
      if (section.getBoundingClientRect().top - top <= 0) found = section;
    }
    // The last section is shorter than the screen, so scrolling can never put
    // its top above the line — at the foot of the page it would light the one
    // before it, which is the one you have already read past.
    if (innerHeight + scrollY >= document.body.scrollHeight - 2) {
      found = sections[sections.length - 1];
    }
    if (found === current) return;
    current = found;
    for (const link of links) {
      const on = link.getAttribute("href") === "#" + found.id;
      link.classList.toggle("on", on);
      if (on && window.innerWidth <= 900) {
        /* The rail lies down on a phone, so the row being pointed at has to be
           brought into it — otherwise it says nothing you can see. */
        link.scrollIntoView({ inline: "center", block: "nearest", behavior: "smooth" });
      }
    }
  };

  let frame = 0;
  addEventListener("scroll", () => {
    if (frame) return;
    frame = requestAnimationFrame(() => { frame = 0; mark(); });
  }, { passive: true });
  addEventListener("resize", mark, { passive: true });
  mark();
}

PT.mountLanguage();
mountPieces();
mountRail();
