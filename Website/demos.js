/* Paper Time — the nine things worth showing, each one a thing you can press.
   The app introduces itself with working demonstrations rather than sentences;
   the page it is downloaded from should do the same. */

const el = (tag, attrs = {}, ...kids) => {
  const node = document.createElement(tag);
  for (const [k, v] of Object.entries(attrs)) {
    if (k === "class") node.className = v;
    else if (k === "html") node.innerHTML = v;
    else if (k.startsWith("on")) node.addEventListener(k.slice(2), v);
    else node.setAttribute(k, v);
  }
  for (const kid of kids.flat()) {
    if (kid == null) continue;
    node.append(kid.nodeType ? kid : document.createTextNode(kid));
  }
  return node;
};

/* A formula, set the way a paper sets one. */
const f = (html) => `<i style="font-family:'Times New Roman',serif">${html}</i>`;
const sub = (s) => `<sub style="font-size:.72em">${s}</sub>`;

/* ══════════════════════════ two languages ══════════════════════════════
   Decided in the page's head before anything painted; read once here. Both
   versions sit next to each other in the source so they have to be edited
   together. Switching reloads the page — everything on it is a string. */
const KO = document.documentElement.lang !== "en";
const L = (ko, en) => (KO ? ko : en);

function mountLanguage() {
  const node = document.getElementById("lang");
  if (!node) return;
  const pick = (lang) => {
    try { localStorage.setItem("papertime.lang", lang); } catch (e) {}
    location.reload();
  };
  node.replaceChildren(...[["ko", "한국어"], ["en", "English"]].map(([code, name]) => {
    const b = el("button", { type: "button", class: code === (KO ? "ko" : "en") ? "on" : "" }, name);
    b.setAttribute("aria-pressed", String(code === (KO ? "ko" : "en")));
    if (code !== (KO ? "ko" : "en")) b.addEventListener("click", () => pick(code));
    return b;
  }));
}

/* The title and the card a messenger unfurls follow the same choice. */
function mountMetadata() {
  document.title = L(
    "Paper Time — 논문에만 집중하기 위한 앱",
    "Paper Time — read a paper, and write from it"
  );
  const set = (selector, value) => {
    const node = document.querySelector(selector);
    if (node) node.setAttribute("content", value);
  };
  set('meta[name="description"]', L(
    "논문을 읽고, 표시하고, 그 표시를 생각으로 바꾸기 위한 앱. 맥·윈도우·리눅스에서 같은 라이브러리 폴더를 열어요. 수식은 LaTeX으로 나오고, 구절은 주소째로 노트가 돼요.",
    "An app for reading papers, marking them up, and turning those marks into writing. The same library folder opens on macOS, Windows and Linux. Formulas copy out as LaTeX; passages become notes with their page numbers attached."
  ));
  set('meta[property="og:description"]', L(
    "논문을 읽고, 표시하고, 그 표시를 생각으로 바꾸기 위한 앱.",
    "An app for reading papers, marking them up, and writing from them."
  ));
  set('meta[property="og:locale"]', KO ? "ko_KR" : "en_US");
}

/* ══════════════════════════ 1 · Ultracopy ══════════════════════════ */

function ultracopy() {
  // The sentence around the formula changes language; the formula is one
  // string the two share, so the mathematics cannot drift between them.
  const LEAD = L("각 단계에서 롤아웃 손실 ", "At each step we minimise the rollout loss ");
  const PASSAGE =
    LEAD +
    `${f("&#x2112;")}${sub("rollout")}${f("(&phi;)")} := ` +
    `&#8214;${f("P")}${sub("&phi;")}${f("(a")}${sub("1:T")}${f(", s")}${sub("1")}` +
    `${f(", z")}${sub("1")}${f(")")} &minus; ${f("z")}${sub("T+1")}&#8214;${sub("1")}` +
    L(`을 최소화한다.`, `.`);

  const PLAIN =
    LEAD + "L rollout (ϕ) := ∥P ϕ (a 1:T , s 1 , z 1 ) − z T+1 ∥ 1" + L(" 을 최소화한다.", " .");
  const ULTRA =
    LEAD + "$\\mathcal{L}_{\\mathrm{rollout}}(\\phi) := " +
    "\\lVert P_\\phi(a_{1:T}, s_1, z_1) - z_{T+1} \\rVert_1$" + L(" 을 최소화한다.", ".");

  const out = el("pre", {
    style:
      "margin:0;font:12.5px/1.75 var(--mono);white-space:pre-wrap;word-break:break-word;" +
      "color:var(--ink-2);min-height:5.2em",
  }, L("아래 두 단추를 눌러보세요.", "Try both buttons."));

  const label = el("div", { class: "hint", style: "margin:0 0 6px" }, " ");

  const show = (text, kind) => {
    out.textContent = text;
    out.style.color = kind === "ultra" ? "var(--ink)" : "var(--ink-3)";
    label.innerHTML =
      kind === "ultra"
        ? L('<b style="color:var(--green)">붙여넣으면 그대로 컴파일돼요.</b>',
            '<b style="color:var(--green)">Paste it. It compiles.</b>')
        : L('<b>수식이 글자 부스러기로 깨졌어요.</b> 다시 손으로 쳐야 해요.',
            '<b>The formula came apart into crumbs.</b> Type it again by hand.');
    navigator.clipboard?.writeText(text).catch(() => {});
  };

  return el("div", { class: "demo-shell", style: "flex-direction:column;gap:12px" },
    el("div", { class: "pane paper-face", style: "flex:0 0 auto" },
      el("p", { html: PASSAGE, style: "margin:0;background:var(--mark-soft);padding:6px 8px;border-radius:5px" })),
    el("div", { style: "display:flex;gap:10px;flex-wrap:wrap" },
      el("button", { class: "btn btn-ghost", onclick: () => show(PLAIN, "plain") },
        el("span", { class: "key" }, "⌘C"), L("그냥 복사", "Plain copy")),
      el("button", { class: "btn btn-primary", onclick: () => show(ULTRA, "ultra") },
        el("span", { class: "key", style: "background:rgba(255,255,255,.16);border-color:rgba(255,255,255,.3);color:#fff" }, "⇧⌘C"),
        "Ultracopy")),
    el("div", { class: "pane", style: "flex:1;min-height:0" }, label, out));
}

/* ═════════════════════ 2 · Search Everything ═════════════════════ */

function searchEverything() {
  const G = {
    paper: L("논문", "Paper"), note: L("노트", "Note"), tag: L("태그", "Tag"),
    text: L("본문", "Text"), action: L("동작", "Action"),
  };
  const ITEMS = [
    { g: G.paper, t: "Overcoming catastrophic forgetting in neural networks", s: "Kirkpatrick et al. · 2017" },
    { g: G.paper, t: "OpenVLA: An Open-Source Vision-Language-Action Model", s: "Kim et al. · 2024" },
    { g: G.paper, t: "Auto-Encoding Variational Bayes", s: "Kingma & Welling · 2013" },
    { g: G.note, t: L("시냅스 강화가 기억을 지킨다", "Synaptic consolidation protects memory"),
      s: L("Kirkpatrick 2017에서", "from Kirkpatrick 2017") },
    { g: G.note, t: L("왜 EWC는 피셔 정보를 쓰는가", "Why EWC uses Fisher information"),
      s: L("지도 · 연속 학습", "Map · Continual learning") },
    { g: G.tag, t: "continual-learning", s: L("논문 7편", "7 papers") },
    // 제목에는 없고 본문에만 있는 낱말: 이 줄이 없으면 그 논문은 떠오르지 않는다.
    { g: G.text, t: "…synaptic consolidation enables continual learning…",
      s: L("Kirkpatrick 2017 · 1쪽 · 9군데", "Kirkpatrick 2017 · p. 1 · 9 matches") },
    { g: G.text, t: "…unlearning specific layers may not help the model forget…",
      s: L("Can Memorization Be Localized? · 9쪽", "Can Memorization Be Localized? · p. 9") },
    { g: G.action, t: L("PDF 추가…", "Add PDFs…"), s: "⌘O" },
    { g: G.action, t: L("BibTeX 내보내기…", "Export BibTeX…"), s: "⇧⌘E" },
  ];
  const OFFERED = [
    { h: L("이어 읽기", "Keep reading"), t: "Overcoming catastrophic forgetting…",
      s: L("3쪽에서 멈췄어요", "Stopped on page 3") },
    { h: L("읽었으니", "Read next"), t: "Progressive Neural Networks",
      s: L("EWC를 읽었다면", "Since you read EWC") },
    { h: L("다시 보기", "Look again"), t: "Auto-Encoding Variational Bayes",
      s: L("두 달 전에 표시해 둔 것", "Marked up two months ago") },
  ];

  const list = el("div", { style: "display:flex;flex-direction:column;gap:1px" });
  const caption = el("div", { class: "hint", style: "margin:0 0 8px" });

  const row = (title, sub, tag) =>
    el("div", {
      style:
        "display:flex;align-items:baseline;gap:10px;padding:8px 10px;border-radius:9px;" +
        "cursor:default",
      onmouseenter: (e) => (e.currentTarget.style.background = "var(--accent-soft)"),
      onmouseleave: (e) => (e.currentTarget.style.background = "none"),
    },
      el("span", { style: "font-size:11px;color:var(--ink-3);min-width:34px" }, tag),
      el("span", { style: "flex:1;min-width:0;font-size:14px;overflow:hidden;text-overflow:ellipsis;white-space:nowrap" }, title),
      el("span", { style: "font-size:12px;color:var(--ink-3);white-space:nowrap" }, sub));

  const render = (q) => {
    list.replaceChildren();
    const query = q.trim().toLowerCase();
    if (!query) {
      caption.innerHTML = L("빈칸일 때는 <b>묻기 전에 먼저 보여줘요</b> — 이유와 함께.",
                            "With the field empty, it <b>offers before you ask</b> — and says why.");
      for (const o of OFFERED) {
        list.append(el("div", {
          style: "font:600 11px/1 var(--sans);letter-spacing:.05em;color:var(--ink-3);" +
                 "text-transform:uppercase;padding:10px 10px 4px",
        }, o.h));
        list.append(row(o.t, o.s, ""));
      }
      return;
    }
    const hits = ITEMS.filter((i) => (i.t + i.s + i.g).toLowerCase().includes(query));
    caption.innerHTML = hits.length
      ? L(`제목도 노트도 태그도, <b>논문 본문 속 한 줄까지</b>. ${hits.length}개 찾았어요.`,
          `Titles, notes, tags, <b>down to a line inside a paper</b>. ${hits.length} found.`)
      : L("그런 건 없어요.", "No such thing.");
    for (const h of hits) list.append(row(h.t, h.s, h.g));
  };

  const input = el("input", {
    type: "text",
    placeholder: L("찾거나, 이어서 읽거나", "Search, or pick up where you were"),
    style:
      "flex:1;border:none;background:none;outline:none;font:400 19px/1.4 var(--sans);" +
      "color:var(--ink);min-width:0",
    oninput: (e) => render(e.target.value),
  });

  const box = el("div", { class: "pane", style: "flex:1;display:flex;flex-direction:column;min-height:0;padding:0" },
    el("div", { style: "display:flex;align-items:center;gap:12px;padding:14px 16px;border-bottom:1px solid var(--rule)" },
      el("span", { style: "font-size:19px;color:var(--ink-3)" }, "⌕"), input),
    el("div", { style: "padding:8px 6px 12px;overflow:auto;flex:1;min-height:0" }, list));

  render("");
  const shell = el("div", { class: "demo-shell", style: "flex-direction:column;gap:10px" }, box, caption);
  shell.activate = () => setTimeout(() => input.focus({ preventScroll: true }), 180);
  return shell;
}

