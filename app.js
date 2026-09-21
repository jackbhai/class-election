"use strict";
/* ============================================================================
   Class Election — vanilla JS frontend (zero dependencies, zero build step).
   Talks to Supabase with fetch only. Hash routing, renders into #app.
   ============================================================================ */

/* ---------------- config ---------------- */
const CFG = (typeof window !== "undefined" && window.ELECTION_CONFIG) || {};
const SUPABASE_URL = CFG.SUPABASE_URL || "";
const ANON = CFG.SUPABASE_ANON_KEY || "";
const NOT_CONFIGURED =
  !SUPABASE_URL || String(SUPABASE_URL).includes("YOUR-PROJECT");

/* ---------------- tiny helpers ---------------- */
const esc = (s) =>
  String(s ?? "").replace(/[&<>"']/g, (c) => ({
    "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;", "'": "&#39;",
  }[c]));

/* ---------------- SVG icons (ported from components/icons.jsx) ---------------- */
const ICONS = {
  vote: '<rect x="3" y="4" width="18" height="16" rx="2"/><path d="M3 9h18"/><path d="m9 15 2 2 4-4"/>',
  chart: '<path d="M4 20h16"/><path d="M7 16v-5M12 16V8M17 16v-8"/>',
  shield: '<path d="M12 3l7 3v5c0 5-3.5 8-7 9-3.5-1-7-4-7-9V6z"/><path d="m9.5 12 2 2 3.5-3.5"/>',
  sun: '<circle cx="12" cy="12" r="4"/><path d="M12 2v2M12 20v2M4.9 4.9l1.4 1.4M17.7 17.7l1.4 1.4M2 12h2M20 12h2M4.9 19.1l1.4-1.4M17.7 6.3l1.4-1.4"/>',
  moon: '<path d="M21 12.8A9 9 0 1 1 11.2 3a7 7 0 0 0 9.8 9.8z"/>',
  volume: '<path d="M11 5 6 9H3v6h3l5 4z"/><path d="M15.5 8.5a5 5 0 0 1 0 7M18.3 5.7a9 9 0 0 1 0 12.6"/>',
  volumeOff: '<path d="M11 5 6 9H3v6h3l5 4z"/><path d="m22 9-6 6M16 9l6 6"/>',
  share: '<circle cx="18" cy="5" r="3"/><circle cx="6" cy="12" r="3"/><circle cx="18" cy="19" r="3"/><path d="m8.6 10.6 6.8-4M8.6 13.4l6.8 4"/>',
  copy: '<rect x="9" y="9" width="12" height="12" rx="2"/><path d="M5 15H4a2 2 0 0 1-2-2V4a2 2 0 0 1 2-2h9a2 2 0 0 1 2 2v1"/>',
  download: '<path d="M21 15v4a2 2 0 0 1-2 2H5a2 2 0 0 1-2-2v-4"/><path d="m7 10 5 5 5-5"/><path d="M12 15V3"/>',
  refresh: '<path d="M21 12a9 9 0 1 1-2.6-6.4"/><path d="M21 3v6h-6"/>',
  check: '<path d="m4 12.5 5 5L20 6.5"/>',
  checkCircle: '<circle cx="12" cy="12" r="9"/><path d="m8.5 12.5 2.5 2.5 5-5"/>',
  arrowLeft: '<path d="M19 12H5"/><path d="m11 6-6 6 6 6"/>',
  arrowRight: '<path d="M5 12h14"/><path d="m13 6 6 6-6 6"/>',
  key: '<circle cx="8" cy="16" r="4"/><path d="m10.8 13.2 8.7-8.7"/><path d="m15 6 3 3"/>',
  lock: '<rect x="4" y="11" width="16" height="10" rx="2"/><path d="M8 11V7a4 4 0 0 1 8 0v4"/>',
  ticket: '<path d="M3 9V6a1 1 0 0 1 1-1h16a1 1 0 0 1 1 1v3a2.5 2.5 0 0 0 0 5v3a1 1 0 0 1-1 1H4a1 1 0 0 1-1-1v-3a2.5 2.5 0 0 0 0-5z"/><path d="M14 5v2M14 11v2M14 17v2"/>',
  eye: '<path d="M2 12s3.5-7 10-7 10 7 10 7-3.5 7-10 7-10-7-10-7z"/><circle cx="12" cy="12" r="3"/>',
  eyeOff: '<path d="M3 3l18 18"/><path d="M10.6 5.1A10 10 0 0 1 12 5c6.5 0 10 7 10 7a17 17 0 0 1-3.2 3.9M6.6 6.6C4 8.2 2 12 2 12s3.5 7 10 7a9.6 9.6 0 0 0 4.4-1.1"/><path d="M9.9 9.9a3 3 0 0 0 4.2 4.2"/>',
  megaphone: '<path d="m3 11 18-7-7 18-2.5-7.5z"/><path d="M11.6 16.8a3 3 0 1 1-5.8-1.6"/>',
  play: '<path d="M7 4.5v15l12-7.5z"/>',
  pause: '<path d="M8 5v14M16 5v14"/>',
  trash: '<path d="M4 7h16M9 7V4h6v3M6.5 7l1 13h9l1-13"/><path d="M10 11v6M14 11v6"/>',
  plus: '<path d="M12 5v14M5 12h14"/>',
  scan: '<path d="M3 7V5a2 2 0 0 1 2-2h2M17 3h2a2 2 0 0 1 2 2v2M21 17v2a2 2 0 0 1-2 2h-2M7 21H5a2 2 0 0 1-2-2v-2"/><path d="M7 12h10"/>',
  upload: '<path d="M12 16V4"/><path d="m6 10 6-6 6 6"/><path d="M4 20h16"/>',
  camera: '<path d="M4 8h3l2-3h6l2 3h3a1 1 0 0 1 1 1v10a1 1 0 0 1-1 1H4a1 1 0 0 1-1-1V9a1 1 0 0 1 1-1z"/><circle cx="12" cy="14" r="3.5"/>',
  idcard: '<rect x="2" y="5" width="20" height="14" rx="2"/><circle cx="8" cy="11" r="2"/><path d="M5.5 16.5c.5-1.6 1.5-2.5 2.5-2.5s2 .9 2.5 2.5"/><path d="M14 9.5h5M14 13h5"/>',
  badge: '<rect x="5" y="3" width="14" height="18" rx="2"/><circle cx="12" cy="9.5" r="2.5"/><path d="M8.5 15.5c.7-1.4 2-2.2 3.5-2.2s2.8.8 3.5 2.2"/>',
  users: '<circle cx="9" cy="8" r="3.5"/><path d="M2.5 20c.8-3.2 3.4-5 6.5-5s5.7 1.8 6.5 5"/><circle cx="17" cy="9" r="2.5"/><path d="M16.2 15.3c2.5.4 4.4 2 5.1 4.7"/>',
  sparkles: '<path d="m12 3 2.7 5.8 6.3.8-4.6 4.3 1.2 6.1-5.6-3.1L6.4 20l1.2-6.1L3 9.6l6.3-.8z"/>',
  settings: '<path d="M4 8h10M18 8h2M4 16h4M12 16h8"/><circle cx="16" cy="8" r="2"/><circle cx="10" cy="16" r="2"/>',
  alert: '<path d="M12 3 2 20h20z"/><path d="M12 10v4M12 17.5v.5"/>',
  mail: '<rect x="2" y="4" width="20" height="16" rx="2"/><path d="m22 7-10 6L2 7"/>',
  phone: '<path d="M22 16.9v3a2 2 0 0 1-2.2 2 19.8 19.8 0 0 1-8.6-3.1 19.5 19.5 0 0 1-6-6A19.8 19.8 0 0 1 2.1 4.2 2 2 0 0 1 4.1 2h3a2 2 0 0 1 2 1.7c.1.9.3 1.9.6 2.8a2 2 0 0 1-.5 2.1L8 9.8a16 16 0 0 0 6 6l1.2-1.2a2 2 0 0 1 2.1-.5c.9.3 1.9.5 2.8.6a2 2 0 0 1 1.9 2z"/>',
  x: '<path d="M6 6l12 12M18 6 6 18"/>',
};
const icon = (name, size = 20, cls = "") =>
  `<svg class="icon ${cls}" width="${size}" height="${size}" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round" aria-hidden="true">${ICONS[name] || ""}</svg>`;

/* ---------------- theme ---------------- */
const THEME_KEY = "ce-theme";
function getTheme() {
  try { return localStorage.getItem(THEME_KEY) || "dark"; } catch { return "dark"; }
}
function setTheme(t) {
  try { localStorage.setItem(THEME_KEY, t); } catch {}
  document.documentElement.setAttribute("data-theme", t);
  const m = document.querySelector('meta[name="theme-color"]');
  if (m) m.setAttribute("content", t === "light" ? "#eef1f8" : "#000000");
}
function toggleTheme() {
  const next = getTheme() === "light" ? "dark" : "light";
  setTheme(next);
  return next;
}


/* ---------------- haptics ---------------- */
function buzz(pattern = 15) {
  try { if (navigator.vibrate) navigator.vibrate(pattern); } catch {}
}

/* ---------------- auth session (localStorage + silent refresh) ---------------- */
const SES_KEY = "ce-session";
function loadSession() {
  try { return JSON.parse(localStorage.getItem(SES_KEY)); } catch { return null; }
}
function saveSession(s) {
  try { localStorage.setItem(SES_KEY, JSON.stringify(s)); } catch {}
}
function clearSession() {
  try { localStorage.removeItem(SES_KEY); } catch {}
}
function storeAuthPayload(data) {
  if (!data) return null;
  const sess = {
    access_token: data.access_token,
    refresh_token: data.refresh_token,
    expires_at: Date.now() + (data.expires_in || 3600) * 1000,
    user: data.user || null,
  };
  saveSession(sess);
  return sess;
}
async function refreshSession() {
  const s = loadSession();
  if (!s || !s.refresh_token) { clearSession(); return null; }
  try {
    const res = await fetch(
      SUPABASE_URL + "/auth/v1/token?grant_type=refresh_token",
      {
        method: "POST",
        headers: { apikey: ANON, "Content-Type": "application/json" },
        body: JSON.stringify({ refresh_token: s.refresh_token }),
      }
    );
    if (!res.ok) { clearSession(); return null; }
    return storeAuthPayload(await res.json());
  } catch { clearSession(); return null; }
}
async function getToken() {
  const s = loadSession();
  if (!s || !s.access_token) return null;
  if (Date.now() > (s.expires_at || 0) - 60000) {
    const r = await refreshSession();
    return r ? r.access_token : null;
  }
  return s.access_token;
}
async function getUser() {
  const t = await getToken();
  if (!t) return null;
  const s = loadSession();
  return (s && s.user) || null;
}
async function signUp(email, password) {
  const res = await fetch(SUPABASE_URL + "/auth/v1/signup", {
    method: "POST",
    headers: { apikey: ANON, "Content-Type": "application/json" },
    body: JSON.stringify({ email, password }),
  });
  const data = await res.json().catch(() => null);
  if (!res.ok)
    throw new Error((data && (data.msg || data.message || data.error_description)) || ("HTTP " + res.status));
  if (data && data.session) storeAuthPayload({ ...data.session, user: data.user || data.session.user });
  else if (data && data.access_token) storeAuthPayload(data);
  return data;
}
async function signIn(email, password) {
  const res = await fetch(SUPABASE_URL + "/auth/v1/token?grant_type=password", {
    method: "POST",
    headers: { apikey: ANON, "Content-Type": "application/json" },
    body: JSON.stringify({ email, password }),
  });
  const data = await res.json().catch(() => null);
  if (!res.ok)
    throw new Error((data && (data.msg || data.message || data.error_description)) || ("HTTP " + res.status));
  storeAuthPayload(data);
  return data;
}
async function signOut() {
  try {
    const t = await getToken();
    await fetch(SUPABASE_URL + "/auth/v1/logout", {
      method: "POST",
      headers: Object.assign(
        { apikey: ANON },
        t ? { Authorization: "Bearer " + t } : {}
      ),
    });
  } catch {}
  clearSession();
}

