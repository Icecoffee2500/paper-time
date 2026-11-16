/* Paper Time — the reading plan, as a window you can use.

   One demonstration in three places: the page that introduces the feature
   (`plans.html`), the Mac's Settings → About (a web view, `PlansDemoView`)
   and the Portable build's About (a frame, `demos.html?demo=readingPlan`).
   Written once, so it cannot drift between them.

     PlansDemo.mount(host, {
       lang: 'ko' | 'en',          // the page's language when left out
       theme: 'light' | 'dark',    // the system's when left out
       fit: 1000,                  // narrower than this, the window is shown smaller rather than rearranged
       parts: ['tour', 'window', 'fine', 'howto'],
       onHeight: (px) => {},       // how tall it is, for a frame that has to be as tall
     })

   Both languages sit side by side, Korean in Toss's 해요체 and English in
   Apple's voice; neither is a translation of the other. Everything is plain
   strings — no network, no fonts to fetch, nothing outside this file and
   `plans-demo.css`. Today is fixed at Monday, November 16, 2026, so the
   demonstration says the same thing whenever it is opened. */
(function () {
'use strict';

const TODAY = '2026-11-16';

/* The stylesheet beside this file, for the shadow root the demo lives in. */
const CSS_URL = (() => {
  const script = document.currentScript;
  return script && script.src ? script.src.replace(/plans-demo\.js(\?.*)?$/, 'plans-demo.css$1') : 'plans-demo.css';
})();

/* Dates as UTC days, so no time zone moves them. */
const d = s => { const a = s.split('-').map(Number); return new Date(Date.UTC(a[0], a[1] - 1, a[2])); };
const iso = t => t.toISOString().slice(0, 10);
const add = (s, n) => { const t = d(s); t.setUTCDate(t.getUTCDate() + n); return iso(t); };
const dow = s => d(s).getUTCDay();
const monday = s => add(s, -((dow(s) + 6) % 7));
const diff = (a, b) => Math.round((d(a) - d(b)) / 864e5);
const esc = s => String(s).replace(/[&<>"]/g, c => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;' }[c]));

const PATHS = {
  doc: 'M4.5 2.5h5l3 3v8h-8z M9.5 2.5v3h3', lines: 'M3 4.5h10M3 8h10M3 11.5h6',
  slides: 'M2.5 3.5h11v7h-11z M8 10.5v2.5 M5.5 13.5h5', code: 'M6 4.5 2.5 8 6 11.5 M10 4.5 13.5 8 10 11.5',
  notebook: 'M3.5 2.5h9v11h-9z M6.8 6l3.2 2-3.2 2z', video: 'M2.5 4h11v8h-11z M7 6.3l3 1.7-3 1.7z',
  data: 'M3 4.5c0-1.1 2.2-2 5-2s5 .9 5 2-2.2 2-5 2-5-.9-5-2z M3 4.5v7c0 1.1 2.2 2 5 2s5-.9 5-2v-7 M3 8c0 1.1 2.2 2 5 2s5-.9 5-2',
  calendar: 'M2.5 4h11v9.5h-11z M2.5 6.8h11 M5.5 2.5v2.5 M10.5 2.5v2.5', table: 'M2.5 3.5h11v9h-11z M2.5 6.5h11 M2.5 9.5h11 M6.5 3.5v9',
  plus: 'M8 3.5v9M3.5 8h9', x: 'M4.5 4.5l7 7M11.5 4.5l-7 7', arrow: 'M3 8h9.5 M9 4.5 12.5 8 9 11.5',
  spark: 'M8 2.5l1.3 3.4 3.4 1.3-3.4 1.3L8 12l-1.3-3.5L3.3 7.2l3.4-1.3z',
  tray: 'M2.5 9.5 4 3.5h8l1.5 6v3h-11z M2.5 9.5h3.2l.8 1.5h3l.8-1.5h3.2', folder: 'M2.5 4.5h4l1.2 1.5h5.8v6.5h-11z',
  star: 'M8 2.5l1.7 3.5 3.8.5-2.8 2.7.7 3.8L8 11.2 4.6 13l.7-3.8L2.5 6.5l3.8-.5z',
  circle: 'M8 2.8a5.2 5.2 0 1 0 0 10.4A5.2 5.2 0 0 0 8 2.8z', half: 'M8 2.8a5.2 5.2 0 1 0 0 10.4A5.2 5.2 0 0 0 8 2.8z M8 2.8v10.4',
  check: 'M8 2.8a5.2 5.2 0 1 0 0 10.4A5.2 5.2 0 0 0 8 2.8z M5.6 8.2l1.7 1.7 3.2-3.6',
  link: 'M6.8 9.2a2.6 2.6 0 0 0 3.7 0l2-2a2.6 2.6 0 0 0-3.7-3.7l-.8.8 M9.2 6.8a2.6 2.6 0 0 0-3.7 0l-2 2a2.6 2.6 0 0 0 3.7 3.7l.8-.8',
  route: 'M4 3.2a1.3 1.3 0 1 0 0 2.6 1.3 1.3 0 0 0 0-2.6z M12 10.2a1.3 1.3 0 1 0 0 2.6 1.3 1.3 0 0 0 0-2.6z M5.3 4.5H10a1.75 1.75 0 0 1 0 3.5H6a1.75 1.75 0 0 0 0 3.5h4.7'
};
const I = (n, s) => '<svg width="' + (s || 16) + '" height="' + (s || 16) + '" viewBox="0 0 16 16" fill="none" stroke="currentColor" stroke-width="1.5" stroke-linecap="round" stroke-linejoin="round" aria-hidden="true"><path d="' + PATHS[n] + '"/></svg>';

/* The six steps of 쓰는 법, for whoever sets them: the page in its own
   cells, the app inside the demonstration. `<k>` marks a name you press. */
const HOWTO = [
  { ko: ['모으기', '논문을 여러 편 골라 <k>계획에 넣기</k>를 눌러요. 컬렉션·태그·폴더를 통째로 계획으로 바꿀 수도 있고, 계획 맨 아래 줄에 arXiv 주소를 여러 줄 붙여넣어도 돼요.'],
    en: ['Gather', 'Select several papers and choose <k>Add to Plan</k>. A collection, a tag or a folder becomes a plan in one step, and the plan’s last row takes arXiv links, several lines at a time.'] },
  { ko: ['차례 잡기', '줄을 끌어 차례를 바꾸고, 섹션으로 계열을 나눠요. 위쪽의 동그라미 줄이 그 차례를 한눈에 보여줘요.'],
    en: ['Put them in order', 'Drag rows to change the order, and split the path into sections. The row of circles at the top shows the whole order at a glance.'] },
  { ko: ['날짜 정하기', '<k>고르게 나누기</k>가 요일과 하루 편수만 물어보고 한 번에 정해요. 한 편씩은 날짜 칸에 <k>금요일</k> <k>12/3</k> <k>+1주</k>처럼 적거나, 달력에서 끌어요.'],
    en: ['Set the days', '<k>Spread Out</k> asks which days and how many a day, then dates them all. For one paper, type <k>Fri</k> <k>12/3</k> <k>+1w</k> in its date, or drag it on the calendar.'] },
  { ko: ['자료 붙이기', '논문을 고르고 주소를 붙여넣으면 코드·슬라이드·영상·노트북을 알아채서 붙여요. 파일은 끌어다 놓아요. arXiv·DOI 링크는 서지에서 저절로 생겨요.'],
    en: ['Attach materials', 'Select a paper and paste a link. Code, slides, videos and notebooks are recognized as they are. Drop files in. arXiv and DOI links come from the bibliography.'] },
  { ko: ['읽기', '<k>이번 주</k>를 열면 모든 계획에서 이번 주 논문만 모여 있어요. 읽은 쪽만큼 진행이 차고, 동그라미를 누르면 읽음이 돼요.'],
    en: ['Read', '<k>This Week</k> gathers this week’s papers from every plan. Progress fills as you read, and a click on the circle marks a paper read.'] },
  { ko: ['밀렸을 때', '<k>한 주 미루기</k>가 남은 날짜를 전부 7일 뒤로 옮겨요. 밀린 논문은 빨간 경고 없이 «이번 주» 맨 위에 올라와요.'],
    en: ['Falling behind', '<k>Push a Week</k> moves every remaining date seven days later. Overdue papers rise to the top of This Week, with no red warnings.'] }
];

/** The six steps in one language: `[{n, title, html}]`, each `<k>` set as
 *  a key with the class the caller's stylesheet draws keys with. */
function howTo(lang, keyClass) {
  const en = (lang || document.documentElement.lang) === 'en';
  return HOWTO.map((step, i) => {
    const [title, body] = en ? step.en : step.ko;
    return { n: i + 1, title, html: body.replace(/<k>/g, '<span class="' + (keyClass || 'k') + '">').replace(/<\/k>/g, '</span>') };
  });
}

function mount(host, opts) {
  opts = opts || {};
  const KO = (opts.lang || document.documentElement.lang || 'ko') !== 'en';
  const L = (ko, en) => (KO ? ko : en);
  const parts = new Set(opts.parts || ['tour', 'window', 'fine']);
  const fit = +opts.fit || 0;
  const calm = !!(window.matchMedia && window.matchMedia('(prefers-reduced-motion: reduce)').matches);

  /* Words for dates, in each language's own shape. */
  const DOW = KO ? ['일', '월', '화', '수', '목', '금', '토'] : ['Sun', 'Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat'];
  const DAY = KO ? ['일요일', '월요일', '화요일', '수요일', '목요일', '금요일', '토요일'] : ['Sunday', 'Monday', 'Tuesday', 'Wednesday', 'Thursday', 'Friday', 'Saturday'];
  const MON = ['Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun', 'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec'];
  const md = s => { const t = d(s); return KO ? (t.getUTCMonth() + 1) + '.' + t.getUTCDate() : MON[t.getUTCMonth()] + ' ' + t.getUTCDate(); };
  const long = s => { const t = d(s); return KO ? (t.getUTCMonth() + 1) + '월 ' + t.getUTCDate() + '일' : MON[t.getUTCMonth()] + ' ' + t.getUTCDate(); };
  /** «11월 20일 금요일» · «Friday, Nov 20» */
  const full = s => KO ? long(s) + ' ' + DAY[dow(s)] : DAY[dow(s)] + ', ' + long(s);
  const span = (a, b) => long(a) + ' – ' + long(b);
  const papers = n => KO ? n + '편' : n === 1 ? '1 paper' : n + ' papers';
  const plural = (n, one, many) => n === 1 ? '1 ' + one : n + ' ' + many;
  /** 으로 after a closed syllable, 로 after an open one or ㄹ. */
  const ro = w => { const c = w.charCodeAt(w.length - 1); if (c < 0xAC00 || c > 0xD7A3) return '로'; const j = (c - 0xAC00) % 28; return (j === 0 || j === 8) ? '로' : '으로'; };

  const KIND = {
    paper: { n: L('논문', 'Paper'), c: '--tag-blue', i: 'doc' }, slides: { n: L('슬라이드', 'Slides'), c: '--tag-orange', i: 'slides' },
    code: { n: L('코드', 'Code'), c: '--tag-gray', i: 'code' }, notebook: { n: L('노트북', 'Notebook'), c: '--tag-yellow', i: 'notebook' },
    video: { n: L('영상', 'Video'), c: '--tag-pink', i: 'video' }, post: { n: L('글', 'Article'), c: '--tag-green', i: 'lines' }, data: { n: L('데이터', 'Data'), c: '--tag-teal', i: 'data' }
  };
  const TAGC = { MuJoCo: '--tag-blue', Atari: '--tag-pink', D4RL: '--tag-teal', theory: '--tag-purple' };
  const TAGN = { MuJoCo: 'MuJoCo', Atari: 'Atari', D4RL: 'D4RL', theory: L('이론', 'Theory') };
  const PLANS = {
    offline: { name: L('Offline RL 정주행', 'Offline RL, in Order'), sections: KO ? ['바탕', '값을 낮춰 잡기', '단순하게', '모델로 풀기', '불확실성과 이론'] : ['Foundations', 'Conservative Values', 'Keeping It Simple', 'Model-Based', 'Uncertainty and Theory'] },
    pg: { name: L('Policy Gradient 복습', 'Policy Gradient Review') }
  };
  const besidePDF = L('파일 · PDF 옆에 있어요', 'File · beside the PDF');
  const P = [
    { id: 'bcq', title: 'Off-Policy Deep Reinforcement Learning without Exploration', first: 'Fujimoto', venue: 'ICML', year: 2019, arxiv: '1812.02900', pages: 23, page: 23, status: 'read', date: '2026-11-09', plan: 'offline', sec: 0, tags: ['MuJoCo'], links: [{ k: 'code', t: 'sfujim/BCQ', h: 'github.com' }], notes: 1, marks: 9 },
    { id: 'brac', title: 'Behavior Regularized Offline Reinforcement Learning', first: 'Wu', venue: 'arXiv', year: 2019, arxiv: '1911.11361', pages: 25, page: 25, status: 'read', date: '2026-11-11', plan: 'offline', sec: 0, tags: ['MuJoCo'], links: [], notes: 0, marks: 4 },
    { id: 'cql', title: 'Conservative Q-Learning for Offline Reinforcement Learning', first: 'Kumar', venue: 'NeurIPS', year: 2020, arxiv: '2006.04779', pages: 31, page: 31, status: 'read', date: '2026-11-13', plan: 'offline', sec: 1, tags: ['MuJoCo', 'D4RL'], links: [{ k: 'slides', t: L('CQL 발표자료.pptx', 'CQL talk.pptx'), h: besidePDF }, { k: 'code', t: 'aviralkumar2907/CQL', h: 'github.com' }, { k: 'notebook', t: 'practice04_cql.ipynb', h: besidePDF }], notes: 3, marks: 21 },
    { id: 'fisher', title: 'Offline Reinforcement Learning with Fisher Divergence Critic Regularization', first: 'Kostrikov', venue: 'ICML', year: 2021, arxiv: '2103.08050', pages: 14, page: 0, status: 'unread', date: '2026-11-12', plan: 'offline', sec: 1, tags: ['D4RL'], links: [], notes: 0, marks: 0 },
    { id: 'mcq', title: 'Mildly Conservative Q-Learning for Offline Reinforcement Learning', first: 'Lyu', venue: 'NeurIPS', year: 2022, arxiv: '2206.04745', pages: 36, page: 0, status: 'unread', date: '2026-11-20', plan: 'offline', sec: 1, tags: ['D4RL'], links: [{ k: 'notebook', t: 'practice07_mcq.ipynb', h: besidePDF }], notes: 0, marks: 0 },
    { id: 'td3bc', title: 'A Minimalist Approach to Offline Reinforcement Learning', first: 'Fujimoto', venue: 'NeurIPS', year: 2021, arxiv: '2106.06860', pages: 17, page: 9, status: 'reading', date: '2026-11-16', plan: 'offline', sec: 2, tags: ['MuJoCo', 'D4RL'], links: [{ k: 'code', t: 'sfujim/TD3_BC', h: 'github.com' }], notes: 1, marks: 6 },
    { id: 'iql', title: 'Offline Reinforcement Learning with Implicit Q-Learning', first: 'Kostrikov', venue: 'ICLR', year: 2022, arxiv: '2110.06169', pages: 13, page: 0, status: 'unread', date: '2026-11-18', plan: 'offline', sec: 2, tags: ['D4RL'], links: [{ k: 'video', t: L('저자 발표 영상', 'The authors’ talk'), h: 'youtube.com' }], found: { k: 'code', t: 'ikostrikov/implicit_q_learning', h: 'github.com' }, notes: 0, marks: 0 },
    { id: 'mopo', title: 'MOPO: Model-based Offline Policy Optimization', first: 'Yu', venue: 'NeurIPS', year: 2020, arxiv: '2005.13239', pages: 22, page: 0, status: 'unread', date: '2026-11-25', plan: 'offline', sec: 3, tags: ['MuJoCo'], links: [{ k: 'code', t: 'tianheyu927/mopo', h: 'github.com' }], notes: 0, marks: 0 },
    { id: 'rambo', title: 'RAMBO-RL: Robust Adversarial Model-Based Offline Reinforcement Learning', first: 'Rigter', venue: 'NeurIPS', year: 2022, arxiv: '2204.12581', pages: 24, page: 0, status: 'unread', date: '2026-11-27', plan: 'offline', sec: 3, tags: ['D4RL'], links: [], notes: 0, marks: 0 },
    { id: 'edac', title: 'Uncertainty-Based Offline Reinforcement Learning with Diversified Q-Ensemble', first: 'An', venue: 'NeurIPS', year: 2021, arxiv: '2110.01548', pages: 20, page: 0, status: 'unread', date: null, plan: 'offline', sec: 4, tags: ['D4RL'], links: [], found: { k: 'code', t: 'snu-mllab/EDAC', h: 'github.com' }, notes: 0, marks: 0 },
    { id: 'dac', title: 'DeepAveragers: Offline Reinforcement Learning by Solving Derived Non-Parametric MDPs', first: 'Shrestha', venue: 'ICLR', year: 2021, arxiv: '2010.08891', pages: 24, page: 0, status: 'unread', date: null, plan: 'offline', sec: 4, tags: ['Atari'], links: [], notes: 0, marks: 0 },
    { id: 'ppo', title: 'Proximal Policy Optimization Algorithms', first: 'Schulman', venue: 'arXiv', year: 2017, arxiv: '1707.06347', pages: 12, page: 5, status: 'reading', date: '2026-11-19', plan: 'pg', tags: ['MuJoCo'], links: [{ k: 'slides', t: 'PPO.pptx', h: besidePDF }], notes: 2, marks: 11 },
    { id: 'trpo', title: 'Trust Region Policy Optimization', first: 'Schulman', venue: 'ICML', year: 2015, arxiv: '1502.05477', pages: 16, page: 16, status: 'read', date: null, plan: 'pg', tags: ['MuJoCo'], links: [{ k: 'slides', t: 'TRPO.pptx', h: besidePDF }], notes: 1, marks: 7 },
    { id: 'sac', title: 'Soft Actor-Critic: Off-Policy Maximum Entropy Deep Reinforcement Learning with a Stochastic Actor', first: 'Haarnoja', venue: 'ICML', year: 2018, arxiv: '1801.01290', pages: 14, page: 0, status: 'unread', date: '2026-11-26', plan: 'pg', tags: ['MuJoCo'], links: [], notes: 0, marks: 0 },
    { id: 'ddpg', title: 'Continuous Control with Deep Reinforcement Learning', first: 'Lillicrap', venue: 'ICLR', year: 2016, arxiv: '1509.02971', pages: 14, page: 14, status: 'read', date: null, plan: 'pg', tags: ['MuJoCo'], links: [], notes: 0, marks: 3 },
    { id: 'dqn', title: 'Human-level Control through Deep Reinforcement Learning', first: 'Mnih', venue: 'Nature', year: 2015, doi: '10.1038/nature14236', pages: 13, page: 13, status: 'read', date: null, plan: null, tags: ['Atari'], links: [], notes: 2, marks: 15 },
    { id: 'dt', title: 'Decision Transformer: Reinforcement Learning via Sequence Modeling', first: 'Chen', venue: 'NeurIPS', year: 2021, arxiv: '2106.01345', pages: 21, page: 0, status: 'unread', date: null, plan: null, tags: ['Atari', 'D4RL'], links: [], notes: 0, marks: 0 }
  ];
  const EXTRA = { id: 'bcp', title: 'Bellman-consistent Pessimism for Offline Reinforcement Learning', first: 'Xie', venue: 'NeurIPS', year: 2021, arxiv: '2106.06926', pages: 38, page: 0, status: 'unread', date: null, plan: 'offline', sec: 4, tags: ['theory'], links: [], notes: 0, marks: 0 };

  const S = { shelf: 'plan', view: 'table', group: 'section', sel: 'td3bc', sort: { key: null, dir: 1 } };
  const SP = { days: new Set([1, 3, 5]), per: 1, from: 'today' };
  let POP = null, toastTimer = 0, dragId = null, scale = 1;

  /* The root, in a shadow root of its own: the page around it has a `.seg`,
     a `.caption` and a `.key` of its own, and neither side should reach the
     other. The stylesheet comes inline when the host has it as text (the
     Mac's web view loads no files), and as a link otherwise — hidden until it
     arrives, so nothing shows unstyled for a frame. */
  const app = document.createElement('div');
  app.className = 'ptp';
  if (opts.theme === 'dark' || opts.theme === 'light') app.dataset.theme = opts.theme;
  app.lang = KO ? 'ko' : 'en';
  /* An unstyled frame of our own inside the host, so a host with padding or
     a background of its own (a card on the page) neither throws off the
     width the demo is fitted to nor gets clipped by it. */
  const frame = document.createElement('div');
  frame.style.cssText = 'position:relative;width:100%;margin:0;padding:0;border:0;' + (fit ? 'overflow:hidden;' : '');
  host.replaceChildren(frame);
  const shadow = frame.attachShadow ? frame.attachShadow({ mode: 'open' }) : frame;
  const inline = opts.cssText || (document.getElementById('ptp-css') || {}).textContent;
  let sheet;
  if (inline) {
    sheet = document.createElement('style');
    sheet.textContent = inline;
  } else {
    sheet = document.createElement('link');
    sheet.rel = 'stylesheet';
    sheet.href = opts.cssHref || CSS_URL;
    app.style.visibility = 'hidden';
    const show = () => { app.style.visibility = ''; relayout(); };
    sheet.addEventListener('load', show);
    sheet.addEventListener('error', show);
  }
  shadow.replaceChildren(sheet, app);
  if (fit) app.style.transformOrigin = '0 0';
  const $ = s => app.querySelector(s);

  const STEP_NAMES = KO ? ['모으기', '날짜 정하기', '달력에서 옮기기', '자료 붙이기', '이번 주', '밀렸을 때']
    : ['Gather', 'Set Days', 'Move on the Calendar', 'Attach Materials', 'This Week', 'Falling Behind'];
  const INTRO = L('번호를 누르면 그 장면으로 가요. 그냥 창을 만져 봐도 돼요. <strong>동그라미</strong>는 읽기 상태, <strong>날짜</strong>는 읽을 날이에요. 줄을 누르면 그 논문의 자료가 보여요.',
    'Press a number to go to that step, or use the window on your own. The <strong>circle</strong> is the reading status and the <strong>date</strong> is the day to read it. Select a row to see its materials.');
  let html = '';
  if (parts.has('tour')) {
    html += '<nav class="tour" id="ptp-tour" aria-label="' + L('따라 해 보기', 'Try It') + '"><span class="lab">' + L('따라 해 보기', 'Try it') + '</span>'
      + STEP_NAMES.map((n, i) => '<button type="button" data-step="' + i + '" aria-pressed="false"><b>' + (i + 1) + '</b>' + n + '</button>').join('') + '</nav>'
      + '<p class="caption" id="ptp-caption">' + INTRO + '</p>';
  }
  html += '<div class="stage"><div class="window" id="ptp-win"><div class="chrome">'
    + '<span class="lights" aria-hidden="true"><i></i><i></i><i></i></span><span class="grow"></span>'
    + '<span class="find" aria-hidden="true">' + L('전부 찾기', 'Search Everything') + ' <kbd>⌘K</kbd></span>'
    + '<span class="tabs" aria-hidden="true"><span class="on">Info</span><span>Marks</span><span>Notes</span><span>Tool</span></span></div>'
    + '<div class="body"><aside class="sidebar" id="ptp-sidebar" aria-label="' + L('옆 목록', 'Sidebar') + '"></aside>'
    + '<div class="main" id="ptp-main" role="main"></div>'
    + '<aside class="inspector" id="ptp-inspector" aria-label="' + L('인스펙터', 'Inspector') + '"></aside></div>'
    + '<div class="toast" id="ptp-toast" hidden></div></div></div>';
  if (parts.has('fine')) html += '<p class="fine">' + L('예시로 넣은 논문과 날짜예요. 오늘을 2026년 11월 16일 월요일로 두고 그렸어요.', 'Sample papers and dates, drawn as if today were Monday, November 16, 2026.') + '</p>';
  if (parts.has('howto')) {
    html += '<div class="howto">' + howTo(KO ? 'ko' : 'en').map(s => '<div class="card"><h3><b>' + s.n + '</b>' + esc(s.title) + '</h3><p>' + s.html + '</p></div>').join('') + '</div>';
  }
  html += '<div class="pop" id="ptp-pop" hidden></div>';
  app.innerHTML = html;
  if (!parts.has('window')) $('.stage').hidden = true;

  const planPapers = k => P.filter(p => p.plan === k);
  const isLate = p => !!p.date && p.date < TODAY && p.status !== 'read';
  const fromBib = L('서지에서 저절로', 'From the bibliography');
  const linksOf = p => (p.arxiv ? [{ k: 'paper', t: 'arXiv:' + p.arxiv, h: fromBib, auto: true }] : p.doi ? [{ k: 'paper', t: 'doi.org/' + p.doi, h: fromBib, auto: true }] : []).concat(p.links);
  const weekCount = () => P.filter(p => p.status !== 'read' && p.date && (isLate(p) || monday(p.date) === monday(TODAY))).length;
  const who = p => KO ? p.first + ' 외' : p.first + ' et al.';

  function ring(p, size) {
    const s = size || 16, c = 2 * Math.PI * 6, open = '<svg width="' + s + '" height="' + s + '" viewBox="0 0 16 16" aria-hidden="true">';
    if (p.status === 'read') return open + '<circle cx="8" cy="8" r="7" fill="var(--read)"/><path d="M5 8.3l2 2 4-4.4" fill="none" stroke="var(--panel)" stroke-width="1.7" stroke-linecap="round" stroke-linejoin="round"/></svg>';
    if (p.status === 'reading') { const f = Math.max(.12, Math.min(.92, p.page / p.pages)); return open + '<circle cx="8" cy="8" r="6" fill="none" stroke="var(--reading-track)" stroke-width="2"/><circle cx="8" cy="8" r="6" fill="none" stroke="var(--reading)" stroke-width="2" stroke-linecap="round" stroke-dasharray="' + (c * f).toFixed(1) + ' ' + c.toFixed(1) + '" transform="rotate(-90 8 8)"/></svg>'; }
    return open + '<circle cx="8" cy="8" r="6" fill="none" stroke="var(--ring-empty)" stroke-width="1.5"/></svg>';
  }
  function donut(f) { const c = 2 * Math.PI * 5; return '<svg width="14" height="14" viewBox="0 0 14 14" aria-hidden="true"><circle cx="7" cy="7" r="5" fill="none" stroke="var(--sep-strong)" stroke-width="2"/><circle cx="7" cy="7" r="5" fill="none" stroke="var(--read)" stroke-width="2" stroke-linecap="round" stroke-dasharray="' + (c * f).toFixed(1) + ' ' + c.toFixed(1) + '" transform="rotate(-90 7 7)"/></svg>'; }

  function dateLabel(p) {
    if (!p.date) return { text: L('정하기', 'Set Date'), cls: 'none' };
    const n = diff(p.date, TODAY);
    if (isLate(p)) return { text: md(p.date) + ' · ' + L('밀림', 'Overdue'), cls: 'late' };
    if (n === 0) return { text: L('오늘', 'Today'), cls: 'today' };
    if (n === 1) return { text: L('내일', 'Tomorrow'), cls: '' };
    return { text: KO ? DOW[dow(p.date)] + ' ' + md(p.date) : DOW[dow(p.date)] + ', ' + md(p.date), cls: '' };
  }
  const dateChip = p => { const D = dateLabel(p); return '<button type="button" class="dchip ' + D.cls + '" data-act="date" data-id="' + p.id + '" title="' + L('읽을 날 정하기', 'Choose a day to read it') + '">' + D.text + '</button>'; };
  function progCell(p) { const f = p.pages ? p.page / p.pages : 0; const txt = (p.page && p.status !== 'read') ? p.page + '/' + p.pages : p.pages + L('쪽', ' pp.'); return '<div class="prog"><span class="bar' + (p.status === 'read' ? ' done' : '') + '"><i style="width:' + Math.round(f * 100) + '%"></i></span>' + txt + '</div>'; }
  function linkCell(p) { const A = linksOf(p); return '<div class="links">' + A.slice(0, 4).map(l => '<span class="kchip" style="--k:var(' + KIND[l.k].c + ')" title="' + KIND[l.k].n + ' · ' + esc(l.t) + '">' + I(KIND[l.k].i, 14) + '</span>').join('') + (A.length > 4 ? '<span class="more">+' + (A.length - 4) + '</span>' : '') + '</div>'; }
  const tagCell = p => '<div class="tags">' + p.tags.slice(0, 2).map(t => '<span class="tag" style="--k:var(' + TAGC[t] + ')">' + esc(TAGN[t]) + '</span>').join('') + '</div>';
  const planCell = p => '<div class="tags">' + (p.plan ? '<span class="tag" style="--k:var(--tag-indigo)">' + esc(PLANS[p.plan].name) + '</span>' : '<span class="dim">—</span>') + '</div>';

  function row(p, kind) {
    if (p.pending) return '<div class="row pending"><span class="st">' + ring(p) + '</span><div class="t"><span class="shimmer">arxiv.org/abs/' + p.arxiv + ' · ' + L('서지를 채우는 중…', 'Filling in the details…') + '</span></div></div>';
    const cells = kind === 'plan' ? dateChip(p) + progCell(p) + linkCell(p) + tagCell(p)
      : kind === 'all' ? '<div class="who">' + who(p) + ' · ' + p.year + '</div>' + dateChip(p) + planCell(p) + linkCell(p)
        : planCell(p) + dateChip(p) + linkCell(p);
    return '<div class="row s-' + p.status + (p.id === S.sel ? ' on' : '') + '" data-act="select" data-id="' + p.id + '" tabindex="0"><button type="button" class="st" data-act="status" data-id="' + p.id + '" aria-label="' + L('읽기 상태 바꾸기', 'Change Reading Status') + '" title="' + L('누르면 상태가 바뀌어요', 'Click to change the status') + '">' + ring(p) + '</button><div class="t" title="' + esc(p.title) + '">' + esc(p.title) + '</div>' + cells + '</div>';
  }

  function sidebarHTML() {
    const off = planPapers('offline'), pg = planPapers('pg');
    const frac = a => a.filter(p => p.status === 'read').length / a.length;
    const count = a => a.filter(p => p.status === 'read').length + '/' + a.length;
    const live = (shelf, icon, name, n) => '<button type="button" class="sb-row' + (S.shelf === shelf ? ' on' : '') + '" data-act="shelf" data-v="' + shelf + '">' + I(icon) + '<span class="name">' + name + '</span><span class="n">' + n + '</span></button>';
    const still = (icon, name, n) => '<div class="sb-row">' + I(icon) + '<span class="name">' + name + '</span><span class="n">' + n + '</span></div>';
    const n = st => P.filter(p => p.status === st).length;
    return '<div class="sb-group"><div class="sb-row">' + I('folder') + '<span class="libchip">PaperLibrary</span></div></div>'
      + '<div class="sb-group">' + live('all', 'tray', L('모두', 'All'), P.length) + still('circle', L('안 읽음', 'Unread'), n('unread')) + still('half', L('읽는 중', 'Reading'), n('reading')) + still('check', L('읽음', 'Read'), n('read')) + still('star', L('즐겨찾기', 'Favorites'), 4) + '</div>'
      + '<div class="sb-group" id="ptp-sb-plans"><div class="sb-title">' + L('계획', 'Plans') + '</div>'
      + live('week', 'calendar', L('이번 주', 'This Week'), weekCount())
      + '<button type="button" class="sb-row' + (S.shelf === 'plan' ? ' on' : '') + '" data-act="shelf" data-v="plan">' + I('route') + '<span class="name">' + esc(PLANS.offline.name) + '</span><span class="n">' + count(off) + donut(frac(off)) + '</span></button>'
      + '<button type="button" class="sb-row" data-act="say" data-msg="' + esc(L('데모에는 «' + PLANS.offline.name + '»만 들어 있어요.', 'The demo has only “' + PLANS.offline.name + '”.')) + '">' + I('route') + '<span class="name">' + esc(PLANS.pg.name) + '</span><span class="n">' + count(pg) + donut(frac(pg)) + '</span></button>'
      + '<button type="button" class="sb-row quiet" data-act="say" data-msg="' + esc(L('이름만 적으면 계획이 생겨요. 데모에서는 만들어 둔 계획을 써 주세요.', 'Name a plan and it’s there. In the demo, use the one that’s ready.')) + '">' + I('plus') + '<span class="name">' + L('새 계획…', 'New Plan…') + '</span></button></div>'
      + '<div class="sb-group"><div class="sb-title">' + L('컬렉션', 'Collections') + '</div>' + still('folder', L('세미나 발표', 'Seminar Talks'), 9) + still('folder', L('졸업 논문 참고', 'Thesis References'), 23) + '</div>'
      + '<div class="sb-group"><div class="sb-title">' + L('태그', 'Tags') + '</div>' + Object.keys(TAGC).map(t => '<div class="sb-row"><span class="tdot" style="--k:var(' + TAGC[t] + ')"></span><span class="name">' + esc(TAGN[t]) + '</span></div>').join('') + '</div>';
  }

  const shelfChips = () => '<div class="shelfchips">' + [['plan', PLANS.offline.name], ['week', L('이번 주', 'This Week')], ['all', L('모두', 'All')]].map(a => '<button type="button" data-act="shelf" data-v="' + a[0] + '" aria-pressed="' + (S.shelf === a[0]) + '">' + esc(a[1]) + '</button>').join('') + '</div>';

  function pathHTML(ps) {
    return '<div class="path">' + PLANS.offline.sections.map((name, i) => {
      const g = ps.filter(p => p.sec === i && !p.pending); if (!g.length) return '';
      return '<div class="seg"><div class="dots">' + g.map(p => '<button type="button" class="dot' + (p.id === S.sel ? ' on' : '') + '" data-act="select" data-id="' + p.id + '" title="' + esc(p.title) + '" aria-label="' + esc(p.title) + '">' + ring(p, 16) + '</button>').join('') + '</div><small>' + esc(name) + '</small></div>';
    }).join('') + '</div>';
  }
  function weekRange(m) {
    const e = add(m, 6);
    if (KO) return md(m) + '–' + md(e);
    return d(m).getUTCMonth() === d(e).getUTCMonth() ? md(m) + '–' + d(e).getUTCDate() : md(m) + ' – ' + md(e);
  }
  function weekName(m) { const n = diff(m, monday(TODAY)) / 7, r = weekRange(m); return n === 0 ? L('이번 주', 'This week') + ' · ' + r : n === 1 ? L('다음 주', 'Next week') + ' · ' + r : n === -1 ? L('지난주', 'Last week') + ' · ' + r : r; }
  function groupsFor(ps) {
    if (S.group === 'section') return PLANS.offline.sections.map((n, i) => ({ name: n, items: ps.filter(p => p.sec === i) })).filter(g => g.items.length);
    if (S.group === 'status') return [['reading', L('읽는 중', 'Reading')], ['unread', L('안 읽음', 'Unread')], ['read', L('읽음', 'Read')]].map(a => ({ name: a[1], items: ps.filter(p => p.status === a[0]) })).filter(g => g.items.length);
    const by = {}; ps.forEach(p => { const k = p.date ? monday(p.date) : 'none'; (by[k] = by[k] || []).push(p); });
    return Object.keys(by).sort().map(k => ({ name: k === 'none' ? L('날짜 없음', 'No date') : weekName(k), items: by[k].slice().sort((a, b) => (a.date || '') < (b.date || '') ? -1 : 1) }));
  }
  const readOf = items => { const r = items.filter(p => p.status === 'read').length; return L(r + '/' + items.length + ' 읽음', r + ' of ' + items.length + ' read'); };

  function mainPlan() {
    const ps = planPapers('offline'), real = ps.filter(p => !p.pending);
    const read = real.filter(p => p.status === 'read').length;
    const wk = real.filter(p => p.date && monday(p.date) === monday(TODAY)).length;
    const late = real.filter(isLate).length, none = real.filter(p => !p.date).length;
    const ds = real.filter(p => p.date).map(p => p.date).sort();
    const when = ds.length ? span(ds[0], ds[ds.length - 1]) : L('날짜를 아직 안 정했어요', 'No dates yet');
    const head = '<div class="head"><div class="head-top"><span class="tile">' + I('route', 18) + '</span><div><h2>' + esc(PLANS.offline.name) + '</h2><p class="sub">' + when + ' · ' + L(real.length + '편 중 ' + read + '편 읽음', read + ' of ' + real.length + ' read') + '</p></div>'
      + '<div class="head-actions"><button type="button" class="cap" id="ptp-btn-spread" data-act="spread">' + I('calendar', 14) + L('고르게 나누기…', 'Spread Out…') + '</button><button type="button" class="cap" id="ptp-btn-push" data-act="push">' + I('arrow', 14) + L('한 주 미루기', 'Push a Week') + '</button>'
      + '<span class="seg2" role="group" aria-label="' + L('보기', 'View') + '"><button type="button" data-act="view" data-v="table" aria-pressed="' + (S.view === 'table') + '">' + I('table', 14) + L('표', 'Table') + '</button><button type="button" data-act="view" data-v="calendar" aria-pressed="' + (S.view === 'calendar') + '">' + I('calendar', 14) + L('달력', 'Calendar') + '</button></span></div></div>'
      + '<div class="stats"><span class="stat" style="--k:var(--tag-blue)">' + L('이번 주 ' + wk + '편', wk + ' this week') + '</span>' + (late ? '<span class="stat" style="--k:var(--tag-orange)">' + L('밀린 것 ' + late + '편', late + ' overdue') + '</span>' : '') + (none ? '<span class="stat">' + L('날짜 없음 ' + none + '편', none + ' with no date') + '</span>' : '') + '</div>'
      + pathHTML(ps) + '</div>';
    if (S.view === 'calendar') return head + calendarHTML(real);
    const G = groupsFor(ps);
    return head
      + '<div class="viewbar"><span>' + L('묶기', 'Group by') + '</span><span class="gchips" role="group" aria-label="' + L('묶기', 'Group By') + '">' + [['section', L('섹션', 'Section')], ['week', L('주', 'Week')], ['status', L('상태', 'Status')]].map(a => '<button type="button" data-act="group" data-v="' + a[0] + '" aria-pressed="' + (S.group === a[0]) + '">' + a[1] + '</button>').join('') + '</span></div>'
      + '<div class="scroll"><div class="table cols-plan"><div class="thead"><span></span><span>' + L('제목', 'Title') + '</span><span>' + L('읽을 날', 'Read On') + '</span><span>' + L('진행', 'Progress') + '</span><span>' + L('자료', 'Materials') + '</span><span>' + L('태그', 'Tags') + '</span></div>'
      + G.map(g => '<div class="grp">' + esc(g.name) + '<small>' + readOf(g.items) + '</small></div>' + g.items.map(p => row(p, 'plan')).join('')).join('')
      + '<label class="addrow" id="ptp-addrow">' + I('plus', 14) + '<input id="ptp-add-input" type="text" placeholder="' + L('arXiv 주소나 DOI를 붙여넣어 논문을 더해요', 'Paste an arXiv link or a DOI to add a paper') + '" autocomplete="off" spellcheck="false"><span class="hint">' + L('목록에서 끌어와도 돼요', 'Or drag one in from the list') + '</span></label></div></div>';
  }

  function pill(p) { return '<div class="pill s-' + p.status + (isLate(p) ? ' late' : '') + (p.id === S.sel ? ' on' : '') + '" draggable="true" data-act="select" data-id="' + p.id + '" tabindex="0" title="' + esc(p.title) + '"><span>' + ring(p, 13) + esc(p.title) + '</span></div>'; }
  function calendarHTML(ps) {
    const start = '2026-11-09', thisMon = monday(TODAY);
    const heads = KO ? ['월', '화', '수', '목', '금', '토', '일'] : ['Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat', 'Sun'];
    let cells = heads.map(x => '<div class="dh">' + x + '</div>').join('');
    for (let i = 0; i < 35; i++) {
      const day = add(start, i), t = d(day).getUTCDate();
      const cls = (day < TODAY ? ' past' : '') + (day === TODAY ? ' today' : '') + (monday(day) === thisMon ? ' week' : '');
      const label = (t === 1 || i === 0) ? long(day) : t;
      const mine = ps.filter(p => p.date === day).map(pill).join('');
      const others = P.filter(p => p.plan && p.plan !== 'offline' && p.date === day).map(p => '<div class="pill ghost" title="' + esc(PLANS[p.plan].name + ' · ' + p.title) + '"><span>' + esc(p.title) + '</span></div>').join('');
      cells += '<div class="day' + cls + '" data-drop="' + day + '"><span class="num">' + label + '</span>' + mine + others + '</div>';
    }
    const none = ps.filter(p => !p.date);
    return '<div class="cal-wrap"><div class="cal-scroll"><div class="cal" id="ptp-cal">' + cells + '</div></div>'
      + '<div class="tray" id="ptp-tray" data-drop=""><h4>' + L('날짜 없음', 'No Date') + ' · ' + none.length + '</h4><p>' + L('달력으로 끌면 그날로 정해요. 여기로 끌면 날짜를 지워요.', 'Drag to the calendar to give it a day. Drag here to clear the day.') + '</p>' + none.map(pill).join('') + '</div></div>';
  }

  function mainWeek() {
    const mon = monday(TODAY), late = P.filter(isLate), days = [];
    for (let i = 0; i < 7; i++) { const day = add(mon, i); const items = P.filter(p => p.date === day && !isLate(p)); if (items.length) days.push({ day: day, items: items }); }
    const all = late.concat(days.reduce((a, g) => a.concat(g.items), []));
    const plans = new Set(all.map(p => p.plan).filter(Boolean)).size;
    const dayName = day => day === TODAY ? L('오늘', 'Today') + ' · ' + full(day) : day === add(TODAY, 1) ? L('내일', 'Tomorrow') + ' · ' + full(day) : KO ? DAY[dow(day)] + ' · ' + long(day) : full(day);
    return '<div class="head"><div class="head-top"><span class="tile">' + I('calendar', 18) + '</span><div><h2>' + L('이번 주', 'This Week') + '</h2><p class="sub">' + span(mon, add(mon, 6)) + ' · ' + L('계획 ' + plans + '개에서 ' + all.length + '편', papers(all.length) + ' from ' + plural(plans, 'plan', 'plans')) + '</p></div></div></div>'
      + '<div class="scroll"><div class="table cols-week"><div class="thead"><span></span><span>' + L('제목', 'Title') + '</span><span>' + L('계획', 'Plan') + '</span><span>' + L('읽을 날', 'Read On') + '</span><span>' + L('자료', 'Materials') + '</span></div>'
      + (late.length ? '<div class="grp" id="ptp-grp-late">' + L('밀린 것', 'Overdue') + '<small>' + papers(late.length) + '</small><button type="button" class="cap" data-act="pull-late">' + L('오늘로 옮기기', 'Move to Today') + '</button></div>' + late.map(p => row(p, 'week')).join('') : '')
      + days.map(g => '<div class="grp">' + dayName(g.day) + '</div>' + g.items.map(p => row(p, 'week')).join('')).join('')
      + (all.length ? '' : '<div class="empty">' + L('이번 주에 읽을 논문이 없어요', 'Nothing to read this week.') + '</div>') + '</div></div>';
  }

  function mainAll() {
    const ps = P.filter(p => !p.pending).slice(), key = S.sort.key, dir = S.sort.dir;
    if (key) ps.sort((a, b) => { const va = key === 'title' ? a.title.toLowerCase() : key === 'year' ? a.year : (a.date || '9999'), vb = key === 'title' ? b.title.toLowerCase() : key === 'year' ? b.year : (b.date || '9999'); return (va < vb ? -1 : va > vb ? 1 : 0) * dir; });
    const th = (k, n) => '<button type="button" data-act="sort" data-k="' + k + '" title="' + L('눌러서 정렬', 'Click to sort') + '">' + n + (key === k ? (dir > 0 ? ' ↑' : ' ↓') : '') + '</button>';
    return '<div class="head"><div class="head-top"><span class="tile">' + I('tray', 18) + '</span><div><h2>' + L('모두', 'All') + '</h2><p class="sub">' + L('논문 ' + ps.length + '편 · 열 머리를 눌러 정렬해요', ps.length + ' papers · Click a column heading to sort') + '</p></div>'
      + '<div class="head-actions"><span class="seg2" role="group" aria-label="' + L('보기', 'View') + '"><button type="button" data-act="say" data-msg="' + esc(L('지금 쓰는 목록 그대로예요. 데모에는 표만 넣었어요.', 'The list you use now. The demo has only the table.')) + '" aria-pressed="false">' + L('목록', 'List') + '</button><button type="button" aria-pressed="true">' + I('table', 14) + L('표', 'Table') + '</button></span></div></div></div>'
      + '<div class="scroll"><div class="table cols-all"><div class="thead"><span></span><span>' + th('title', L('제목', 'Title')) + '</span><span>' + th('year', L('저자 · 해', 'Author · Year')) + '</span><span>' + th('date', L('읽을 날', 'Read On')) + '</span><span>' + L('계획', 'Plan') + '</span><span>' + L('자료', 'Materials') + '</span></div>'
      + ps.map(p => row(p, 'all')).join('') + '</div></div>';
  }

  function inspectorHTML() {
    const p = P.find(x => x.id === S.sel);
    if (!p || p.pending) return '<div class="empty">' + L('고른 논문이 없어요', 'No paper selected.') + '</div>';
    const A = linksOf(p), pl = p.plan ? PLANS[p.plan] : null;
    const dl = p.date ? full(p.date) + (isLate(p) ? ' · ' + L('밀림', 'Overdue') : '') : L('정하기', 'Set Date');
    const dcls = !p.date ? 'none' : isLate(p) ? 'late' : p.date === TODAY ? 'today' : '';
    const mats = A.map(l => {
      const K = KIND[l.k], i = p.links.indexOf(l);
      return '<div class="mat"><span class="ic" style="--k:var(' + K.c + ')">' + I(K.i, 14) + '</span><div class="tx"><div class="tt">' + esc(l.t) + '</div><div class="ss">' + K.n + ' · ' + esc(l.h) + '</div></div>' + (l.auto ? '' : '<button type="button" class="x" data-act="rm-link" data-i="' + i + '" aria-label="' + L('자료 빼기', 'Remove') + '" title="' + L('빼기', 'Remove') + '">' + I('x', 12) + '</button>') + '</div>';
    }).join('');
    const found = p.found ? '<div class="found">' + I('spark', 16) + '<div class="tx"><div class="tt">' + esc(p.found.t) + '</div><div class="ss">' + L('논문에서 찾은 링크', 'Found in the paper') + ' <span class="later">' + L('다음에', 'Later') + '</span></div></div><button type="button" class="cap" data-act="add-found">' + L('더하기', 'Add') + '</button></div>' : '';
    const status = [['unread', L('안 읽음', 'Unread')], ['reading', L('읽는 중', 'Reading')], ['read', L('읽음', 'Read')]];
    return '<div class="ins"><div><h3>' + esc(p.title) + '</h3><p class="by">' + who(p) + ' · ' + p.venue + ' ' + p.year + '</p></div>'
      + '<span class="seg2 wide" role="group" aria-label="' + L('읽기 상태', 'Reading Status') + '">' + status.map(a => '<button type="button" data-act="set-status" data-v="' + a[0] + '" aria-pressed="' + (p.status === a[0]) + '">' + a[1] + '</button>').join('') + '</span>'
      + '<div><p class="sec-t">' + L('계획', 'Plan') + '</p><dl class="kv"><dt>' + L('읽을 날', 'Read on') + '</dt><dd><button type="button" class="dchip ' + dcls + '" data-act="date" data-id="' + p.id + '">' + dl + '</button></dd>'
      + '<dt>' + L('계획', 'Plan') + '</dt><dd>' + (pl ? esc(pl.name) + (pl.sections && p.sec != null ? ' · ' + esc(pl.sections[p.sec]) : '') : '<span class="dim">' + L('없음', 'None') + '</span>') + '</dd>'
      + '<dt>' + L('진행', 'Progress') + '</dt><dd>' + progCell(p) + '</dd></dl></div>'
      + '<div id="ptp-mats"><p class="sec-t">' + L('자료', 'Materials') + '</p><div class="mats">' + mats + '</div>' + found
      + '<label class="linkfield">' + I('link', 14) + '<input id="ptp-link-input" type="text" placeholder="' + L('주소를 붙여넣어요', 'Paste a link') + '" autocomplete="off" spellcheck="false"></label><div class="detect" id="ptp-detect"></div></div>'
      + '<div class="counts">' + L('노트 ' + (p.notes || 0) + '개 · 표시 ' + (p.marks || 0) + '개', plural(p.notes || 0, 'note', 'notes') + ' · ' + plural(p.marks || 0, 'mark', 'marks')) + '</div></div>';
  }

  function render() {
    $('#ptp-sidebar').innerHTML = sidebarHTML();
    $('#ptp-main').innerHTML = shelfChips() + (S.shelf === 'plan' ? mainPlan() : S.shelf === 'week' ? mainWeek() : mainAll());
    $('#ptp-inspector').innerHTML = inspectorHTML();
  }

  /* 바꾸는 일 */
  const snap = () => JSON.stringify(P.map(p => [p.id, p.date, p.status, p.page]));
  function restore(s) { JSON.parse(s).forEach(a => { const p = P.find(x => x.id === a[0]); if (p) { p.date = a[1]; p.status = a[2]; p.page = a[3]; } }); render(); toast(L('되돌렸어요.', 'Undone.')); }
  function toast(msg, undo) {
    const t = $('#ptp-toast'); clearTimeout(toastTimer);
    t.innerHTML = '<span>' + esc(msg) + '</span>' + (undo ? '<button type="button" data-act="undo">' + L('되돌리기', 'Undo') + '</button>' : '');
    t._undo = undo || null; t.hidden = false;
    toastTimer = setTimeout(() => { t.hidden = true; }, undo ? 7000 : 3200);
  }
  function setStatus(p, v) { p.status = v; p.page = v === 'read' ? p.pages : v === 'reading' ? Math.max(p.page && p.page < p.pages ? p.page : 0, Math.round(p.pages * .3)) : 0; }
  function kindOf(u) {
    u = u.toLowerCase();
    if (/github\.com|gitlab\.com/.test(u)) return 'code';
    if (/colab\.research\.google|kaggle\.com\/code|\.ipynb/.test(u)) return 'notebook';
    if (/youtube\.com|youtu\.be|vimeo\.com/.test(u)) return 'video';
    if (/docs\.google\.com\/presentation|slideshare|speakerdeck|\.pptx?$|\.key$/.test(u)) return 'slides';
    if (/arxiv\.org|openreview\.net|doi\.org/.test(u)) return 'paper';
    if (/huggingface\.co\/datasets|kaggle\.com\/datasets/.test(u)) return 'data';
    return 'post';
  }
  function labelOf(url) { const u = url.trim().replace(/^https?:\/\//, '').replace(/^www\./, '').replace(/[?#].*$/, '').replace(/\/$/, ''); const a = u.split('/'); if (/github\.com|gitlab\.com/.test(a[0]) && a.length >= 3) return { t: a[1] + '/' + a[2], h: a[0] }; return { t: a.length > 1 ? a[0] + '/…' : a[0], h: a[0] }; }
  function addLink() {
    const el = $('#ptp-link-input'), v = el ? el.value.trim() : '', p = P.find(x => x.id === S.sel); if (!v || !p) return;
    const k = kindOf(v), A = labelOf(v); p.links.push({ k: k, t: A.t, h: A.h }); render();
    toast(L(KIND[k].n + ro(KIND[k].n) + ' 붙였어요.', KIND[k].n + ' link added.'));
  }
  function addExtra() {
    if (P.some(p => p.id === 'bcp')) { toast(L('데모에는 한 편만 준비했어요.', 'The demo has one paper ready.')); return; }
    const one = Object.assign({}, EXTRA, { pending: true }); P.push(one); S.shelf = 'plan'; S.view = 'table'; render();
    setTimeout(() => { one.pending = false; S.sel = 'bcp'; render(); toast(L('논문 1편을 더했어요. 서지도 채웠어요.', 'Added 1 paper, with its details filled in.')); }, calm ? 0 : 1300);
  }
  function parseWhen(raw) {
    const s = raw.trim().toLowerCase().replace(/\s+/g, ' '); let m;
    if (!s) return null;
    if (s === '오늘' || s === 'today') return TODAY;
    if (s === '내일' || s === 'tomorrow') return add(TODAY, 1);
    if (s === '모레') return add(TODAY, 2);
    if ((m = s.match(/^\+ ?(\d{1,2}) ?(일|d|days?|주|w|wk|weeks?)?$/))) return add(TODAY, (+m[1]) * (/^(주|w|wk|week|weeks)$/.test(m[2] || '') ? 7 : 1));
    if ((m = s.match(/^(\d{1,2}) ?[\/.\-월] ?(\d{1,2})일?$/))) { const mo = +m[1], da = +m[2]; if (mo < 1 || mo > 12 || da < 1 || da > 31) return null; const two = n => String(n).padStart(2, '0'); let v = '2026-' + two(mo) + '-' + two(da); if (v < add(TODAY, -60)) v = '2027-' + two(mo) + '-' + two(da); return v; }
    if ((m = s.match(/^(다음 ?주 ?)?([월화수목금토일])(요일)?$/))) { const want = '일월화수목금토'.indexOf(m[2]); if (m[1]) return add(add(monday(TODAY), 7), (want + 6) % 7); for (let i = 0; i < 7; i++) { const day = add(TODAY, i); if (dow(day) === want) return day; } }
    if ((m = s.match(/^(next )?([a-z]{3,9})$/))) {
      const names = ['sunday', 'monday', 'tuesday', 'wednesday', 'thursday', 'friday', 'saturday'];
      const want = names.findIndex(n => n.startsWith(m[2]));
      if (want < 0) return null;
      if (m[1]) return add(add(monday(TODAY), 7), (want + 6) % 7);
      for (let i = 0; i < 7; i++) { const day = add(TODAY, i); if (dow(day) === want) return day; }
    }
    return null;
  }
  function spreadPlan() {
    const todo = planPapers('offline').filter(p => p.status !== 'read' && !p.pending).sort((a, b) => (a.status === 'reading' ? 0 : 1) - (b.status === 'reading' ? 0 : 1));
    const out = []; if (!SP.days.size) return out;
    let day = SP.from === 'today' ? TODAY : add(monday(TODAY), 7), i = 0, guard = 0;
    while (i < todo.length && guard++ < 400) { if (SP.days.has(dow(day))) for (let k = 0; k < SP.per && i < todo.length; k++) out.push([todo[i++], day]); day = add(day, 1); }
    return out;
  }

  /* 팝오버 — positioned inside the demo, in its own (unscaled) points. */
  function openPop(anchor, kind, id) {
    const pop = $('#ptp-pop'); POP = { anchor: anchor, kind: kind, id: id };
    pop.innerHTML = kind === 'date' ? datePop(P.find(x => x.id === id)) : spreadPop();
    pop.hidden = false;
    const box = app.getBoundingClientRect(), r = anchor.getBoundingClientRect(), w = pop.offsetWidth;
    const left = (r.left - box.left) / scale, top = (r.bottom - box.top) / scale + 6;
    pop.style.left = Math.max(8, Math.min(left, app.clientWidth - w - 8)) + 'px';
    pop.style.top = top + 'px';
    const first = $('#ptp-date-text'); if (first && !('ontouchstart' in window)) first.focus({ preventScroll: true });
    relayout();
  }
  function closePop() { const pop = $('#ptp-pop'); if (!pop) return; pop.hidden = true; pop.innerHTML = ''; POP = null; relayout(); }
  function datePop(p) {
    let fri = TODAY; for (let i = 0; i < 7; i++) { const day = add(TODAY, i); if (dow(day) === 5) { fri = day; break; } }
    const q = [[L('오늘', 'Today'), TODAY], [L('내일', 'Tomorrow'), add(TODAY, 1)], [L('이번 금요일', 'This Friday'), fri], [L('다음 주 월요일', 'Next Monday'), add(monday(TODAY), 7)]];
    let cells = ''; const start = monday(TODAY);
    for (let i = 0; i < 35; i++) { const day = add(start, i); cells += '<button type="button" class="' + (day === TODAY ? 'tod ' : '') + (day === p.date ? 'sel' : '') + '" data-act="pick-date" data-date="' + day + '" title="' + full(day) + '">' + d(day).getUTCDate() + '</button>'; }
    const heads = KO ? ['월', '화', '수', '목', '금', '토', '일'] : ['M', 'T', 'W', 'T', 'F', 'S', 'S'];
    return '<input id="ptp-date-text" type="text" placeholder="' + L('금요일, 12/3, +1주처럼 적어요', 'Try “Fri”, “12/3” or “+1w”') + '" autocomplete="off"><div class="pd-prev" id="ptp-date-prev"></div>'
      + '<div class="pd-quick">' + q.map(a => '<button type="button" data-act="pick-date" data-date="' + a[1] + '">' + a[0] + '<small>' + (KO ? DOW[dow(a[1])] + ' ' + md(a[1]) : md(a[1])) + '</small></button>').join('') + '</div>'
      + '<div class="pd-dow">' + heads.map(x => '<span>' + x + '</span>').join('') + '</div><div class="pd-grid">' + cells + '</div>'
      + (p.date ? '<button type="button" class="pd-clear" data-act="pick-date" data-date="">' + L('날짜 지우기', 'Clear Date') + '</button>' : '');
  }
  function spreadPop() {
    const plan = spreadPlan(), n = plan.length;
    const prev = !SP.days.size ? L('요일을 하나 이상 골라주세요.', 'Choose at least one day.') : n ? '<strong>' + papers(n) + '</strong> · ' + span(plan[0][1], plan[n - 1][1]) : L('안 읽은 논문이 없어요.', 'Every paper here is read.');
    const letters = KO ? null : ['S', 'M', 'T', 'W', 'T', 'F', 'S'];
    return '<h4>' + L('고르게 나누기', 'Spread Out') + '</h4><p class="sub">' + L('아직 안 읽은 논문에 차례대로 날짜를 정해요.', 'Gives each unread paper a day, in order.') + '</p>'
      + '<div class="sp-row"><span>' + L('요일', 'Days') + '</span><span class="sp-days">' + [1, 2, 3, 4, 5, 6, 0].map(k => '<button type="button" data-act="sp-day" data-v="' + k + '" aria-pressed="' + SP.days.has(k) + '" aria-label="' + DAY[k] + '">' + (KO ? DOW[k] : letters[k]) + '</button>').join('') + '</span></div>'
      + '<div class="sp-row"><span>' + L('하루에', 'Per day') + '</span><span class="stepper"><button type="button" data-act="sp-per" data-v="-1" aria-label="' + L('줄이기', 'Fewer') + '">−</button><b>' + (KO ? SP.per + '편' : SP.per) + '</b><button type="button" data-act="sp-per" data-v="1" aria-label="' + L('늘리기', 'More') + '">+</button></span></div>'
      + '<div class="sp-row"><span>' + L('시작', 'Start') + '</span><span class="seg2"><button type="button" data-act="sp-from" data-v="today" aria-pressed="' + (SP.from === 'today') + '">' + L('오늘부터', 'Today') + '</button><button type="button" data-act="sp-from" data-v="next" aria-pressed="' + (SP.from === 'next') + '">' + L('다음 주부터', 'Next Week') + '</button></span></div>'
      + '<div class="sp-prev">' + prev + '</div><div class="sp-foot"><button type="button" class="cap strong" data-act="sp-apply"' + (n ? '' : ' disabled') + '>' + L('날짜 정하기', 'Set Days') + '</button></div>';
  }

  /* 따라 해 보기 */
  function spot(sel) { const el = $(sel); if (!el) return; el.classList.add('spot'); setTimeout(() => el.classList.remove('spot'), 2600); }
  const STEPS = [
    { text: L('논문을 여러 편 골라 <strong>계획에 넣기</strong>를 누르거나, 계획 맨 아래 줄에 arXiv 주소를 붙여넣어요. 제목·저자·학회는 서지가 채워요. 지금 주소 하나를 붙여넣어 볼게요.',
      'Select several papers and choose <strong>Add to Plan</strong>, or paste arXiv links into the plan’s last row. The bibliography fills in the title, the authors and the venue. Here’s one being pasted now.'),
      run() {
        S.shelf = 'plan'; S.view = 'table'; S.group = 'section'; render(); spot('#ptp-addrow');
        const el = $('#ptp-add-input'); if (!el) return; if (P.some(p => p.id === 'bcp')) return;
        const url = 'arxiv.org/abs/2106.06926'; if (calm) { addExtra(); return; }
        let i = 0; const tick = setInterval(() => { const cur = $('#ptp-add-input'); if (!cur) { clearInterval(tick); return; } cur.value = url.slice(0, ++i); if (i >= url.length) { clearInterval(tick); setTimeout(addExtra, 350); } }, 28);
      } },
    { text: L('<strong>고르게 나누기</strong>가 안 읽은 논문에 차례대로 날짜를 정해요. 요일과 하루 편수를 바꾸면 아래 미리보기가 따라와요. 한 편씩 고치려면 표의 날짜를 누르고 «금요일», «12/3», «+1주»처럼 적어요.',
      '<strong>Spread Out</strong> gives each unread paper a day, in order. Change the days or how many a day, and the preview follows. To change one paper, click its date and type “Fri”, “12/3” or “+1w”.'),
      run() { S.shelf = 'plan'; S.view = 'table'; S.group = 'week'; render(); const b = $('#ptp-btn-spread'); spot('#ptp-btn-spread'); if (b) openPop(b, 'spread'); } },
    { text: L('<strong>달력</strong>에서는 논문을 끌어서 날짜를 바꿔요. «날짜 없음»에서 끌어오면 그날로 정하고, 다른 계획의 논문은 흐리게 보여서 겹치는 날을 알 수 있어요.',
      'In the <strong>calendar</strong>, drag a paper to another day. Drag one out of No Date to give it a day. Papers from other plans show faintly, so a crowded day is easy to see.'),
      run() { S.shelf = 'plan'; S.view = 'calendar'; render(); spot('#ptp-tray'); } },
    { text: L('논문을 고르고 <strong>주소를 붙여넣으면</strong> 코드·슬라이드·영상·노트북을 알아채서 붙여요. 지금 영상 주소를 적어 뒀어요. 칸을 누르고 Enter를 눌러 보세요. 파일을 끌어다 놓으면 PDF 옆에 사본을 둬요.',
      'Select a paper and <strong>paste a link</strong>. Code, slides, videos and notebooks are recognized and attached. A video link is waiting in the field — click it and press Return. A dropped file is copied beside the PDF.'),
      run() { S.shelf = 'plan'; S.view = 'table'; S.group = 'section'; S.sel = 'cql'; render(); spot('#ptp-mats'); const el = $('#ptp-link-input'); if (el) { el.value = 'youtube.com/watch?v=cql-talk'; detect(); } } },
    { text: L('<strong>이번 주</strong>는 모든 계획에서 이번 주 논문만 모아요. 밀린 논문은 빨간 경고 없이 맨 위에 올라오고, 한 번에 오늘로 옮길 수 있어요.',
      '<strong>This Week</strong> gathers this week’s papers from every plan. Overdue ones rise to the top with no red warnings, and one click moves them to today.'),
      run() { S.shelf = 'week'; render(); spot('#ptp-grp-late .cap'); } },
    { text: L('한 주를 통째로 놓쳤으면 <strong>한 주 미루기</strong>가 남은 날짜를 전부 7일 뒤로 옮겨요. 아래 알림에서 바로 되돌릴 수 있어요. 눌러 보세요.',
      'Missed a whole week? <strong>Push a Week</strong> moves every remaining date seven days later, and the notice below undoes it. Try it.'),
      run() { S.shelf = 'plan'; S.view = 'table'; S.group = 'week'; render(); spot('#ptp-btn-push'); } }
  ];
  function detect() {
    const el = $('#ptp-link-input'), out = $('#ptp-detect'); if (!el || !out) return;
    const v = el.value.trim(); if (!v) { out.innerHTML = ''; return; }
    const K = KIND[kindOf(v)];
    out.innerHTML = '<span class="kchip" style="--k:var(' + K.c + ')">' + I(K.i, 14) + '</span>' + L(K.n + ro(K.n) + ' 알아챘어요 · Enter로 붙여요', K.n + ' link · Press Return to add');
  }

  /* 누르기 */
  app.addEventListener('click', e => {
    const stepBtn = e.target.closest('#ptp-tour button');
    if (stepBtn) {
      closePop(); const i = +stepBtn.dataset.step;
      app.querySelectorAll('#ptp-tour button').forEach(b => b.setAttribute('aria-pressed', b === stepBtn));
      $('#ptp-caption').innerHTML = STEPS[i].text; STEPS[i].run(); return;
    }
    const el = e.target.closest('[data-act]');
    if (!el) { if (POP && !e.target.closest('#ptp-pop')) closePop(); return; }
    const act = el.dataset.act, inPop = !!el.closest('#ptp-pop');
    if (POP && !inPop && act !== 'date' && act !== 'spread') closePop();
    const p = el.dataset.id ? P.find(x => x.id === el.dataset.id) : P.find(x => x.id === S.sel);
    switch (act) {
      case 'shelf': S.shelf = el.dataset.v; render(); break;
      case 'view': S.view = el.dataset.v; render(); break;
      case 'group': S.group = el.dataset.v; render(); break;
      case 'sort': S.sort = { key: el.dataset.k, dir: S.sort.key === el.dataset.k ? -S.sort.dir : 1 }; render(); break;
      case 'select': if (p && !p.pending) { S.sel = p.id; render(); } break;
      case 'status': if (p) { setStatus(p, p.status === 'unread' ? 'reading' : p.status === 'reading' ? 'read' : 'unread'); S.sel = p.id; render(); } break;
      case 'set-status': if (p) { setStatus(p, el.dataset.v); render(); } break;
      case 'date': { const same = POP && POP.kind === 'date' && POP.anchor === el; closePop(); if (!same && p) { S.sel = p.id; openPop(el, 'date', p.id); } break; }
      case 'pick-date': { const q = POP && P.find(x => x.id === POP.id); if (q) { q.date = el.dataset.date || null; } closePop(); render(); break; }
      case 'spread': { const same = POP && POP.kind === 'spread'; closePop(); if (!same) openPop(el, 'spread'); break; }
      case 'sp-day': { const k = +el.dataset.v; SP.days.has(k) ? SP.days.delete(k) : SP.days.add(k); openPop(POP.anchor, 'spread'); break; }
      case 'sp-per': SP.per = Math.max(1, Math.min(3, SP.per + (+el.dataset.v))); openPop(POP.anchor, 'spread'); break;
      case 'sp-from': SP.from = el.dataset.v; openPop(POP.anchor, 'spread'); break;
      case 'sp-apply': { const plan = spreadPlan(); if (!plan.length) break; const before = snap(); plan.forEach(a => { a[0].date = a[1]; }); closePop(); render(); toast(L(plan.length + '편에 날짜를 정했어요.', 'Days set for ' + papers(plan.length) + '.'), before); break; }
      case 'push': { const before = snap(); let n = 0; planPapers('offline').forEach(q => { if (q.status !== 'read' && q.date) { q.date = add(q.date, 7); n++; } }); render(); toast(L('남은 ' + n + '편을 한 주 뒤로 옮겼어요.', 'Moved ' + papers(n) + ' a week later.'), before); break; }
      case 'pull-late': { const before = snap(); let n = 0; P.forEach(q => { if (isLate(q)) { q.date = TODAY; n++; } }); render(); toast(L(n + '편을 오늘로 옮겼어요.', 'Moved ' + papers(n) + ' to today.'), before); break; }
      case 'add-found': if (p && p.found) { p.links.push(p.found); p.found = null; render(); toast(L('코드 링크를 붙였어요.', 'Code link added.')); } break;
      case 'rm-link': if (p) { p.links.splice(+el.dataset.i, 1); render(); } break;
      case 'undo': { const t = $('#ptp-toast'); if (t._undo) restore(t._undo); break; }
      case 'say': toast(el.dataset.msg); break;
    }
  });
  /* A click anywhere outside the demo puts a popover away too. */
  document.addEventListener('click', e => { if (POP && !e.composedPath().includes(app)) closePop(); });
  document.addEventListener('keydown', e => { if (e.key === 'Escape' && POP) closePop(); });
  app.addEventListener('keydown', e => {
    if (e.key !== 'Enter') return;
    const t = e.target;
    if (t.id === 'ptp-add-input') { e.preventDefault(); if (t.value.trim()) addExtra(); }
    else if (t.id === 'ptp-link-input') { e.preventDefault(); addLink(); }
    else if (t.id === 'ptp-date-text') { e.preventDefault(); const v = parseWhen(t.value), q = POP && P.find(x => x.id === POP.id); if (v && q) { q.date = v; closePop(); render(); } }
    else if (t.matches && t.matches('div[data-act="select"]')) { t.click(); }
  });
  app.addEventListener('input', e => {
    if (e.target.id === 'ptp-link-input') detect();
    if (e.target.id === 'ptp-date-text') { const v = parseWhen(e.target.value), out = $('#ptp-date-prev'); if (out) out.textContent = v ? '→ ' + full(v) + ' · ' + L('Enter', 'Return') : (e.target.value.trim() ? L('아직 못 읽었어요', 'Not a day yet') : ''); }
  });

  /* 달력에서 끌기 */
  const main = $('#ptp-main');
  const clearOver = () => app.querySelectorAll('.over').forEach(x => x.classList.remove('over'));
  main.addEventListener('dragstart', e => { const pl = e.target.closest && e.target.closest('.pill[draggable]'); if (!pl) return; dragId = pl.dataset.id; e.dataTransfer.effectAllowed = 'move'; e.dataTransfer.setData('text/plain', dragId); setTimeout(() => pl.classList.add('dragging'), 0); });
  main.addEventListener('dragover', e => { const cell = e.target.closest && e.target.closest('[data-drop]'); if (!cell || !dragId) return; e.preventDefault(); e.dataTransfer.dropEffect = 'move'; if (!cell.classList.contains('over')) { clearOver(); cell.classList.add('over'); } });
  main.addEventListener('drop', e => {
    const cell = e.target.closest && e.target.closest('[data-drop]'); if (!cell || !dragId) return; e.preventDefault();
    const p = P.find(x => x.id === dragId); dragId = null; if (!p) return;
    const to = cell.dataset.drop || null; if (p.date === to) { render(); return; }
    const before = snap(); p.date = to; S.sel = p.id; render();
    toast(to ? L(full(to) + ro(full(to)) + ' 옮겼어요.', 'Moved to ' + full(to) + '.') : L('날짜를 지웠어요.', 'Day cleared.'), before);
  });
  main.addEventListener('dragend', () => { dragId = null; clearOver(); app.querySelectorAll('.dragging').forEach(x => x.classList.remove('dragging')); });

  /* As tall as it is, and as small as it has to be. */
  function contentHeight() {
    let h = app.offsetHeight;
    const pop = $('#ptp-pop');
    if (pop && !pop.hidden) h = Math.max(h, pop.offsetTop + pop.offsetHeight + 12);
    return h;
  }
  let reported = 0;
  function relayout() {
    if (fit) {
      const room = frame.clientWidth;
      if (room && room < fit) {
        scale = room / fit;
        app.style.width = fit + 'px';
        app.style.transform = 'scale(' + scale + ')';
      } else {
        scale = 1;
        app.style.width = '';
        app.style.transform = '';
      }
      frame.style.height = Math.ceil(contentHeight() * scale) + 'px';
    }
    const h = Math.ceil(fit ? contentHeight() * scale : contentHeight());
    if (opts.onHeight && h !== reported) { reported = h; opts.onHeight(h); }
  }
  if ('ResizeObserver' in window) {
    const watch = new ResizeObserver(() => relayout());
    watch.observe(app);
    if (fit) watch.observe(frame);
  }
  /* A popover is put away when the page gets narrower or wider — not when
     only its height moves: in a frame that grows to fit the demo, opening a
     popover makes the frame taller, and that is a resize too. */
  let lastWidth = window.innerWidth;
  window.addEventListener('resize', () => {
    if (window.innerWidth === lastWidth) return;
    lastWidth = window.innerWidth;
    if (POP) closePop();
  });

  render();
  relayout();
  return {
    /** The theme, changed while it is showing (the app's appearance moved). */
    setTheme(theme) { if (theme === 'dark' || theme === 'light') app.dataset.theme = theme; else delete app.dataset.theme; },
    /** Jump to a step of the tour, as its button would. */
    step(i) { const b = app.querySelector('#ptp-tour button[data-step="' + i + '"]'); if (b) b.click(); },
    get height() { return reported; },
  };
}

window.PlansDemo = { mount, howTo };
})();