/* ══════════════════ 3 · Book mode and its contents ══════════════════ */

function bookMode() {
  const SECTIONS = [
    { h: "1. Introduction", p: 2 },
    { h: "2. Elastic Weight Consolidation", p: 4 },
    { h: "3. EWC in supervised learning", p: 6 },
    { h: "4. Results on Atari", p: 8 },
    { h: "5. Discussion", p: 10 },
  ];
  const lorem =
    "Achieving artificial general intelligence requires that agents are able to learn and " +
    "remember many different tasks. This is particularly difficult in real-world settings: " +
    "the sequence of tasks may not be explicitly labelled, tasks may switch unpredictably, " +
    "and any individual task may not recur for long time intervals. ";

  let spread = 0;
  const page = (n) =>
    el("div", {
      style:
        "flex:1;min-width:0;background:var(--card);border:1px solid var(--rule);border-radius:8px;" +
        "padding:14px 16px 20px;display:flex;flex-direction:column;overflow:hidden",
    },
      el("div", { class: "paper-face", style: "flex:1;overflow:hidden" },
        n === 2 ? el("h4", {}, SECTIONS[0].h) : null,
        n === 4 ? el("h4", {}, SECTIONS[1].h) : null,
        n === 6 ? el("h4", {}, SECTIONS[2].h) : null,
        n === 8 ? el("h4", {}, SECTIONS[3].h) : null,
        n === 10 ? el("h4", {}, SECTIONS[4].h) : null,
        el("p", {}, lorem.repeat(2)),
        el("p", {}, lorem)),
      el("div", { style: "text-align:center;font:11px var(--sans);color:var(--ink-3);padding-top:8px" }, n));

  const spreadBox = el("div", {
    style: "flex:1;display:flex;gap:12px;min-height:0;transition:transform .3s ease,opacity .3s ease",
  });
  const counter = el("span", { style: "font:12px var(--mono);color:var(--ink-3)" });

  const draw = (dir = 0) => {
    if (dir) {
      spreadBox.style.transform = `translateX(${dir * -26}px)`;
      spreadBox.style.opacity = "0";
    }
    setTimeout(() => {
      const left = 2 + spread * 2;
      spreadBox.replaceChildren(page(left), page(left + 1));
      counter.textContent = `${left}–${left + 1} / 12`;
      spreadBox.style.transition = "none";
      spreadBox.style.transform = `translateX(${dir * 26}px)`;
      requestAnimationFrame(() => {
        spreadBox.style.transition = "transform .3s ease, opacity .3s ease";
        spreadBox.style.transform = "none";
        spreadBox.style.opacity = "1";
      });
    }, dir ? 200 : 0);
  };

  const go = (next) => {
    const clamped = Math.max(0, Math.min(5, next));
    if (clamped === spread) return;
    const dir = clamped > spread ? 1 : -1;
    spread = clamped;
    draw(dir);
  };

  const toc = el("div", {
    style:
      "display:flex;gap:6px;flex-wrap:wrap;padding:10px 12px;background:var(--paper);" +
      "border:1px solid var(--rule);border-radius:12px;transition:opacity .2s,transform .2s",
  }, SECTIONS.map((s) =>
    el("button", {
      class: "chip",
      style: "border-color:var(--rule);background:var(--card)",
      onclick: () => { go(Math.floor((s.p - 2) / 2)); },
    }, s.h)));
  toc.hidden = true;

  const tocButton = el("button", {
    class: "btn btn-ghost",
    onclick: () => {
      toc.hidden = !toc.hidden;
      tocButton.classList.toggle("is-on", !toc.hidden);
    },
  }, el("span", { class: "key" }, "⇧⌘L"), L("목차", "Contents"));

  draw();

  return el("div", { class: "demo-shell", style: "flex-direction:column;gap:10px" },
    el("div", { style: "display:flex;align-items:center;gap:10px;flex-wrap:wrap" },
      tocButton, counter,
      el("span", { style: "flex:1" }),
      el("button", { class: "btn btn-ghost", onclick: () => go(spread - 1) }, "◀"),
      el("button", { class: "btn btn-ghost", onclick: () => go(spread + 1) }, "▶")),
    el("div", { class: "pane", style: "flex:1;display:flex;min-height:0;background:var(--paper)" }, spreadBox),
    toc);
}

/* ═════════════ 4 · A highlight that knows where the line is ═════════════ */

function fittedHighlight() {
  let fitted = true;
  const lines = [
    "network training from a probabilistic perspective. From this point",
    "of view, optimizing the parameters is tantamount to finding their",
    `most probable values given some data ${f("&#x1D49F;")}. We can compute the`,
    `conditional probability ${f("p(&theta;|&#x1D49F;)")} from the prior probability of the`,
    `parameters ${f("p(&theta;)")} and the probability of the data ${f("p(&#x1D49F;|&theta;)")} by using`,
    "Bayes' rule:",
  ];
  const MARKED = 2;

  const body = el("div", { class: "paper-face", style: "font-size:clamp(11px,1.25vw,14px);line-height:2.05" });
  const draw = () => {
    body.replaceChildren(...lines.map((text, i) => {
      const line = el("div", { html: text, style: "position:relative;z-index:1" });
      if (i === MARKED) {
        line.style.background = "var(--mark-soft)";
        line.style.borderRadius = "3px";
        line.style.transition = "padding .3s ease, margin .3s ease, box-shadow .3s ease";
        if (!fitted) {
          // The band grows to the formula's full box and swallows its neighbours.
          line.style.padding = "13px 2px";
          line.style.margin = "-13px 0";
          line.style.zIndex = "2";
          line.style.boxShadow = "0 0 0 1px rgba(0,0,0,.04)";
        } else {
          line.style.padding = "1px 2px";
          line.style.margin = "0";
        }
      }
      return line;
    }));
  };

  const note = el("p", { class: "hint" });
  const sync = () => {
    draw();
    note.innerHTML = fitted
      ? L("<b>Paper Time</b> — 글자가 앉은 자리만 덮어요. 위아래 줄은 그대로 읽을 수 있어요.",
          "<b>Paper Time</b> — covers where the letters sit, nothing more. The lines above and below stay readable.")
      : L("<b>다른 PDF 앱</b> — 수식의 상자를 통째로 덮어서 이웃한 줄까지 지워요.",
          "<b>Other PDF apps</b> — cover the formula's whole box and blot out the neighbouring lines.");
  };

  const seg = el("div", { class: "seg" },
    el("button", { onclick: () => { fitted = false; seg.children[0].classList.add("on"); seg.children[1].classList.remove("on"); sync(); } }, L("다른 PDF 앱", "Other PDF apps")),
    el("button", { class: "on", onclick: () => { fitted = true; seg.children[1].classList.add("on"); seg.children[0].classList.remove("on"); sync(); } }, "Paper Time"));

  sync();
  return el("div", { class: "demo-shell", style: "flex-direction:column;gap:12px" },
    seg,
    el("div", { class: "pane", style: "flex:1;min-height:0;display:flex;align-items:center" }, body),
    note);
}

/* ═══════════════ 5 · The list of marks is a set of doors ═══════════════ */

function marksJump() {
  const MARKS = [
    { id: "m1", kind: L("하이라이트", "Highlight"), c: "var(--mark-soft)", t: "synaptic consolidation" },
    { id: "m2", kind: L("밑줄", "Underline"), c: "transparent", t: "elastic weight consolidation (EWC)" },
    { id: "m3", kind: L("노트", "Note"), c: "var(--accent-soft)", t: "quadratic penalty" },
  ];
  const para = (text) => el("p", { html: text });
  const page = el("div", { class: "pane paper-face", style: "flex:1.35;min-height:0" },
    el("h4", {}, "Overcoming catastrophic forgetting"),
    para("The ability to learn tasks in a sequential fashion is crucial to the development of artificial intelligence. Until now neural networks have not been capable of this."),
    para(`We show that it is possible to overcome this limitation and train networks that can maintain expertise on tasks they have not experienced for a long time, by <span id="m1" style="background:var(--mark-soft);border-radius:3px;padding:0 2px">synaptic consolidation</span>.`),
    para("Our approach remembers old tasks by selectively slowing down learning on the weights important for those tasks."),
    para(`We develop an algorithm analogous to synaptic consolidation, which we refer to as <span id="m2" style="border-bottom:2px solid var(--accent);padding-bottom:1px">elastic weight consolidation (EWC)</span>.`),
    para("This algorithm slows down learning on certain weights based on how important they are to previously seen tasks."),
    para(`The constraint is implemented as a <span id="m3" style="background:var(--accent-soft);border-radius:3px;padding:0 2px">quadratic penalty</span>, and can therefore be imagined as a spring anchoring the parameters to the previous solution.`),
    para("Importantly, the stiffness of this spring should not be the same for all parameters."));

  const flash = (id) => {
    const target = page.querySelector("#" + id);
    if (!target) return;
    target.scrollIntoView({ behavior: "smooth", block: "center" });
    target.animate(
      [{ boxShadow: "0 0 0 0 rgba(31,95,139,0)" },
       { boxShadow: "0 0 0 6px rgba(31,95,139,.28)" },
       { boxShadow: "0 0 0 0 rgba(31,95,139,0)" }],
      { duration: 900, easing: "ease-out" });
  };

  const inspector = el("div", { class: "pane", style: "flex:1;min-height:0" },
    el("div", { style: "font:600 11px/1 var(--sans);letter-spacing:.05em;color:var(--ink-3);text-transform:uppercase;margin-bottom:10px" }, "Marks"),
    MARKS.map((m) =>
      el("button", {
        style:
          "display:block;width:100%;text-align:left;border:1px solid var(--rule);background:var(--card);" +
          "border-radius:10px;padding:9px 11px;margin-bottom:7px;cursor:pointer",
        onclick: () => flash(m.id),
      },
        el("div", { style: "font-size:10.5px;color:var(--ink-3);margin-bottom:3px" }, m.kind),
        el("div", { style: `font-size:13px;background:${m.c};border-radius:3px;padding:0 2px;display:inline` }, m.t))),
    el("p", { class: "hint", style: "margin-top:12px" },
      L("표시를 누르면 쪽이 그리로 가요.", "Click a mark and the page goes there.")));

  return el("div", { class: "demo-shell" }, page, inspector);
}

