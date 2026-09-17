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

/* ══════════════════════════ 1 · Ultracopy ══════════════════════════ */

function ultracopy() {
  const PASSAGE =
    `각 단계에서 롤아웃 손실 ${f("&#x2112;")}${sub("rollout")}${f("(&phi;)")} := ` +
    `&#8214;${f("P")}${sub("&phi;")}${f("(a")}${sub("1:T")}${f(", s")}${sub("1")}` +
    `${f(", z")}${sub("1")}${f(")")} &minus; ${f("z")}${sub("T+1")}&#8214;${sub("1")}` +
    `을 최소화한다.`;

  const PLAIN =
    "각 단계에서 롤아웃 손실 L rollout (ϕ) := ∥P ϕ (a 1:T , s 1 , z 1 ) − z T+1 ∥ 1 을 최소화한다.";
  const ULTRA =
    "각 단계에서 롤아웃 손실 $\\mathcal{L}_{\\mathrm{rollout}}(\\phi) := " +
    "\\lVert P_\\phi(a_{1:T}, s_1, z_1) - z_{T+1} \\rVert_1$ 을 최소화한다.";

  const out = el("pre", {
    style:
      "margin:0;font:12.5px/1.75 var(--mono);white-space:pre-wrap;word-break:break-word;" +
      "color:var(--ink-2);min-height:5.2em",
  }, "아래 두 단추를 눌러 보라.");

  const label = el("div", { class: "hint", style: "margin:0 0 6px" }, " ");

  const show = (text, kind) => {
    out.textContent = text;
    out.style.color = kind === "ultra" ? "var(--ink)" : "var(--ink-3)";
    label.innerHTML =
      kind === "ultra"
        ? '<b style="color:var(--green)">붙여넣으면 그대로 컴파일된다.</b>'
        : '<b>수식이 글자 부스러기로 깨졌다.</b> 다시 손으로 쳐야 한다.';
    navigator.clipboard?.writeText(text).catch(() => {});
  };

  return el("div", { class: "demo-shell", style: "flex-direction:column;gap:12px" },
    el("div", { class: "pane paper-face", style: "flex:0 0 auto" },
      el("p", { html: PASSAGE, style: "margin:0;background:var(--mark-soft);padding:6px 8px;border-radius:5px" })),
    el("div", { style: "display:flex;gap:10px;flex-wrap:wrap" },
      el("button", { class: "btn btn-ghost", onclick: () => show(PLAIN, "plain") },
        el("span", { class: "key" }, "⌘C"), "그냥 복사"),
      el("button", { class: "btn btn-primary", onclick: () => show(ULTRA, "ultra") },
        el("span", { class: "key", style: "background:rgba(255,255,255,.16);border-color:rgba(255,255,255,.3);color:#fff" }, "⇧⌘C"),
        "Ultracopy")),
    el("div", { class: "pane", style: "flex:1;min-height:0" }, label, out));
}

/* ═════════════════════ 2 · Search Everything ═════════════════════ */

