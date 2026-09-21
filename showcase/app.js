/* Class Election — Showcase interactions. Zero dependencies. */
(function () {
  "use strict";
  var $ = function (s, c) { return (c || document).querySelector(s); };
  var $$ = function (s, c) { return Array.prototype.slice.call((c || document).querySelectorAll(s)); };
  var reduceMotion = window.matchMedia("(prefers-reduced-motion: reduce)").matches;
  var finePointer = window.matchMedia("(pointer: fine)").matches;

  /* ---------- theme ---------- */
  var root = document.documentElement;
  var toggle = $("#themeToggle");
  function setTheme(t) {
    root.setAttribute("data-theme", t);
    try { localStorage.setItem("ce-showcase-theme", t); } catch (e) {}
  }
  if (toggle) toggle.addEventListener("click", function () {
    setTheme(root.getAttribute("data-theme") === "dark" ? "light" : "dark");
  });

  /* ---------- mobile nav ---------- */
  var nav = $("#nav"), burger = $("#navBurger"), mobile = $("#navMobile");
  if (burger) burger.addEventListener("click", function () {
    var open = nav.classList.toggle("open");
    burger.setAttribute("aria-expanded", open ? "true" : "false");
  });
  if (mobile) $$("a", mobile).forEach(function (a) {
    a.addEventListener("click", function () { nav.classList.remove("open"); });
  });

  /* ---------- scroll reveal ---------- */
  var revealEls = $$(".reveal");
  if ("IntersectionObserver" in window && !reduceMotion) {
    var io = new IntersectionObserver(function (entries) {
      entries.forEach(function (e) {
        if (e.isIntersecting) { e.target.classList.add("in"); io.unobserve(e.target); }
      });
    }, { threshold: 0.12, rootMargin: "0px 0px -40px 0px" });
    revealEls.forEach(function (el, i) {
      el.style.transitionDelay = (Math.min(i % 4, 3) * 70) + "ms";
      io.observe(el);
    });
  } else {
    revealEls.forEach(function (el) { el.classList.add("in"); });
  }

  /* ---------- animated counters ---------- */
  function countUp(el) {
    var target = parseInt(el.getAttribute("data-count"), 10) || 0;
    if (target === 0 || reduceMotion) { el.textContent = "0"; return; }
    var dur = 1400, start = null;
    function step(ts) {
      if (!start) start = ts;
      var p = Math.min((ts - start) / dur, 1);
      var eased = 1 - Math.pow(1 - p, 3);
      el.textContent = Math.round(target * eased);
      if (p < 1) requestAnimationFrame(step);
    }
    requestAnimationFrame(step);
  }
  var stats = $$(".stat-num");
  if ("IntersectionObserver" in window && !reduceMotion) {
    var cio = new IntersectionObserver(function (entries) {
      entries.forEach(function (e) {
        if (e.isIntersecting) { countUp(e.target); cio.unobserve(e.target); }
      });
    }, { threshold: 0.5 });
    stats.forEach(function (s) { cio.observe(s); });
  } else {
    stats.forEach(countUp);
  }

  /* ---------- hero parallax (desktop, fine pointer) ---------- */
  var heroVisual = $("#heroVisual");
  var hero = $(".hero");
  if (heroVisual && hero && finePointer && !reduceMotion) {
    var cards = $$(".float-card", heroVisual);
    hero.addEventListener("mousemove", function (ev) {
      var r = hero.getBoundingClientRect();
      var x = (ev.clientX - r.left) / r.width - 0.5;
      var y = (ev.clientY - r.top) / r.height - 0.5;
      cards.forEach(function (c, i) {
        var depth = (i + 1) * 14;
        c.style.translate = (-x * depth) + "px " + (-y * depth) + "px";
      });
    });
    hero.addEventListener("mouseleave", function () {
      cards.forEach(function (c) { c.style.translate = "0px 0px"; });
    });
  }

  /* ---------- 3D tilt on cards (desktop only) ---------- */
  if (finePointer && !reduceMotion) {
    $$(".card").forEach(function (card) {
      card.addEventListener("mousemove", function (ev) {
        var r = card.getBoundingClientRect();
        var x = (ev.clientX - r.left) / r.width - 0.5;
        var y = (ev.clientY - r.top) / r.height - 0.5;
        card.style.transform = "perspective(800px) rotateX(" + (-y * 7) + "deg) rotateY(" + (x * 7) + "deg) translateY(-4px)";
      });
      card.addEventListener("mouseleave", function () { card.style.transform = ""; });
    });
  }

  /* ---------- timeline progress line ---------- */
  var timeline = $("#timeline"), progress = $("#timelineProgress");
  function drawTimeline() {
    if (!timeline || !progress) return;
    var r = timeline.getBoundingClientRect();
    var vh = window.innerHeight;
    var total = r.height - 16;
    var passed = Math.min(Math.max(vh * 0.6 - r.top, 0), total);
    progress.style.height = Math.max(passed, 0) + "px";
  }
  var ticking = false;
  window.addEventListener("scroll", function () {
    if (ticking) return;
    ticking = true;
    requestAnimationFrame(function () { drawTimeline(); ticking = false; });
  }, { passive: true });
  drawTimeline();

  /* ---------- screenshots gallery ---------- */
  // Expected files under assets/shots/. Missing files are dropped automatically.
  var SHOTS = [
    { file: "shot-home-dark-desktop.png",   route: "Home",    theme: "dark",  device: "desktop" },
    { file: "shot-home-light-desktop.png",  route: "Home",    theme: "light", device: "desktop" },
    { file: "shot-home-dark-mobile.png",    route: "Home",    theme: "dark",  device: "mobile"  },
    { file: "shot-auth-dark-desktop.png",   route: "Auth",    theme: "dark",  device: "desktop" },
    { file: "shot-auth-light-mobile.png",   route: "Auth",    theme: "light", device: "mobile"  },
    { file: "shot-results-dark-desktop.png", route: "Results", theme: "dark",  device: "desktop" },
    { file: "shot-register-dark-desktop.png", route: "Register", theme: "dark", device: "desktop" },
    { file: "shot-vote-dark-desktop.png",   route: "Vote",    theme: "dark",  device: "desktop" }
  ];
  var gallery = $("#gallery"), empty = $("#galleryEmpty"), note = $("#galleryNote");
  var activeFilter = "all";

  function cap(s) { return s.charAt(0).toUpperCase() + s.slice(1); }

  function matchesFilter(s) {
    if (activeFilter === "all") return true;
    if (activeFilter === "mobile") return s.device === "mobile";
    return s.theme === activeFilter;
  }

  function buildGallery() {
    if (!gallery) return;
    gallery.innerHTML = "";
    var loaded = 0;
    SHOTS.forEach(function (s) {
      var fig = document.createElement("figure");
      fig.className = "shot reveal in";
      fig.setAttribute("data-shot-idx", SHOTS.indexOf(s));
      var isMobile = s.device === "mobile";
      var frame = document.createElement("div");
      frame.className = isMobile ? "frame-phone" : "frame-browser";
      if (!isMobile) {
        var bar = document.createElement("div");
        bar.className = "frame-bar";
        bar.innerHTML = '<span class="dots"><i></i><i></i><i></i></span>' +
          '<span class="frame-url">class-election.app</span>';
        frame.appendChild(bar);
      }
      var img = document.createElement("img");
      img.src = "assets/shots/" + s.file;
      img.alt = s.route + " page, " + s.theme + " theme, " + s.device;
      img.loading = "lazy";
      img.onerror = function () { fig.remove(); updateEmpty(); };
      img.onload = function () { loaded++; };
      frame.appendChild(img);
      fig.appendChild(frame);
      var capEl = document.createElement("figcaption");
      capEl.className = "shot-cap";
      capEl.innerHTML = "<strong>" + s.route + "</strong>" +
        '<span class="chip">' + cap(s.theme) + "</span>" +
        '<span class="chip">' + cap(s.device) + "</span>";
      fig.appendChild(capEl);
      gallery.appendChild(fig);
      applyFilterTo(fig, s);
    });
    updateEmpty();
  }

  function applyFilterTo(fig, s) {
    fig.classList.toggle("hide", !matchesFilter(s));
  }

  function updateEmpty() {
    if (!gallery || !empty) return;
    var visible = $$(".shot", gallery).filter(function (f) { return !f.classList.contains("hide"); });
    empty.hidden = visible.length > 0;
    if (note) note.textContent = visible.length > 0
      ? visible.length + " screen" + (visible.length === 1 ? "" : "s") + " captured from the live site, unedited."
      : note.textContent;
  }

  $$(".filter").forEach(function (btn) {
    btn.addEventListener("click", function () {
      $$(".filter").forEach(function (b) {
        b.classList.remove("active");
        b.setAttribute("aria-selected", "false");
      });
      btn.classList.add("active");
      btn.setAttribute("aria-selected", "true");
      activeFilter = btn.getAttribute("data-filter");
      $$(".shot", gallery).forEach(function (fig) {
        var s = SHOTS[parseInt(fig.getAttribute("data-shot-idx"), 10)];
        if (s) applyFilterTo(fig, s);
      });
      updateEmpty();
    });
  });

  buildGallery();
})();