/* ═════════════ 6 · A passage keeps its address in the note ═════════════ */

function passageToNote() {
  const SENTENCE = "The constraint is implemented as a quadratic penalty, and can therefore be imagined as a spring anchoring the parameters to the previous solution.";
  let sent = false;

  const sentence = el("span", {
    style: "background:rgba(31,95,139,.22);border-radius:3px;padding:0 2px;transition:background .25s",
  }, SENTENCE);

  // 고른 자리에 수식이 걸쳐 있다 — 노트에 도착한 것이 수식인지 글자 부스러기인지가
  // 갈리는 자리.
  const formula = el("p", {
    style:
      "text-align:center;font:italic 15px/1.6 'Times New Roman',serif;margin:10px 0;" +
      "background:rgba(31,95,139,.22);border-radius:3px;transition:background .25s",
  }, "ℒ(θ) = ℒ\u2099(θ) + Σᵢ (λ⁄2) Fᵢ (θᵢ − θ*ᴀ,ᵢ)²");

  const page = el("div", { class: "pane paper-face", style: "flex:1.2;min-height:0" },
    el("h4", {}, "2. Elastic Weight Consolidation"),
    el("p", {}, "A deep neural network consists of multiple layers of linear projection followed by element-wise nonlinearities."),
    el("p", {}, sentence),
    formula,
    el("p", {}, "Importantly, the stiffness of this spring should not be the same for all parameters; rather, it should be greater for parameters that most affect performance."));

  const noteBody = el("div", { style: "display:flex;flex-direction:column;gap:10px;min-height:0" });
  const hint = el("p", { class: "hint" });

  const backToPage = () => {
    sentence.scrollIntoView({ behavior: "smooth", block: "center" });
    sentence.animate(
      [{ background: "rgba(31,95,139,.22)" },
       { background: "var(--mark)" },
       { background: "rgba(31,95,139,.22)" }],
      { duration: 900, easing: "ease-out" });
  };

  const render = () => {
    noteBody.replaceChildren();
    if (!sent) {
      noteBody.append(el("div", { style: "color:var(--ink-3);font-size:14px" },
        L("노트가 아직 비어 있어요.", "Nothing in the note yet.")));
      hint.innerHTML = L("논문에서 고른 문장을 <b>주소째로</b> 노트에 보내요.",
                         "Send the sentence you picked to the note, <b>address and all</b>.");
      return;
    }
    noteBody.append(
      el("button", {
        style:
          "display:block;width:100%;text-align:left;border:none;border-left:3px solid var(--accent);" +
          "background:var(--accent-soft);border-radius:0 8px 0 0;padding:9px 12px 6px;cursor:pointer;" +
          "font:italic 13px/1.55 'Times New Roman',serif;color:var(--ink)",
        onclick: backToPage,
      }, SENTENCE + " "),
      el("div", {
        style:
          "border-left:3px solid var(--accent-line);background:var(--accent-soft);" +
          "border-radius:0 8px 8px 0;padding:6px 12px 9px;margin-top:-1px;" +
          "font:italic 14px/1.5 var(--serif);color:var(--ink);text-align:center",
      }, "ℒ(θ) = ℒ\u2099(θ) + Σᵢ (λ⁄2) Fᵢ (θᵢ − θ*ᴀ,ᵢ)²"),
      // The page rides at the end of the quotation as a small tinted mark,
      // the way the app sets it — not as a line of prose under it.
      el("div", {
        style:
          "border-left:3px solid var(--accent-line);background:var(--accent-soft);" +
          "border-radius:0 0 8px 0;padding:0 12px 8px;margin-top:-1px",
      }, el("button", {
        style:
          "border:none;background:var(--accent-soft);color:var(--accent);border-radius:5px;" +
          "padding:2px 7px;font:600 11px/1 var(--sans);cursor:pointer",
        onclick: backToPage,
      }, L("3쪽", "p. 3"))),
      el("div", {
        contenteditable: "true",
        style: "border:1px solid var(--rule);border-radius:10px;padding:10px 12px;font-size:14px;" +
               "min-height:64px;outline:none;background:var(--card)",
      }, L("스프링의 뻣뻣함이 파라미터마다 다르다는 게 핵심이다.",
           "The point is that the spring's stiffness differs from parameter to parameter.")));
    hint.innerHTML = L(
      "<b style='color:var(--green)'>구절이 주소를 들고 왔어요.</b> 수식은 수식으로 남아요 — 인용을 누르면 그 줄로 돌아가요.",
      "<b style='color:var(--green)'>The passage brought its address along.</b> The formula stays a formula — click the quotation and the paper opens at that line.");
  };

  const send = el("button", {
    class: "btn btn-primary",
    onclick: () => { sent = true; render(); },
  }, el("span", { class: "key", style: "background:rgba(255,255,255,.16);border-color:rgba(255,255,255,.3);color:#fff" }, "⌘L"),
     L("고른 문장을 노트로", "Selection to note"));

  render();
  return el("div", { class: "demo-shell", style: "flex-direction:column;gap:12px" },
    el("div", { class: "demo-shell", style: "flex:1;min-height:0" },
      page,
      el("div", { class: "pane", style: "flex:1;min-height:0;display:flex;flex-direction:column" },
        el("div", { style: "font:600 11px/1 var(--sans);letter-spacing:.05em;color:var(--ink-3);text-transform:uppercase;margin-bottom:10px" }, "Note"),
        noteBody)),
    el("div", { style: "display:flex;align-items:center;gap:12px;flex-wrap:wrap" }, send, hint));
}

/* ═══════════════════ 7 · Notes that know each other ═══════════════════ */

function noteLinks() {
  const NOTES = {
    // A [[name]] is drawn as the other note's title, so the English is
    // written to read with a title in that spot.
    ewc: {
      t: L("왜 EWC는 피셔 정보를 쓰는가", "Why EWC uses Fisher information"),
      b: L("손실의 곡률이 큰 방향일수록 그 파라미터는 옛 과제에 중요하다. 피셔 정보 행렬의 대각이 그 곡률의 값싼 추정이다. 그래서 [[spring]]의 뻣뻣함을 파라미터마다 다르게 줄 수 있다. 이것은 [[laplace]]와 같은 근사다.",
           "The more the loss curves along a direction, the more that parameter matters to the old task. The diagonal of the Fisher information matrix is a cheap estimate of that curvature. That is what lets each parameter have its own stiffness — see [[spring]]. It is the same approximation as [[laplace]]."),
    },
    spring: {
      t: L("스프링 비유는 어디까지 맞는가", "How far the spring metaphor holds"),
      b: L("이차 페널티는 옛 해에 파라미터를 매어 두는 스프링이다. 다만 모든 스프링의 뻣뻣함이 같으면 아무것도 못 배운다. [[ewc]]가 이 문제를 푼다.",
           "A quadratic penalty is a spring tying the parameters to the old solution. But if every spring is equally stiff, nothing new can be learned. [[ewc]] solves this."),
    },
    laplace: {
      t: L("라플라스 근사", "Laplace approximation"),
      b: L("사후분포를 최빈값 주변의 가우시안으로 본다. 그 정밀도가 곧 곡률이고, 곡률이 곧 중요도다. [[ewc]]는 이 근사를 연속 학습에 옮긴 것이다.",
           "Take the posterior to be a Gaussian around its mode. Its precision is the curvature, and the curvature is the importance. [[ewc]] carries this approximation over to continual learning."),
    },
  };
  let current = "ewc";
  const trail = [];

  const card = el("div", { class: "pane", style: "flex:1;min-height:0" });
  const crumbs = el("div", { style: "display:flex;gap:6px;align-items:center;flex-wrap:wrap;min-height:26px" });

  const open = (id, push = true) => {
    if (push && id !== current) trail.push(current);
    current = id;
    render();
  };

  const render = () => {
    const note = NOTES[current];
    const body = note.b.replace(/\[\[(\w+)\]\]/g, (_, id) =>
      `<button data-note="${id}" style="border:none;background:var(--accent-soft);color:var(--accent);` +
      `border-radius:5px;padding:1px 6px;cursor:pointer;font:inherit">${NOTES[id].t}</button>`);
    card.replaceChildren(
      el("div", { style: "font-family:var(--display);font-size:18px;font-weight:600;margin-bottom:10px" }, note.t),
      el("div", { style: "font-size:14.5px;line-height:1.85", html: body }));
    card.querySelectorAll("[data-note]").forEach((b) =>
      b.addEventListener("click", () => open(b.dataset.note)));

    crumbs.replaceChildren(
      trail.length
        ? el("button", {
            class: "btn btn-ghost",
            style: "padding:5px 12px;font-size:13px",
            onclick: () => { const back = trail.pop(); if (back) open(back, false); },
          }, "← " + NOTES[trail[trail.length - 1]].t)
        : el("span", { class: "hint", style: "margin:0" },
            L("노트 안의 이름을 누르면 그 노트가 열려요.", "Click a name inside a note and that note opens.")));
  };

  render();
  return el("div", { class: "demo-shell", style: "flex-direction:column;gap:10px" }, crumbs, card);
}

/* ══════════════════════ 8 · The panes are yours ══════════════════════ */