function searchEverything() {
  const ITEMS = [
    { g: "논문", t: "Overcoming catastrophic forgetting in neural networks", s: "Kirkpatrick et al. · 2017" },
    { g: "논문", t: "OpenVLA: An Open-Source Vision-Language-Action Model", s: "Kim et al. · 2024" },
    { g: "논문", t: "Auto-Encoding Variational Bayes", s: "Kingma & Welling · 2013" },
    { g: "노트", t: "시냅스 강화가 기억을 지킨다", s: "Kirkpatrick 2017에서" },
    { g: "노트", t: "왜 EWC는 피셔 정보를 쓰는가", s: "지도 · 연속 학습" },
    { g: "태그", t: "continual-learning", s: "논문 7편" },
    // 제목에는 없고 본문에만 있는 낱말: 이 줄이 없으면 그 논문은 떠오르지 않는다.
    { g: "본문", t: "…synaptic consolidation enables continual learning…", s: "Kirkpatrick 2017 · 1쪽 · 9번" },
    { g: "본문", t: "…unlearning specific layers may not help the model forget…", s: "Can Memorization Be Localized? · 9쪽" },
    { g: "동작", t: "PDF 추가…", s: "⌘O" },
    { g: "동작", t: "BibTeX 내보내기…", s: "⇧⌘E" },
  ];
  const OFFERED = [
    { h: "이어 읽기", t: "Overcoming catastrophic forgetting…", s: "3쪽에서 멈췄다" },
    { h: "읽었으니", t: "Progressive Neural Networks", s: "EWC를 읽었다면" },
    { h: "다시 보기", t: "Auto-Encoding Variational Bayes", s: "두 달 전에 표시해 둔 것" },
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
      caption.innerHTML = "빈칸일 때는 <b>묻기 전에 내놓는다</b> — 이유와 함께.";
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
      ? `제목도 노트도 태그도, <b>논문 본문 속 한 줄까지</b>. ${hits.length}개.`
      : "그런 것은 없다.";
    for (const h of hits) list.append(row(h.t, h.s, h.g));
  };

  const input = el("input", {
    type: "text",
    placeholder: "찾거나, 이어서 읽거나",
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
  }, el("span", { class: "key" }, "⇧⌘L"), "목차");

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
      ? "<b>Paper Time</b> — 글자가 앉은 자리만 덮는다. 위아래 줄은 읽을 수 있다."
      : "<b>다른 PDF 앱</b> — 수식의 상자 전체를 덮어 이웃한 줄까지 지운다.";
  };

  const seg = el("div", { class: "seg" },
    el("button", { onclick: () => { fitted = false; seg.children[0].classList.add("on"); seg.children[1].classList.remove("on"); sync(); } }, "다른 PDF 앱"),
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
    { id: "m1", kind: "하이라이트", c: "var(--mark-soft)", t: "synaptic consolidation" },
    { id: "m2", kind: "밑줄", c: "transparent", t: "elastic weight consolidation (EWC)" },
    { id: "m3", kind: "노트", c: "var(--accent-soft)", t: "quadratic penalty" },
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
    el("p", { class: "hint", style: "margin-top:12px" }, "표시를 누르면 쪽이 그리로 간다."));

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
      noteBody.append(el("div", { style: "color:var(--ink-3);font-size:14px" }, "노트는 아직 비어 있다."));
      hint.innerHTML = "논문에서 고른 문장을 <b>주소째로</b> 노트에 보낸다.";
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
      }, "3쪽")),
      el("div", {
        contenteditable: "true",
        style: "border:1px solid var(--rule);border-radius:10px;padding:10px 12px;font-size:14px;" +
               "min-height:64px;outline:none;background:var(--card)",
      }, "스프링의 뻣뻣함이 파라미터마다 다르다는 게 핵심이다."));
    hint.innerHTML = "<b style='color:var(--green)'>구절이 주소를 가지고 왔다.</b> 수식은 수식으로 남는다 — 인용을 누르면 그 줄로 돌아간다.";
  };

  const send = el("button", {
    class: "btn btn-primary",
    onclick: () => { sent = true; render(); },
  }, el("span", { class: "key", style: "background:rgba(255,255,255,.16);border-color:rgba(255,255,255,.3);color:#fff" }, "⌘L"),
     "고른 문장을 노트로");

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
    ewc: {
      t: "왜 EWC는 피셔 정보를 쓰는가",
      b: "손실의 곡률이 큰 방향일수록 그 파라미터는 옛 과제에 중요하다. 피셔 정보 행렬의 대각이 그 곡률의 값싼 추정이다. 그래서 [[spring]]의 뻣뻣함을 파라미터마다 다르게 줄 수 있다. 이것은 [[laplace]]와 같은 근사다.",
    },
    spring: {
      t: "스프링 비유는 어디까지 맞는가",
      b: "이차 페널티는 옛 해에 파라미터를 매어 두는 스프링이다. 다만 모든 스프링의 뻣뻣함이 같으면 아무것도 못 배운다. [[ewc]]가 이 문제를 푼다.",
    },
    laplace: {
      t: "라플라스 근사",
      b: "사후분포를 최빈값 주변의 가우시안으로 본다. 그 정밀도가 곧 곡률이고, 곡률이 곧 중요도다. [[ewc]]는 이 근사를 연속 학습에 옮긴 것이다.",
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
        : el("span", { class: "hint", style: "margin:0" }, "노트 안의 이름을 누르면 그 노트가 열린다."));
  };

  render();
  return el("div", { class: "demo-shell", style: "flex-direction:column;gap:10px" }, crumbs, card);
}

