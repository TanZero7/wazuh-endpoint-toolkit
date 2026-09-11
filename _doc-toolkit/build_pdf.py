"""Render the shared content model to a PDF."""
import re, sys, html
from reportlab.lib.pagesizes import A4
from reportlab.lib.units import mm
from reportlab.lib import colors
from reportlab.lib.styles import ParagraphStyle
from reportlab.lib.enums import TA_LEFT, TA_CENTER
from reportlab.platypus import (BaseDocTemplate, PageTemplate, Frame, Paragraph, Spacer,
                                Table, TableStyle, Image, PageBreak, KeepTogether, Flowable)
from reportlab.pdfbase import pdfmetrics
from reportlab.pdfbase.ttfonts import TTFont

sys.path.insert(0, ".")
_src = sys.argv[2] if len(sys.argv) > 2 else 'content'
if _src.endswith('.md'):
    import md_parse
    _mod = md_parse.parse(_src, eyebrow=(sys.argv[3] if len(sys.argv) > 3 else None))
else:
    import importlib
    _mod = importlib.import_module(_src)
TITLE, SUBTITLE, META, BLOCKS = _mod.TITLE, _mod.SUBTITLE, _mod.META, _mod.BLOCKS
EYEBROW = getattr(_mod, 'EYEBROW', 'WAZUH DEPLOYMENT TOOLKIT')

# ---- fonts: use real Windows faces so the doc doesn't fall back to Helvetica ----
import os
WF = r"C:\Windows\Fonts"
def reg(name, fn):
    p = os.path.join(WF, fn)
    if os.path.exists(p):
        pdfmetrics.registerFont(TTFont(name, p)); return True
    return False
SERIF  = "Georgia"  if reg("Georgia", "georgia.ttf")   else "Times-Roman"
SERIFB = "GeorgiaB" if reg("GeorgiaB", "georgiab.ttf") else "Times-Bold"
MONO   = "Consola"  if reg("Consola", "consola.ttf")   else "Courier"
MONOB  = "ConsolaB" if reg("ConsolaB", "consolab.ttf") else "Courier-Bold"

# Registering a bold TTF is not enough on its own: the <b> inline tag resolves through
# the FONT FAMILY map, so without this every <b> silently renders at normal weight.
from reportlab.pdfbase.pdfmetrics import registerFontFamily
registerFontFamily(SERIF, normal=SERIF, bold=SERIFB, italic=SERIF, boldItalic=SERIFB)
registerFontFamily(MONO,  normal=MONO,  bold=MONOB,  italic=MONO,  boldItalic=MONOB)

ACCENT = colors.HexColor("#0A6C7E")
INK    = colors.HexColor("#0F171B")
INK2   = colors.HexColor("#51646D")
LINE   = colors.HexColor("#D3DDE1")
WARN   = colors.HexColor("#A85F09")
CRIT   = colors.HexColor("#A32A1C")

S = {
 "body":   ParagraphStyle("body", fontName=SERIF, fontSize=9.3, leading=13.6, textColor=INK,
                          spaceAfter=6, alignment=TA_LEFT),
 "h1":     ParagraphStyle("h1", fontName=MONOB, fontSize=14, leading=18, textColor=INK,
                          spaceBefore=16, spaceAfter=3),
 "h2":     ParagraphStyle("h2", fontName=MONOB, fontSize=10.5, leading=14, textColor=ACCENT,
                          spaceBefore=11, spaceAfter=3),
 "code":   ParagraphStyle("code", fontName=MONO, fontSize=7.6, leading=10.4,
                          textColor=colors.HexColor("#12222A"), backColor=colors.HexColor("#EEF3F4"),
                          borderPadding=(6,7,6,7), leftIndent=2, spaceBefore=4, spaceAfter=8),
 "cap":    ParagraphStyle("cap", fontName=MONO, fontSize=7.2, leading=9.5, textColor=INK2,
                          alignment=TA_CENTER, spaceAfter=10),
 "cell":   ParagraphStyle("cell", fontName=SERIF, fontSize=8.1, leading=11, textColor=INK),
 "cellm":  ParagraphStyle("cellm", fontName=MONO, fontSize=7.5, leading=10.4, textColor=INK),
 "th":     ParagraphStyle("th", fontName=MONOB, fontSize=7, leading=9.5,
                          textColor=colors.HexColor("#33444C")),
 "notel":  ParagraphStyle("notel", fontName=MONOB, fontSize=7.4, leading=10, spaceAfter=2),
 "notet":  ParagraphStyle("notet", fontName=SERIF, fontSize=8.8, leading=12.4, textColor=INK),
 "title":  ParagraphStyle("title", fontName=MONOB, fontSize=23, leading=26, textColor=INK, spaceAfter=6),
 "eyeb":   ParagraphStyle("eyeb", fontName=MONOB, fontSize=7.6, leading=10, textColor=ACCENT, spaceAfter=5),
 "sub":    ParagraphStyle("sub", fontName=SERIF, fontSize=10.5, leading=15, textColor=INK2, spaceAfter=10),
 "bullet": ParagraphStyle("bullet", fontName=SERIF, fontSize=9.1, leading=13, textColor=INK,
                          leftIndent=13, bulletIndent=3, spaceAfter=4),
}