function panes() {
  const PANES = [
    { id: "sidebar", n: L("서가", "Shelf"), w: 0.9, c: "var(--paper)" },
    { id: "list", n: L("논문 목록", "Paper list"), w: 1.3, c: "var(--paper-2)" },
    { id: "reader", n: L("논문", "Paper"), w: 2.6, c: "var(--card)" },
    { id: "inspector", n: L("인스펙터", "Inspector"), w: 1.2, c: "var(--paper-2)" },
  ];
  const on = new Set(PANES.map((p) => p.id));

  const window_ = el("div", {
    style:
      "flex:1;display:flex;gap:6px;padding:8px;background:var(--paper);border:1px solid var(--rule);" +
      "border-radius:14px;min-height:0;overflow:hidden",
  });

  const draw = () => {
    window_.replaceChildren(...PANES.map((p) => {
      const box = el("div", {
        style:
          `flex:${on.has(p.id) ? p.w : 0} 1 0;min-width:0;background:${p.c};` +
          "border:1px solid var(--rule);border-radius:9px;overflow:hidden;" +
          "transition:flex-grow .32s cubic-bezier(.22,.61,.36,1),opacity .28s,margin .32s;" +
          (on.has(p.id) ? "opacity:1" : "opacity:0;margin-left:-3px;border-width:0"),
      },
        el("div", { style: "font:11px/1 var(--sans);color:var(--ink-3);padding:9px 10px;white-space:nowrap" }, p.n),
        el("div", { style: "padding:0 10px" },
          [0, 1, 2, 3, 4].map((i) =>
            el("div", {
              style: `height:6px;border-radius:3px;background:var(--rule);margin-bottom:7px;` +
                     `width:${[92, 74, 88, 60, 80][i]}%`,
            }))));
      return box;
    }));
  };

  const toggles = el("div", { style: "display:flex;gap:8px;flex-wrap:wrap" },
    PANES.map((p) =>
      el("button", {
        class: "chip is-current",
        style: "font-size:13px;padding:7px 14px",
        onclick: (e) => {
          if (on.has(p.id)) on.delete(p.id); else on.add(p.id);
          e.currentTarget.classList.toggle("is-current", on.has(p.id));
          draw();
        },
      }, p.n)));

  draw();
  return el("div", { class: "demo-shell", style: "flex-direction:column;gap:12px" },
    toggles, window_,
    el("p", { class: "hint" },
      L("읽을 때는 논문만 두고, 정리할 때는 넷을 다 펴요. 창은 껐다 켜는 거지, 참으면서 보는 게 아니에요.",
        "Keep only the paper while you read. Open all four while you sort. A pane switches off and on — you never put up with it.")));
}

/* ════════════════════ 9 · One folder, three devices ════════════════════ */

/* One folder, three desktops.
   A different claim from the one below it: that is about how *fast* a mark
   crosses between Apple devices; this is about there being no wall at all. */
function everyDesktop() {
  const desk = (name, ratio, delay) => {
    const mark = el("div", {
      style: "height:9px;border-radius:3px;background:var(--mark);width:64%;opacity:0;transition:opacity .4s",
    });
    const box = el("div", {
      style: "flex:1;min-width:0;display:flex;flex-direction:column;gap:8px;align-items:center",
    },
      el("div", {
        style:
          `width:100%;aspect-ratio:${ratio};background:var(--card);border:1px solid var(--rule);` +
          "border-radius:10px;padding:10px;display:flex;flex-direction:column;gap:6px;overflow:hidden",
      },
        el("div", { style: "height:7px;border-radius:3px;background:var(--rule);width:86%" }),
        mark,
        el("div", { style: "height:7px;border-radius:3px;background:var(--rule);width:74%" }),
        el("div", { style: "height:7px;border-radius:3px;background:var(--rule);width:58%" })),
      el("div", { style: "font-size:11.5px;color:var(--ink-3)" }, name));
    box.mark = mark;
    box.delay = delay;
    return box;
  };

  const mac = desk(L("맥", "Mac"), "16/10", 0);
  const win = desk(L("윈도우", "Windows"), "16/10", 900);
  const linux = desk(L("리눅스", "Linux"), "16/10", 900);
  const caption = el("p", { class: "hint" },
    L("라이브러리는 폴더 하나예요. 클라우드 폴더든 USB든, 파일이 닿는 곳이면 돼요.",
      "The library is one folder. A cloud folder or a USB stick — anywhere the files can reach."));

  const run = () => {
    for (const d of [mac, win, linux]) {
      d.mark.style.opacity = "0";
      setTimeout(() => { d.mark.style.opacity = "1"; }, d.delay);
    }
    caption.innerHTML = L(
      "표시를 <b>PDF 파일 안에</b> 썼고, 폴더는 그 파일을 옮겼을 뿐이에요. 계정도, 서버도, 내보내기도 없어요.",
      "The mark went <b>into the PDF file</b>, and the folder only carried the file across. No account, no server, no export.");
  };

  return el("div", { class: "demo-shell", style: "flex-direction:column;gap:14px" },
    el("div", { style: "display:flex;gap:8px;flex-wrap:wrap;align-items:center" },
      el("button", { class: "btn btn-primary", onclick: run }, L("맥에서 하이라이트 긋기", "Highlight on the Mac")),
      el("span", { class: "hint" }, L("0.5.0부터 윈도우·리눅스에서도", "Windows and Linux too, since 0.5.0"))),
    el("div", { style: "display:flex;gap:12px;align-items:flex-end;width:100%" }, mac, win, linux),
    caption);
}

function threeDevices() {
  const device = (name, ratio, delay) => {
    const mark = el("div", {
      style: "height:9px;border-radius:3px;background:var(--mark);width:62%;opacity:0;transition:opacity .45s",
    });
    const box = el("div", {
      style:
        `flex:1;min-width:0;display:flex;flex-direction:column;gap:8px;align-items:center`,
    },
      el("div", {
        style:
          `width:100%;aspect-ratio:${ratio};background:var(--card);border:1px solid var(--rule);` +
          "border-radius:10px;padding:10px;display:flex;flex-direction:column;gap:6px;overflow:hidden",
      },
        el("div", { style: "height:7px;border-radius:3px;background:var(--rule);width:88%" }),
        el("div", { style: "height:7px;border-radius:3px;background:var(--rule);width:70%" }),
        mark,
        el("div", { style: "height:7px;border-radius:3px;background:var(--rule);width:80%" }),
        el("div", { style: "height:7px;border-radius:3px;background:var(--rule);width:52%" })),
      el("div", { style: "font-size:11.5px;color:var(--ink-3)" }, name));
    box.mark = mark;
    box.delay = delay;
    return box;
  };

  const mac = device(L("맥", "Mac"), "16/10", 0);
  const pad = device(L("아이패드", "iPad"), "4/3", 1100);
  const phone = device(L("아이폰", "iPhone"), "9/16", 1900);
  const caption = el("p", { class: "hint" },
    L("맥에서 그으면, 다른 두 기기도 몇 초 안에 같은 줄을 보여줘요.",
      "Draw on the Mac, and within seconds the other two show the same line."));

  const run = () => {
    for (const d of [mac, pad, phone]) {
      d.mark.style.opacity = "0";
      setTimeout(() => { d.mark.style.opacity = "1"; }, d.delay);
    }
    caption.innerHTML = L(
      "표시는 몇 KB짜리 저널로 먼저 건너가고, <b>20 MB PDF는 뒤따라와요.</b> 파일을 기다릴 일이 없어요.",
      "The mark crosses first as a journal of a few KB; <b>the 20 MB PDF follows.</b> Nobody waits for the file.");
  };

  return el("div", { class: "demo-shell", style: "flex-direction:column;gap:14px" },
    el("div", { style: "display:flex;gap:8px;flex-wrap:wrap;align-items:center" },
      el("button", { class: "btn btn-primary", onclick: run }, L("맥에서 하이라이트 긋기", "Highlight on the Mac")),
      el("span", { class: "hint", style: "margin:0" }, L("iCloud Drive 폴더 하나면 돼요.", "One iCloud Drive folder is all it takes."))),
    el("div", { class: "pane", style: "flex:1;min-height:0;display:flex;gap:16px;align-items:center;justify-content:center" },
      mac, pad, phone),
    caption);
}

/* ═════════════════════ the draft that becomes a manuscript ══════════════ */

/// A draft note, and what ⇧⌘E makes of it.
///
/// The end of the whole thing, and the hardest to believe without seeing:
/// the passages you pressed ⌘L on come out as \cite{키}, the notes you linked
/// come out as their own sentences, and the .bib holds exactly the papers you
/// actually cited — nothing else in the library.
function draftToManuscript() {
  let rendered = false;

  const draft = el("div", { class: "pane", style: "flex:1;min-height:0" },
    el("div", { style: "font-weight:600;margin-bottom:8px" }, L("초안 · 관련연구", "Draft · Related work")),
    el("div", { style: "font-size:13.5px;line-height:1.7" },
      el("div", { style: "color:var(--ink-3);font-size:11px;letter-spacing:.06em;text-transform:uppercase;margin-bottom:6px" },
        L("연속 학습", "Continual learning")),
      el("div", { style: "display:flex;gap:8px;margin-bottom:8px" },
        el("span", { style: "color:var(--ink-3)" }, "•"),
        el("span", {},
          L("EWC는 파라미터마다 다른 뻣뻣함의 스프링이다 ", "EWC is a spring with a different stiffness for each parameter "),
          el("span", {
            style: "background:var(--accent-soft);color:var(--accent);border-radius:5px;" +
                   "padding:1px 6px;font-size:12px;white-space:nowrap",
          }, L("❝ Kirkpatrick 2017 · 3쪽", "❝ Kirkpatrick 2017 · p. 3")))),
      el("div", { style: "display:flex;gap:8px" },
        el("span", { style: "color:var(--ink-3)" }, "•"),
        el("span", {},
          L("이 관점은 ", "This view follows from "),
          el("span", { style: "color:var(--accent)" },
            L("[[시냅스 강화가 기억을 지킨다]]", "[[Synaptic consolidation protects memory]]")),
          L(" 에서 이어진다.", ".")))));

  const out = el("div", { class: "pane", style: "flex:1;min-height:0;font:12.5px/1.65 var(--mono);white-space:pre-wrap" });
  const hint = el("p", { class: "hint" });

  const render = () => {
    if (!rendered) {
      out.textContent = L("⇧⌘E를 누르면 여기에 원고가 나와요.", "Press ⇧⌘E and the manuscript appears here.");
      out.style.color = "var(--ink-3)";
      hint.innerHTML = L("초안도 노트 하나예요 — 구절과 링크로 지어요.", "A draft is one note, built from passages and links.");
      return;
    }
    out.style.color = "var(--ink)";
    out.textContent =
      L("EWC는 파라미터마다 다른 뻣뻣함의 스프링이다", "EWC is a spring with a different stiffness for each parameter") +
      "~\\cite{kirkpatrick2017overcoming}.\n" +
      L("이 관점은 시냅스 강화가 기억을 지킨다는 관찰에서 이어진다.",
        "This view follows from the observation that synaptic consolidation protects memory.") + "\n\n" +
      L("% draft.bib — 인용한 논문만", "% draft.bib — only the papers cited") + "\n" +
      "@article{kirkpatrick2017overcoming,\n" +
      "  title  = {Overcoming catastrophic forgetting in neural networks},\n" +
      "  author = {Kirkpatrick, James and Pascanu, Razvan and others},\n" +
      "  year   = {2017}, journal = {PNAS}\n}";
    hint.innerHTML = L(
      "<b style='color:var(--green)'>Overleaf에 붙이면 그대로 컴파일돼요.</b> 인용 키도, .bib도 손으로 옮기지 않았어요.",
      "<b style='color:var(--green)'>Paste it into Overleaf and it compiles.</b> Nobody typed the citation key or the .bib.");
  };

  const go = el("button", {
    class: "btn btn-primary",
    onclick: () => { rendered = !rendered; render(); },
  }, el("span", { class: "key", style: "background:rgba(255,255,255,.16);border-color:rgba(255,255,255,.3);color:#fff" }, "⇧⌘E"),
     L("원고로 만들기", "Render as manuscript"));

  render();
  return el("div", { class: "demo-shell", style: "flex-direction:column;gap:12px" },
    el("div", { class: "demo-shell", style: "flex:1;min-height:0" }, draft, out),
    el("div", { style: "display:flex;gap:10px;align-items:center;flex-wrap:wrap" }, go, hint));
}