/* ══════════════════════ 8 · The panes are yours ══════════════════════ */

function panes() {
  const PANES = [
    { id: "sidebar", n: "서가", w: 0.9, c: "var(--paper)" },
    { id: "list", n: "논문 목록", w: 1.3, c: "var(--paper-2)" },
    { id: "reader", n: "논문", w: 2.6, c: "var(--card)" },
    { id: "inspector", n: "인스펙터", w: 1.2, c: "var(--paper-2)" },
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
    el("p", { class: "hint" }, "읽을 때는 논문만 두고, 정리할 때는 넷을 다 편다. 창은 껐다 켜는 것이지 참고 보는 것이 아니다."));
}

/* ════════════════════ 9 · One folder, three devices ════════════════════ */

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

  const mac = device("맥", "16/10", 0);
  const pad = device("아이패드", "4/3", 1100);
  const phone = device("아이폰", "9/16", 1900);
  const caption = el("p", { class: "hint" }, "맥에서 긋고, 다른 두 기기가 몇 초 안에 같은 줄을 보인다.");

  const run = () => {
    for (const d of [mac, pad, phone]) {
      d.mark.style.opacity = "0";
      setTimeout(() => { d.mark.style.opacity = "1"; }, d.delay);
    }
    caption.innerHTML = "표시는 몇 KB짜리 저널로 먼저 건너가고, <b>20 MB PDF는 뒤따라온다.</b> 아무도 파일을 기다리지 않는다.";
  };

  return el("div", { class: "demo-shell", style: "flex-direction:column;gap:14px" },
    el("div", { style: "display:flex;gap:8px;flex-wrap:wrap;align-items:center" },
      el("button", { class: "btn btn-primary", onclick: run }, "맥에서 하이라이트 긋기"),
      el("span", { class: "hint", style: "margin:0" }, "iCloud Drive 폴더 하나면 된다.")),
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
    el("div", { style: "font-weight:600;margin-bottom:8px" }, "초안 · 관련연구"),
    el("div", { style: "font-size:13.5px;line-height:1.7" },
      el("div", { style: "color:var(--ink-3);font-size:11px;letter-spacing:.06em;text-transform:uppercase;margin-bottom:6px" },
        "연속 학습"),
      el("div", { style: "display:flex;gap:8px;margin-bottom:8px" },
        el("span", { style: "color:var(--ink-3)" }, "•"),
        el("span", {},
          "EWC는 파라미터마다 다른 뻣뻣함의 스프링이다 ",
          el("span", {
            style: "background:var(--accent-soft);color:var(--accent);border-radius:5px;" +
                   "padding:1px 6px;font-size:12px;white-space:nowrap",
          }, "❝ Kirkpatrick 2017 · 3쪽"))),
      el("div", { style: "display:flex;gap:8px" },
        el("span", { style: "color:var(--ink-3)" }, "•"),
        el("span", {},
          "이 관점은 ",
          el("span", { style: "color:var(--accent)" }, "[[시냅스 강화가 기억을 지킨다]]"),
          " 에서 이어진다."))));

  const out = el("div", { class: "pane", style: "flex:1;min-height:0;font:12.5px/1.65 var(--mono);white-space:pre-wrap" });
  const hint = el("p", { class: "hint" });

  const render = () => {
    if (!rendered) {
      out.textContent = "⇧⌘E를 누르면 여기에 원고가 나온다.";
      out.style.color = "var(--ink-3)";
      hint.innerHTML = "초안은 노트 하나다 — 구절과 링크로 짓는다.";
      return;
    }
    out.style.color = "var(--ink)";
    out.textContent =
      "EWC는 파라미터마다 다른 뻣뻣함의 스프링이다~\\cite{kirkpatrick2017overcoming}.\n" +
      "이 관점은 시냅스 강화가 기억을 지킨다는 관찰에서 이어진다.\n\n" +
      "% draft.bib — 인용한 논문만\n" +
      "@article{kirkpatrick2017overcoming,\n" +
      "  title  = {Overcoming catastrophic forgetting in neural networks},\n" +
      "  author = {Kirkpatrick, James and Pascanu, Razvan and others},\n" +
      "  year   = {2017}, journal = {PNAS}\n}";
    hint.innerHTML = "<b style='color:var(--green)'>Overleaf에 붙이면 컴파일된다.</b> 인용 키도, .bib도 손으로 옮기지 않았다.";
  };

  const go = el("button", {
    class: "btn btn-primary",
    onclick: () => { rendered = !rendered; render(); },
  }, el("span", { class: "key", style: "background:rgba(255,255,255,.16);border-color:rgba(255,255,255,.3);color:#fff" }, "⇧⌘E"),
     "원고로 렌더");

  render();
  return el("div", { class: "demo-shell", style: "flex-direction:column;gap:12px" },
    el("div", { class: "demo-shell", style: "flex:1;min-height:0" }, draft, out),
    el("div", { style: "display:flex;gap:10px;align-items:center;flex-wrap:wrap" }, go, hint));
}

