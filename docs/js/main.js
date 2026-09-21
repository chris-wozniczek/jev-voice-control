/* Jev Voice docs — no dependencies */
(function () {
  'use strict';
  var reduced = window.matchMedia('(prefers-reduced-motion: reduce)').matches;
  var $ = function (s, c) { return (c || document).querySelector(s); };
  var $$ = function (s, c) { return Array.prototype.slice.call((c || document).querySelectorAll(s)); };

  /* ---------- mobile menu ---------- */
  var burger = $('.hamburger'), menu = $('#mobile-menu');
  if (burger && menu) {
    burger.addEventListener('click', function () {
      var open = menu.hidden;
      menu.hidden = !open;
      burger.setAttribute('aria-expanded', String(open));
    });
    $$('a', menu).forEach(function (a) { a.addEventListener('click', function () { menu.hidden = true; burger.setAttribute('aria-expanded', 'false'); }); });
  }

  /* ---------- reveal on scroll ---------- */
  var revealEls = $$('[data-reveal]');
  if ('IntersectionObserver' in window && !reduced) {
    var io = new IntersectionObserver(function (entries) {
      entries.forEach(function (e) { if (e.isIntersecting) { e.target.classList.add('in'); io.unobserve(e.target); } });
    }, { rootMargin: '0px 0px -8% 0px' });
    revealEls.forEach(function (el) { io.observe(el); });
  } else {
    revealEls.forEach(function (el) { el.classList.add('in'); });
  }

  /* ---------- flow scenarios ---------- */
  var SCN = {
    local: {
      desc: 'The local parser recognises "quit" + an installed app. No network call at all: Executor terminates Spotify and the app speaks "Done." Most everyday commands take this path.',
      nodes: ['speak', 'engine', 'norm', 'parser', 'exec', 'done', 'you-done'],
      links: ['speak-engine', 'engine-norm', 'norm-parser', 'parser-exec', 'exec-done', 'done-you'],
      trace: [
        ['analyzer final=', '"quit Spotify" latency=0.06s'],
        ['command:', 'local closeApp target=Spotify'],
        ['executor:', 'terminated Spotify (pid 4121)'],
        ['outcome=', 'done', 'ok']
      ]
    },
    ui: {
      desc: 'Not a parser verb, so one Jev request routes it: action=uiTask, target_app=Devin, destructive=0.03. Devin comes forward, the fast path finds no verified shortcut, the tree is read, Jev picks the real "New session" button, one click, re-observe shows a new session.',
      nodes: ['speak', 'engine', 'norm', 'parser', 'router', 'policy', 'fast', 'observe', 'choice', 'act', 'verify', 'done', 'you-done'],
      links: ['speak-engine', 'engine-norm', 'norm-parser', 'parser-router', 'router-policy', 'policy-fast', 'fast-observe', 'observe-choice', 'choice-act', 'act-verify', 'verify-done', 'done-you'],
      trace: [
        ['analyzer final=', '"open a new session in Devin" latency=0.11s'],
        ['router:', 'action=uiTask target_app=Devin destructive=0.03 (1 request, 180 ms)'],
        ['stage=menu', 'item="New Text File" skipped=goal-mismatch', 'warn'],
        ['stage=axtree', 'elements=412 partial=false interactive=61 elapsed=0.62s'],
        ['stage=jev', 'next_action=[3] AXButton "New session" p=0.93'],
        ['stage=click', 'kind=axpress token=3 → ok'],
        ['stage=verify', 'creation satisfied: elements 412→438, new AXTextArea focused', 'ok'],
        ['outcome=', 'done steps=1 elapsed=1.9s', 'ok']
      ]
    },
    dictate: {
      desc: 'Content-first: everything after "type" is payload, and SlotExtractor strips the target phrase — "in the prompt box" — leaving "check CPU usage". Candidates are text inputs only, so the session row titled "Check RAM and CPU…" can\'t be picked. In-process typing, then read-back.',
      nodes: ['speak', 'engine', 'norm', 'parser', 'router', 'policy', 'observe', 'choice', 'act', 'verify', 'done', 'you-done'],
      links: ['speak-engine', 'engine-norm', 'norm-parser', 'parser-router', 'router-policy', 'policy-fast', 'fast-observe', 'observe-choice', 'choice-act', 'act-verify', 'verify-done', 'done-you'],
      trace: [
        ['analyzer final=', '"type in the prompt box check CPU usage" latency=0.09s'],
        ['router:', 'action=dictate text="check CPU usage" (target phrase stripped)'],
        ['stage=axtree', 'elements=438 partial=false'],
        ['planner:', 'dictation goal → candidates restricted to text inputs (2 of 61)'],
        ['stage=jev', 'next_action=[7] AXTextArea "Ask Devin…" p=0.97'],
        ['stage=type', 'in-process unicode 15 chars → readback=match', 'ok'],
        ['outcome=', 'done steps=1 elapsed=1.4s', 'ok']
      ]
    },
    sparse: {
      desc: 'The submit fast path presses ⌘↩ but the prompt box doesn\'t empty, so the generic loop runs. Electron exposed 27 elements and no Send; Jev says stuck. The ladder: full re-observe (still thin) → wake-up (tree grows to 603) → Jev now sees the Send button → click → box empties. No confirmation: "send" only asks in a browser.',
      nodes: ['speak', 'engine', 'norm', 'parser', 'router', 'policy', 'fast', 'observe', 'choice', 'recover', 'act', 'verify', 'done', 'you-done'],
      links: ['speak-engine', 'engine-norm', 'norm-parser', 'parser-router', 'router-policy', 'policy-fast', 'fast-observe', 'observe-choice', 'verify-recover', 'recover-observe', 'choice-act', 'act-verify', 'verify-done', 'done-you'],
      trace: [
        ['analyzer final=', '"send the prompt" latency=0.05s'],
        ['router:', 'action=uiTask target_app=Devin  policy: send → local app, no confirm'],
        ['fastpath', 'submit ⌘↩ → box not emptied → fall through', 'warn'],
        ['stage=axtree', 'elements=27 partial=true interactive=2', 'warn'],
        ['stage=jev', 'next_action=stuck'],
        ['stage=observe', 'full=true elements=31 partial=false', 'warn'],
        ['stage=axtree', 'wake before=31 after=603'],
        ['stage=jev', 'next_action=[58] AXButton "Send" p=0.95'],
        ['stage=click', 'kind=axpress → refused; fallback=known-frame CGEvent click'],
        ['stage=verify', 'prompt box emptied, new AXRow "Thought for 1s"', 'ok'],
        ['outcome=', 'done steps=3 elapsed=6.8s', 'ok']
      ]
    },
    browser: {
      desc: 'Target is x.com in Chrome, so the policy\'s in-browser list applies: "post" asks first. In hold mode the app speaks the question and waits for your next held utterance (or the popover\'s Yes/No). "Yes" → observe → Jev picks the Post button → click → the composer closes.',
      nodes: ['speak', 'engine', 'norm', 'parser', 'router', 'policy', 'confirm', 'fast', 'observe', 'choice', 'act', 'verify', 'done', 'you-done'],
      links: ['speak-engine', 'engine-norm', 'norm-parser', 'parser-router', 'router-policy', 'policy-confirm', 'confirm-fast', 'fast-observe', 'observe-choice', 'choice-act', 'act-verify', 'verify-done', 'done-you'],
      trace: [
        ['analyzer final=', '"post this on X" latency=0.07s'],
        ['router:', 'action=uiTask site=x.com browser=Google Chrome'],
        ['policy:', 'confirmInBrowser matched "post" → ask', 'warn'],
        ['confirm:', 'spoken "This will post on X — go ahead?" waiting for held utterance (15 s)'],
        ['analyzer final=', '"yes go ahead" → affirmative', 'ok'],
        ['stage=axtree', 'elements=356 partial=false'],
        ['stage=jev', 'next_action=[12] AXButton "Post" p=0.96'],
        ['stage=click', 'kind=axpress → ok'],
        ['stage=verify', 'composer dismissed: elements 356→298', 'ok'],
        ['outcome=', 'done steps=1 elapsed=2.3s (+ wait for yes)', 'ok']
      ]
    }
  };

  var svg = $('#flow-svg'), desc = $('#flow-desc'), trace = $('#trace'), packet = $('#fl-packet');
  var packetTimer = null, packetRAF = null;

  function esc(s) { return String(s).replace(/[&<>]/g, function (c) { return { '&': '&amp;', '<': '&lt;', '>': '&gt;' }[c]; }); }

  function renderTrace(rows) {
    if (!trace) return;
    trace.innerHTML = rows.map(function (r) {
      var cls = r[2] === 'ok' ? 't-ok' : r[2] === 'warn' ? 't-warn' : 't-v';
      return '<span class="t-k">' + esc(r[0]) + '</span> <span class="' + cls + '">' + esc(r[1]) + '</span>';
    }).join('\n');
  }

  function stopPacket() {
    if (packetTimer) { clearTimeout(packetTimer); packetTimer = null; }
    if (packetRAF) { cancelAnimationFrame(packetRAF); packetRAF = null; }
    if (packet) packet.setAttribute('opacity', '0');
  }

  function runPacket(linkIds) {
    if (!packet || reduced || !svg) return;
    var paths = linkIds.map(function (id) { return svg.querySelector('[data-l="' + id + '"]'); }).filter(Boolean);
    var i = 0;
    function one() {
      if (i >= paths.length) { packetTimer = setTimeout(function () { i = 0; one(); }, 1400); return; }
      var p = paths[i], len = p.getTotalLength(), t0 = null, dur = Math.max(260, Math.min(700, len * 3));
      packet.setAttribute('opacity', '1');
      function frame(ts) {
        if (t0 === null) t0 = ts;
        var k = Math.min(1, (ts - t0) / dur);
        var pt = p.getPointAtLength(k * len);
        packet.setAttribute('cx', pt.x); packet.setAttribute('cy', pt.y);
        if (k < 1) { packetRAF = requestAnimationFrame(frame); }
        else { i += 1; packetTimer = setTimeout(one, 80); }
      }
      packetRAF = requestAnimationFrame(frame);
    }
    one();
  }

  function applyScenario(key) {
    var s = SCN[key]; if (!s || !svg) return;
    stopPacket();
    $$('.chip[data-scn]').forEach(function (b) {
      var on = b.dataset.scn === key;
      b.classList.toggle('is-on', on); b.setAttribute('aria-selected', String(on));
    });
    if (desc) desc.textContent = s.desc;
    $$('.fl-node', svg).forEach(function (n) {
      var on = s.nodes.indexOf(n.dataset.n) !== -1;
      n.classList.toggle('lit', on); n.classList.toggle('dim', !on);
    });
    $$('.fl-link', svg).forEach(function (l) {
      var on = s.links.indexOf(l.dataset.l) !== -1;
      l.classList.toggle('lit', on); l.classList.toggle('dim', !on);
      l.setAttribute('marker-end', on ? 'url(#arr-lit)' : 'url(#arr)');
    });
    renderTrace(s.trace);
    runPacket(s.links);
  }

  $$('.chip[data-scn]').forEach(function (b) { b.addEventListener('click', function () { applyScenario(b.dataset.scn); }); });
  var initial = new URLSearchParams(location.search).get('scn');
  applyScenario(SCN[initial] ? initial : 'local');

  /* ---------- hero voice card demo ---------- */
  var vcText = $('#vc-text'), vcSteps = $('#vc-steps'), vcState = $('#vc-state'), vcDot = $('#vc-dot'), wave = $('#wave');
  var DEMOS = [
    { say: 'open a new session in Devin', steps: [['Jev router', 'uiTask · Devin', '180 ms'], ['observe', '412 elements', '0.6 s'], ['Jev Choice', '"New session" p=0.93', '210 ms'], ['click → verify', 'new session open', 'ok']] },
    { say: 'type in the prompt box check CPU usage', steps: [['extract', '"check CPU usage"', '0 ms'], ['candidates', 'text inputs only (2)', ''], ['type', 'in-process, 15 chars', '90 ms'], ['read-back', 'field matches', 'ok']] },
    { say: 'quit Spotify', steps: [['local parser', 'closeApp · Spotify', '0 ms'], ['executor', 'terminated', '40 ms'], ['spoken', '"Done."', 'ok']] },
    { say: 'post this on X', steps: [['policy', 'in-browser "post" → ask', ''], ['you', '"yes go ahead"', ''], ['Jev Choice', '"Post" p=0.96', '200 ms'], ['verify', 'composer closed', 'ok']] }
  ];
  var di = 0;
  function sleep(ms) { return new Promise(function (r) { setTimeout(r, ms); }); }
  function setListening(on) {
    if (vcDot) vcDot.classList.toggle('idle', !on);
    if (wave) wave.style.visibility = on ? 'visible' : 'hidden';
    if (vcState) vcState.textContent = on ? 'listening · hold ⌥Space' : 'released · running';
  }
  async function runDemo() {
    if (!vcText || !vcSteps) return;
    for (;;) {
      var d = DEMOS[di % DEMOS.length]; di += 1;
      vcSteps.innerHTML = ''; vcText.textContent = '';
      setListening(true);
      if (reduced) { vcText.textContent = d.say; }
      else { for (var i = 0; i < d.say.length; i++) { vcText.textContent += d.say[i]; await sleep(d.say[i] === ' ' ? 90 : 38); } }
      await sleep(350);
      setListening(false);
      var lis = d.steps.map(function (s) {
        var li = document.createElement('li');
        li.innerHTML = '<span>' + esc(s[0]) + '</span><b>' + esc(s[1]) + '</b><span class="ms' + (s[2] === 'ok' ? ' ok' : '') + '">' + esc(s[2] === 'ok' ? '✓ verified' : s[2]) + '</span>';
        vcSteps.appendChild(li); return li;
      });
      for (var j = 0; j < lis.length; j++) { await sleep(reduced ? 0 : 420); lis[j].classList.add('on'); }
      await sleep(reduced ? 3500 : 2600);
    }
  }
  runDemo();
})();