/* ════════════════ the drawing layer, and papers side by side ════════════
   The two things 0.8.0 added, each shown rather than claimed. */

/* Frames, groups and auto layout — on the page of a paper.
   The claim is not "it has shapes". Every PDF app has shapes. It is that the
   shapes behave the way a design tool's do, and still land in the file as
   ordinary annotations. */
function figmaDrawing() {
  const TOOLS = [
    ["V", L("고르기", "Move")],
    ["F", L("프레임", "Frame")],
    ["R", L("네모", "Rectangle")],
    ["P", L("펜", "Pen")],
    ["T", L("글", "Text")],
  ];
  let chosen = 1;
  const rack = el("div", {
    style: "display:inline-flex;gap:2px;padding:4px;border-radius:12px;background:var(--panel-2);" +
           "border:1px solid var(--rule)",
  });
  const buttons = TOOLS.map(([key, name], i) => {
    const b = el("button", {
      class: "pick",
      title: `${name} (${key})`,
      style: "width:30px;height:30px;border-radius:8px;font-weight:600",
      onclick: () => { chosen = i; paint(); },
    }, key);
    rack.append(b);
    return b;
  });
  const paint = () => buttons.forEach((b, i) => b.setAttribute("aria-pressed", String(i === chosen)));
  paint();

  /* Three cards on the page, dropped where a hand drops them. */
  const card = (title, body, x, y) => {
    const node = el("div", {
      style: "position:absolute;width:132px;background:var(--card);border:1px solid var(--rule);" +
             "border-radius:10px;padding:8px 9px;box-shadow:var(--shadow-1);transition:all .5s cubic-bezier(.2,.7,.2,1)",
    },
      el("div", { style: "font-size:11px;font-weight:700;margin-bottom:3px" }, title),
      el("div", { style: "font-size:11px;color:var(--ink-3);line-height:1.5", html: body }));
    node.style.left = x + "px";
    node.style.top = y + "px";
    return node;
  };

  const LOOSE = [[92, 50], [186, 108], [104, 174]];
  const cards = [
    card(L("가정", "Assumption"), L("과제는 순서대로 와요.", "Tasks arrive in order."), ...LOOSE[0]),
    card(L("정의", "Definition"),
      `${f("F")} = ${f("E")}[&nabla;<sub style="font-size:.72em">&theta;</sub>${f("L")}]`, ...LOOSE[1]),
    card(L("결론", "So"), L("곡률이 큰 쪽을 붙잡아요.", "Hold the steep directions."), ...LOOSE[2]),
  ];

  const name = el("div", {
    style: "position:absolute;left:0;top:-17px;font-size:10.5px;color:var(--accent);font-weight:600",
  }, L("프레임 · 3장", "Frame · 3 cards"));

  const frame = el("div", {
    style: "position:absolute;left:74px;top:30px;width:272px;height:214px;border:1.5px solid var(--accent);" +
           "border-radius:12px;background:color-mix(in srgb, var(--accent) 5%, transparent);" +
           "transition:all .5s cubic-bezier(.2,.7,.2,1)",
  }, name);

  const page = el("div", {
    style: "position:relative;width:min(100%,420px);height:268px;margin:0 auto;background:var(--card);" +
           "border:1px solid var(--rule);border-radius:12px;overflow:hidden",
  },
    el("div", { style: "position:absolute;left:18px;top:8px;right:18px;height:7px;border-radius:3px;background:var(--rule)" }),
    frame, ...cards);

  const caption = el("p", { class: "hint" },
    L("프레임 안에 놓으면 프레임의 것이 돼요. 묶기는 ⌘G, 오토 레이아웃은 ⇧A예요.",
      "Drop something inside a frame and it belongs to the frame. ⌘G groups, ⇧A turns on auto layout."));

  let tidy = false;
  const arrange = () => {
    tidy = !tidy;
    if (tidy) {
      cards.forEach((c, i) => {
        c.style.left = "96px";
        c.style.top = (48 + i * 62) + "px";
        c.style.width = "228px";
      });
      frame.style.height = "196px";
      name.textContent = L("프레임 · 세로 · 간격 12", "Frame · Vertical · gap 12");
      caption.innerHTML = L(
        "프레임이 자식을 줄로 세우고 <b>제 크기를 자식에 맞춰요.</b> 카드 하나를 지우면 나머지가 따라 올라와요.",
        "The frame lines its children up and <b>takes its size from them.</b> Delete one card and the rest move up.");
    } else {
      cards.forEach((c, i) => {
        c.style.left = LOOSE[i][0] + "px";
        c.style.top = LOOSE[i][1] + "px";
        c.style.width = "132px";
      });
      frame.style.height = "214px";
      name.textContent = L("프레임 · 3장", "Frame · 3 cards");
      caption.innerHTML = L(
        "그린 것은 사이드카가 아니라 <b>PDF 주석으로도 써져요</b> — Preview에서도 보여요.",
        "What you draw is <b>written into the PDF as annotations</b> too — it opens in Preview.");
    }
  };

  return el("div", { class: "demo-shell", style: "flex-direction:column;gap:12px" },
    el("div", { style: "display:flex;gap:10px;flex-wrap:wrap;align-items:center" },
      rack,
      el("button", { class: "btn btn-primary", onclick: arrange }, L("오토 레이아웃", "Auto layout")),
      el("span", { class: "hint", style: "margin:0" }, L("0.8.0부터", "New in 0.8.0"))),
    page,
    caption);
}

/* Four papers at once — and one of them in a window of its own. */
function papersSideBySide() {
  const pane = (title) => el("div", {
    style: "flex:1;min-width:0;background:var(--card);border:1px solid var(--rule);border-radius:10px;" +
           "padding:9px 10px;display:flex;flex-direction:column;gap:5px;overflow:hidden;transition:all .45s",
  },
    el("div", { style: "font-size:11px;font-weight:700;white-space:nowrap;overflow:hidden;text-overflow:ellipsis" }, title),
    el("div", { style: "height:6px;border-radius:3px;background:var(--rule);width:92%" }),
    el("div", { style: "height:6px;border-radius:3px;background:var(--mark);width:64%" }),
    el("div", { style: "height:6px;border-radius:3px;background:var(--rule);width:80%" }),
    el("div", { style: "height:6px;border-radius:3px;background:var(--rule);width:52%" }));

  const TITLES = ["EWC", "Progressive Nets", "PackNet", "GEM"];
  const area = el("div", {
    style: "flex:1;min-height:188px;display:flex;flex-wrap:wrap;gap:8px;align-content:stretch",
  });

  const shelf = el("div", { style: "display:flex;flex-direction:column;gap:4px;width:132px;flex:0 0 auto" },
    el("div", { style: "font-size:10px;letter-spacing:.06em;text-transform:uppercase;color:var(--ink-3);margin-bottom:2px" },
      L("열린 논문", "Open papers")),
    ...TITLES.map((t) => el("div", {
      style: "font-size:11.5px;padding:5px 7px;border-radius:7px;background:var(--panel-2);" +
             "white-space:nowrap;overflow:hidden;text-overflow:ellipsis",
    }, t)));

  const caption = el("p", { class: "hint" },
    L("⇧⌘O로 열린 논문을 펼쳐요. 한 줄을 창 밖으로 끌면 그 논문만 담은 창이 열려요.",
      "⇧⌘O lists what is open. Drag a row out of the window and that paper gets a window of its own."));

  let many = 1;
  const show = (n) => {
    many = n;
    area.replaceChildren(...TITLES.slice(0, n).map((t) => {
      const p = pane(t);
      p.style.flex = n === 1 ? "1 1 100%" : "1 1 calc(50% - 4px)";
      p.style.minHeight = n > 2 ? "86px" : "auto";
      return p;
    }));
  };
  show(1);

  return el("div", { class: "demo-shell", style: "flex-direction:column;gap:12px" },
    el("div", { style: "display:flex;gap:8px;flex-wrap:wrap;align-items:center" },
      el("button", { class: "btn btn-primary", onclick: () => show(many >= 4 ? 1 : many + 1) },
        L("한 편 더 나란히", "Add one beside it")),
      el("span", { class: "hint", style: "margin:0" }, L("최대 넷까지", "Up to four")),
    ),
    el("div", { style: "flex:1;min-height:0;display:flex;gap:10px" }, shelf, area),
    caption);
}

/* ═══════════════════ 11 · A paper, or a document ═══════════════════
   The app began as a reader for papers and now holds everything else
   somebody reads. Rather than guess silently, it asks once — and the form
   underneath is the answer's, not a compromise between two. */