/* ═══════════════════════════ the carousel ═══════════════════════════ */

/// Three goes at it, the same three the app's own About window uses: what no
/// other reader does at all, what makes the window a place to read in, and
/// what becomes of the reading afterwards. Nine things in a row is a list;
/// four, then four, then two is an argument.
const TIERS = [
  { n: 1, name: "다른 데 없는 것" },
  { n: 2, name: "읽는 자리" },
  { n: 3, name: "읽고 난 뒤" },
];

const SLIDES = [
  { t: 1, n: "Ultracopy", h: "수식은 LaTeX으로, 글은 글로",
    p: "PDF에서 수식이 든 문단을 그냥 복사하면 글자 부스러기가 나온다. Ultracopy는 같은 선택에서 글은 그대로, 수식은 바로 컴파일되는 LaTeX으로 돌려준다.",
    make: ultracopy },
  { t: 1, n: "하이라이트", h: "수식이 있어도 줄은 한 줄이다",
    p: "수식이 든 줄은 상자가 높아서, 여느 앱의 하이라이트는 위아래 줄까지 삼킨다. 여기서는 글자가 앉은 자리만 덮는다.",
    make: fittedHighlight },
  { t: 1, n: "구절 → 노트", h: "구절이 주소를 가지고 간다",
    p: "읽다가 고른 문장을 노트로 보내면 세로줄이 선 인용이 되고, 끝에 쪽수가 붙는다. 쪽수를 누르면 논문의 그 줄로 돌아간다. 수식이 든 문장은 수식째로 — Ultracopy와 같은 눈으로 읽는다.",
    make: passageToNote },
  { t: 1, n: "Search Everything", h: "논문 안의 한 줄까지 찾는다",
    p: "논문·노트·지도·초안·태그·동작이 한 칸에 있고, 제목에 없는 낱말은 본문에서 찾는다 — 고르면 그 논문의 그 줄로 간다. 빈칸일 때는 이어 읽을 것과 다시 볼 것을 이유와 함께 먼저 내놓는다.",
    make: searchEverything },

  { t: 2, n: "Book mode", h: "책처럼 펴고, 목차로 건너뛴다",
    p: "두 쪽이 마주 보고, 여백은 잘려 본문만 남는다. 목차는 단축키 하나 — 절 이름을 누르면 그 절로 바로 간다.",
    make: bookMode },
  { t: 2, n: "Marks", h: "표시 목록은 문이다",
    p: "인스펙터의 하이라이트·밑줄·메모를 누르면 논문이 그 자리로 간다. 무엇을 표시했는지가 아니라 어디에 표시했는지가 남는다.",
    make: marksJump },
  { t: 2, n: "창", h: "필요한 창만 켠다",
    p: "서가·목록·논문·인스펙터를 하나씩 껐다 켠다. 읽을 때는 논문만, 정리할 때는 넷 다. 열의 너비는 창이 허락하는 데까지 늘어난다.",
    make: panes },
  { t: 2, n: "세 기기", h: "폴더 하나, 기기 셋",
    p: "맥·아이패드·아이폰이 같은 폴더를 본다. 표시는 작은 저널로 먼저 건너가고 PDF는 뒤따라온다.",
    make: threeDevices },

  { t: 3, n: "노트 ↔ 노트", h: "노트가 서로를 안다",
    p: "노트 안에서 다른 노트를 이름으로 부른다. 읽은 것이 쌓이는 대신 엮인다 — 그게 나중에 초고가 된다.",
    make: noteLinks },
  { t: 3, n: "초안 → 원고", h: "노트는 글이 되어야 한다",
    p: "초안도 노트 하나다. 구절은 ❝로, 노트는 [[링크]]로 넣고 ⇧⌘E를 누르면 구절이 \\cite{키}가 되고, 인용한 논문만 담은 .bib이 함께 나온다.",
    make: draftToManuscript },
];

