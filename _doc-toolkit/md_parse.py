"""
Parse one of this project's own Markdown docs (README.md / INTEGRATION-GUIDE.md /
docs/<Name>-PoC.md) into the same TITLE/SUBTITLE/META/BLOCKS content model that
Suricata-Wazuh-Windows-Kit/docs/source/content.py and guide_content.py hand-author
directly in Python -- so build_docx.py / build_pdf.py can render either a hand-written
content module OR a markdown file with no changes to the renderers themselves.

Relies on the house markdown convention used throughout this kit family:
  # Title                                   -> TITLE
  > Subtitle sentence                       -> SUBTITLE
  | **Key** | Value |  (a table, no ## yet)  -> META
  ## 1. Section                             -> ("h1", "1. Section")
  ### Subsection                            -> ("h2", "Subsection")
  fenced ``` code ```                       -> ("code", text)
  | col | col | ...   (table, after META)   -> ("table", ("", headers, rows, colw, ()))
  > **Label** ...  /  > text                -> ("note", (kind, label, text))
  - bullet / - **bold** bullet              -> ("bullets", [items])
  1. numbered item                          -> ("numbers", [items])
  plain paragraph lines                     -> ("p", text)
Not a general Markdown parser -- it only needs to handle what this project's own
docs actually contain, in the shape this project actually writes it.
"""
import re


class Doc:
    def __init__(self, title, subtitle, meta, blocks, eyebrow):
        self.TITLE = title
        self.SUBTITLE = subtitle
        self.META = meta
        self.BLOCKS = blocks
        self.EYEBROW = eyebrow


def _strip_bold(s):
    return re.sub(r"\*\*(.+?)\*\*", r"\1", s)


def _split_table_row(line):
    line = line.strip()
    if line.startswith("|"):
        line = line[1:]
    if line.endswith("|"):
        line = line[:-1]
    # naive split on unescaped pipes -- this project's tables don't use \| in cells
    return [c.strip() for c in line.split("|")]


def _is_sep_row(cells):
    return all(re.match(r"^:?-{2,}:?$", c.strip()) for c in cells if c.strip())


def _is_block_start(line):
    """True if this line starts a NEW block (heading/list/table/quote/fence),
    so a bullet/number item shouldn't swallow it as a wrapped continuation."""
    s = line.strip()
    return bool(
        re.match(r"^(#{2,4} |[-*] |\d+\. |> |\| |```)", s)
    )


def _note_kind(label, text):
    blob = f"{label} {text}".lower()
    if re.search(r"\b(critical|do not|dangerous|never)\b", blob):
        return "crit"
    if re.search(r"\b(warn|caution|risk|disk[- ]growth)\b", blob):
        return "warn"
    return "info"