function paperOrDocument() {
  const PAPER = [
    [L("학술지·학회", "Venue"), "Neural Information Processing Systems"],
    [L("권·호", "Volume, issue"), "37 · 2"],
    ["DOI", "10.5555/3600270.3601883"],
    [L("인용 키", "Citation key"), "almudevar2026representation"],
  ];
  const BOOK = [
    [L("출판사", "Publisher"), "The MIT Press"],
    [L("펴낸 곳", "Place"), L("케임브리지, 매사추세츠", "Cambridge, Massachusetts")],
    [L("판", "Edition"), L("2판", "Second edition")],
    ["ISBN", "978-0-262-03924-6"],
  ];
  const LECTURE = [
    [L("과목", "Course"), "STA 512"],
    [L("만든 사람", "Made by"), L("서현교", "Hyeongyo Seo")],
    [L("해", "Year"), "2026"],
    [L("파일", "File"), "lecture06.pdf"],
  ];
  const DOC = [
    [L("펴낸 곳", "From"), L("고려대학교 산학협력단", "Korea University")],
    [L("해", "Year"), "2026"],
    [L("종류", "Kind"), L("보고서", "Report")],
    [L("파일", "File"), "2026-2 계약서.pdf"],
  ];

  const fields = el("div", { style: "display:flex;flex-direction:column;gap:7px" });
  const hint = el("p", { class: "hint", style: "margin:0" });
  const buttons = {};

  const row = ([label, value]) => el("div", {
    style: "display:flex;flex-direction:column;gap:2px;padding:7px 9px;border-radius:8px;background:var(--panel-2)",
  },
    el("div", { style: "font-size:10px;font-weight:700;letter-spacing:.02em;color:var(--ink-3)" }, label),
    el("div", { style: "font-size:12.5px;white-space:nowrap;overflow:hidden;text-overflow:ellipsis" }, value));

  const SETS = { paper: PAPER, book: BOOK, lecture: LECTURE, document: DOC };
  const HINTS = () => ({
    paper: L("등록기관에 물어 서지를 채우고, 비슷한 후보를 보여줘요.",
             "Paper Time looks the record up and offers the near matches."),
    book: L("책도 인용하니까 인용 키는 그대로 있어요. 학술지·권·호는 사라지고요 — 교과서가 «권 9, 호 5, 1054쪽»이 되던 자리예요.",
            "A book is cited too, so it keeps its key — but the journal, the volume and the issue go. "
            + "That is where a textbook used to come back as volume 9, issue 5, page 1054."),
    lecture: L("쪽이 가로로 넓거나 이름이 강의를 가리키면 앱이 먼저 짐작해요. 강의자료는 읽는 것이지 인용하는 것이 아니라서, 인용 키 칸도 없어요.",
               "Pages wider than they are tall, or a name that names a course, and the app guesses it. "
               + "Course material is read rather than cited, so there is no citation key."),
    document: L("학술지·DOI·인용 키 칸이 사라져요. 등록기관에 묻지도 않아요 — 계약서 제목이 밖으로 나갈 일이 없어요.",
                "Journal, DOI and citation key go away. Nothing is looked up online, so a contract's title never leaves the machine."),
  });

  const answer = (kind) => {
    for (const [k, b] of Object.entries(buttons)) b.classList.toggle("on", k === kind);
    fields.replaceChildren(...SETS[kind].map(row));
    hint.textContent = HINTS()[kind];
  };

  const seg = el("div", { class: "seg" },
    ...[
      ["paper", L("논문", "A paper")],
      ["book", L("책", "A book")],
      ["lecture", L("강의자료", "Course")],
      ["document", L("일반 문서", "A document")],
    ].map(([k, name]) => {
      const b = el("button", { type: "button", onclick: () => answer(k) }, name);
      buttons[k] = b;
      return b;
    }));

  answer("paper");

  return el("div", { class: "demo-shell", style: "flex-direction:column;gap:12px" },
    el("div", { class: "pane", style: "flex:1;display:flex;flex-direction:column;gap:11px" },
      el("div", { style: "font-size:13px;font-weight:700" },
        L("이 PDF는 무엇인가요?", "What is this PDF?")),
      seg,
      el("div", { style: "height:1px;background:var(--rule)" }),
      fields),
    hint);
}

/* ═════════════════════ 12 · Every page, small ═════════════════════
   A scanned contract has no headings to make a table of contents out of.
   It has pages, and you know the one you want when you see it. */
function pageGrid() {
  const PAGES = 12;
  let current = 4;
  const grid = el("div", {
    style: "display:grid;grid-template-columns:repeat(4,1fr);gap:8px;flex:1;min-height:0",
  });

  const paint = () => grid.replaceChildren(...Array.from({ length: PAGES }, (_, i) => {
    const on = i === current;
    const page = el("div", {
      style: "aspect-ratio:3/4;border-radius:5px;background:var(--panel);cursor:pointer;" +
             "display:flex;flex-direction:column;gap:3px;padding:7px 6px;overflow:hidden;transition:box-shadow .2s;" +
             "box-shadow:" + (on ? "0 0 0 2px var(--accent)" : "inset 0 0 0 1px var(--rule)"),
      onclick: () => { current = i; paint(); },
    },
      ...Array.from({ length: 6 }, (_, line) => el("div", {
        style: "height:2px;border-radius:1px;background:var(--rule);width:" +
               (line === 0 ? "62%" : line === 5 ? "44%" : "100%"),
      })),
      el("div", { style: "margin-top:auto;font-size:9px;color:var(--ink-3);text-align:center" }, String(i + 1)));
    return page;
  }));
  paint();

  return el("div", { class: "demo-shell", style: "flex-direction:column;gap:12px" },
    el("div", { style: "display:flex;gap:8px;align-items:center" },
      el("span", { class: "key" }, "⇧⌘L"),
      el("div", { class: "seg" },
        el("button", { type: "button" }, L("차례", "Contents")),
        el("button", { type: "button", class: "on" }, L("쪽", "Pages")))),
    el("div", { class: "pane", style: "flex:1;min-height:200px;display:flex" }, grid),
    el("p", { class: "hint", style: "margin:0" },
      L("제목을 하나도 못 찾은 PDF는 이 칸으로 바로 열려요 — 스캔한 계약서, «1장»만 반복되는 안내서.",
        "A PDF whose headings could not be read opens straight to this tab — a scanned contract, a handbook whose every heading is “Chapter 7”.")));
}

/* ═══════════════════ 13 · A library is many folders ═══════════════════ */
function manyLibraries() {
  const FOLDERS = [
    { name: "PaperLibrary", where: "cloud", count: 62, papers: ["Attention Is All You Need", "Diffusion Policy", "OpenVLA"] },
    { name: "test", where: "cloud", count: 11, papers: ["Scaling Laws", "Chinchilla"] },
    { name: L("강화학습", "RL seminar"), where: "disk", count: 6, papers: ["PPO", "SAC", "Dreamer V3"] },
  ];
  let current = -1;

  const cloud = `<svg viewBox="0 0 16 16" width="14" height="14" fill="none" stroke="currentColor" stroke-width="1.3"
    stroke-linecap="round" stroke-linejoin="round"><path d="M4.6 12.4h6.2a3 3 0 0 0 .3-6 4.1 4.1 0 0 0-7.7-.6A2.9 2.9 0 0 0 4.6 12.4Z"/></svg>`;
  const disk = `<svg viewBox="0 0 16 16" width="14" height="14" fill="none" stroke="currentColor" stroke-width="1.3"
    stroke-linecap="round" stroke-linejoin="round"><rect x="1.9" y="4.2" width="12.2" height="7.6" rx="1.8"/><circle cx="11.4" cy="8" r="1.2"/><path d="M4.2 8h3.6"/></svg>`;

  const list = el("div", { style: "flex:1;min-width:0;display:flex;flex-direction:column;gap:5px" });
  const rows = el("div", { style: "display:flex;flex-direction:column;gap:2px" });

  const paint = () => {
    rows.replaceChildren(...FOLDERS.map((folder, i) => {
      const on = i === current;
      return el("button", {
        type: "button",
        style: "display:flex;align-items:center;gap:8px;padding:5px 7px;border:none;cursor:pointer;text-align:left;" +
               "border-radius:8px;background:" + (on ? "var(--accent-soft)" : "transparent"),
        onclick: () => { current = on ? -1 : i; paint(); },
      },
        el("span", { style: "color:var(--ink-3);display:flex", html: folder.where === "cloud" ? cloud : disk }),
        el("span", {
          style: "font-size:12px;font-weight:500;color:var(--accent);background:var(--accent-soft);" +
                 "border:.5px solid var(--accent-line);border-radius:6px;padding:1px 6px;margin-right:auto",
        }, folder.name),
        el("span", { style: "font-size:11.5px;color:var(--ink-3)" }, String(folder.count)));
    }));

    const shown = current < 0 ? FOLDERS.flatMap((x) => x.papers) : FOLDERS[current].papers;
    list.replaceChildren(
      el("div", { style: "font-size:10px;letter-spacing:.06em;text-transform:uppercase;color:var(--ink-3)" },
        current < 0 ? L("모두", "All") : FOLDERS[current].name),
      ...shown.map((p) => el("div", {
        style: "font-size:11.5px;padding:6px 8px;border-radius:7px;background:var(--panel-2);" +
               "white-space:nowrap;overflow:hidden;text-overflow:ellipsis",
      }, p)));
  };
  paint();

  return el("div", { class: "demo-shell", style: "flex-direction:column;gap:12px" },
    // Wraps rather than squeezing: on a phone the two parts stack, and the
    // list of papers keeps enough width to be a list of titles.
    el("div", { style: "flex:1;min-height:180px;display:flex;gap:12px;flex-wrap:wrap" },
      el("div", { class: "pane", style: "flex:1 1 180px;padding:11px 9px;display:flex;flex-direction:column;gap:6px" },
        el("div", { style: "font-size:10px;letter-spacing:.06em;text-transform:uppercase;color:var(--ink-3);padding:0 7px" },
          L("라이브러리", "Libraries")),
        rows),
      el("div", { class: "pane", style: "flex:2 1 210px;min-width:0;padding:11px 12px" }, list)),
    el("p", { class: "hint", style: "margin:0" },
      L("폴더 이름을 누르면 그 폴더만 봐요. 연결을 해제해도 파일도 기록도 그대로예요 — 노트와 태그까지 그 폴더 안에 있으니까요.",
        "Click a folder's name to see only that folder. Disconnect one and its files and records stay exactly as they were — its notes and tags live inside it too.")));
}

