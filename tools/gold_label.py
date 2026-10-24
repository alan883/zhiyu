"""Gold-set labeler: play saved takes in the browser, correct the text, save as the reference.

Picks up to N saved recordings from ~/.config/zhiyu/audio (spread over lengths), pre-fills each with
the text Zhiyu typed, and writes corrections to ~/.config/zhiyu/bench/gold.jsonl (the set and its audio are frozen in bench/gold_audio on first run). Run:
    python3 tools/gold_label.py [N]      then open http://127.0.0.1:8790
Keys: Cmd+Enter = save and next, Tab in the box = replay.
"""
import html, json, os, shutil, sys, wave
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import parse_qs, urlparse

D = os.path.expanduser("~/.config/zhiyu/")
GOLD = D + "bench/gold.jsonl"
N = int(sys.argv[1]) if len(sys.argv) > 1 else 100


def duration(path):
    try:
        with wave.open(path) as w:
            return w.getnframes() / w.getframerate()
    except Exception:
        return 0.0


def pick():
    rows = {}
    for line in open(D + "history.jsonl", encoding="utf-8"):
        try:
            r = json.loads(line)
        except ValueError:
            continue
        a = r.get("audio")
        if a and os.path.exists(D + "audio/" + a) and r.get("clean") and not str(r.get("swap", "")).startswith("command"):
            rows[a] = r
    items = [(a, r, duration(D + "audio/" + a)) for a, r in rows.items()]
    items = [x for x in items if x[2] >= 1.0]
    items.sort(key=lambda x: x[2])
    if len(items) > N:   # even spread over lengths: short, medium and long takes all count
        step = len(items) / N
        items = [items[int(i * step)] for i in range(N)]
    return [{"audio": a, "draft": r["clean"], "raw": r.get("raw", ""), "dur": round(d, 2)} for a, r, d in items]


POOL = D + "bench/gold_audio/"


def load_items():
    """The labeling set is fixed on first run and its audio copied out, because the app deletes old takes."""
    meta = POOL + "items.json"
    if os.path.exists(meta):
        return json.load(open(meta, encoding="utf-8"))
    items = pick()
    os.makedirs(POOL, exist_ok=True)
    for it in items:
        shutil.copy2(D + "audio/" + it["audio"], POOL + it["audio"])
    json.dump(items, open(meta, "w", encoding="utf-8"), ensure_ascii=False, indent=0)
    return items


ITEMS = load_items()


def done():
    out = {}
    if os.path.exists(GOLD):
        for line in open(GOLD, encoding="utf-8"):
            try:
                g = json.loads(line)
                out[g["audio"]] = g
            except (ValueError, KeyError):
                pass
    return out


PAGE = """<!doctype html><meta charset=utf-8><title>指语 · 标准答案</title>
<style>body{font:16px -apple-system;max-width:820px;margin:30px auto;color:#222}
textarea{width:100%;height:110px;font:18px -apple-system;padding:8px}
.m{color:#888;font-size:13px}button{font-size:15px;padding:6px 16px}</style>
<p class=m>第 {i}/{n} 条 · 已校对 {k} 条 · {dur} 秒</p>
<audio id=a src="/audio/{audio}" controls autoplay style="width:100%"></audio>
<p class=m>听录音，把下面文字改成你<b>实际说的话</b>（保留口头语也行，标点不计分）。</p>
<form method=post action="/save"><input type=hidden name=audio value="{audio}">
<input type=hidden name=i value="{i}"><textarea id=t name=ref autofocus>{draft}</textarea>
<p><button>保存，下一条（⌘↩）</button> <a href="/?i={prev}">上一条</a> · <a href="/?i={next}">跳过</a></p></form>
<p class=m>识别原文：{raw}</p>
<script>t.addEventListener('keydown',e=>{if(e.key=='Enter'&&e.metaKey){e.preventDefault();t.form.submit()}
if(e.key=='Tab'){e.preventDefault();a.currentTime=0;a.play()}});</script>"""


class H(BaseHTTPRequestHandler):
    def do_GET(self):
        u = urlparse(self.path)
        if u.path.startswith("/audio/"):
            name = os.path.basename(u.path)
            p = POOL + name
            if not os.path.exists(p):
                return self.send_error(404)
            data = open(p, "rb").read()
            self.send_response(200)
            self.send_header("Content-Type", "audio/wav")
            self.send_header("Content-Length", str(len(data)))
            self.end_headers()
            self.wfile.write(data)
            return
        g = done()
        q = parse_qs(u.query)
        if "i" in q:
            i = max(0, min(len(ITEMS) - 1, int(q["i"][0])))
        else:
            i = next((j for j, it in enumerate(ITEMS) if it["audio"] not in g), None)
            if i is None:
                return self._html(f"<p>全部 {len(ITEMS)} 条已校对完。结果在 {GOLD}</p>")
        it = ITEMS[i]
        draft = g.get(it["audio"], {}).get("ref", it["draft"])
        self._html(PAGE.replace("{i}", str(i + 1)).replace("{n}", str(len(ITEMS)))
                   .replace("{k}", str(len(g))).replace("{dur}", str(it["dur"])).replace("{audio}", it["audio"])
                   .replace("{draft}", html.escape(draft)).replace("{raw}", html.escape(it["raw"]))
                   .replace("{prev}", str(max(0, i - 1))).replace("{next}", str(i + 1)))

    def do_POST(self):
        body = parse_qs(self.rfile.read(int(self.headers.get("Content-Length", 0))).decode("utf-8"))
        audio, ref = body.get("audio", [""])[0], body.get("ref", [""])[0].strip()
        it = next((x for x in ITEMS if x["audio"] == audio), None)
        if it and ref:
            g = done()
            g[audio] = {"audio": audio, "ref": ref, "draft": it["draft"], "dur": it["dur"]}
            with open(GOLD + ".tmp", "w", encoding="utf-8") as f:
                for v in g.values():
                    f.write(json.dumps(v, ensure_ascii=False) + "\n")
            os.replace(GOLD + ".tmp", GOLD)
        self.send_response(303)
        self.send_header("Location", "/")
        self.end_headers()

    def _html(self, s):
        b = s.encode("utf-8")
        self.send_response(200)
        self.send_header("Content-Type", "text/html; charset=utf-8")
        self.send_header("Content-Length", str(len(b)))
        self.end_headers()
        self.wfile.write(b)

    def log_message(self, *a):
        pass


if __name__ == "__main__":
    print(f"{len(ITEMS)} takes · open http://127.0.0.1:8790", flush=True)
    ThreadingHTTPServer(("127.0.0.1", 8790), H).serve_forever()