/* ---------------- API layer (fetch only) ---------------- */
function errMsg(data, res) {
  if (data && typeof data === "object")
    return data.message || data.msg || data.error_description || data.error || null;
  return null;
}
async function authFetch(path, { method = "GET", body, auth = true } = {}) {
  const headers = { apikey: ANON };
  if (auth) {
    const t = await getToken();
    if (t) headers["Authorization"] = "Bearer " + t;
  }
  let b;
  if (body !== undefined) {
    headers["Content-Type"] = "application/json";
    b = JSON.stringify(body);
  }
  return fetch(SUPABASE_URL + path, { method, headers, body: b });
}
async function rpc(name, args) {
  const res = await authFetch("/rest/v1/rpc/" + name, {
    method: "POST",
    body: args || {},
  });
  const txt = await res.text();
  let data = null;
  try { data = txt ? JSON.parse(txt) : null; } catch {}
  if (!res.ok) throw new Error(errMsg(data) || ("HTTP " + res.status));
  return data;
}
/* v2 voter-flow RPC wrappers (same call shapes as the previous frontend) */
const listOpenElections = () => rpc("list_open_elections");
const getBallot = (electionId) => rpc("get_ballot", { p_election_id: electionId });
const registerVoter = (electionId, name, cls, enrollmentId, phone) =>
  rpc("register_voter", {
    p_election_id: electionId,
    p_name: name || null,
    p_class: cls || null,
    p_enrollment_id: enrollmentId || null,
    p_phone: phone || null,
  });
const requestIdUploadV2 = (electionId) =>
  rpc("request_id_upload_v2", { p_election_id: electionId });
const confirmIdUploadV2 = (electionId) =>
  rpc("confirm_id_upload_v2", { p_election_id: electionId });
const castVoteV2 = (electionId, monitorId, crId, idempotencyKey) =>
  rpc("cast_vote_v2", {
    p_election_id: electionId,
    p_monitor_id: monitorId || null,
    p_cr_id: crId || null,
    p_idempotency_key: idempotencyKey || null,
  });
const adminUpdateSettings = (electionId, s) =>
  rpc("admin_update_settings", {
    p_election_id: electionId,
    p_require_name: s.require_name,
    p_require_class: s.require_class,
    p_require_enrollment_id: s.require_enrollment_id,
    p_require_id_upload: s.require_id_upload,
    p_manual_review: s.manual_review,
    p_require_phone: s.require_phone,
  });
const adminListRegistrations = (electionId) =>
  rpc("admin_list_registrations", { p_election_id: electionId });
const adminVerifyRegistration = (regId, approved) =>
  rpc("admin_verify_registration", {
    p_registration_id: regId,
    p_approved: approved,
  });
/* read-only vote audit: who voted for whom + duplicate-phone fraud flags */
const adminVoteAudit = async (electionId) => {
  const r = await rpc("admin_vote_audit", { p_election_id: electionId });
  if (!r || !r.ok) throw new Error((r && r.error) || "Audit load fail");
  return r;
};

/* storage: ID photo upload + admin signed preview */
async function storageUpload(path, file) {
  const t = await getToken();
  if (!t) throw new Error("Please sign in first");
  const res = await fetch(SUPABASE_URL + "/storage/v1/object/id-cards/" + path, {
    method: "POST",
    headers: {
      apikey: ANON,
      Authorization: "Bearer " + t,
      "Content-Type": file.type || "application/octet-stream",
      "x-upsert": "false",
    },
    body: file,
  });
  if (res.status !== 200 && res.status !== 201) {
    const j = await res.json().catch(() => null);
    throw new Error(errMsg(j) || ("Upload fail: HTTP " + res.status));
  }
}
async function storageSignUrl(path, expiresIn = 600) {
  const t = await getToken();
  if (!t) throw new Error("Please sign in first");
  const res = await fetch(
    SUPABASE_URL + "/storage/v1/object/sign/id-cards/" + path,
    {
      method: "POST",
      headers: {
        apikey: ANON,
        Authorization: "Bearer " + t,
        "Content-Type": "application/json",
      },
      body: JSON.stringify({ expiresIn }),
    }
  );
  if (!res.ok) throw new Error("sign failed");
  const j = await res.json();
  let u = j.signedURL || j.signedUrl || "";
  if (u && !/^https?:/i.test(u)) u = SUPABASE_URL + u;
  return u;
}