function mountCarousel() {
  const track = document.getElementById("track");
  const rail = document.getElementById("rail");
  let index = 0;
  const nodes = [];

  const chips = [];

  SLIDES.forEach((s, i) => {
    const demo = s.make();
    const tier = TIERS.find((t) => t.n === s.t);
    const slide = el("section", { class: "slide", "aria-hidden": "true" },
      el("div", { class: "said" },
        el("span", { class: "tag" }, tier.name),
        el("h2", {}, s.h),
        el("p", { class: "pitch" }, s.p)),
      el("div", { class: "demo" }, demo));
    slide.demo = demo;
    track.append(slide);
    nodes.push(slide);
  });

  // The rail is grouped the way the app's source list is: a small caption
  // over the rows that belong under it.
  for (const tier of TIERS) {
    const row = el("div", { class: "tier-row" });
    SLIDES.forEach((s, i) => {
      if (s.t !== tier.n) return;
      const chip = el("button", { class: "chip", onclick: () => go(i) },
        el("span", { class: "n" }, String(i + 1).padStart(2, "0")), s.n);
      chips[i] = chip;
      row.append(chip);
    });
    if (!row.children.length) continue;
    rail.append(el("div", { class: "tier" },
      el("div", { class: "tier-name" }, tier.name), row));
  }

  const go = (next, dir) => {
    const count = SLIDES.length;
    const target = ((next % count) + count) % count;
    const way = dir ?? (target > index || (index === count - 1 && target === 0) ? 1 : -1);
    nodes.forEach((node, i) => {
      node.style.setProperty("--from", (i === target ? way * 40 : -way * 40) + "px");
      node.classList.toggle("is-current", i === target);
      node.setAttribute("aria-hidden", i === target ? "false" : "true");
    });
    chips.forEach((c, i) => c.classList.toggle("is-current", i === target));
    chips[target]?.scrollIntoView({ behavior: "smooth", block: "nearest", inline: "center" });
    index = target;
    nodes[target].demo.activate?.();
  };

  document.getElementById("prev").addEventListener("click", () => go(index - 1, -1));
  document.getElementById("next").addEventListener("click", () => go(index + 1, 1));
  addEventListener("keydown", (e) => {
    if (e.target.closest("input, [contenteditable], dialog")) return;
    if (e.key === "ArrowLeft") go(index - 1, -1);
    if (e.key === "ArrowRight") go(index + 1, 1);
  });

  // A swipe on the stage turns it, the way the app's own book does.
  let x0 = null;
  track.addEventListener("touchstart", (e) => { x0 = e.touches[0].clientX; }, { passive: true });
  track.addEventListener("touchend", (e) => {
    if (x0 == null) return;
    const dx = e.changedTouches[0].clientX - x0;
    if (Math.abs(dx) > 48) go(index + (dx < 0 ? 1 : -1), dx < 0 ? 1 : -1);
    x0 = null;
  }, { passive: true });

  go(0, 1);
}

