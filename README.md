# Class Election — Monitor & CR Voting

Real, secure online voting for class Monitor / CR elections.
Built with **pure HTML5 + CSS + vanilla JavaScript** — no framework, no build step, no npm.
Just 4 static files (`index.html`, `app.js`, `styles.css`, `config.js`) served from GitHub Pages + Supabase backend.
**No demo data — everything is real.** Fully responsive — mobile, tablet, laptop, PC, TV.

## Features

- **Signup-based voter flow** — students sign up with email + password, then register for an election
- **Double-vote impossible** — each vote is cast in a single database transaction (registration row lock + UNIQUE constraint)
- **RLS locked** — the anon key cannot read/write tables directly; voting happens only through tightly-scoped RPCs
- **Unique receipt** — after voting, every voter gets a `XXXX-XXXX` receipt (tap-to-copy)
- **Idempotent voting** — if the network fails, retrying returns the same original receipt; no second vote is created
- **Secure admin login** — email + password (Supabase Auth). **No service_role key in the browser**. Every admin action runs after a server-side role check
- **ID Card Verification (admin-controlled)** — the admin can turn it ON; when ON, every voter must upload their school ID card (camera or gallery) before voting. Uploads happen only on a server-issued one-time slot, to a random unguessable path, with image-only + 6MB limit enforced server-side. Admin approval without an ID upload is **technically impossible**. Photos live in a private bucket, visible only to the admin via short-lived signed URLs
- **Results control** — the teacher publishes results whenever they choose
- **Real SVG icons everywhere** — no emoji icons, crisp vector icons throughout
- **AMOLED dark + Day themes** — pure plain-black background in dark mode, one-tap toggle
- **Keyboard voting** — the whole ballot works with Tab / arrow keys / Enter, no mouse needed
- Winner highlight + animated result bars, confetti on successful vote
- **Conditional voter identity** — admin chooses which details voters must give: name, class, enrollment ID, ID-card photo, and mobile number (10 digits, validated server-side)
- **Hidden admin panel** — lives at `#/admin.html`; there is no link or hint anywhere in the voter UI. Sidebar sections: Overview, Elections, Candidates, Registrations, **Vote Audit**, Settings. Sticky on desktop, collapses to a top bar on mobile
- **Read-only vote audit** — admin can see exactly who voted for whom (voter identity, receipt, timestamp, Monitor + CR choice) to detect fake or multiple voting. Duplicate mobile numbers are flagged automatically, with search/filter and CSV export. Votes **cannot** be changed, deleted, or created from the admin panel — or anywhere else except one legitimate vote per verified voter
- **Universal responsive** — mobile, tablet, laptop, PC, TV

## Tech

- Vanilla HTML5 + CSS + JS — no build, served straight from GitHub Pages
- Talks to Supabase with `fetch` only (Auth REST + PostgREST RPC) — no JS library
- Pure CSS design system (`styles.css`) — no UI framework

## Setup (fresh Supabase project)

### 1. Run the database schema
- Supabase Dashboard → **SQL Editor** → paste the full content of `supabase/schema_full.sql` and **Run** it
- This creates: `elections`, `candidates`, `voter_registrations`, `votes`, `profiles`, `id_uploads`, `election_settings` tables + RLS policies + voter RPCs (`register_voter` / `request_id_upload_v2` / `confirm_id_upload_v2` / `cast_vote_v2` / `get_ballot` …) + admin RPCs (`admin_*`) + the private **`id-cards`** bucket
- **Existing database?** Don't re-run the whole schema — run `supabase/migration_v2.sql` through `migration_v7.sql` **in order**, one by one (all idempotent):
  - v2: auth-based voter accounts + registration flow
  - v3: ID upload slot fixes
  - v4: security hardening (v2 slots, opaque paths, admin RPCs)
  - v5: server-side ID enforcement + id_ready + vote idempotency
  - v6: mobile number (`phone`) + `require_phone` setting + read-only `admin_vote_audit()`
  - v7: revoke legacy token-based `cast_vote` so it can't be invoked via API by anyone