/* ---------------- hash router ---------------- */
function hashQuery() {
  const h = window.location.hash.replace(/^#/, "");
  const q = h.indexOf("?");
  if (q === -1) return {};
  return Object.fromEntries(new URLSearchParams(h.slice(q + 1)));
}
function hashPath() {
  const h = window.location.hash.replace(/^#/, "") || "/";
  const q = h.indexOf("?");
  return q === -1 ? h : h.slice(0, q);
}
const navTo = (path) => { window.location.hash = "#" + path; };

/* ---------------- shared UI partials ---------------- */
const card = (inner, cls = "", style = "") =>
  `<div class="card reveal ${cls}"${style ? ` style="${style}"` : ""}>${inner}</div>`;
const alertHtml = (type, inner) => `<div class="alert ${type}">${inner}</div>`;
const pill = (status) => `<span class="pill ${esc(status)}">${esc(status)}</span>`;
const spinnerBig = `<span class="spinner big"></span>`;
const spinner = `<span class="spinner"></span>`;

function topbarHtml(route) {
  const links = [
    { to: "/", label: "Vote", ic: "vote" },
    { to: "/results", label: "Results", ic: "chart" },
  ];
  const theme = getTheme();
  return `<header class="topbar">
    <a class="brand" href="#/">
      <span class="brand-badge">${icon("vote", 22)}</span>
      <span class="brand-text">Class<b>Election</b></span>
    </a>
    <nav class="topnav">
      ${links.map((l) => `<a href="#${l.to}" class="${route === l.to ? "active" : ""}"><span class="nav-icon">${icon(l.ic, 18)}</span><span class="nav-label">${l.label}</span></a>`).join("")}
      <button class="icon-btn" id="tb-theme" title="${theme === "light" ? "AMOLED dark mode" : "Day mode"}" aria-label="Toggle theme">${icon(theme === "light" ? "moon" : "sun", 19)}</button>
    </nav>
  </header>`;
}
function wireTopbar() {
  const tb = document.getElementById("tb-theme");
  if (tb) tb.addEventListener("click", () => { toggleTheme(); render(); });
}
const footerHtml = () =>
  `<footer class="footer"><p>One account · One vote · Fully secure</p></footer>`;

function setupBannerHtml() {
  return card(`<h2>${icon("settings", 26)} Setup pending</h2>
    <p class="sub">Supabase is not connected yet. Open <b>config.js</b> and paste your <b>Project URL</b> and <b>anon key</b> (Supabase Dashboard → Project Settings → API).</p>`);
}

/* per-route timer (e.g. pending auto-refresh) + Esc handler cleanup */
let pageTimer = null;
let escHandler = null;
function clearPageFx() {
  if (pageTimer) { clearInterval(pageTimer); pageTimer = null; }
  if (escHandler) { window.removeEventListener("keydown", escHandler); escHandler = null; }
}

/* ---------------- router ---------------- */
const app = document.getElementById("app");

async function render() {
  clearPageFx();
  const route = hashPath();
  let pageHtml = "";
  try {
    if (NOT_CONFIGURED) {
      pageHtml = setupBannerHtml();
    } else if (route === "/results") {
      pageHtml = await renderResults();
    } else if (route === "/admin.html") {
      pageHtml = await renderAdmin();
    } else if (route === "/auth") {
      pageHtml = renderAuth();
    } else if (route === "/register") {
      pageHtml = await renderRegister();
    } else if (route === "/vote") {
      pageHtml = await renderBallot();
    } else if (route === "/receipt") {
      if (!hashQuery().code) { navTo("/vote"); return; }
      pageHtml = renderReceipt();
    } else {
      pageHtml = await renderHome();
    }
  } catch (e) {
    pageHtml = card(alertHtml("error", esc(e.message || "Something went wrong")));
  }
  app.innerHTML = topbarHtml(route) + `<main class="container page-enter" id="page-main">${pageHtml}</main>` + footerHtml();
  wireTopbar();
  if (!NOT_CONFIGURED) afterRender(route);
  try { window.scrollTo({ top: 0 }); } catch {}
}

/* per-route post-render wiring (async data fills, listeners) */
const afterRenderHooks = {};
function afterRender(route) {
  const fn = afterRenderHooks[route];
  if (fn) { try { fn(); } catch (e) { console.error(e); } }
}

/* ================= HOME ================= */
async function renderHome() {
  const user = await getUser().catch(() => null);
  let elections = [];
  try { elections = (await listOpenElections()) || []; } catch { elections = []; }

  const electionRows = elections.length
    ? `<div class="election-list">${elections.map((e, i) => `
        <button class="election-row reveal" style="animation-delay:${(i * 0.07).toFixed(2)}s" data-eid="${esc(e.id)}">
          <span class="election-icon">${icon("vote", 24)}</span>
          <span class="grow"><b>${esc(e.title)}</b><br /><small class="live-dot">Voting is open</small></span>
          ${icon("arrowRight", 22, "election-go")}
        </button>`).join("")}</div>`
    : alertHtml("info", "No election is open right now. It will appear here once voting opens.");

  return `
  <section class="hero">
    <div class="hero-eyebrow">${icon("sparkles", 15)} Secure class voting</div>
    <h1>Class <span class="grad">Election</span></h1>
    <p class="hero-sub">Vote for your <b>Class Monitor</b> and <b>CR</b> — safe, private, one vote per student.</p>
    ${user ? `<div class="user-chip">${icon("checkCircle", 17)}<span class="grow">${esc(user.email)}</span><button class="mini-btn ghost" id="home-logout">Logout</button></div>`
           : `<div class="btn-row" style="justify-content:center"><a class="btn big" href="#/auth">Login / Signup ${icon("arrowRight", 18)}</a></div>`}
  </section>

  ${card(`<h2>${icon("vote", 24)} Open Elections</h2>${electionRows}${
    !user && elections.length ? `<p class="sub" style="margin-top:10px">${icon("lock", 15)} Please <a href="#/auth">log in / sign up</a> first to vote.</p>` : ""
  }`)}

  <div class="trust-strip">
    <span>${icon("badge", 16)} One account, one vote</span>
    <span>${icon("shield", 16)} Fraud-checked</span>
    <span>${icon("lock", 16)} Double-vote proof</span>
  </div>`;
}

afterRenderHooks["/"] = function () {
  const lo = document.getElementById("home-logout");
  if (lo) lo.addEventListener("click", async () => { await signOut(); render(); });
  document.querySelectorAll(".election-row[data-eid]").forEach((b) =>
    b.addEventListener("click", async () => {
      const id = b.getAttribute("data-eid");
      const user = await getUser().catch(() => null);
      navTo(user ? `/register?election=${id}` : `/auth?next=/register?election=${id}`);
    })
  );
};

/* ================= AUTH ================= */

let authTab = "login";
let pwVisible = false;
function renderAuth() {
  return `<div class="auth-wrap">
    <div class="auth-orb o1"></div>
    <div class="auth-orb o2"></div>
    <div class="auth-orb o3"></div>
    ${card(`
      <div class="auth-brand">
        <span class="auth-logo">${icon("vote", 30)}</span>
        <span class="auth-name">Class<b>Election</b></span>
      </div>
      <h2 class="auth-title" id="auth-title">${authTab === "login" ? "Welcome back" : "Create your account"}</h2>
      <p class="sub auth-sub" id="auth-sub">${authTab === "login" ? "Log in to cast your vote." : "One account, one vote — takes 10 seconds."}</p>
      <div class="auth-tabs" role="tablist">
        <span class="auth-pill" data-active="${authTab}"></span>
        <button class="auth-tab ${authTab === "login" ? "active" : ""}" data-tab="login" role="tab">Login</button>
        <button class="auth-tab ${authTab === "signup" ? "active" : ""}" data-tab="signup" role="tab">Signup</button>
      </div>
      <label class="lbl" for="auth-email">Email</label>
      <div class="field">
        <span class="field-ic">${icon("mail", 18)}</span>
        <input type="email" id="auth-email" placeholder="you@email.com" autocomplete="email" />
      </div>
      <label class="lbl" for="auth-pw">Password</label>
      <div class="field">
        <span class="field-ic">${icon("key", 18)}</span>
        <input type="${pwVisible ? "text" : "password"}" id="auth-pw" placeholder="${authTab === "signup" ? "Min. 6 characters" : "Your password"}" autocomplete="${authTab === "login" ? "current-password" : "new-password"}" />
        <button type="button" class="pw-toggle" id="auth-pwtoggle" aria-label="${pwVisible ? "Hide password" : "Show password"}">${icon(pwVisible ? "eyeOff" : "eye", 18)}</button>
      </div>
      <div id="auth-msg"></div>
      <button class="btn big auth-go" id="auth-go">${authTab === "login" ? "Login" : "Create account"} ${icon("arrowRight", 18)}</button>
      <p class="auth-trust">${icon("lock", 15)} One email = one vote. Double voting is technically impossible.</p>
    `, "auth-card")}
  </div>`;
}

afterRenderHooks["/auth"] = function () {
  document.querySelectorAll(".auth-tab[data-tab]").forEach((b) =>
    b.addEventListener("click", () => {
      authTab = b.getAttribute("data-tab");
      render();
      setTimeout(() => { const em = document.getElementById("auth-email"); if (em) em.focus(); }, 50);
    })
  );
  const pwt = document.getElementById("auth-pwtoggle");
  if (pwt) pwt.addEventListener("click", () => {
    pwVisible = !pwVisible;
    const inp = document.getElementById("auth-pw");
    if (inp) inp.type = pwVisible ? "text" : "password";
    pwt.innerHTML = icon(pwVisible ? "eyeOff" : "eye", 18);
    pwt.setAttribute("aria-label", pwVisible ? "Hide password" : "Show password");
  });
  const goBtn = document.getElementById("auth-go");
  const go = async () => {
    const msgBox = document.getElementById("auth-msg");
    const email = (document.getElementById("auth-email").value || "").trim();
    const pw = document.getElementById("auth-pw").value || "";
    msgBox.innerHTML = "";
    if (!email.includes("@") || pw.length < 6) {
      msgBox.innerHTML = alertHtml("error", "Enter a valid email and a password of at least 6 characters.");
      buzz(60);
      return;
    }
    goBtn.disabled = true;
    goBtn.innerHTML = `${spinner} Please wait…`;
    const restoreBtn = () => {
      goBtn.disabled = false;
      goBtn.innerHTML = `${authTab === "login" ? "Login" : "Create account"} ${icon("arrowRight", 18)}`;
    };
    try {
      if (authTab === "login") {
        await signIn(email, pw);
      } else {
        await signUp(email, pw);
        const sess = loadSession();
        if (!sess || !sess.access_token) await signIn(email, pw); // no session yet -> log in directly
      }
      navTo(hashQuery().next || "/");
    } catch (e) {
      buzz(60);
      const m = String(e.message || "");
      let text = "Something went wrong — please try again.";
      if (/invalid login|invalid credentials/i.test(m)) text = "Email or password is incorrect.";
      else if (/user already registered|already exists/i.test(m)) text = "This email is already registered — please log in.";
      else if (/email.*confirm/i.test(m)) text = "Please confirm your email — a link has been sent to your inbox.";
      else if (m) text = m;
      msgBox.innerHTML = alertHtml("error", esc(text));
      restoreBtn();
    }
  };
  goBtn.addEventListener("click", go);
  ["auth-email", "auth-pw"].forEach((id) => {
    const inp = document.getElementById(id);
    if (inp) inp.addEventListener("keydown", (e) => { if (e.key === "Enter") go(); });
  });
};

/* ================= REGISTER ================= */

let RG = null; // register page state (reset per navigation)

function renderRegister() {
  const electionId = hashQuery().election;
  if (!electionId)
    return card(alertHtml("error", "Election not found."));
  RG = {
    electionId, user: null, ballot: null, loading: true, err: null,
    name: "", cls: "", enr: "", phone: "", prefilled: false,
    msg: null, busy: false,
    file: null, preview: null, upBusy: false, upMsg: null,
  };
  return card(`${spinnerBig}<p class="sub">Loading…</p>`, "center");
}

afterRenderHooks["/register"] = function () {
  const my = RG;
  my.seq = navSeq;
  const eid = my.electionId;
  (async () => {
    const user = await getUser().catch(() => null);
    if (my.seq !== navSeq || RG !== my) return;
    if (!user) { navTo(`/auth?next=/register?election=${eid}`); return; }
    my.user = user;
    await reloadReg(my);
  })();
};

async function reloadReg(my) {
  my = my || RG;
  if (!my || RG !== my || my.seq !== navSeq) return;
  my.loading = false;
  try {
    const b = await getBallot(my.electionId);
    if (my.seq !== navSeq) return;
    if (!b.ok) throw new Error(b.error || "Load fail");
    if (!my.prefilled && b.registration) {
      my.name = b.registration.name || "";
      my.cls = b.registration.class || "";
      my.enr = b.registration.enrollment_id || "";
      my.phone = b.registration.phone || "";
      my.prefilled = true;
    }
    my.ballot = b;
    my.err = null;
  } catch (e) {
    my.err = e.message;
  }
  if (RG !== my || my.seq !== navSeq) return;
  paintReg();
  const pending = my.ballot && my.ballot.registration && my.ballot.registration.status === "pending";
  if (pending && !pageTimer) {
    pageTimer = setInterval(() => {
      if (my.seq === navSeq && hashPath() === "/register" && RG === my) reloadReg(my);
    }, 10000);
  }
  if (!pending && pageTimer) { clearInterval(pageTimer); pageTimer = null; }
}

function idUploadHtml() {
  const st = RG;
  return `<div class="idzone">
    <label class="lbl">${icon("idcard", 17)} School ID card photo</label>
    <p class="sub" style="margin-top:2px">Take a clear photo of your school ID card — only used for identity verification.</p>
    <input type="file" id="reg-file" accept="image/*" capture="environment" class="file-hidden" />
    ${st.preview ? `
      <div class="upload-preview">
        <img src="${st.preview}" alt="ID card preview" />
        <div class="btn-row">
          <button type="button" class="btn small ghost" id="reg-repick">${icon("refresh", 15)} Retake</button>
          <button type="button" class="btn small" id="reg-upload" ${st.upBusy ? "disabled" : ""}>${st.upBusy ? `${spinner} Upload…` : `${icon("upload", 15)} Upload`}</button>
        </div>
      </div>` : `
      <button type="button" class="upload-drop" id="reg-pick">
        ${icon("camera", 34)}
        <span>Take photo / Choose</span>
        <small>JPG · PNG · WebP · max 6 MB</small>
      </button>`}
    <div id="reg-upmsg">${st.upMsg ? alertHtml(st.upMsg.type, esc(st.upMsg.text)) : ""}</div>
  </div>`;
}

function paintReg() {
  const my = RG;
  if (!my || my.seq !== navSeq) return;
  let html;
  if (my.loading) {
    html = card(`${spinnerBig}<p class="sub">Loading…</p>`, "center");
  } else if (my.err) {
    html = card(alertHtml("error", esc(my.err)));
  } else {
    const b = my.ballot || {};
    const settings = b.settings || {};
    const reg = b.registration;
    const election = b.election || {};
    const needsId = !!settings.require_id_upload;
    const idReady = !!(reg && reg.id_ready);
    const showIdStep = needsId && !idReady && reg && !reg.voted;

    if (election.status !== "open") {
      html = card(`<h2>${esc(election.title || "")}</h2>` +
        alertHtml("info", "Voting is not open yet.") +
        `<a class="btn ghost" href="#/">${icon("arrowLeft", 16)} Back</a>`, "center");
    } else if (reg && reg.voted) {
      html = card(`<div class="vote-done-badge">${icon("checkCircle", 54)}</div>
        <h2>Vote cast!</h2>
        <p class="sub">You have already voted in this election. One account = one vote.</p>
        <a class="btn ghost" href="#/">${icon("arrowLeft", 16)} Home</a>`, "center");
    } else if (reg && reg.status === "verified" && showIdStep) {
      html = card(`<p class="eyebrow">Step 2 / 2 — ID Verification</p>
        <h2 style="margin-top:4px">${esc(election.title || "")}</h2>
        <p class="sub">Registration approved. Now upload your ID card photo — it will be checked when you vote.</p>
        ${idUploadHtml()}
        <a class="btn big" href="#/vote?election=${esc(my.electionId)}">Vote Now ${icon("arrowRight", 18)}</a>`, "reg-card");
    } else if (reg && reg.status === "verified") {
      html = card(`<div class="vote-done-badge ok">${icon("checkCircle", 54)}</div>
        <h2>Verified!</h2>
        <p class="sub">Your registration has been approved. Now cast your vote.</p>
        <a class="btn big" href="#/vote?election=${esc(my.electionId)}">Vote Now ${icon("arrowRight", 18)}</a>`, "center");
    } else if (reg && reg.status === "pending") {
      const hint = needsId && !idReady
        ? "First upload your ID card photo below — only then can you be approved."
        : settings.manual_review
          ? "Your details are under review. The “Vote Now” button will appear here as soon as you are approved — keep this page open, it auto-refreshes."
          : "Your ID is being verified — the “Vote Now” button will appear shortly.";
      html = card(`${spinnerBig}<h2>Verification pending</h2>
        <p class="sub">${hint}</p>
        ${showIdStep ? `<div style="text-align:left;margin-top:8px">${idUploadHtml()}</div>` : ""}
        <button class="btn small ghost" id="reg-check">${icon("refresh", 15)} Check now</button>`, "center");
    } else {
      /* step 1: details form */
      const rejectedNotice = reg && reg.status === "rejected"
        ? alertHtml("error", "Your registration was rejected. Correct your details and submit again.") : "";
      html = card(`<p class="eyebrow">Voter Registration</p>
        <h2 style="margin-top:4px">${esc(election.title || "")}</h2>
        ${rejectedNotice}
        <p class="sub">Fill in your details below. They will be linked to <b>${esc(my.user.email)}</b>.</p>
        ${settings.require_name ? `<label class="lbl">Full name *</label><input type="text" id="reg-name" placeholder="Your name" value="${esc(my.name)}" />` : ""}
        ${settings.require_class ? `<label class="lbl">Class / Section *</label><input type="text" id="reg-cls" placeholder="e.g. 10-B" value="${esc(my.cls)}" />` : ""}
        ${settings.require_enrollment_id ? `<label class="lbl">Enrollment / Admission ID *</label><input type="text" id="reg-enr" placeholder="e.g. SCH-2026-0142" value="${esc(my.enr)}" />` : ""}
        ${settings.require_phone ? `<label class="lbl">Mobile number *</label><input type="tel" id="reg-phone" inputmode="numeric" pattern="[0-9]{10}" maxlength="10" placeholder="e.g. 9876543210" value="${esc(my.phone)}" />` : ""}
        ${!settings.require_name && !settings.require_class && !settings.require_enrollment_id && !settings.require_phone ? alertHtml("info", "This election needs no extra details — just hit submit.") : ""}
        ${needsId ? alertHtml("info", `${icon("idcard", 16)} After submitting, you will need to upload your ID card photo (Step 2).`) : ""}
        <div id="reg-msg">${my.msg ? alertHtml(my.msg.type, esc(my.msg.text)) : ""}</div>
        <button class="btn big" id="reg-submit" ${my.busy ? "disabled" : ""}>${my.busy ? `${spinner} Submit…` : "Submit registration →"}</button>
        ${settings.manual_review ? `<p class="sub center" style="margin-top:10px">${icon("shield", 15)} Your details will be verified after you submit, then you will be able to vote.</p>` : ""}`, "reg-card");
    }
  }
  const main = document.getElementById("page-main");
  if (main && RG === my) { main.innerHTML = html; wireReg(); }
}

function wireReg() {
  const my = RG;
  if (!my) return;
  const pick = document.getElementById("reg-pick");
  const fileInp = document.getElementById("reg-file");
  if (pick && fileInp) pick.addEventListener("click", () => fileInp.click());
  const repick = document.getElementById("reg-repick");
  if (repick && fileInp) repick.addEventListener("click", () => fileInp.click());
  if (fileInp) fileInp.addEventListener("change", () => {
    const f = fileInp.files && fileInp.files[0];
    if (!f) return;
    if (!f.type.startsWith("image/")) {
      my.upMsg = { type: "error", text: "Only image files are allowed (JPG/PNG/WebP)." };
      paintReg();
      return;
    }
    if (f.size > 6 * 1024 * 1024) {
      my.upMsg = { type: "error", text: "Photo must be smaller than 6 MB." };
      paintReg();
      return;
    }
    my.file = f;
    if (my.preview) { try { URL.revokeObjectURL(my.preview); } catch {} }
    my.preview = URL.createObjectURL(f);
    my.upMsg = null;
    paintReg();
  });
  const upBtn = document.getElementById("reg-upload");
  if (upBtn) upBtn.addEventListener("click", () => regUpload());
  const sub = document.getElementById("reg-submit");
  if (sub) sub.addEventListener("click", () => regSubmit());
  const chk = document.getElementById("reg-check");
  if (chk) chk.addEventListener("click", () => { reloadReg(my); });
  ["reg-name", "reg-cls", "reg-enr", "reg-phone"].forEach((id) => {
    const inp = document.getElementById(id);
    if (inp) inp.addEventListener("input", () => {
      if (id === "reg-name") my.name = inp.value;
      if (id === "reg-cls") my.cls = inp.value;
      if (id === "reg-enr") my.enr = inp.value;
      if (id === "reg-phone") my.phone = inp.value;
    });
  });
}

async function regUpload() {
  const my = RG;
  if (!my || !my.file || my.upBusy) return;
  my.upBusy = true;
  my.upMsg = null;
  paintReg();
  try {
    const slot = await requestIdUploadV2(my.electionId);
    if (!slot.ok) throw new Error(slot.error);
    await storageUpload(slot.path, my.file);
    /* server-side confirmation: validates the object, flips
       auto-review registrations to verified. Only now is ID "done". */
    const conf = await confirmIdUploadV2(my.electionId);
    if (!conf.ok) throw new Error(conf.error);
    my.file = null;
    if (my.preview) { try { URL.revokeObjectURL(my.preview); } catch {} }
    my.preview = null;
    my.upBusy = false;
    await reloadReg(my); // re-read id_ready from the server, never guess
  } catch (e) {
    buzz(60);
    if (my.seq !== navSeq || RG !== my) return;
    my.upBusy = false;
    my.upMsg = { type: "error", text: "Upload fail: " + e.message };
    paintReg();
  }
}

async function regSubmit() {
  const my = RG;
  if (!my || my.busy) return;
  my.msg = null;
  my.busy = true;
  paintReg();
  try {
    const r = await registerVoter(my.electionId, my.name, my.cls, my.enr, my.phone);
    if (!r.ok) throw new Error(r.error);
    await reloadReg(my);
  } catch (e) {
    buzz(60);
    if (my.seq !== navSeq || RG !== my) return;
    my.busy = false;
    my.msg = { type: "error", text: e.message };
    paintReg();
  }
}

/* ================= BALLOT ================= */
let BL = null; // ballot page state

function renderBallot() {
  const electionId = hashQuery().election;
  if (!electionId) return card(alertHtml("error", "Election not found."));
  let idemKey;
  try { idemKey = crypto.randomUUID(); }
  catch { idemKey = "k-" + Date.now() + "-" + Math.random().toString(36).slice(2); }
  BL = {
    electionId, user: null, ballot: null, loading: true, err: null,
    selMonitor: null, selCr: null, mani: null, confirming: false,
    busy: false, voteErr: null, idError: false, alreadyVoted: false,
    idemKey,
    file: null, preview: null, upBusy: false, upMsg: null,
  };
  return `<div class="ballot-stage"><div class="stage-orb s1"></div><div class="stage-orb s2"></div><div class="stage-orb s3"></div>
    ${card(`${spinnerBig}<p class="sub">Preparing your ballot…</p>`, "center")}</div>`;
}

afterRenderHooks["/vote"] = function () {
  const my = BL;
  my.seq = navSeq;
  const eid = my.electionId;
  (async () => {
    const user = await getUser().catch(() => null);
    if (my.seq !== navSeq || BL !== my) return;
    if (!user) { navTo(`/auth?next=/vote?election=${eid}`); return; }
    my.user = user;
    try {
      const b = await getBallot(eid);
      if (my.seq !== navSeq) return;
      if (!b.ok) throw new Error(b.error);
      my.ballot = b;
    } catch (e) {
      my.err = e.message;
    }
    my.loading = false;
    if (my.seq !== navSeq || BL !== my) return;
    paintBallot();
  })();
};

function initials(name) {
  return String(name || "?").split(/\s+/).slice(0, 2).map((w) => (w[0] || "").toUpperCase()).join("");
}

function candCardHtml(c, selected, idx) {
  const photo = c.image_url || c.photo_url;
  return `<div class="cand-reveal" style="animation-delay:${(idx * 0.09).toFixed(2)}s">
    <div class="cand-card ${selected ? "selected" : ""}" data-cid="${esc(c.id)}" data-pos="${esc(c.position)}" role="radio" aria-checked="${selected}" tabindex="0">
      <div class="cand-glow"></div>
      ${photo ? `<img src="${esc(photo)}" alt="${esc(c.name)}" class="cand-photo" loading="lazy" />`
              : `<div class="cand-photo fallback">${esc(initials(c.name))}</div>`}
      <div class="cand-body">
        <div class="cand-name">${esc(c.name)}</div>
        <div class="cand-pos">${c.position === "monitor" ? "Class Monitor" : "Class Representative"}</div>
      </div>
      <button class="cand-mani-btn" data-mani="${esc(c.id)}" title="Read manifesto" aria-label="Read ${esc(c.name)}’s manifesto">${icon("arrowRight", 22)}</button>
      <div class="cand-check ${selected ? "on" : ""}">${icon("check", 18)}</div>
    </div>
  </div>`;
}

function ballotSectionHtml(title, ic, list, sel) {
  return `<section class="ballot-section">
    <div class="ballot-sec-head">
      <span class="ballot-sec-icon">${icon(ic, 22)}</span>
      <h3>${esc(title)}</h3>
      <span class="ballot-sec-hint">Choose one</span>
    </div>
    <div class="cand-grid">${list.map((c, i) => candCardHtml(c, sel === c.id, i)).join("")}</div>
    ${!list.length ? `<p class="sub">No candidates for this position.</p>` : ""}
  </section>`;
}

function maniModalHtml(c) {
  const photo = c.image_url || c.photo_url;
  return `<div class="mani-backdrop" id="mani-backdrop">
    <div class="mani-sheet" role="dialog" aria-label="${esc(c.name)} manifesto">
      <div class="mani-orb m1"></div>
      <div class="mani-orb m2"></div>
      <button class="mani-close" id="mani-close" aria-label="Close">${icon("x", 22)}</button>
      <div class="mani-head">
        ${photo ? `<img src="${esc(photo)}" alt="${esc(c.name)}" class="mani-photo" />`
                : `<div class="mani-photo fallback">${esc(initials(c.name))}</div>`}
        <div>
          <div class="mani-pos">${c.position === "monitor" ? "Class Monitor" : "CR"}</div>
          <h2 class="mani-name">${esc(c.name)}</h2>
        </div>
      </div>
      <div class="mani-divider"></div>
      <div class="mani-label">${icon("sparkles", 17)} Manifesto</div>
      ${c.manifesto ? `<p class="mani-text">${esc(c.manifesto)}</p>` : `<p class="mani-text dim">Manifesto coming soon.</p>`}
      <button class="btn big mani-cta" id="mani-ok">Got it</button>
    </div>
  </div>`;
}

function confirmSheetHtml(my, monitors, crs) {
  const mName = my.selMonitor ? (monitors.find((c) => c.id === my.selMonitor) || {}).name : null;
  const cName = my.selCr ? (crs.find((c) => c.id === my.selCr) || {}).name : null;
  return `<div class="mani-backdrop" id="confirm-backdrop">
    <div class="confirm-sheet" role="dialog" aria-label="Vote confirm">
      <div class="confirm-icon">${icon("shield", 34)}</div>
      <h2>Final confirm?</h2>
      <p class="sub">${mName ? `<b>Monitor:</b> ${esc(mName)}<br />` : ""}${cName ? `<b>CR:</b> ${esc(cName)}<br />` : ""}Your vote <b>cannot</b> be changed afterwards. You will get a receipt code.</p>
      <div class="btn-row">
        <button class="btn ghost" id="confirm-back" ${my.busy ? "disabled" : ""}>Back</button>
        <button class="btn big" id="confirm-yes" ${my.busy ? "disabled" : ""}>${my.busy ? `${spinner} Voting…` : my.voteErr ? "Try again" : "Yes, Cast Vote"}</button>
      </div>
      ${my.voteErr ? alertHtml("error", esc(my.voteErr)) : ""}
    </div>
  </div>`;
}

function paintBallot() {
  const my = BL;
  if (!my || my.seq !== navSeq) return;
  const main = document.getElementById("page-main");
  if (!main) return;
  let html;
  if (my.loading) {
    html = `<div class="ballot-stage"><div class="stage-orb s1"></div><div class="stage-orb s2"></div><div class="stage-orb s3"></div>${card(`${spinnerBig}<p class="sub">Preparing your ballot…</p>`, "center")}</div>`;
  } else if (my.err && !my.idError) {
    html = card(alertHtml("error", esc(my.err)));
  } else {
    const b = my.ballot || {};
    const election = b.election || {};
    const reg = b.registration;
    const cands = b.candidates || [];
    const monitors = cands.filter((c) => c.position === "monitor");
    const crs = cands.filter((c) => c.position === "cr");

    if (election.status !== "open") {
      html = card(alertHtml("info", "Voting is not open yet."), "center");
    } else if (!reg || reg.status !== "verified") {
      html = card(alertHtml("info", "Complete your registration first and wait for verification.") +
        `<a class="btn" href="#/register?election=${esc(my.electionId)}">Register ${icon("arrowRight", 16)}</a>`, "center");
    } else if (reg.voted || my.alreadyVoted) {
      html = card(`<div class="vote-done-badge">${icon("checkCircle", 54)}</div><h2>Vote cast!</h2><p class="sub">You have already voted. One account = one vote.</p><a class="btn ghost" href="#/">${icon("arrowLeft", 16)} Home</a>`, "center");
    } else {
      html = `<div class="ballot-stage">
        <div class="stage-orb s1"></div><div class="stage-orb s2"></div><div class="stage-orb s3"></div>
        <div class="stage-particles" aria-hidden="true">${Array.from({ length: 18 }, (_, i) => `<span class="pt p${(i % 6) + 1}"></span>`).join("")}</div>
        <header class="ballot-hero">
          <p class="eyebrow">Official Ballot</p>
          <h1>${esc(election.title || "")}</h1>
          <p class="ballot-sub">Select a candidate by <b>tapping</b> · press ${icon("arrowRight", 14)} to read their <b>manifesto</b>, then decide.</p>
        </header>
        ${ballotSectionHtml("Class Monitor", "badge", monitors, my.selMonitor)}
        ${ballotSectionHtml("Class Representative (CR)", "users", crs, my.selCr)}
        <div class="ballot-cta-zone">
          ${!my.selMonitor && !my.selCr
            ? `<p class="sub center">Select at least one candidate first.</p>`
            : `<button class="btn big vote-btn" id="vote-cta">${icon("vote", 20)} Confirm Vote</button>`}
        </div>
        ${my.idError ? card(alertHtml("error", esc(my.err || "")) + ballotIdUploadHtml(), "reg-card", "margin-top:14px") : ""}
      </div>`;
      if (my.mani) html += maniModalHtml(my.mani);
      if (my.confirming) html += confirmSheetHtml(my, monitors, crs);
    }
  }
  main.innerHTML = html;
  wireBallot();
}

function ballotIdUploadHtml() {
  const my = BL;
  return `<div class="idzone">
    <label class="lbl">${icon("idcard", 17)} School ID card photo</label>
    <p class="sub" style="margin-top:2px">Upload your ID photo — it is required to vote.</p>
    <input type="file" id="bl-file" accept="image/*" capture="environment" class="file-hidden" />
    ${my.preview ? `
      <div class="upload-preview">
        <img src="${my.preview}" alt="ID card preview" />
        <div class="btn-row">
          <button type="button" class="btn small ghost" id="bl-repick">${icon("refresh", 15)} Retake</button>
          <button type="button" class="btn small" id="bl-upload" ${my.upBusy ? "disabled" : ""}>${my.upBusy ? `${spinner} Upload…` : `${icon("upload", 15)} Upload`}</button>
        </div>
      </div>` : `
      <button type="button" class="upload-drop" id="bl-pick">
        ${icon("camera", 34)}
        <span>Take photo / Choose</span>
        <small>JPG · PNG · WebP · max 6 MB</small>
      </button>`}
    <div>${my.upMsg ? alertHtml(my.upMsg.type, esc(my.upMsg.text)) : ""}</div>
  </div>`;
}

function wireBallot() {
  const my = BL;
  if (!my || my.loading) return;

  document.querySelectorAll(".cand-card[data-cid]").forEach((el) => {
    el.addEventListener("click", () => {
      const id = el.getAttribute("data-cid");
      const pos = el.getAttribute("data-pos");
      if (pos === "monitor") my.selMonitor = my.selMonitor === id ? null : id;
      else my.selCr = my.selCr === id ? null : id;
      paintBallot();
    });
    el.addEventListener("keydown", (e) => { if (e.key === "Enter") el.click(); });
  });
  document.querySelectorAll("[data-mani]").forEach((btn) => {
    btn.addEventListener("click", (e) => {
      e.stopPropagation();
      const id = btn.getAttribute("data-mani");
      const c = (my.ballot.candidates || []).find((x) => x.id === id);
      if (c) { my.mani = c; paintBallot(); }
    });
  });

  const closeMani = () => { my.mani = null; paintBallot(); };
  const maniBackdrop = document.getElementById("mani-backdrop");
  if (maniBackdrop) {
    maniBackdrop.addEventListener("click", (e) => { if (e.target === maniBackdrop) closeMani(); });
    const mc = document.getElementById("mani-close");
    if (mc) mc.addEventListener("click", closeMani);
    const mo = document.getElementById("mani-ok");
    if (mo) mo.addEventListener("click", closeMani);
    if (escHandler) window.removeEventListener("keydown", escHandler);
    escHandler = (e) => { if (e.key === "Escape" && BL === my) closeMani(); };
    window.addEventListener("keydown", escHandler);
  }

  const cta = document.getElementById("vote-cta");
  if (cta) cta.addEventListener("click", () => { my.confirming = true; my.voteErr = null; paintBallot(); });

  const cBack = document.getElementById("confirm-back");
  if (cBack) cBack.addEventListener("click", () => { my.confirming = false; my.voteErr = null; paintBallot(); });
  const cDrop = document.getElementById("confirm-backdrop");
  if (cDrop) cDrop.addEventListener("click", (e) => { if (e.target === cDrop && !my.busy) { my.confirming = false; my.voteErr = null; paintBallot(); } });
  const cYes = document.getElementById("confirm-yes");
  if (cYes) cYes.addEventListener("click", () => doVote());

  /* ID uploader wiring (vote blocked without ID) */
  const blFile = document.getElementById("bl-file");
  const blPick = document.getElementById("bl-pick");
  if (blPick && blFile) blPick.addEventListener("click", () => blFile.click());
  const blRepick = document.getElementById("bl-repick");
  if (blRepick && blFile) blRepick.addEventListener("click", () => blFile.click());
  if (blFile) blFile.addEventListener("change", () => {
    const f = blFile.files && blFile.files[0];
    if (!f) return;
    if (!f.type.startsWith("image/")) { my.upMsg = { type: "error", text: "Only image files are allowed (JPG/PNG/WebP)." }; paintBallot(); return; }
    if (f.size > 6 * 1024 * 1024) { my.upMsg = { type: "error", text: "Photo must be smaller than 6 MB." }; paintBallot(); return; }
    my.file = f;
    if (my.preview) { try { URL.revokeObjectURL(my.preview); } catch {} }
    my.preview = URL.createObjectURL(f);
    my.upMsg = null;
    paintBallot();
  });
  const blUp = document.getElementById("bl-upload");
  if (blUp) blUp.addEventListener("click", () => ballotIdUpload());
}

async function ballotIdUpload() {
  const my = BL;
  if (!my || !my.file || my.upBusy) return;
  my.upBusy = true;
  my.upMsg = null;
  paintBallot();
  try {
    const slot = await requestIdUploadV2(my.electionId);
    if (!slot.ok) throw new Error(slot.error);
    await storageUpload(slot.path, my.file);
    const conf = await confirmIdUploadV2(my.electionId);
    if (!conf.ok) throw new Error(conf.error);
    my.file = null;
    if (my.preview) { try { URL.revokeObjectURL(my.preview); } catch {} }
    my.preview = null;
    my.upBusy = false;
    my.idError = false;
    my.err = null;
    const b = await getBallot(my.electionId);
    if (b.ok && BL === my) { my.ballot = b; paintBallot(); }
  } catch (e) {
    buzz(60);
    if (my.seq !== navSeq || BL !== my) return;
    my.upBusy = false;
    my.upMsg = { type: "error", text: "Upload fail: " + e.message };
    paintBallot();
  }
}

async function doVote() {
  const my = BL;
  if (!my || my.busy) return;
  if (!my.selMonitor && !my.selCr) { buzz(60); return; }
  my.busy = true;
  my.voteErr = null;
  paintBallot();
  try {
    const r = await castVoteV2(my.electionId, my.selMonitor, my.selCr, my.idemKey);
    if (!r.ok) throw new Error(r.error);
    buzz([40, 40, 40]);
    navTo(`/receipt?code=${encodeURIComponent(r.voter_identity)}`);
  } catch (e) {
    buzz(80);
    if (my.seq !== navSeq || BL !== my) return;
    my.busy = false;
    const msg = e.message || "Vote failed";
    if (/already voted/i.test(msg)) {
      my.alreadyVoted = true;
      my.confirming = false;
    } else if (/id photo/i.test(msg)) {
      my.idError = true;
      my.err = msg;
      my.confirming = false;
    } else {
      /* transient failure — sheet stays open; retry reuses the SAME key
         so a lost response replays the original receipt (replay:true). */
      my.voteErr = msg + " — Please try again, your vote will not be counted twice.";
    }
    paintBallot();
  }
}

/* ================= RECEIPT ================= */
function renderReceipt() {
  const code = hashQuery().code || "";
  const colors = ["#6c7bff", "#9d6bff", "#34d399", "#fbbf24", "#f87171"];
  const pieces = Array.from({ length: 60 }, (_, i) => {
    const left = (Math.random() * 100).toFixed(2);
    const delay = (Math.random() * 0.6).toFixed(2);
    const size = (6 + Math.random() * 8).toFixed(1);
    const rot = Math.floor(Math.random() * 360);
    return `<span class="confetti-piece" style="left:${left}%;width:${size}px;height:${(size * 0.6).toFixed(1)}px;background:${colors[i % 5]};animation-delay:${delay}s;transform:rotate(${rot}deg)"></span>`;
  }).join("");
  return `<div class="receipt-stage">
    <div class="confetti" aria-hidden="true">${pieces}</div>
    <div class="stage-orb s1"></div>
    <div class="stage-orb s2"></div>
    ${card(`
      <div class="receipt-badge">${icon("checkCircle", 64)}</div>
      <p class="eyebrow">Vote Recorded</p>
      <h2 style="margin-top:4px">Done! Your vote is in.</h2>
      <p class="sub">Here is your <b>unique receipt code</b> — keep it safe.</p>
      <button class="receipt-code" id="rc-copy" title="Tap to copy">${esc(code) || "----"}</button>
      <p class="sub small">Tap to copy</p>
      <div class="btn-row center-row">
        <a class="btn big" href="#/">${icon("arrowLeft", 17)} Home</a>
        <a class="btn ghost" href="#/results">${icon("chart", 17)} Results</a>
      </div>`, "receipt-card center")}
  </div>`;
}

afterRenderHooks["/receipt"] = function () {
  const btn = document.getElementById("rc-copy");
  if (btn) btn.addEventListener("click", async () => {
    try { await navigator.clipboard.writeText(hashQuery().code || ""); }
    catch {}
  });
};

/* ================= RESULTS ================= */
async function renderResults() {
  return card(`${spinnerBig}<p class="sub">Loading results…</p>`, "center");
}

afterRenderHooks["/results"] = function () {
  const seq = navSeq;
  const alive = () => seq === navSeq && !!document.getElementById("page-main");
  const paint = (html) => {
    if (!alive()) return;
    document.getElementById("page-main").innerHTML = html;
  };
  const load = async () => {
    paint(card(`${spinnerBig}<p class="sub">Loading results…</p>`, "center"));
    try {
      const res = await authFetch(
        "/rest/v1/public_results?select=*&order=vote_count.desc",
        { method: "GET", auth: true }
      );
      if (!res.ok) throw new Error("HTTP " + res.status);
      const rows = (await res.json()) || [];
      if (!alive()) return;
      if (!rows.length) {
        paint(`<section class="hero"><h1>${icon("chart", 34)} <span class="grad">Results</span></h1>
          <p class="hero-sub">Results will appear here once they are published.</p></section>`);
        return;
      }
      const eid = rows[0].election_id;
      const title = rows[0].election_title;
      const list = rows.filter((r) => r.election_id === eid);
      const section = (pos, ic, heading) => {
        const items = list.filter((r) => r.position === pos);
        if (!items.length) return "";
        const max = Math.max(...items.map((r) => Number(r.vote_count)), 1);
        const total = items.reduce((s, r) => s + Number(r.vote_count), 0);
        const top = Math.max(...items.map((r) => Number(r.vote_count)));
        return `<div class="position-title"><span class="icon">${icon(ic, 22)}</span>
            <div><h3>${esc(heading)}</h3><small>${total} vote${total === 1 ? "" : "s"}</small></div></div>
          ${card(items.map((r, i) => {
            const winner = Number(r.vote_count) === top && top > 0;
            const pct = ((Number(r.vote_count) / max) * 100).toFixed(1);
            return `<div class="result-row ${winner ? "winner" : ""}">
              <div class="rhead"><span class="cname"><span class="rank">#${i + 1}</span> ${esc(r.candidate_name)}</span><span class="votes">${esc(String(r.vote_count))} votes</span></div>
              <div class="bar"><div class="bar-fill" data-w="${pct}" style="width:0"></div></div>
            </div>`;
          }).join(""))}`;
      };
      paint(`<section class="hero slim">
          <h1>${icon("chart", 34)} <span class="grad">Results</span></h1>
          <p class="hero-sub">${esc(title || "")}</p>
          <div class="share-row" style="justify-content:center">
            <button class="btn small ghost" id="res-refresh">${icon("refresh", 16)} Refresh</button>
          </div>
        </section>
        ${section("monitor", "users", "Class Monitor")}
        ${section("cr", "badge", "Class Representative (CR)")}`);
      /* animate bars after paint */
      requestAnimationFrame(() => requestAnimationFrame(() => {
        document.querySelectorAll(".bar-fill[data-w]").forEach((el) => {
          el.style.width = el.getAttribute("data-w") + "%";
        });
      }));
      const rf = document.getElementById("res-refresh");
      if (rf) rf.addEventListener("click", load);
    } catch (e) {
      if (alive()) paint(card(alertHtml("error", "Could not load results.")));
    }
  };
  load();
};

/* ================= ADMIN ================= */
let AD = null; // admin page state

async function renderAdmin() {
  AD = {
    user: null, adminState: "checking", denyMsg: "",
    elections: [], current: null, title: "",
    lEmail: "", lPw: "", lMsg: null, lBusy: false,
    admTab: "overview",
    detail: null, // {loading, cands, stats, tally, settings, settingsMsg, regs, regsLoading, regsMsg, needId, loadMsg}
    audit: null, // {loading, err, rows, total, dups, q}
  };
  return card(`${spinnerBig}<p class="sub">Checking admin access…</p>`, "center", "margin-top:20px");
}

afterRenderHooks["/admin.html"] = function () {
  const my = AD;
  my.seq = navSeq;
  (async () => {
    const user = await getUser().catch(() => null);
    if (my.seq !== navSeq || AD !== my) return;
    my.user = user;
    if (!user) { my.adminState = "login"; paintAdmin(); return; }
    await checkAdmin(my);
  })();
};

async function checkAdmin(my) {
  my.adminState = "checking";
  paintAdmin();
  try {
    const ok = await rpc("am_i_admin");
    if (my.seq !== navSeq || AD !== my) return;
    if (ok) {
      my.adminState = "admin";
      await loadElections(my);
    } else {
      await signOut();
      my.user = null;
      my.denyMsg = "This account is not an admin. Contact an existing admin for access — they can promote you via SQL.";
      my.adminState = "denied";
      paintAdmin();
    }
  } catch (e) {
    if (my.seq !== navSeq || AD !== my) return;
    my.denyMsg = "Auth check fail: " + e.message;
    my.adminState = "denied";
    paintAdmin();
  }
}

async function loadElections(my, keepCurrent) {
  try {
    const data = (await rpc("admin_list_elections")) || [];
    my.elections = data;
    if (!data.length) my.current = null;
    else if (!keepCurrent && !my.current) my.current = data[0].id;
    else if (my.current && !data.find((e) => e.id === my.current)) my.current = data[0].id;
  } catch (e) {
    my.denyMsg = "Load fail: " + e.message;
    my.adminState = "denied";
  }
  if (my.seq !== navSeq || AD !== my) return;
  paintAdmin();
  if (my.adminState === "admin" && my.current) loadDetail(my);
}

function adminLoginHtml(my) {
  return card(`<h2>${icon("key", 26)} Admin login</h2>
    <p class="sub">Log in with your <b>admin email + password</b>. No need to paste any secret key — this is the secure login.</p>
    ${alertHtml("info", `${icon("alert", 17)} Setting up for the first time? Create your admin account in the Supabase dashboard under <b>Authentication → Users → Add user</b>, log in, then run this in the <b>SQL editor</b>: <code>update profiles set is_admin=true where id=(select id from auth.users where email='you@email.com')</code> — no one can become admin without this.`)}
    <label class="lbl">Admin email</label>
    <input type="email" id="ad-email" placeholder="teacher@school.com" autocomplete="username" value="${esc(my.lEmail)}" />
    <label class="lbl">Password</label>
    <input type="password" id="ad-pw" placeholder="••••••••" autocomplete="current-password" value="${esc(my.lPw)}" />
    <div id="ad-lmsg">${my.lMsg ? alertHtml(my.lMsg.type, esc(my.lMsg.text)) : ""}</div>
    <button class="btn" id="ad-login" ${my.lBusy ? "disabled" : ""}>${my.lBusy ? "Logging in…" : "Login"}</button>`, "", "margin-top:20px");
}

const ADMIN_TABS = [
  ["overview", "Overview", "chart"],
  ["elections", "Elections", "vote"],
  ["candidates", "Candidates", "users"],
  ["registrations", "Registrations", "badge"],
  ["audit", "Vote Audit", "shield"],
  ["settings", "Settings", "settings"],
];

function electionPickerHtml(my) {
  const elections = my.elections || [];
  return card(`<div class="detail-head"><h3 style="margin:0">${icon("vote", 20)} Election</h3>
    <select id="ad-eidpick" style="max-width:340px" aria-label="Select election">
      ${elections.map((e) => `<option value="${esc(e.id)}" ${e.id === my.current ? "selected" : ""}>${esc(e.title)} · ${esc(e.status)}</option>`).join("")}
    </select></div>`);
}

function electionsCardHtml(my) {
  const elections = my.elections;
  return card(`<h3 style="margin-top:0">Elections</h3>
    ${elections.length ? elections.map((e) => `
      <div class="kv">
        <span class="grow"><b>${esc(e.title)}</b><br /><small style="color:var(--muted)">${esc(new Date(e.created_at).toLocaleString())}</small></span>
        ${pill(e.status)}
        <button class="mini-btn" data-sel-eid="${esc(e.id)}">${e.id === my.current ? `${icon("check", 14)} Selected` : "Select"}</button>
      </div>`).join("")
    : `<p class="sub">No elections yet — create one below.</p>`}
    <label class="lbl">New election title</label>
    <input type="text" id="ad-newtitle" placeholder="e.g. Class 10-B Election 2026" value="${esc(my.title)}" />
    <button class="btn" id="ad-create">${icon("plus", 17)} Create election</button>`);
}

function electionOverviewHtml(my, election) {
  const d = my.detail || {};
  const stats = d.stats || { registrations: 0, pending: 0, votes: 0 };
  const cands = d.cands || [];
  return card(`<div class="detail-head"><h3 style="margin:0">${esc(election.title)}</h3>${pill(election.status)}</div>
    <div class="stat-grid">
      <div class="stat"><div class="stat-num">${esc(String(stats.votes))}</div><div class="stat-lbl">Votes cast</div></div>
      <div class="stat"><div class="stat-num">${esc(String(stats.registrations || 0))}</div><div class="stat-lbl">Registered</div></div>
      <div class="stat"><div class="stat-num">${esc(String(stats.pending || 0))}</div><div class="stat-lbl">Pending review</div></div>
      <div class="stat"><div class="stat-num">${cands.length}</div><div class="stat-lbl">Candidates</div></div>
      <div class="stat"><div class="stat-num">${icon(election.results_published ? "megaphone" : "eyeOff", 26)}</div><div class="stat-lbl">${election.results_published ? "Public" : "Hidden"}</div></div>
    </div>
    ${d.loadMsg ? alertHtml(d.loadMsg.type, esc(d.loadMsg.text)) : ""}
    <div class="btn-row">
      <button class="btn small" id="ad-open" ${election.status === "open" ? "disabled" : ""}>${icon("play", 15)} Open voting</button>
      <button class="btn small ghost" id="ad-close" ${election.status !== "open" ? "disabled" : ""}>${icon("pause", 15)} Close voting</button>
      <button class="btn small ghost" id="ad-pub">${icon(election.results_published ? "eyeOff" : "megaphone", 15)} ${election.results_published ? "Hide results" : "Publish results"}</button>
      <button class="btn small danger" id="ad-del">${icon("trash", 15)} Delete</button>
    </div>`);
}

function candidatesCardHtml(my) {
  const d = my.detail || {};
  const cands = d.cands || [];
  const tally = d.tally || {};
  return card(`<h3 style="margin-top:0">Candidates</h3>
    <div id="ad-candlist">${d.loading ? `<p class="sub">${spinner} Loading…</p>` : cands.length ? cands.map((c) => `
      <div class="list-item">
        <span class="tag">${c.position === "monitor" ? "Monitor" : "CR"}</span>
        <span class="grow"><b>${esc(c.name)}</b> <small style="color:var(--muted)">· ${tally[c.id] || 0} votes</small></span>
        <button class="mini-btn danger" data-del-cid="${esc(c.id)}">Remove</button>
      </div>`).join("") : `<p class="sub">No candidates yet.</p>`}</div>
    <label class="lbl">Add candidate</label>
    <input type="text" id="ad-cname" placeholder="Student name" style="margin-bottom:10px" />
    <div class="form-row">
      <select id="ad-cpos"><option value="monitor">Class Monitor</option><option value="cr">CR</option></select>
      <input type="url" id="ad-cphoto" placeholder="Photo URL (optional)" />
    </div>
    <label class="lbl">Candidate image URL (ballot card photo)</label>
    <input type="url" id="ad-cimg" placeholder="https://… (optional)" style="margin-bottom:10px" />
    <label class="lbl">Manifesto (voters will read this)</label>
    <textarea id="ad-cmani" rows="3" placeholder="What will this candidate do — write in 2-4 lines…" style="margin-bottom:10px"></textarea>
    <button class="btn" id="ad-cadd">${icon("plus", 17)} Add candidate</button>`);
}

function adminPanelHtml(my) {
  const elections = my.elections;
  const election = elections.find((e) => e.id === my.current);
  const tab = my.admTab || "overview";
  let content;
  if (!election) {
    content = electionsCardHtml(my);
  } else if (tab === "overview") {
    content = electionOverviewHtml(my, election);
  } else if (tab === "elections") {
    content = electionsCardHtml(my);
  } else if (tab === "candidates") {
    content = candidatesCardHtml(my);
  } else if (tab === "registrations") {
    content = regListHtml(my);
  } else if (tab === "audit") {
    content = auditHtml(my);
  } else {
    content = regSettingsHtml(my);
  }
  return `<div class="admin-layout">
    <aside class="admin-side">
      <div class="side-brand">${icon("shield", 22)}<span>Admin Panel</span></div>
      <nav class="side-nav" aria-label="Admin sections">
        ${ADMIN_TABS.map(([key, label, ic]) => `
          <button type="button" class="side-link ${tab === key ? "active" : ""}" data-admtab="${key}">${icon(ic, 17)}<span>${label}</span></button>`).join("")}
      </nav>
      <button class="btn ghost side-logout" id="ad-logout">${icon("lock", 16)} Logout</button>
    </aside>
    <div class="admin-main">
      ${electionPickerHtml(my)}
      ${content}
    </div>
  </div>`;
}

const REG_SETTING_ROWS = [
  ["require_name", "Ask for name", "Make full name mandatory for voters."],
  ["require_class", "Ask for class", "Make class / section mandatory."],
  ["require_enrollment_id", "Ask for enrollment ID", "Make admission / enrollment ID mandatory."],
  ["require_phone", "Ask for mobile number", "Make mobile number (10 digits) mandatory for voters."],
  ["require_id_upload", "ID photo required", "Voters must upload a school ID card photo before voting."],
  ["manual_review", "Manual verification", "The admin must approve each voter before they can vote."],
];

function regSettingsHtml(my) {
  const d = my.detail || {};
  const s = d.settings;
  return card(`<h3 style="margin-top:0">${icon("settings", 22)} Registration Settings</h3>
    <p class="sub">Choose which fields appear on the voter signup form — it is all in your hands.</p>
    ${d.settingsMsg ? alertHtml(d.settingsMsg.type, esc(d.settingsMsg.text)) : ""}
    ${d.loading || !s ? `<p class="sub">${spinner} Loading…</p>` :
      REG_SETTING_ROWS.map(([key, label, hint]) => `
        <label class="switch-row">
          <button type="button" class="switch ${s[key] ? "on" : ""}" role="switch" aria-checked="${!!s[key]}" data-setkey="${key}"><span class="knob"></span></button>
          <span><b>${esc(label)}</b><br /><small style="color:var(--muted)">${esc(hint)}</small></span>
        </label>`).join("")}`);
}

function idThumbHtml(r) {
  if (!r.id_path) return "";
  return `<button type="button" class="id-thumb-btn" data-signpath="${esc(r.id_path)}" title="View ID photo"><span class="sub">ID…</span></button>`;
}

function regListHtml(my) {
  const d = my.detail || {};
  const rows = d.regs || [];
  const pending = rows.filter((r) => r.status === "pending").length;
  return card(`<h3 style="margin-top:0">${icon("users", 22)} Voter Registrations (${rows.length}${pending ? ` · ${pending} pending` : ""})</h3>
    ${d.regsMsg ? alertHtml(d.regsMsg.type, esc(d.regsMsg.text)) : ""}
    ${d.regsLoading ? `<p class="sub">${spinner} Loading…</p>` : rows.length ? rows.map((r) => `
      <div class="list-item reg-item">
        ${idThumbHtml(r)}
        <span class="grow">
          <b>${esc(r.name || r.email)}</b> ${pill(r.status)}${r.voted ? pill("voted") : ""}
          ${d.needId ? `<span class="pill ${r.id_ready ? "ok" : "warn"}" style="margin-left:6px">${r.id_ready ? "ID ok" : "ID pending"}</span>` : ""}
          <br />
          <small style="color:var(--muted)">${esc(r.email)}${r.class ? ` · ${esc(r.class)}` : ""}${r.enrollment_id ? ` · ${esc(r.enrollment_id)}` : ""}${r.phone ? ` · ${icon("phone", 12)} ${esc(r.phone)}` : ""}${r.id_path ? " · ID photo attached" : ""}</small>
        </span>
        ${r.status === "pending" && !r.voted ? `
          <span class="btn-row" style="margin:0">
            <button class="mini-btn" data-approve="${esc(r.id)}"
              ${d.needId && !r.id_ready ? "disabled" : ""}
              title="${d.needId && !r.id_ready ? "The voter must upload a valid ID first" : "Approve"}">${icon("check", 13)} Approve</button>
            <button class="mini-btn danger" data-reject="${esc(r.id)}">${icon("x", 13)} Reject</button>
          </span>` : ""}
      </div>`).join("")
    : `<p class="sub">No registrations yet.</p>`}
    <div class="btn-row" style="margin-top:10px">
      <button class="btn small ghost" id="ad-regrefresh">${icon("refresh", 15)} Refresh</button>
    </div>
    <div id="ad-idfull"></div>`);
}

/* ---------- read-only vote audit ---------- */
async function loadAudit(my, eid) {
  my.audit = Object.assign(my.audit || {}, { loading: true, err: null });
  paintAdmin();
  try {
    const r = await adminVoteAudit(eid);
    if (my.seq !== navSeq || AD !== my || my.current !== eid) return;
    my.audit = {
      loading: false, err: null,
      rows: r.votes || [], total: r.total || 0,
      dups: r.duplicate_phones || [],
      q: (my.audit && my.audit.q) || "",
    };
  } catch (e) {
    if (my.seq !== navSeq || AD !== my || my.current !== eid) return;
    my.audit = { loading: false, err: e.message, rows: [], total: 0, dups: [], q: "" };
  }
  paintAdmin();
}

function auditFilteredRows(my) {
  const a = my.audit || {};
  const q = (a.q || "").trim().toLowerCase();
  const rows = a.rows || [];
  if (!q) return rows;
  return rows.filter((r) =>
    [r.name, r.email, r.class, r.enrollment_id, r.phone, r.receipt, r.monitor, r.cr]
      .some((v) => (v || "").toString().toLowerCase().includes(q))
  );
}

function auditRowsHtml(my) {
  const a = my.audit || {};
  const rows = auditFilteredRows(my);
  const dupSet = new Set((a.dups || []).map((d) => d.phone));
  if (!rows.length) {
    return `<p class="sub">${(a.rows || []).length ? "No votes match your search." : "No votes cast yet."}</p>`;
  }
  return `<div class="table-wrap"><table class="audit-table">
    <thead><tr><th>Voter</th><th>Identity</th><th>Monitor</th><th>CR</th><th>Receipt</th><th>Time</th><th>Flag</th></tr></thead>
    <tbody>${rows.map((r) => {
      const isDup = r.phone && dupSet.has(r.phone);
      return `<tr>
        <td><b>${esc(r.name || "—")}</b><br /><small style="color:var(--muted)">${esc(r.email || "")}</small></td>
        <td><small>${r.class ? esc(r.class) + "<br />" : ""}${r.enrollment_id ? esc(r.enrollment_id) + "<br />" : ""}${r.phone ? `${icon("phone", 11)} ${esc(r.phone)}` : "<span style='color:var(--muted)'>no phone</span>"}</small></td>
        <td>${esc(r.monitor || "—")}</td>
        <td>${esc(r.cr || "—")}</td>
        <td><code>${esc(r.receipt || "")}</code></td>
        <td><small>${r.voted_at ? esc(new Date(r.voted_at).toLocaleString()) : ""}</small></td>
        <td>${isDup ? `<span class="pill warn">dup phone</span>` : ""}</td>
      </tr>`;
    }).join("")}</tbody>
  </table></div>`;
}

function auditHtml(my) {
  const a = my.audit || {};
  const dups = a.dups || [];
  return card(`<div class="detail-head"><h3 style="margin:0">${icon("shield", 22)} Vote Audit</h3>
      <span class="sub">${a.total || 0} votes</span></div>
    <p class="sub">Read-only: every vote mapped to its voter and chosen candidates. Votes cannot be changed, deleted, or created from here.</p>
    ${a.err ? alertHtml("error", esc(a.err)) : ""}
    ${dups.length ? alertHtml("warn", `${icon("alert", 16)} <b>${dups.length} duplicate phone number${dups.length > 1 ? "s" : ""}</b> — possible fake / multiple registrations:<br />` +
      dups.map((d) => `<b>${esc(d.phone)}</b> × ${d.count} — ${(d.voters || []).map((v) => `${esc(v.name || v.email)}${v.voted ? " (voted)" : ""}`).join(", ")}`).join("<br />")) : ""}
    <div class="form-row">
      <input type="search" id="ad-auditq" class="grow" placeholder="Search name, email, phone, receipt…" value="${esc(a.q || "")}" aria-label="Search audit" />
      <button class="btn small ghost" id="ad-auditrefresh">${icon("refresh", 15)} Refresh</button>
      <button class="btn small ghost" id="ad-auditcsv">${icon("download", 15)} CSV</button>
    </div>
    ${a.loading ? `<p class="sub">${spinner} Loading audit…</p>` : `<div id="ad-auditrows">${auditRowsHtml(my)}</div>`}`);
}

function exportAuditCsv(my) {
  const rows = auditFilteredRows(my);
  const head = ["vote_id", "voted_at", "receipt", "name", "email", "class", "enrollment_id", "phone", "monitor", "cr"];
  const cell = (v) => `"${String(v == null ? "" : v).replace(/"/g, '""')}"`;
  const csv = [head.join(","), ...rows.map((r) => head.map((k) => cell(r[k])).join(","))].join("\r\n");
  const blob = new Blob(["\uFEFF" + csv], { type: "text/csv;charset=utf-8" });
  const a = document.createElement("a");
  a.href = URL.createObjectURL(blob);
  a.download = "vote-audit.csv";
  document.body.appendChild(a);
  a.click();
  a.remove();
  setTimeout(() => URL.revokeObjectURL(a.href), 5000);
}

function paintAdmin() {
  const my = AD;
  if (!my || my.seq !== navSeq) return;
  const main = document.getElementById("page-main");
  if (!main) return;
  let html;
  if (my.adminState === "login") {
    html = (my.denyMsg ? alertHtml("error", esc(my.denyMsg)) : "") + adminLoginHtml(my);
  } else if (my.adminState === "checking") {
    html = card(`${spinnerBig}<p class="sub">Checking admin access…</p>`, "center", "margin-top:20px");
  } else if (my.adminState === "denied") {
    html = card(`${alertHtml("error", esc(my.denyMsg || "Access denied."))}
      <button class="btn ghost" id="ad-backlogin">${icon("lock", 17)} Back to login</button>`, "", "margin-top:20px");
  } else {
    html = adminPanelHtml(my);
  }
  main.innerHTML = html;
  wireAdmin();
}

async function loadDetail(my) {
  if (!my.current) return;
  my.detail = Object.assign(my.detail || {}, { loading: true, loadMsg: null });
  paintAdmin();
  const eid = my.current;
  try {
    const [c, s, t] = await Promise.all([
      rpc("admin_list_candidates", { p_election_id: eid }),
      rpc("admin_stats", { p_election_id: eid }),
      rpc("admin_tally", { p_election_id: eid }),
    ]);
    if (my.seq !== navSeq || AD !== my || my.current !== eid) return;
    const m = {};
    (t || []).forEach((x) => { m[x.candidate_id] = Number(x.votes); });
    my.detail.cands = c || [];
    my.detail.stats = s || { registrations: 0, pending: 0, votes: 0 };
    my.detail.tally = m;
    my.detail.loading = false;
  } catch (e) {
    if (my.seq !== navSeq || AD !== my || my.current !== eid) return;
    my.detail.loadMsg = { type: "error", text: "Load fail: " + e.message };
    my.detail.loading = false;
  }
  paintAdmin();
  loadSettings(my, eid);
  loadRegs(my, eid);
}

async function loadSettings(my, eid) {
  try {
    const b = await rpc("get_ballot", { p_election_id: eid });
    if (my.seq !== navSeq || AD !== my || my.current !== eid) return;
    my.detail.settings = (b && b.settings) || null;
    my.detail.needId = !!((b && b.settings && b.settings.require_id_upload));
    paintAdmin();
    wireIdThumbs();
  } catch (e) {
    if (my.seq !== navSeq || AD !== my || my.current !== eid) return;
    my.detail.settingsMsg = { type: "error", text: e.message };
    paintAdmin();
  }
}

async function loadRegs(my, eid) {
  my.detail.regsLoading = true;
  my.detail.regsMsg = null;
  paintAdmin();
  try {
    const rows = (await adminListRegistrations(eid)) || [];
    if (my.seq !== navSeq || AD !== my || my.current !== eid) return;
    my.detail.regs = rows;
    my.detail.regsLoading = false;
  } catch (e) {
    if (my.seq !== navSeq || AD !== my || my.current !== eid) return;
    my.detail.regsMsg = { type: "error", text: e.message };
    my.detail.regsLoading = false;
  }
  paintAdmin();
  wireIdThumbs();
}

/* fetch signed URLs for admin ID thumbnails + fullscreen viewer */
function wireIdThumbs() {
  document.querySelectorAll("[data-signpath]").forEach(async (btn) => {
    if (btn.dataset.done) return;
    btn.dataset.done = "1";
    const path = btn.getAttribute("data-signpath");
    try {
      const url = await storageSignUrl(path, 600);
      btn.innerHTML = `<img src="${esc(url)}" alt="Voter ID" loading="lazy" />`;
      btn.addEventListener("click", () => {
        const host = document.getElementById("ad-idfull");
        if (!host) return;
        host.innerHTML = `<div class="mani-backdrop" id="idfull-drop">
          <div class="mani-sheet" style="text-align:center" id="idfull-sheet">
            <img src="${esc(url)}" alt="Voter ID full" style="max-width:100%;border-radius:12px" />
            <button class="btn small ghost" style="margin-top:12px" id="idfull-close">Close</button>
          </div></div>`;
        const drop = document.getElementById("idfull-drop");
        const close = () => { host.innerHTML = ""; };
        drop.addEventListener("click", (e) => { if (e.target === drop) close(); });
        document.getElementById("idfull-close").addEventListener("click", close);
        document.getElementById("idfull-sheet").addEventListener("click", (e) => e.stopPropagation());
      });
    } catch {
      btn.innerHTML = `<span class="sub">ID?</span>`;
    }
  });
}

function wireAdmin() {
  const my = AD;
  if (!my) return;

  /* login form */
  const em = document.getElementById("ad-email");
  const pw = document.getElementById("ad-pw");
  if (em) em.addEventListener("input", () => { my.lEmail = em.value; });
  if (pw) pw.addEventListener("input", () => { my.lPw = pw.value; });
  const doLogin = async () => {
    my.lMsg = null;
    const email = (my.lEmail || "").trim();
    const pwd = my.lPw || "";
    if (!email.includes("@") || pwd.length < 6) {
      my.lMsg = { type: "error", text: "Enter a valid email and password." };
      paintAdmin();
      return;
    }
    my.lBusy = true;
    paintAdmin();
    try {
      await signIn(email, pwd);
      my.lBusy = false;
      my.lEmail = ""; my.lPw = "";
      my.user = await getUser().catch(() => null);
      my.denyMsg = "";
      await checkAdmin(my);
    } catch (e) {
      my.lBusy = false;
      my.lMsg = { type: "error", text: "Login fail: " + e.message };
      paintAdmin();
    }
  };
  const lg = document.getElementById("ad-login");
  if (lg) lg.addEventListener("click", doLogin);
  [em, pw].forEach((inp) => { if (inp) inp.addEventListener("keydown", (e) => { if (e.key === "Enter") doLogin(); }); });

  const backBtn = document.getElementById("ad-backlogin");
  if (backBtn) backBtn.addEventListener("click", async () => {
    await signOut();
    my.user = null;
    my.adminState = "login";
    my.denyMsg = "";
    paintAdmin();
  });

  if (my.adminState !== "admin") return;

  /* sidebar tabs */
  document.querySelectorAll("[data-admtab]").forEach((b) =>
    b.addEventListener("click", () => {
      my.admTab = b.getAttribute("data-admtab");
      paintAdmin();
      if (my.admTab === "audit" && my.current && (!my.audit || (!my.audit.rows && !my.audit.loading && !my.audit.err))) {
        loadAudit(my, my.current);
      }
    })
  );

  /* election picker (top of admin main) */
  const eidPick = document.getElementById("ad-eidpick");
  if (eidPick) eidPick.addEventListener("change", () => {
    my.current = eidPick.value;
    my.detail = null;
    my.audit = null;
    paintAdmin();
    loadDetail(my);
  });

  /* elections */
  document.querySelectorAll("[data-sel-eid]").forEach((b) =>
    b.addEventListener("click", () => {
      my.current = b.getAttribute("data-sel-eid");
      my.detail = null;
      paintAdmin();
      loadDetail(my);
    })
  );
  const nt = document.getElementById("ad-newtitle");
  if (nt) nt.addEventListener("input", () => { my.title = nt.value; });
  const createElection = async () => {
    const title = (my.title || "").trim();
    if (!title) { alert("Enter a title first."); return; }
    try {
      const row = await rpc("admin_create_election", { p_title: title });
      my.title = "";
      await loadElections(my, true);
      if (row && row.id) { my.current = row.id; my.detail = null; paintAdmin(); loadDetail(my); }
    } catch (e) { alert("Error: " + e.message); }
  };
  const cr = document.getElementById("ad-create");
  if (cr) cr.addEventListener("click", createElection);
  if (nt) nt.addEventListener("keydown", (e) => { if (e.key === "Enter") createElection(); });

  const logout = document.getElementById("ad-logout");
  if (logout) logout.addEventListener("click", async () => {
    await signOut();
    my.user = null;
    my.elections = [];
    my.current = null;
    my.detail = null;
    my.adminState = "login";
    paintAdmin();
  });

  const election = my.elections.find((e) => e.id === my.current);
  if (!election) { wireIdThumbs(); return; }

  const updateElection = async (field, value) => {
    try {
      const updated = await rpc("admin_update_election", {
        p_election_id: election.id,
        p_status: field === "status" ? value : election.status,
        p_results_published: field === "results_published" ? value : election.results_published,
      });
      my.elections = my.elections.map((e) => (e.id === updated.id ? updated : e));
      paintAdmin();
    } catch (e) { alert("Error: " + e.message); }
  };
  const bOpen = document.getElementById("ad-open");
  if (bOpen) bOpen.addEventListener("click", () => updateElection("status", "open"));
  const bClose = document.getElementById("ad-close");
  if (bClose) bClose.addEventListener("click", () => updateElection("status", "closed"));
  const bPub = document.getElementById("ad-pub");
  if (bPub) bPub.addEventListener("click", () => updateElection("results_published", !election.results_published));
  const bDel = document.getElementById("ad-del");
  if (bDel) bDel.addEventListener("click", async () => {
    if (!window.confirm("Delete this election and ALL its data? This cannot be undone.")) return;
    try {
      await rpc("admin_delete_election", { p_election_id: election.id });
      my.current = null;
      my.detail = null;
      await loadElections(my, true);
    } catch (e) { alert("Error: " + e.message); }
  });

  /* candidates */
  document.querySelectorAll("[data-del-cid]").forEach((b) =>
    b.addEventListener("click", async () => {
      if (!window.confirm("Remove this candidate?")) return;
      try {
        await rpc("admin_delete_candidate", { p_candidate_id: b.getAttribute("data-del-cid") });
        loadDetail(my);
      } catch (e) { alert("Error: " + e.message); }
    })
  );
  const cAdd = document.getElementById("ad-cadd");
  if (cAdd) cAdd.addEventListener("click", async () => {
    const name = (document.getElementById("ad-cname").value || "").trim();
    if (!name) { alert("Enter the candidate's name."); return; }
    const pos = document.getElementById("ad-cpos").value;
    const photo = (document.getElementById("ad-cphoto").value || "").trim() || null;
    const imageUrl = (document.getElementById("ad-cimg").value || "").trim() || null;
    const manifesto = (document.getElementById("ad-cmani").value || "").trim() || null;
    try {
      await rpc("admin_add_candidate", {
        p_election_id: election.id,
        p_name: name,
        p_position: pos,
        p_photo_url: photo,
        p_image_url: imageUrl,
        p_manifesto: manifesto,
      });
      loadDetail(my);
    } catch (e) { alert("Error: " + e.message); }
  });

  /* settings toggles */
  document.querySelectorAll("[data-setkey]").forEach((b) =>
    b.addEventListener("click", async () => {
      const key = b.getAttribute("data-setkey");
      const s = my.detail && my.detail.settings;
      if (!s) return;
      const next = Object.assign({}, s, { [key]: !s[key] });
      my.detail.settings = next;
      my.detail.needId = !!next.require_id_upload;
      paintAdmin();
      wireIdThumbs();
      try {
        await adminUpdateSettings(election.id, next);
      } catch (e) {
        my.detail.settingsMsg = { type: "error", text: e.message };
        loadSettings(my, election.id);
      }
    })
  );

  /* registrations approve / reject */
  const decide = async (id, approved) => {
    try {
      await adminVerifyRegistration(id, approved);
      const eid = my.current;
      if (eid) loadRegs(my, eid);
    } catch (e) {
      /* surface the server's rejection (e.g. ID required but not uploaded) */
      my.detail.regsMsg = { type: "error", text: e.message };
      paintAdmin();
      wireIdThumbs();
    }
  };
  document.querySelectorAll("[data-approve]").forEach((b) =>
    b.addEventListener("click", () => decide(b.getAttribute("data-approve"), true))
  );
  document.querySelectorAll("[data-reject]").forEach((b) =>
    b.addEventListener("click", () => decide(b.getAttribute("data-reject"), false))
  );
  const rRef = document.getElementById("ad-regrefresh");
  if (rRef) rRef.addEventListener("click", () => { loadRegs(my, election.id); });

  /* vote audit: search / refresh / csv */
  const auditQ = document.getElementById("ad-auditq");
  if (auditQ) auditQ.addEventListener("input", () => {
    if (!my.audit) return;
    my.audit.q = auditQ.value;
    const host = document.getElementById("ad-auditrows");
    if (host) host.innerHTML = auditRowsHtml(my);
  });
  const auditRefresh = document.getElementById("ad-auditrefresh");
  if (auditRefresh) auditRefresh.addEventListener("click", () => { loadAudit(my, election.id); });
  const auditCsv = document.getElementById("ad-auditcsv");
  if (auditCsv) auditCsv.addEventListener("click", () => { exportAuditCsv(my); });

  wireIdThumbs();
}

/* ---------------- boot ---------------- */
let navSeq = 0;
const _render = render;
render = async function () {
  navSeq++;
  return _render();
};

setTheme(getTheme());
window.addEventListener("hashchange", () => render());
if (!window.location.hash) {
  window.location.hash = "#/";
} else {
  render();
}
