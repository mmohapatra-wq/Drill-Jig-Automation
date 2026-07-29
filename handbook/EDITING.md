# Editing the Drill-Jig Handbook (no coding needed)

The handbook web page is **generated**. You edit small **source files**, then run one command to
rebuild it. Never edit the built page (`handbook\dist\index.html`) or the published copy on GitLab —
the build **overwrites** them every time, so any change made there is lost. Always edit the source
files listed below.

## Which file holds which text?

| What you see on the page | Edit this source file |
|---|---|
| Tab 1 content — **"Using the GUI"** | `handbook\parts\tab1.html` |
| Tab 2 content — **"Build & Develop"** | `handbook\parts\tab2.html` |
| Tab 3 content — **"Other Tools & Downloads"** | `handbook\parts\tab3.html` |
| Tab 4 content — **"Roadmap"** | `handbook\parts\tab4.html` |
| The **page title** (browser tab / big heading) | `handbook\shell.html` |
| The **four tab button labels** (Using the GUI / Build & Develop / …) | `handbook\shell.html` |
| The **footer** (authors, date line at the bottom) | `handbook\shell.html` |

## How to find the text

1. Open the right file (see the table) in Notepad, VS Code, or any text editor.
2. Press **Ctrl+F** and type a few exact words you see on the page (e.g. `Quick start`).
3. Edit only the words that sit **between** the HTML tags. The tag is the part inside `< >`.

**Example — change a heading.** To rename the "Quick start" heading to "Getting started":

```
<h2 class="sec">2. Quick start</h2>
```
change only the words, leaving the tags alone:
```
<h2 class="sec">2. Getting started</h2>
```

**Example — change a table cell.** A table row looks like this; edit the text inside each `<td>`:

```
<tr><td>Windows PowerShell</td><td>Runs the launcher and the GUI. Built into Windows.</td></tr>
```

**Example — change a tab label** (in `shell.html`):

```
<button class="tabbtn active" data-tab="use"><span class="n">1</span>Using the GUI</button>
```
edit only `Using the GUI` — leave `<span class="n">1</span>` and everything else as-is.

## DO NOT touch these (edit around them, never them)

If you change any of the following, downloads, images, or the build will break:

- Anything inside **`data-shot="..."`** — these name the screenshots (e.g. `data-shot="01-welcome.png"`).
- The id inside a **`dl('...')`** download button (e.g. `dl('pl_gui_zip')`) — it wires the button to its file.
- The comment markers **`<!--INCLUDE:tab1-->`** (and tab2/3/4) and **`<!--PAYLOADS-->`** in `shell.html` — the build fills these in.
- Any **`class="..."`** attribute (e.g. `class="callout warn"`, `class="card stepcard"`) — these control styling.
- The long **`<script type="application/octet-stream">`** blocks — these are the embedded downloads (base64). Leave them entirely alone.

You **can** freely change the plain words, table cells, list items, headings, and callout text.

## Preview your change

From the repo root, run:

```
powershell -File handbook\build.ps1
```

Then open `handbook\dist\index.html` in any web browser to check it. Repeat edit → build → refresh
until it looks right.

## Publish it live

When you're happy, publish:

```
powershell -File handbook\build.ps1 -Publish
```

This rebuilds **and** pushes to the `drilljig-handbook` GitLab repo; GitLab Pages then redeploys the
live site automatically (give it a minute or two).

Add **`-Shots`** *only if the wizard GUI itself changed* — it re-renders the screenshots and needs a
Windows machine:

```
powershell -File handbook\build.ps1 -Publish -Shots
```

If you only changed words, leave `-Shots` off — it's slower and unnecessary.

## Note: Tab 1 step numbering is hand-written

The step-by-step order and numbers on **Tab 1** (`tab1.html`) — the numbered step cards like
"1 Welcome", "11 Finish the box", etc. — are **hand-written prose**, not generated. The screenshots
refresh automatically with `-Shots`, **but the words do not**. If the wizard's sequence changes in the
code (a step added, removed, or reordered), you must edit those step blocks in `tab1.html` yourself so
the written steps match the new flow.