INLINE = re.compile(r"(\*\*.+?\*\*|`[^`]+?`)")
def rich(text):
    """**bold** and `code` -> reportlab inline markup, everything else escaped."""
    out = []
    for part in INLINE.split(text):
        if not part: continue
        if part.startswith("**") and part.endswith("**"):
            out.append(f"<b>{html.escape(part[2:-2])}</b>")
        elif part.startswith("`") and part.endswith("`"):
            out.append(f'<font face="{MONO}" size="8" color="#0A6C7E">{html.escape(part[1:-1])}</font>')
        else:
            out.append(html.escape(part))
    return "".join(out)

class HRule(Flowable):
    def __init__(self, w, color=ACCENT, thick=1.2):
        Flowable.__init__(self); self.w, self.color, self.thick = w, color, thick
    def wrap(self, aw, ah): self.width = aw; return (aw, self.thick + 5)
    def draw(self):
        self.canv.setStrokeColor(self.color); self.canv.setLineWidth(self.thick)
        self.canv.line(0, 3, self.width, 3)

story = []
AVAIL = A4[0] - 36*mm

# ---- title block --------------------------------------------------------
story.append(Paragraph(EYEBROW, S["eyeb"]))
story.append(Paragraph(html.escape(TITLE), S["title"]))
story.append(Paragraph(html.escape(SUBTITLE), S["sub"]))
story.append(HRule(AVAIL, ACCENT, 1.4))
story.append(Spacer(1, 8))
if META:
    meta_rows = [[Paragraph(f"<b>{html.escape(k)}</b>", S["cellm"]),
                  Paragraph(html.escape(v), S["cellm"])] for k, v in META]
    mt = Table(meta_rows, colWidths=[35*mm, AVAIL - 35*mm])
    mt.setStyle(TableStyle([
        ("VALIGN", (0,0), (-1,-1), "TOP"),
        ("TOPPADDING", (0,0), (-1,-1), 1.5), ("BOTTOMPADDING", (0,0), (-1,-1), 1.5),
        ("LEFTPADDING", (0,0), (-1,-1), 0),
    ]))
    story.append(mt)
    story.append(Spacer(1, 12))

# ---- renderers ----------------------------------------------------------
def add_h1(t):
    story.append(Paragraph(html.escape(t), S["h1"]))
    story.append(HRule(AVAIL, ACCENT, 0.9))
    story.append(Spacer(1, 4))

def add_code(t):
    esc = html.escape(t).replace(" ", "&nbsp;").replace("\n", "<br/>")
    story.append(Paragraph(esc, S["code"]))

def add_note(kind, label, text):
    col = {"info": ACCENT, "warn": WARN, "crit": CRIT}[kind]
    bg  = {"info": "#E8F3F5", "warn": "#FBF2E3", "crit": "#FAEBE8"}[kind]
    lbl = ParagraphStyle("l", parent=S["notel"], textColor=col)
    inner = [Paragraph(html.escape(label.upper()), lbl), Paragraph(rich(text), S["notet"])]
    t = Table([[inner]], colWidths=[AVAIL])
    t.setStyle(TableStyle([
        ("BACKGROUND", (0,0), (-1,-1), colors.HexColor(bg)),
        ("LINEBEFORE", (0,0), (0,-1), 2.2, col),
        ("LEFTPADDING", (0,0), (-1,-1), 8), ("RIGHTPADDING", (0,0), (-1,-1), 8),
        ("TOPPADDING", (0,0), (-1,-1), 6), ("BOTTOMPADDING", (0,0), (-1,-1), 6),
    ]))
    story.append(Spacer(1, 3)); story.append(t); story.append(Spacer(1, 9))