### 2. Create the admin account
- Dashboard → **Authentication → Users → Add user** → enter email + password
- Dashboard → **Authentication → Sign In / Providers → Email** → keep **"Allow new users to sign up" ON** — students sign up themselves; if it's OFF the whole voter flow stops working
- Don't worry: signing up can never make anyone an **admin** — `claim_first_admin()` is permanently disabled, there is no UPDATE policy on `profiles` (self-promotion impossible), and `is_admin = true` can only be set via the SQL Editor, which only you control
- Then run this in the **SQL Editor**:
  ```sql
  update profiles set is_admin = true where email = 'your-admin@email.com';
  ```
  (`claim_first_admin()` bootstrap is permanently disabled — the first admin is created via SQL only)

### 3. Put the keys in `config.js`
- Supabase Dashboard → **Project Settings → API**
- Paste `Project URL` → into `SUPABASE_URL`
- Paste the `Publishable` / `anon public` key → into `SUPABASE_ANON_KEY`
  (this is a public key — the frontend is where it belongs)
- **The service_role key is never used anywhere in this project — never paste it in the browser**

### 4. Deploy to GitHub Pages
- This repo's `main` branch is the source; `index.html` + `app.js` + `styles.css` + `config.js` live directly on the **gh-pages** branch
- Repo Settings → Pages → select the gh-pages branch — done, no build step

## Running an election

1. Open `#/admin` → log in with your **admin email + password**
2. **Create an election** → **add candidates** (Monitor / CR)
3. In **Registration Settings** you can turn **ID photo mandatory** ON (default OFF) — when ON, every voter must upload a school ID card photo before voting
4. If **Manual verification** is ON, the admin approves every registration; if OFF, voters auto-verify once their ID is OK
5. Press **Open voting**
6. Students **sign up** on the site and **register** for the election (if ID is mandatory: upload + confirm the ID photo first)
7. After voting, every student gets a **unique receipt (`XXXX-XXXX`)** — proof of voting
8. Voting over → **Close voting** → **Publish results**
9. If ID verification was ON, review the **uploaded ID cards** in the admin panel; press **Clean orphan uploads** from time to time to clear incomplete uploads

## Security notes (honest)

What's guaranteed:
- Two votes from one registration are **technically impossible** (row lock + UNIQUE constraint + single transaction)
- The anon key **cannot directly read or write any table** (RLS) — voting happens only through tightly-scoped RPCs
- **No browser-side master key for the admin** — login is via Supabase Auth, and every admin action runs only after a server-side `require_admin()` check
- If ID photo is mandatory, **admin approval without an ID upload is technically impossible** (server-side `id_upload_ready_v2()` check) — it cannot be bypassed from the browser
- ID card upload happens **only** when: the voter is logged in, voting is open, and the admin has turned ID verification ON. The upload path is random/unguessable. Image files only, max 6MB — this check lives in a **server-side (database function)**, not just the browser
- Malformed file metadata cannot cause server errors — safe casts are used
- ID photos and vote choices are stored in **separate tables**
- Results are visible only after the admin publishes them
- ID verification is **OFF by default**

What to keep in mind (inherent limits — no system can fully eliminate these):
- Keep **"Allow new users to sign up" ON** — turning it OFF stops students from signing up and halts the whole voter flow. Creating a new account never makes anyone an admin (`claim_first_admin()` is disabled and there is no UPDATE policy on `profiles`), so there's no need to keep signup OFF
- Press **Close voting** as soon as voting ends
- ID photos are students' personal documents — **empty the bucket** after the election (Supabase Dashboard → Storage → id-cards → delete). Set the retention policy per your school's rules
- Keep the admin password strong and don't share it

## Project structure

```
class-election/
├── index.html              # App shell (hash routes: #/ #/auth #/register #/vote #/receipt #/results #/admin)
├── app.js                  # The whole app — vanilla JS, fetch-only Supabase (Auth + RPC)
├── styles.css              # AMOLED dark + day themes, glassmorphism design system
├── config.js               # Supabase URL + anon key (you fill this in)
└── supabase/
    ├── schema_full.sql     # Fresh install: the entire backend in one file
    ├── schema.sql          # Base schema (v1/v2)
    ├── migration_v2.sql    # Auth-based voter accounts + registration flow
    ├── migration_v3.sql    # ID upload slot fixes
    ├── migration_v4.sql    # Security hardening (v2 slots, opaque paths, admin RPCs)
    └── migration_v5.sql    # Server-side ID enforcement + id_ready + vote idempotency
```
