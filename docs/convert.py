"""Convert HELP.md into a chapter/section structure with HTML bodies."""
import re, html, json, sys

SRC = "/Users/koraybirand/Desktop/CNC G-Coder/HELP.md"

def slug(s):
    s = re.sub(r"[^\w\s-]", "", s.lower()).strip()
    return re.sub(r"[\s_]+", "-", s)[:60] or "section"

def inline(t):
    t = html.escape(t, quote=False)
    t = re.sub(r"`([^`]+)`", r"<code>\1</code>", t)
    t = re.sub(r"\*\*(.+?)\*\*", r"<strong>\1</strong>", t)
    t = re.sub(r"(?<![\w*])\*(?!\s)(.+?)(?<!\s)\*(?![\w*])", r"<em>\1</em>", t)
    # keyboard shortcuts: ⌘N, ⇧⌘O, ⌘, ⌘' ⌘. ⌘Z
    t = re.sub(r"([⌘⇧⌥⌃]+(?:[A-Z0-9]|,|\.|&#x27;|'|\?))(?![\w])", r"<kbd>\1</kbd>", t)
    t = t.replace(" — ", " <span class='dash'>—</span> ")
    return t

def blocks_to_html(lines):
    out, i = [], 0
    n = len(lines)
    while i < n:
        line = lines[i]
        if not line.strip():
            i += 1; continue
        if line.startswith("```"):
            buf = []; i += 1
            while i < n and not lines[i].startswith("```"):
                buf.append(lines[i]); i += 1
            i += 1
            out.append("<pre><code>" + html.escape("\n".join(buf)) + "</code></pre>")
            continue
        if line.startswith("|"):
            rows = []
            while i < n and lines[i].startswith("|"):
                cells = [c.strip() for c in lines[i].strip().strip("|").split("|")]
                if not all(re.fullmatch(r":?-+:?", c) for c in cells):
                    rows.append(cells)
                i += 1
            head, body = rows[0], rows[1:]
            out.append("<div class='table-wrap'><table><thead><tr>" + "".join(f"<th>{inline(c)}</th>" for c in head) + "</tr></thead><tbody>"
                       + "".join("<tr>" + "".join(f"<td>{inline(c)}</td>" for c in r) + "</tr>" for r in body) + "</tbody></table></div>")
            continue
        m = re.match(r"^(\d+)\.\s+(.*)", line)
        if m or line.startswith("- "):
            ordered = bool(m)
            items = []
            while i < n and (re.match(r"^\d+\.\s+", lines[i]) if ordered else lines[i].startswith("- ")):
                text = re.sub(r"^(\d+\.|-)\s+", "", lines[i]); i += 1
                cont = []
                while i < n and lines[i].startswith("  ") and lines[i].strip():
                    cont.append(lines[i].strip()); i += 1
                body = inline(text)
                if cont:
                    body += "<br>" + "<br>".join(inline(c) for c in cont)
                items.append(f"<li>{body}</li>")
                # blank line between items of the same list is allowed
                if i < n and not lines[i].strip() and i + 1 < n and (re.match(r"^\d+\.\s+", lines[i+1]) if ordered else lines[i+1].startswith("- ")):
                    i += 1
            tag = "ol" if ordered else "ul"
            out.append(f"<{tag}>" + "".join(items) + f"</{tag}>")
            continue
        # paragraph: gather until blank
        buf = []
        while i < n and lines[i].strip() and not lines[i].startswith(("```", "- ", "#", "|")) and not re.match(r"^\d+\.\s+", lines[i]):
            buf.append(lines[i].strip()); i += 1
        if buf:
            p = " ".join(buf)
            cls = ""
            if p.startswith("*(") and p.endswith(")*"):
                p = p[2:-2]; cls = " class='note'"
            out.append(f"<p{cls}>{inline(p)}</p>")
        else:
            i += 1
    return "\n".join(out)

def parse():
    text = open(SRC, encoding="utf-8").read().splitlines()
    title = text[0].lstrip("# ").strip()
    chapters, cur, sec, buf = [], None, None, []
    def flush():
        nonlocal buf
        h = blocks_to_html(buf); raw = "\n".join(buf).strip("\n"); buf = []
        if cur is None: return h
        if sec is not None: sec["html"] += h; sec["md"] += raw
        else: cur["intro"] += h; cur["md"] += raw
        return ""
    preamble = ""
    for line in text[1:]:
        if line.startswith("## "):
            pre = flush()
            if cur is None: preamble = pre
            t = line[3:].strip()
            cur = {"id": slug(t), "title": t, "intro": "", "md": "", "sections": []}
            chapters.append(cur); sec = None
        elif line.startswith("### "):
            flush()
            t = line[4:].strip()
            sec = {"id": cur["id"] + "-" + slug(t), "title": t, "html": "", "md": ""}
            cur["sections"].append(sec)
        else:
            buf.append(line)
    flush()
    return {"title": title, "preamble": preamble, "chapters": chapters}

if __name__ == "__main__":
    json.dump(parse(), open(sys.argv[1], "w"), ensure_ascii=False, indent=1)