/* Class Election — Showcase v2 interactions (tubes, stepper, code typing, receipt demo). Zero dependencies. */
(function () {
  "use strict";
  var $ = function (s, c) { return (c || document).querySelector(s); };
  var $$ = function (s, c) { return Array.prototype.slice.call((c || document).querySelectorAll(s)); };
  var reduceMotion = window.matchMedia("(prefers-reduced-motion: reduce)").matches;

  /* ---------- fluid tubes ---------- */
  var tubes = $$("[data-tube]");
  function tickPct(el, target) {
    var decimals = target % 1 !== 0 ? 1 : 0;
    if (reduceMotion) { el.textContent = target.toFixed(decimals) + "%"; return; }
    var dur = 2100, start = null;
    function step(ts) {
      if (!start) start = ts;
      var p = Math.min((ts - start) / dur, 1);
      var eased = 1 - Math.pow(1 - p, 3);
      el.textContent = (target * eased).toFixed(decimals) + "%";
      if (p < 1) requestAnimationFrame(step);
      else el.textContent = target.toFixed(decimals) + "%";
    }
    requestAnimationFrame(step);
  }
  function fillTube(row, i) {
    var pct = $(".tube-pct", row);
    var target = parseFloat(pct.getAttribute("data-target"));
    var delay = reduceMotion ? 0 : i * 260;
    row.classList.add("glugging");
    setTimeout(function () {
      row.classList.remove("glugging");
      row.classList.add("filled");
      tickPct(pct, target);
    }, delay);
  }
  if ("IntersectionObserver" in window) {
    var tio = new IntersectionObserver(function (entries) {
      entries.forEach(function (e) {
        if (e.isIntersecting) {
          fillTube(e.target, tubes.indexOf(e.target));
          tio.unobserve(e.target);
        }
      });
    }, { threshold: 0.35 });
    tubes.forEach(function (t) { tio.observe(t); });
  } else {
    tubes.forEach(function (t, i) { fillTube(t, i); });
  }

  /* ---------- anatomy stepper ---------- */
  var ASTEPS = [
    { t: "You tap a candidate",
      d: "Your pick is marked locally and a confirm sheet slides up. Nothing has touched the network yet.",
      c: "paintBallot() — app.js" },
    { t: "One RPC fires",
      d: "A single call carries the election, both picks, and an idempotency key to the database.",
      c: "cast_vote_v2(uuid, uuid, uuid, text)" },
    { t: "Postgres takes over",
      d: "The function locks your registration row and checks it is verified — plus id_ready when an ID photo is required.",
      c: "row lock + id_upload_ready_v2()" },
    { t: "Doubles die here",
      d: "A uniqueness constraint on the vote row means a second vote for the same registration is rejected by the database itself.",
      c: "UNIQUE (voter_registration_id)" },
    { t: "Receipt lands",
      d: "The server returns your voter identity, the app routes to the receipt page, and your phone buzzes.",
      c: "r.voter_identity → /receipt" }
  ];
  var nodes = $$(".a-node"), aFill = $("#aFill");
  var aTitle = $("#aTitle"), aText = $("#aText"), aCode = $("#aCode"), aPanel = $("#aPanel");
  function setStep(i) {
    var s = ASTEPS[i];
    nodes.forEach(function (n, j) {
      n.classList.toggle("active", j === i);
      n.classList.toggle("done", j < i);
      n.setAttribute("aria-selected", j === i ? "true" : "false");
    });
    if (aFill) aFill.style.width = (i / (ASTEPS.length - 1)) * 100 + "%";
    if (aPanel) {
      aPanel.classList.remove("a-swap");
      void aPanel.offsetWidth; /* restart animation */
      aPanel.classList.add("a-swap");
    }
    if (aTitle) aTitle.textContent = (i + 1) + ". " + s.t;
    if (aText) aText.textContent = s.d;
    if (aCode) aCode.textContent = s.c;
  }
  nodes.forEach(function (n) {
    n.addEventListener("click", function () {
      setStep(parseInt(n.getAttribute("data-step"), 10));
    });
  });
  if (nodes.length) setStep(0);

  /* ---------- code typing ---------- */
  var CODE_LINES = [
    "const r = await castVoteV2(my.electionId, my.selMonitor, my.selCr, my.idemKey);",
    'if (!r.ok) throw new Error(r.error);',
    "buzz([40, 40, 40]);",
    "navTo(`/receipt?code=${encodeURIComponent(r.voter_identity)}`);"
  ];
  var cwCode = $("#cwCode"), cwCaret = $("#cwCaret");
  if (cwCode) {
    if (reduceMotion) {
      cwCode.textContent = CODE_LINES.join("\n");
      if (cwCaret) cwCaret.style.display = "none";
    } else {
      var li = 0, ci = 0, typed = ["", "", "", ""];
      function render() { cwCode.textContent = typed.join("\n"); }
      function typeTick() {
        if (li >= CODE_LINES.length) {
          setTimeout(function () { li = 0; ci = 0; typed = ["", "", "", ""]; render(); setTimeout(typeLoop, 700); }, 2800);
          return;
        }
        var line = CODE_LINES[li];
        if (ci <= line.length) {
          typed[li] = line.slice(0, ci);
          render();
          ci++;
          setTimeout(typeTick, line[ci - 1] === " " ? 12 : 34 + Math.random() * 40);
        } else {
          li++; ci = 0;
          setTimeout(typeTick, 260);
        }
      }
      function typeLoop() { typeTick(); }
      /* start when visible */
      if ("IntersectionObserver" in window) {
        var cio = new IntersectionObserver(function (entries) {
          entries.forEach(function (e) {
            if (e.isIntersecting) { typeLoop(); cio.disconnect(); }
          });
        }, { threshold: 0.4 });
        cio.observe(cwCode);
      } else { typeLoop(); }
    }
  }

  /* ---------- receipt demo ---------- */
  var CHARSET = "ABCDEFGHJKMNPQRSTUVWXYZ23456789"; /* no ambiguous chars */
  var genBtn = $("#genReceipt"), demoBox = $("#demoReceipt"), drCode = $("#drCode");
  function sampleReceipt() {
    var s = "";
    for (var i = 0; i < 8; i++) s += CHARSET.charAt(Math.floor(Math.random() * CHARSET.length));
    return s.slice(0, 4) + "-" + s.slice(4);
  }
  if (genBtn && demoBox && drCode) {
    genBtn.addEventListener("click", function () {
      drCode.textContent = sampleReceipt();
      demoBox.hidden = false;
      demoBox.classList.remove("dr-pop");
      void demoBox.offsetWidth;
      demoBox.classList.add("dr-pop");
      demoBox.scrollIntoView({ behavior: reduceMotion ? "auto" : "smooth", block: "nearest" });
    });
  }
})();

