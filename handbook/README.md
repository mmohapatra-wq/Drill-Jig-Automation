# handbook/ — the Drill-Jig handbook build

This folder builds the self-contained **Operator & Developer Handbook** (a single
`index.html`) and keeps it in sync with the code. The published copy lives in the
separate **`drilljig-handbook`** GitLab project, which serves it via GitLab Pages.

## What updates automatically vs. by hand

| Part of the handbook | Source | Refresh |
|---|---|---|
| Offline `drilljig-gui.zip`, toolkit zip, the 36 individual `.cmd` downloads, `DEVELOPMENT_SETUP.html`, tool catalog | the **live repo** | **automatic** — rebuilt on every run of `build.ps1` |
| The 22 wizard screenshots | rendering `drilljig-gui.cmd` via WinForms | **manual, Windows only** — `build.ps1 -Shots` (committed under `shots/`) |
| The written explanations (tab prose) | hand-authored (`parts/*.html`) | edited by a person when behavior changes |

## Rebuild it (one command)

```powershell
# Windows or Linux (pwsh) — rebuild everything from the current repo:
pwsh -File handbook/build.ps1                      # -> handbook/dist/index.html
pwsh -File handbook/build.ps1 -Out public/index.html -Sha abc1234   # CI form

# Windows only — also re-capture the wizard screenshots first:
powershell -File handbook\build.ps1 -Shots

# Rebuild AND publish straight to the drilljig-handbook repo (Pages redeploys) —
# one-command update using your local gitlab.blueorigin.com credentials:
powershell -File handbook\build.ps1 -Publish
powershell -File handbook\build.ps1 -Shots -Publish     # refresh screenshots too, then publish
```

`build.ps1` rebuilds both zips from the live repo (re-applying the launcher's two
offline patches so code changes flow through), embeds everything, writes `index.html`,
and runs sanity checks (fails loudly if a patch anchor drifted or a download is missing).

## Auto-publish on every change (CI)

`../.gitlab-ci.yml` has a `publish-handbook` job: on each push to the default branch it
runs `build.ps1` and pushes the fresh `index.html` into the `drilljig-handbook` repo,
whose own `pages` job then redeploys the site.

**One-time prerequisites for the CI to run + publish:**
1. The **code repo must be hosted on a GitLab instance you push to, with a runner**
   (Linux + Docker). `.gitlab-ci.yml` does nothing on GitHub.
2. A CI/CD variable **`HANDBOOK_PUSH_TOKEN`** (masked) in this project — a *Project
   Access Token* from `drilljig-handbook` with role **Maintainer** + scope
   **`write_repository`** (to push to its protected `main`).

If those aren't in place, use the one-command rebuild above and push `index.html` to
`drilljig-handbook/public/index.html` yourself — same result, just manual.

## Folder contents
- `shell.html`, `parts/tab1..4.html` — the page shell + the four tab fragments (authored).
- `shots/*.png` — the 22 committed wizard screenshots.
- `overlay/` — the two offline-patched infra files (`webview2_host.ps1`, `drilljig_3d_preview.html`).
- `vendor/` — the vendored WebView2 SDK + three.js needed to rebuild the offline zip.
- `data/` — the bushing catalogs (committed here because `*.csv` is gitignored repo-wide).
- `build.ps1`, `capture_shots.ps1` — the build + screenshot scripts.
- `dist/` — build output (gitignored).