/* ════════════════════════ downloads and dialogs ════════════════════════ */

const mb = (n) => (n / 1048576).toFixed(1) + " MB";

async function mountDownloads() {
  const primary = document.getElementById("get");
  const list = document.getElementById("versions-list");
  try {
    const data = await (await fetch("releases.json", { cache: "no-cache" })).json();
    const releases = (data.releases || []).filter((r) => r.asset);
    if (data.repo) {
      const link = document.getElementById("repo-link");
      link.href = "https://github.com/" + data.repo;
      link.textContent = data.repo;
    }
    if (!releases.length) throw new Error("empty");

    const latest = releases[0];
    primary.href = latest.asset;
    primary.querySelector(".label").textContent = `${latest.version} 받기`;
    primary.querySelector(".sub").textContent = `macOS · ${mb(latest.size)}`;

    // How many times each disk image has been taken. GitHub counts every
    // download of a release asset, and has since the first one was put
    // up, so the tally reaches back before the page showed it. The number
    // written at publish time is shown first; the live one replaces it
    // when the API answers (sixty asks an hour per visitor, more than
    // enough for a landing page).
    const render = (counts) => {
      list.replaceChildren(...releases.map((r) => {
        const n = counts[r.version];
        return el("div", { class: "vrow" },
          el("span", { class: "v" }, r.version),
          el("span", { class: "n" }, r.note || ""),
          el("a", { href: r.asset }, "DMG 받기"),
          el("span", { class: "s" }, r.size ? mb(r.size) : ""),
          el("span", { class: "d" }, n == null ? "" : `${n.toLocaleString("ko-KR")}번 받음`));
      }));
      const total = Object.values(counts).reduce((a, b) => a + (b || 0), 0);
      const tally = document.getElementById("tally");
      if (tally) tally.replaceChildren(
        "지금까지 ", el("b", {}, `${total.toLocaleString("ko-KR")}번`), " 받아갔다 · 버전별은 이전 버전에서");
    };
    render(Object.fromEntries(releases.map((r) => [r.version, r.downloads])));
    if (data.repo) fetchDownloadCounts(data.repo).then((live) => { if (live) render(live); });
  } catch {
    primary.querySelector(".label").textContent = "GitHub에서 받기";
    primary.href = "https://github.com/Icecoffee2500/paper-time/releases";
    list.replaceChildren(el("p", { class: "hint" }, "버전 목록을 불러오지 못했다."));
  }
}

/* The live tally, from GitHub's releases API — or nothing, quietly. */
async function fetchDownloadCounts(repo) {
  try {
    const res = await fetch(`https://api.github.com/repos/${repo}/releases?per_page=100`, {
      headers: { Accept: "application/vnd.github+json" },
    });
    if (!res.ok) return null;
    const counts = {};
    for (const release of await res.json()) {
      const dmg = (release.assets || []).find((a) => /\.dmg$/i.test(a.name));
      if (dmg) counts[release.tag_name] = dmg.download_count;
    }
    return Object.keys(counts).length ? counts : null;
  } catch {
    return null;
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

mountCarousel();
mountDownloads();
mountDialogs();
