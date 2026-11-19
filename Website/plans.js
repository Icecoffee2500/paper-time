/* Paper Time — the reading-plans page.

   The window is `plans-demo.js`, the same demonstration the app shows in
   Settings → About; this file only puts it on the page, sets the six steps in
   the page's own cells, and borrows the language picker and the reveals from
   `demos.js`. Inside a function, because `demos.js` already declared its own
   names in the scope every script on the page shares. */
(function () {
  "use strict";
  const PT = window.PaperTime;
  const lang = document.documentElement.lang === "en" ? "en" : "ko";
  const say = (ko, en) => (lang === "ko" ? ko : en);

  if (PT) {
    PT.mountLanguage();
    PT.mountReveals();
  }

  document.title = say("Paper Time — 읽기 계획", "Paper Time — Reading Plans");
  const set = (selector, value) => {
    const node = document.querySelector(selector);
    if (node) node.setAttribute("content", value);
  };
  set('meta[name="description"]', say(
    "한 계열의 논문을 모아 차례와 날짜를 정하고, 발표 자료와 코드를 논문 옆에 붙여 둬요. Paper Time 1.1.0의 읽기 계획이에요.",
    "Gather a line of papers, give them an order and days to read them, and keep the slides and the code beside each one. Reading plans are new in Paper Time 1.1.0."
  ));
  set('meta[property="og:title"]', document.title);
  set('meta[property="og:description"]', say(
    "한 계열의 논문을 모아 차례와 날짜를 정하고, 자료를 논문 옆에 붙여 둬요.",
    "A line of papers, in order, with a day for each and the materials beside it."
  ));

  const slot = document.getElementById("plans-demo");
  if (slot && window.PlansDemo) {
    window.PlansDemo.mount(slot, { lang, parts: ["tour", "window", "fine"] });
  }

  const steps = document.getElementById("plans-steps");
  if (steps && window.PlansDemo) {
    steps.replaceChildren(...window.PlansDemo.howTo(lang, "key").map((step) => {
      const cell = document.createElement("article");
      cell.className = "cell";
      const head = document.createElement("h3");
      const no = document.createElement("span");
      no.className = "plans-no";
      no.textContent = String(step.n);
      head.append(no, document.createTextNode(step.title));
      const body = document.createElement("p");
      body.innerHTML = step.html;
      cell.append(head, body);
      return cell;
    }));
  }
})();