def parse(path, eyebrow=None):
    with open(path, "r", encoding="utf-8") as f:
        lines = f.read().replace("\r\n", "\n").split("\n")

    i = 0
    n = len(lines)

    def peek():
        return lines[i] if i < n else None

    # ---- title ----
    title = None
    while i < n:
        if lines[i].startswith("# "):
            title = lines[i][2:].strip()
            i += 1
            break
        i += 1
    if title is None:
        title = "Untitled"

    # ---- subtitle (first blockquote right after the title) ----
    while i < n and lines[i].strip() == "":
        i += 1
    subtitle = ""
    if i < n and lines[i].startswith(">"):
        qlines = []
        while i < n and lines[i].startswith(">"):
            qlines.append(lines[i][1:].strip())
            i += 1
        subtitle = _strip_bold(" ".join(x for x in qlines if x))

    # ---- meta table (first table block before the first "## ") ----
    meta = []
    while i < n and lines[i].strip() == "":
        i += 1
    if i < n and lines[i].lstrip().startswith("|"):
        rows = []
        while i < n and lines[i].lstrip().startswith("|"):
            rows.append(_split_table_row(lines[i]))
            i += 1
        # rows[0] = header (ignored, it's "| | |"), rows[1] = separator, rest = data
        for r in rows[2:]:
            if len(r) >= 2:
                meta.append((_strip_bold(r[0]), _strip_bold(r[1])))

    # ---- body ----
    blocks = []
    para_buf = []

    def flush_para():
        if para_buf:
            text = " ".join(x.strip() for x in para_buf if x.strip())
            if text:
                blocks.append(("p", text))
            para_buf.clear()

    while i < n:
        line = lines[i]
        stripped = line.strip()

        if stripped == "":
            flush_para()
            i += 1
            continue

        if re.match(r"^-{3,}$", stripped):
            # a standalone "---" (markdown horizontal rule) -- headings
            # already render with their own accent-colored rule, so this is
            # a no-op rather than literal "---" text in the output.
            flush_para()
            i += 1
            continue

        if stripped.startswith("## "):
            flush_para()
            blocks.append(("h1", stripped[3:].strip()))
            i += 1
            continue

        if stripped.startswith("### "):
            flush_para()
            blocks.append(("h2", stripped[4:].strip()))
            i += 1
            continue

        if stripped.startswith("```"):
            flush_para()
            i += 1
            code_lines = []
            while i < n and not lines[i].strip().startswith("```"):
                code_lines.append(lines[i])
                i += 1
            i += 1  # skip closing fence
            blocks.append(("code", "\n".join(code_lines)))
            continue

        if stripped.startswith("|"):
            flush_para()
            rows = []
            while i < n and lines[i].strip().startswith("|"):
                rows.append(_split_table_row(lines[i]))
                i += 1
            if len(rows) >= 2 and _is_sep_row(rows[1]):
                headers = [_strip_bold(h) for h in rows[0]]
                data = [[_strip_bold(c) for c in r] for r in rows[2:]]
                ncols = len(headers)
                colw = [max(8, min(60, max([len(h)] + [len(r[ci]) if ci < len(r) else 0 for r in data]) ))
                        for ci, h in enumerate(headers)]
                blocks.append(("table", ("", headers, data, colw, ())))
            continue

        if stripped.startswith(">"):
            flush_para()
            qlines = []
            while i < n and lines[i].strip().startswith(">"):
                qtext = lines[i].strip()[1:].strip()
                qlines.append(qtext)
                i += 1
            joined = " ".join(x for x in qlines if x)
            m = re.match(r"^\*\*(.+?)\*\*[:\s]*(.*)$", joined)
            if m:
                label, text = m.group(1).strip(), m.group(2).strip()
            else:
                label, text = "Note", joined
            if not text:
                text = label
                label = "Note"
            blocks.append(("note", (_note_kind(label, text), label, text)))
            continue

        if re.match(r"^[-*] ", stripped):
            flush_para()
            items = []
            while i < n and re.match(r"^[-*] ", lines[i].strip()):
                items.append(lines[i].strip()[2:].strip())
                i += 1
                # absorb wrapped continuation lines (no marker of their own)
                while i < n and lines[i].strip() and not _is_block_start(lines[i]):
                    items[-1] += " " + lines[i].strip()
                    i += 1
            blocks.append(("bullets", items))
            continue

        if re.match(r"^\d+\. ", stripped):
            flush_para()
            items = []
            while i < n and re.match(r"^\d+\. ", lines[i].strip()):
                items.append(re.sub(r"^\d+\.\s*", "", lines[i].strip()))
                i += 1
                # absorb wrapped continuation lines (no marker of their own)
                while i < n and lines[i].strip() and not _is_block_start(lines[i]):
                    items[-1] += " " + lines[i].strip()
                    i += 1
            blocks.append(("numbers", items))
            continue

        # plain paragraph text
        para_buf.append(line)
        i += 1

    flush_para()

    if eyebrow is None:
        base = path.replace("\\", "/").rsplit("/", 1)[-1].upper()
        if "INTEGRATION-GUIDE" in base:
            eyebrow = "INTEGRATION GUIDE"
        elif "POC" in base:
            eyebrow = "PROOF OF CONCEPT"
        else:
            eyebrow = "WAZUH DEPLOYMENT TOOLKIT"

    return Doc(title, subtitle, meta, blocks, eyebrow)