/* ═══════════════════ 14 · The name on the file ═══════════════════ */
function fileName() {
  const field = el("input", {
    type: "text", value: "2403.18293v1.pdf", spellcheck: "false",
    style: "width:100%;font:inherit;font-size:13px;padding:6px 9px;border-radius:8px;" +
           "border:1px solid var(--rule);background:var(--panel-2);color:var(--ink)",
  });
  const finder = el("div", { style: "font-size:12.5px" }, "2403.18293v1.pdf");
  const sync = () => { finder.textContent = field.value.trim() || "…"; };
  field.addEventListener("input", sync);

  return el("div", { class: "demo-shell", style: "flex-direction:column;gap:12px" },
    el("div", { class: "pane", style: "display:flex;flex-direction:column;gap:6px" },
      el("div", { style: "font-size:10px;font-weight:700;letter-spacing:.02em;color:var(--ink-3)" },
        L("파일 · 이름", "File · Name")),
      field),
    el("div", {
      style: "display:flex;align-items:center;gap:9px;padding:9px 11px;border-radius:10px;" +
             "background:var(--panel-2);border:1px solid var(--rule)",
    },
      el("span", { style: "font-size:15px" }, "📄"),
      finder,
      el("span", { class: "hint", style: "margin:0 0 0 auto" }, L("Finder에서도", "In Finder too"))),
    el("p", { class: "hint", style: "margin:0" },
      L("표시도 필기도 노트도 논문의 번호를 따라다녀서, 이름만 바뀌고 나머지는 하나도 안 움직여요.",
        "Marks, handwriting and notes follow the paper's identifier, so the name changes and nothing else moves.")));
}

/* ═══════════════════ 15 · A PDF somebody locked ═══════════════════
   Three kinds of locked, and the app can open exactly one of them. Saying
   which is the whole feature: a blank page with no message is the bug. */
function lockedPDF() {
  const CASES = [
    { key: "password", name: L("암호", "A password"),
      can: true,
      line: L("암호를 넣으면 열려요. 암호는 어디에도 안 남아요.",
              "Type the password and it opens. Nothing keeps it."),
      body: L("표준 암호화(/Standard)예요. 이건 열쇠를 사용자가 들고 있어요.",
              "Standard encryption. This is the one whose key you hold.") },
    { key: "irm", name: L("회사 권한", "Company rights"),
      can: false,
      line: L("이건 못 열어요. 열쇠를 회사의 서버가 들고 있어요.",
              "This one cannot be opened here. The key is on your company's server."),
      body: L("Microsoft Purview 같은 권한 관리예요. Acrobat이 여는 건 등록된 앱이라서예요 — 그렇다고 말해 주는 게 빈 화면보다 나아요.",
              "Rights management, like Microsoft Purview. Acrobat opens it because Acrobat is a registered app. Saying so beats a blank page.") },
    { key: "cert", name: L("인증서", "A certificate"),
      can: false,
      line: L("이것도 못 열어요. 열쇠가 인증서 안에 있어요.",
              "Nor this one. The key lives inside a certificate."),
      body: L("Adobe.PubSec이에요. 앱이 열 길이 없다는 걸 파일을 열어 보기 전에 알려줘요.",
              "Adobe.PubSec. The app says it cannot before you have waited for it.") },
  ];
  let current = 0;

  const face = el("div", { class: "pane", style: "flex:1;display:flex;flex-direction:column;justify-content:center;gap:9px;text-align:center;min-height:168px" });
  const buttons = [];

  const paint = () => {
    const c = CASES[current];
    buttons.forEach((b, i) => b.classList.toggle("on", i === current));
    face.replaceChildren(
      el("div", { style: "font-size:26px" }, c.can ? "🔑" : "🔒"),
      el("div", { style: "font-size:14px;font-weight:700;color:" + (c.can ? "var(--green)" : "var(--ink)") }, c.line),
      el("p", { class: "hint", style: "margin:0 auto;max-width:36ch" }, c.body));
  };

  const seg = el("div", { class: "seg" }, ...CASES.map((c, i) => {
    const b = el("button", { type: "button", onclick: () => { current = i; paint(); } }, c.name);
    buttons.push(b);
    return b;
  }));
  paint();

  return el("div", { class: "demo-shell", style: "flex-direction:column;gap:12px" }, seg, face,
    el("p", { class: "hint", style: "margin:0" },
      L("잠긴 파일에서는 서지도 안 읽어요 — 암호문이 제목이 되니까요.",
        "Nothing is parsed out of a locked file either: the ciphertext would become the title.")));
}

/* ═════════════════════════ the bands ═════════════════════════
   The page is a stack of full-bleed bands, one idea to a band, the way a
   product page is built — not a carousel, where nine tenths of what there is
   to show is behind an arrow nobody presses. Each band names a slot; this
   fills it, and wakes the demonstration when it comes into view rather than
   when the page loads, so seventeen of them do not all animate at once into
   an empty screen. */
const BANDS = [
  ["demo-kind", paperOrDocument],
  ["demo-pages", pageGrid],
  ["demo-book", bookMode],
  ["demo-fitted", fittedHighlight],
  ["demo-marks", marksJump],
  ["demo-draw", figmaDrawing],
  ["demo-split", papersSideBySide],
  ["demo-panes", panes],
  ["demo-quote", passageToNote],
  ["demo-links", noteLinks],
  ["demo-draft", draftToManuscript],
  ["demo-search", searchEverything],
  ["demo-libraries", manyLibraries],
  ["demo-name", fileName],
  ["demo-desktops", everyDesktop],
  ["demo-devices", threeDevices],
  ["demo-locked", lockedPDF],
];

function mountBands() {
  const woken = new WeakSet();
  const wake = new IntersectionObserver((entries) => {
    for (const entry of entries) {
      if (!entry.isIntersecting) continue;
      const demo = entry.target.firstElementChild;
      if (demo && !woken.has(demo)) {
        woken.add(demo);
        demo.activate?.();
      }
    }
  }, { rootMargin: "-10% 0px -10% 0px" });

  for (const [id, make] of BANDS) {
    const slot = document.getElementById(id);
    if (!slot) continue;
    const demo = make();
    slot.replaceChildren(demo);
    demo.activate = demo.activate || null;
    wake.observe(slot);
  }
}

/* What arrives as you reach it. Apple's pages do this and it is the only
   reason a page this long does not read as a list. */
function mountReveals() {
  const rises = document.querySelectorAll(".rise");
  if (!("IntersectionObserver" in window)) {
    rises.forEach((node) => node.classList.add("in"));
    return;
  }
  const seen = new IntersectionObserver((entries) => {
    for (const entry of entries) {
      if (!entry.isIntersecting) continue;
      entry.target.classList.add("in");
      seen.unobserve(entry.target);
    }
  }, { rootMargin: "0px 0px -12% 0px" });
  rises.forEach((node) => seen.observe(node));
}

/* ════════════════════════ downloads and dialogs ════════════════════════ */

const mb = (n) => (n / 1048576).toFixed(1) + " MB";

const OS = {
  mac:     { name: "macOS",   note: L("14 Sonoma 이상 · Apple Silicon", "14 Sonoma or later · Apple Silicon") },
  windows: { name: "Windows", note: L("10 이상 · 64비트와 ARM", "10 or later · 64-bit and ARM") },
  linux:   { name: "Linux",   note: L("x86_64와 ARM64", "x86_64 and ARM64") },
};

/* Which desktop the visitor is on.
   Almost nobody downloads for a machine they are not sitting at, so this is
   the right default — and it is only a default, because somebody is. */
function detectOS() {
  const ua = navigator.userAgent;
  const platform = navigator.userAgentData?.platform || navigator.platform || "";
  if (/Win/i.test(platform) || /Windows/i.test(ua)) return "windows";
  if (/Linux|X11/i.test(platform) || (/Linux/i.test(ua) && !/Android/i.test(ua))) return "linux";
  if (/Mac/i.test(platform) || /Mac OS X/i.test(ua)) return "mac";
  return "mac";
}

let chosenOS = detectOS();

/* A release's files for one platform. Older versions carry only the Mac's
   disk image, under the key it has always had. */
/** A build's label in the language the page is being read in. */
/** A version's one-line note, in the language being read. Old versions have
 *  only the Korean one; it is better to show that than a blank line. */
function releaseNote(release) {
  return (KO ? release.note : release.note_en || release.note) || "";
}

function buildLabel(build) {
  return (KO ? build.label : build.label_en || build.label) || "";
}

function buildArch(build) {
  return (KO ? build.arch : build.arch_en || build.arch) || "";
}

function buildsFor(release, os) {
  if (release.builds && release.builds[os]) return release.builds[os];
  if (os === "mac" && release.asset) {
    return [{ label: L("디스크 이미지", "Disk image"), arch: "Apple Silicon", url: release.asset, size: release.size }];
  }
  return [];
}

function picker(node, onPick) {
  node.replaceChildren(...Object.entries(OS).map(([os, meta]) => {
    const b = el("button", { type: "button", class: "pick", "data-os": os }, meta.name);
    b.addEventListener("click", () => onPick(os));
    return b;
  }));
}

function markPicker(node, os) {
  for (const b of node.querySelectorAll(".pick")) {
    b.setAttribute("aria-pressed", String(b.dataset.os === os));
  }
}

/* The big button carries one label per language and the stylesheet shows
   one of them. Write into both — the text is already in the page's language —
   so the visible one is never the one that was skipped. */
const setLabel = (button, text) => {
  for (const node of button.querySelectorAll(".label")) node.textContent = text;
};

/* The day a version went up. Short, and in the reader's own order —
   the row is about the download, and the date is the smaller half of it. */
function day(iso) {
  if (!iso) return "";
  const d = new Date(iso);
  if (isNaN(d)) return "";
  return KO
    ? `${d.getFullYear()}. ${d.getMonth() + 1}. ${d.getDate()}.`
    : d.toLocaleDateString("en-US", { year: "numeric", month: "short", day: "numeric" });
}

/* What other people took. GitHub counts every download of an asset, and the
   ones we made while checking a build are in there too — a release we tried
   on three desktops reads as three strangers. Each version carries how many
   of its downloads were ours (`ours` in releases.json, written by
   `Scripts/note-download.sh`), and the page takes them off. */
function ours(release, count) {
  if (count == null) return null;
  return Math.max(0, count - (release.ours || 0));
}