# Monospace is declared per column in content.py rather than guessed per cell.
# Guessing produced visible inconsistency: prose like "DNS tunnelling / exfiltration
# shape" was rendered mono purely because it contained a slash, while neighbouring
# rows stayed serif.
def add_table(caption, headers, rows, colw, mono_cols=()):
    total = sum(colw)
    widths = [AVAIL * c / total for c in colw]
    data = [[Paragraph(html.escape(h.upper()), S["th"]) for h in headers]]
    for r in rows:
        cells = []
        for i, v in enumerate(r):
            v = str(v)
            style = S["cellm"] if i in mono_cols else S["cell"]
            txt = html.escape(v)
            if v in ("NO",): txt = f'<font color="#A32A1C"><b>{txt}</b></font>'
            elif v == "yes": txt = f"<b>{txt}</b>"
            cells.append(Paragraph(txt, style))
        data.append(cells)
    t = Table(data, colWidths=widths, repeatRows=1)
    t.setStyle(TableStyle([
        ("BACKGROUND", (0,0), (-1,0), colors.HexColor("#E2EAEC")),
        ("GRID", (0,0), (-1,-1), 0.4, LINE),
        ("VALIGN", (0,0), (-1,-1), "TOP"),
        ("TOPPADDING", (0,0), (-1,-1), 3.5), ("BOTTOMPADDING", (0,0), (-1,-1), 3.5),
        ("LEFTPADDING", (0,0), (-1,-1), 5), ("RIGHTPADDING", (0,0), (-1,-1), 5),
        ("ROWBACKGROUNDS", (0,1), (-1,-1), [colors.white, colors.HexColor("#F7FAFA")]),
    ]))
    story.append(t); story.append(Spacer(1, 9))

def add_bullets(items, numbered=False):
    for i, it in enumerate(items, 1):
        story.append(Paragraph(rich(it), S["bullet"],
                               bulletText=(f"{i}." if numbered else "\u2022")))
    story.append(Spacer(1, 4))

def add_image(path, caption):
    from PIL import Image as PILImage
    iw, ih = PILImage.open(path).size
    w = AVAIL; h = w * ih / iw
    story.append(Spacer(1, 4))
    story.append(Image(path, width=w, height=h))
    story.append(Spacer(1, 4))
    story.append(Paragraph(html.escape(caption), S["cap"]))

for kind, val in BLOCKS:
    if   kind == "h1":        add_h1(val)
    elif kind in ("h2","h3"): story.append(Paragraph(html.escape(val), S["h2"]))
    elif kind == "p":         story.append(Paragraph(rich(val), S["body"]))
    elif kind == "code":      add_code(val)
    elif kind == "note":      add_note(*val)
    elif kind == "table":     add_table(*val)
    elif kind == "bullets":   add_bullets(val)
    elif kind == "numbers":   add_bullets(val, True)
    elif kind == "image":     add_image(*val)
    elif kind == "pagebreak": story.append(PageBreak())

# ---- page furniture -----------------------------------------------------
def decorate(canv, doc_):
    canv.saveState()
    canv.setFont(MONO, 7); canv.setFillColor(INK2)
    canv.drawString(18*mm, 12*mm, TITLE)
    canv.drawRightString(A4[0] - 18*mm, 12*mm, f"{doc_.page}")
    canv.setStrokeColor(LINE); canv.setLineWidth(0.4)
    canv.line(18*mm, 15*mm, A4[0] - 18*mm, 15*mm)
    canv.restoreState()

out = sys.argv[1] if len(sys.argv) > 1 else "Suricata-Wazuh-PoC.pdf"
doc = BaseDocTemplate(out, pagesize=A4,
                      leftMargin=18*mm, rightMargin=18*mm, topMargin=17*mm, bottomMargin=20*mm,
                      title=TITLE, author="Suricata + Wazuh Windows Kit")
frame = Frame(doc.leftMargin, doc.bottomMargin, doc.width, doc.height, id="f")
doc.addPageTemplates([PageTemplate(id="main", frames=[frame], onPage=decorate)])
doc.build(story)
print("wrote", out)