/* Class Election — Showcase v3 interactions (sidebar, copy, tree, build log, stats). Zero dependencies. */
(function () {
  "use strict";
  var $ = function (s, c) { return (c || document).querySelector(s); };
  var $$ = function (s, c) { return Array.prototype.slice.call((c || document).querySelectorAll(s)); };
  var reduceMotion = window.matchMedia("(prefers-reduced-motion: reduce)").matches;

  /* ---------- sidebar: active link ---------- */
  var sbLinks = $$("[data-sb]");
  var sections = sbLinks.map(function (a) { return document.getElementById(a.getAttribute("href").slice(1)); })
    .filter(function (el) { return !!el; });
  function setActive(id) {
    sbLinks.forEach(function (a) {
      a.classList.toggle("active", a.getAttribute("href") === "#" + id);
    });
  }
  if ("IntersectionObserver" in window && sections.length) {
    var sio = new IntersectionObserver(function (entries) {
      var best = null, bestRatio = 0;
      entries.forEach(function (e) {
        if (e.isIntersecting && e.intersectionRatio > bestRatio) {
          bestRatio = e.intersectionRatio; best = e.target;
        }
      });
      if (best) setActive(best.id);
    }, { rootMargin: "-30% 0px -60% 0px", threshold: [0, 0.25, 0.5, 0.75, 1] });
    sections.forEach(function (s) { sio.observe(s); });
  }

  /* ---------- sidebar: collapse toggle ---------- */
  var sbToggle = $("#sbToggle");
  if (sbToggle) sbToggle.addEventListener("click", function () {
    var collapsed = document.body.classList.toggle("sb-collapsed");
    sbToggle.setAttribute("aria-expanded", collapsed ? "false" : "true");
    sbToggle.setAttribute("aria-label", collapsed ? "Expand sidebar" : "Collapse sidebar");
  });

  /* ---------- sidebar: keyboard 1-9 ---------- */
  document.addEventListener("keydown", function (e) {
    if (e.metaKey || e.ctrlKey || e.altKey) return;
    var t = e.target;
    if (t && (t.tagName === "INPUT" || t.tagName === "TEXTAREA" || t.isContentEditable)) return;
    var n = parseInt(e.key, 10);
    if (n >= 1 && n <= 9 && sbLinks[n - 1]) {
      e.preventDefault();
      var target = document.getElementById(sbLinks[n - 1].getAttribute("href").slice(1));
      if (target) target.scrollIntoView({ behavior: reduceMotion ? "auto" : "smooth", block: "start" });
    }
  });

  /* ---------- copy buttons ---------- */
  $$(".copy-btn").forEach(function (btn) {
    btn.addEventListener("click", function () {
      var text = btn.getAttribute("data-copy") || "";
      function done() {
        btn.classList.add("copied");
        setTimeout(function () { btn.classList.remove("copied"); }, 1600);
      }
      if (navigator.clipboard && navigator.clipboard.writeText) {
        navigator.clipboard.writeText(text).then(done, function () { fallback(); });
      } else { fallback(); }
      function fallback() {
        var ta = document.createElement("textarea");
        ta.value = text;
        ta.style.position = "fixed"; ta.style.opacity = "0";
        document.body.appendChild(ta); ta.select();
        try { document.execCommand("copy"); } catch (err) {}
        document.body.removeChild(ta); done();
      }
    });
  });

  /* ---------- file tree folder toggle ---------- */
  var folder = $("#treeFolder"), sub = $("#treeSub");
  if (folder && sub) folder.addEventListener("click", function () {
    var open = folder.classList.toggle("open");
    sub.classList.toggle("closed", !open);
    folder.setAttribute("aria-expanded", open ? "true" : "false");
  });

  /* ---------- build log filters ---------- */
  var lfilters = $$(".lfilter"), blItems = $$(".bl-item");
  function applyLogFilter(f) {
    blItems.forEach(function (it) {
      var st = it.getAttribute("data-status");
      var show = f === "all" || st === f;
      it.classList.toggle("hide", !show);
      if (show && !reduceMotion) {
        it.style.animation = "none";
        void it.offsetWidth; /* restart slide-in */
        it.style.animation = "";
      }
    });
  }
  lfilters.forEach(function (btn) {
    btn.addEventListener("click", function () {
      lfilters.forEach(function (b) {
        b.classList.remove("active");
        b.setAttribute("aria-selected", "false");
      });
      btn.classList.add("active");
      btn.setAttribute("aria-selected", "true");
      applyLogFilter(btn.getAttribute("data-lfilter"));
    });
  });

  /* ---------- stat strip counters ---------- */
  function fmt(n, comma) {
    return comma ? n.toString().replace(/\B(?=(\d{3})+(?!\d))/g, ",") : String(n);
  }
  function statUp(el) {
    var target = parseInt(el.getAttribute("data-count"), 10) || 0;
    var comma = el.getAttribute("data-comma") === "1";
    if (target === 0 || reduceMotion) { el.textContent = fmt(target, comma); return; }
    var dur = 1600, start = null;
    function step(ts) {
      if (!start) start = ts;
      var p = Math.min((ts - start) / dur, 1);
      var eased = 1 - Math.pow(1 - p, 3);
      el.textContent = fmt(Math.round(target * eased), comma);
      if (p < 1) requestAnimationFrame(step);
      else el.textContent = fmt(target, comma);
    }
    requestAnimationFrame(step);
  }
  var snums = $$(".sstat-num");
  if ("IntersectionObserver" in window && !reduceMotion) {
    var nio = new IntersectionObserver(function (entries) {
      entries.forEach(function (e) {
        if (e.isIntersecting) { statUp(e.target); nio.unobserve(e.target); }
      });
    }, { threshold: 0.4 });
    snums.forEach(function (n) { nio.observe(n); });
  } else {
    snums.forEach(statUp);
  }
})();
