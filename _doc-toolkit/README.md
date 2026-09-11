# Regenerating the kit docs (PDF + DOCX)

Shared tooling for every kit in `../`, pulled and adapted from
`Suricata-Wazuh-Windows-Kit/docs/source/` — same visual design system (colors,
typography, note callouts, tables), same renderers, so nothing looks like it
came from a different pipeline.

The one thing changed from the Suricata original: **the content model is
parsed straight out of each kit's own `INTEGRATION-GUIDE.md` and
`docs/<Name>-PoC.md`** (via `md_parse.py`) instead of being hand-written in a
separate `content.py`/`guide_content.py` per kit. Eleven kits × two documents
would mean maintaining 22 near-duplicate Python files in parallel with the
markdown that already says the same thing — a drift risk for no benefit.
Suricata's own `content.py`/`guide_content.py` still work unmodified if you'd
rather hand-author one (`build_docx.py`/`build_pdf.py` accept either a `.md`
path or a Python module name).

## Regenerate everything

```bash
pip install python-docx reportlab pymupdf
python build_all.py
```

Walks every kit folder under `../`, renders `INTEGRATION-GUIDE.md` and
`docs/*-PoC.md` (if present) to PDF + DOCX, and writes them into that kit's
own `docs/` folder using the same naming convention as the Suricata kit
(`<Base>-Integration-Guide.pdf/.docx`, `<Base>-PoC.pdf/.docx`).

## Regenerate one kit

```bash
python build_docx.py ../<Kit>/docs/<Base>-Integration-Guide.docx ../<Kit>/INTEGRATION-GUIDE.md "INTEGRATION GUIDE"
python build_pdf.py  ../<Kit>/docs/<Base>-Integration-Guide.pdf  ../<Kit>/INTEGRATION-GUIDE.md "INTEGRATION GUIDE"
python build_docx.py ../<Kit>/docs/<Base>-PoC.docx ../<Kit>/docs/<Base>-PoC.md "PROOF OF CONCEPT"
python build_pdf.py  ../<Kit>/docs/<Base>-PoC.pdf  ../<Kit>/docs/<Base>-PoC.md "PROOF OF CONCEPT"
```

The third argument is the EYEBROW text (top-left label) — optional, inferred
from the filename if omitted.

## Editing content

**Edit the markdown, not the PDF/DOCX** — same rule as the Suricata kit's own
`content.py`, just one level up: edit `INTEGRATION-GUIDE.md` or
`docs/<Name>-PoC.md`, then re-run the build for that kit (or `build_all.py`
for everything). The generated PDF/DOCX are build output, not source.

### What `md_parse.py` expects (the house convention every kit's docs follow)

```
# Title                          -> document title
> One-sentence subtitle          -> subtitle under the title
| **Key** | Value |               (a table right after the subtitle, before
|---|---|                         any ## heading) -> the meta info block
| **Key2** | Value2 |
## 1. Section                    -> top-level heading
### Subsection                   -> sub-heading
plain paragraph text             -> a paragraph (**bold**/`code` supported)
- bullet item                    -> bullet list (wrapped continuation lines
  continues here                    with no marker of their own are folded
                                     into the same item)
1. numbered item                 -> numbered list (same wrapping rule)
| Col | Col |                     -> a table (first row after the header
|---|---|                          separator becomes column headers)
| ... | ... |
```fenced code```                 -> a code block, monospace, shaded
> **Label**: explanation text    -> a callout box (info/warn/crit, guessed
                                     from the label/text - see _note_kind in
                                     md_parse.py)
```

Not a general-purpose Markdown parser — it only needs to handle what these
docs actually contain, in the shape they're actually written. If you add a
new kit's docs by hand rather than copying an existing one's structure,
loosely follow the shapes above and it'll render correctly.

## Known cosmetic gotchas (fixed once already, listed so they don't recur)

- **No Unicode arrows (→) or emoji (✅❌) in prose that gets rendered** — the
  registered TTF fonts (Georgia/Consolas) don't carry every glyph, and a
  missing one renders as an empty box ("tofu"). Use `->` and plain words
  ("yes"/"manual"/"failed") instead. Box-drawing characters (`│▼──►` etc.)
  inside fenced code blocks are fine — those render as literal monospace
  text, not through the font's normal glyph substitution path that broke on
  the inline case.
- **List items that wrap onto a second physical line in the markdown source**
  need no special handling — `md_parse.py` folds continuation lines (lines
  with no marker of their own) into the previous bullet/numbered item. If a
  numbered list renders as "1. / 1. / 1." instead of "1. / 2. / 3.", that's
  this rule not firing — check the continuation lines aren't accidentally
  starting with something that looks like a new block (`#`, `-`, a digit
  followed by `.`, `>`, `|`, or ` ``` `).