async function mountDownloads() {
  const primary = document.getElementById("get");
  const list = document.getElementById("versions-list");
  const pick = document.getElementById("picker");
  const variants = document.getElementById("variants");
  try {
    const data = await (await fetch("releases.json", { cache: "no-cache" })).json();
    const releases = (data.releases || []).filter((r) => r.asset || r.builds);
    if (data.repo) {
      const link = document.getElementById("repo-link");
      link.href = "https://github.com/" + data.repo;
      link.textContent = data.repo;
    }
    if (!releases.length) throw new Error("empty");

    const latest = releases[0];

    /* The button, and the alternatives under it. */
    const showOS = (os) => {
      chosenOS = os;
      markPicker(pick, os);
      const files = buildsFor(latest, os);
      if (!files.length) {
        primary.href = "https://github.com/" + (data.repo || "Icecoffee2500/paper-time") + "/releases";
        setLabel(primary, L("GitHub에서 받기", "Get it from GitHub"));
        primary.querySelector(".sub").textContent =
          L(`${OS[os].name} — 이 버전엔 없어요`, `${OS[os].name} — not in this version`);
        variants.textContent = "";
        return;
      }
      const first = files[0];
      primary.href = first.url;
      setLabel(primary, L(`${latest.version} 받기`, `Download ${latest.version}`));
      primary.querySelector(".sub").textContent =
        `${OS[os].name} · ${buildArch(first) ? buildArch(first) + " · " : ""}${first.size ? mb(first.size) : ""}`;
      /* Everything else for this platform, small, on one line. */
      const rest = files.slice(1);
      variants.replaceChildren(
        ...(rest.length
          ? [el("span", {}, L("다른 갈래: ", "Other builds: ")),
             ...rest.flatMap((f, i) => [
               i ? el("span", {}, " · ") : "",
               el("a", { href: f.url }, `${buildLabel(f)}${buildArch(f) ? ` (${buildArch(f)})` : ""}`),
             ])]
          : [el("span", {}, OS[os].note)]),
      );
    };

    picker(pick, showOS);
    showOS(chosenOS);

    /* How many times each version has been taken, across every file of it.
       GitHub counts every download of a release asset, and has since the
       first one was put up, so the tally reaches back before the page showed
       it. The number written at publish time is shown first; the live one
       replaces it when the API answers (sixty asks an hour per visitor, more
       than enough for a landing page). */
    const render = (counts) => {
      list.replaceChildren(...releases.map((r) => {
        const n = ours(r, counts[r.version]);
        const links = ["mac", "windows", "linux"].flatMap((os) => {
          const files = buildsFor(r, os);
          if (!files.length) return [];
          return [el("a", { href: files[0].url, class: "vget" }, OS[os].name)];
        });
        return el("div", { class: "vrow" },
          el("span", { class: "v" }, r.version),
          el("span", { class: "when" }, day(r.date)),
          el("span", { class: "n" }, releaseNote(r)),
          el("span", { class: "vlinks" }, ...links),
          el("span", { class: "d" }, n == null ? "" :
            L(`${n.toLocaleString("ko-KR")}번 받음`,
              `${n.toLocaleString("en-US")} download${n === 1 ? "" : "s"}`)));
      }));
      const total = releases.reduce((sum, r) => sum + (ours(r, counts[r.version]) || 0), 0);
      const tally = document.getElementById("tally");
      if (tally) tally.replaceChildren(
        L("지금까지 ", "Downloaded "),
        el("b", {}, L(`${total.toLocaleString("ko-KR")}번`, `${total.toLocaleString("en-US")} times`)),
        L(" 받아갔어요 · 버전별은 이전 버전에서", " so far · per version under Older versions"));
    };
    render(Object.fromEntries(releases.map((r) => [r.version, r.downloads])));
    if (data.repo) fetchDownloadCounts(data.repo).then((live) => { if (live) render(live); });
  } catch {
    setLabel(primary, L("GitHub에서 받기", "Get it from GitHub"));
    primary.href = "https://github.com/Icecoffee2500/paper-time/releases";
    list.replaceChildren(el("p", { class: "hint" },
      L("버전 목록을 불러오지 못했어요.", "The list of versions didn't load.")));
  }
}

/* The live tally, from GitHub's releases API — or nothing, quietly.
   Summed across every file of a version, not just the disk image: a download
   is a download whichever desktop it was for. */
async function fetchDownloadCounts(repo) {
  try {
    const res = await fetch(`https://api.github.com/repos/${repo}/releases?per_page=100`, {
      headers: { Accept: "application/vnd.github+json" },
    });
    if (!res.ok) return null;
    const counts = {};
    for (const release of await res.json()) {
      const total = (release.assets || [])
        .filter((a) => /\.(dmg|exe|zip|AppImage|deb|rpm|tar\.gz)$/i.test(a.name))
        .reduce((sum, a) => sum + (a.download_count || 0), 0);
      if (total || (release.assets || []).length) counts[release.tag_name] = total;
    }
    return Object.keys(counts).length ? counts : null;
  } catch {
    return null;
  }
}

/* The install sheet shows one desktop's steps at a time. */
function mountHowPicker() {
  const node = document.getElementById("how-picker");
  if (!node) return;
  const show = (os) => {
    markPicker(node, os);
    for (const panel of document.querySelectorAll(".how-panel")) {
      panel.hidden = panel.dataset.os !== os;
    }
  };
  picker(node, show);
  show(chosenOS);
  /* Opening the sheet follows whatever the hero is offering. */
  document.getElementById("how").addEventListener("click", () => show(chosenOS));
}


/* ═══════════════════ the proof, above everything else ═══════════════════
   The same demonstration that used to be the carousel's first slide, moved
   to where somebody meets the page. A claim underneath a working thing reads
   as a caption; a claim above one reads as a promise. */
function mountHero() {
  const node = document.getElementById("hero-demo");
  if (node) node.replaceChildren(ultracopy());
}

/* ══════════════════════════ built together ═══════════════════════════════
   The list readers asked for, read live from the issues. A check mark is not
   something anybody remembers to tick here: it is the issue being closed. The
   same argument the app makes about marks living in the PDF — the state is
   the truth, not a copy of it that can drift.

   `feedback.json` is written at release time as the answer when the API is
   rate-limited or unreachable, exactly as the download counts are. */
const FEEDBACK_LABEL = "feedback";

function creditOf(issue) {
  const found = /<!--\s*credit:\s*([^>]*?)\s*-->/.exec(issue.body || "");
  const name = found && found[1].trim();
  if (name) return name;
  if (issue.user && issue.user.login) return "@" + issue.user.login;
  return L("익명", "anonymous");
}

function boardRow(issue) {
  const done = issue.state === "closed";
  const version = issue.milestone && issue.milestone.title;
  const where = done
    ? (version ? L(version + "에서 고침", "fixed in " + version) : L("고침", "fixed"))
    : L("기다리는 중", "open");
  return el("a", { href: issue.html_url, target: "_blank", rel: "noopener" },
    el("span", { class: "st " + (done ? "done" : "open") }, done ? "✓" : "○"),
    el("span", { class: "ttl" }, issue.title),
    el("span", { class: "meta" }, where),
    el("span", { class: "who" }, "— " + creditOf(issue)));
}

function paintBoard(issues) {
  const board = document.getElementById("together-board");
  const tally = document.getElementById("together-tally");
  const credits = document.getElementById("credits");
  if (!board) return;

  if (!issues.length) {
    board.replaceChildren(el("div", { class: "row" },
      el("span", { class: "ttl hint" },
        L("아직 아무 얘기도 없어요. 첫 번째가 되어 주세요.",
          "Nobody has said anything yet. Be the first."))));
    if (tally) tally.replaceChildren();
    return;
  }

  const closed = issues.filter((i) => i.state === "closed").length;
  /* Newest first, but anything still open floats above what is done: the
     page is a promise about what happens next, not a trophy case. */
  const sorted = issues.slice().sort((a, b) => {
    if ((a.state === "closed") !== (b.state === "closed")) return a.state === "closed" ? 1 : -1;
    return new Date(b.updated_at || 0) - new Date(a.updated_at || 0);
  });
  board.replaceChildren(...sorted.slice(0, 12).map(boardRow));

  if (tally) {
    tally.replaceChildren(
      el("div", {}, el("span", { class: "n" }, String(issues.length)),
        el("span", { class: "k" }, L("제보", "reported"))),
      el("div", {}, el("span", { class: "n" }, String(closed)),
        el("span", { class: "k" }, L("고침", "fixed"))),
      el("div", {}, el("span", { class: "n" }, String(issues.length - closed)),
        el("span", { class: "k" }, L("보는 중", "in hand"))));
  }

  if (credits) {
    const counts = new Map();
    for (const issue of issues) {
      const who = creditOf(issue);
      counts.set(who, (counts.get(who) || 0) + 1);
    }
    const names = [...counts.entries()].sort((a, b) => b[1] - a[1]);
    credits.replaceChildren(
      el("span", { class: "name", style: "background:transparent;padding-left:0" },
        L("고마워요 —", "Thank you —")),
      ...names.map(([who, n]) =>
        el("span", { class: "name" }, n > 1 ? who + " ×" + n : who)));
  }
}

async function mountTogether() {
  if (!document.getElementById("together-board")) return;
  try {
    const response = await fetch(
      "https://api.github.com/repos/Icecoffee2500/paper-time/issues" +
        "?state=all&labels=" + FEEDBACK_LABEL + "&per_page=100",
      { headers: { Accept: "application/vnd.github+json" } });
    if (!response.ok) throw new Error(String(response.status));
    const issues = (await response.json()).filter((i) => !i.pull_request);
    paintBoard(issues);
    return;
  } catch (e) {
    /* Rate-limited, offline, or the repository moved. Fall back to what the
       last release wrote down rather than showing an error nobody can act on. */
  }
  try {
    const snapshot = await fetch("feedback.json").then((r) => (r.ok ? r.json() : null));
    paintBoard((snapshot && snapshot.issues) || []);
  } catch (e) {
    paintBoard([]);
  }
}

function mountDialogs() {
  for (const [btn, dlg] of [["how", "how-dialog"], ["older", "versions-dialog"]]) {
    const dialog = document.getElementById(dlg);
    document.getElementById(btn).addEventListener("click", () => dialog.showModal());
    dialog.addEventListener("click", (e) => { if (e.target === dialog) dialog.close(); });
    dialog.querySelector(".sheet-close").addEventListener("click", () => dialog.close());
  }
}

/* ═══════════════════════════ what this file is ═════════════════════════
   Two pages read this one file. A demonstration written twice is a
   demonstration that goes stale once: the manual shows the same working
   pieces the landing page shows, out of the same source. */
window.PaperTime = {
  el, L, KO,
  demos: {
    ultracopy, searchEverything, bookMode, fittedHighlight, marksJump,
    passageToNote, noteLinks, panes, everyDesktop, threeDevices,
    draftToManuscript, figmaDrawing, papersSideBySide, paperOrDocument,
    pageGrid, manyLibraries, fileName, lockedPDF,
  },
  mountLanguage, mountReveals, mountDownloads, mountDialogs, mountHowPicker,
};

/* The landing page boots itself; the manual is another page and takes what
   it wants from the object above. */
if (document.body.dataset.page !== "docs") {
  mountLanguage();
  mountMetadata();
  mountHero();
  mountBands();
  mountReveals();
  mountDownloads();
  mountDialogs();
  mountHowPicker();
  void mountTogether();
}
