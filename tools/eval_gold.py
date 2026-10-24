"""Score the recognizer against the hand-checked gold set (tools/gold_label.py writes it).

Usage: python3 tools/eval_gold.py [variant ...]      (server must be running on 8776)
Variants: base = dictionary as the app sends it; ctx = base + the previous dictation(s) in the same app as
context; nohot = no dictionary. Default: base ctx.
Reports per variant: character error rate (CER) of the raw recognizer text and of the corrected text
(sound-alike fixes + learned rules), dictionary-word recall, and recognizer time.
Normalisation before scoring: punctuation, spaces and case ignored, 呃/嗯/额/唔 dropped, Chinese digits → 0-9.
"""
import base64, json, os, re, statistics, sys, urllib.request

D = os.path.expanduser("~/.config/zhiyu/")
POOL = D + "bench/gold_audio/"
OPENER = urllib.request.build_opener(urllib.request.ProxyHandler({}))
DIGITS = str.maketrans("零〇一二三四五六七八九两", "001234567892")


def norm(s):
    s = s.lower().translate(DIGITS)
    s = re.sub(r"[呃嗯额唔]", "", s)
    return re.sub(r"[\W_]+", "", s)


def edits(a, b):
    prev = list(range(len(b) + 1))
    for i, ca in enumerate(a, 1):
        cur = [i]
        for j, cb in enumerate(b, 1):
            cur.append(min(prev[j] + 1, cur[j - 1] + 1, prev[j - 1] + (ca != cb)))
        prev = cur
    return prev[-1]


def terms_like_app():
    lex = json.load(open(D + "lexicon.json", encoding="utf-8"))
    dic = [l.strip() for l in open(D + "dictionary.txt", encoding="utf-8") if l.strip() and not l.startswith("#")]
    hits = lex.get("term_hits", {})
    rest = sorted(enumerate(dic + lex.get("terms", [])), key=lambda x: (-hits.get(x[1], 0), x[0]))
    out = []
    for t in dic[-5:] + [t for _, t in rest]:
        if t not in out:
            out.append(t)
    return out, lex.get("corrections", [])


def apply_rules(text, corrections):
    for c in sorted(corrections, key=lambda c: -len(c.get("wrong", ""))):
        w, r = c.get("wrong", ""), c.get("right", "")
        if not w or any(u.lower() in text.lower() for u in c.get("unless") or []):
            continue
        pat = re.escape(w)
        if re.match(r"[A-Za-z0-9]", w[0]):
            pat = r"(?<![A-Za-z0-9])" + pat
        if re.match(r"[A-Za-z0-9]", w[-1]):
            pat += r"(?![A-Za-z0-9])"
        text = re.sub(pat, lambda _: r, text)
    return text


def contexts():
    """For each saved take: the text typed into the same app in the 3 minutes before it."""
    from datetime import datetime
    out, recent = {}, []
    for line in open(D + "history.jsonl", encoding="utf-8"):
        try:
            r = json.loads(line)
            t = datetime.fromisoformat(r["ts"].replace("Z", "+00:00")).timestamp()
        except (ValueError, KeyError):
            continue
        recent = [x for x in recent if t - x[0] < 180]
        if r.get("audio"):
            out[r["audio"]] = " ".join(x[2] for x in recent if x[1] == r.get("app"))[-200:]
        if r.get("clean"):
            recent.append((t, r.get("app"), r["clean"]))
    return out


def transcribe(wav, hotwords, context):
    h = {"Content-Type": "audio/wav"}
    if hotwords:
        h["X-Hotwords"] = base64.b64encode(json.dumps(hotwords, ensure_ascii=False).encode()).decode()
    if context:
        h["X-Context"] = base64.b64encode(context.encode()).decode()
    req = urllib.request.Request("http://127.0.0.1:8776/transcribe", data=wav, headers=h)
    return json.load(OPENER.open(req, timeout=120))


def main():
    variants = sys.argv[1:] or ["base", "ctx"]
    gold = [json.loads(l) for l in open(D + "bench/gold.jsonl", encoding="utf-8") if l.strip()]
    terms, corrections = terms_like_app()
    ctx = contexts()
    out_rows = []
    print(f"gold: {len(gold)} takes, {sum(g['dur'] for g in gold) / 60:.1f} min")
    for v in variants:
        e_raw = e_fix = n_chars = t_hit = t_all = 0
        ms = []
        for g in gold:
            wav = open(POOL + g["audio"], "rb").read()
            o = transcribe(wav, [] if v == "nohot" else terms, ctx.get(g["audio"], "") if v == "ctx" else "")
            fixed = apply_rules(o["text"], corrections)
            ref = norm(g["ref"])
            e_raw += edits(norm(o["raw"]), ref)
            e_fix += edits(norm(fixed), ref)
            n_chars += len(ref)
            ms.append(o["ms"])
            for t in terms:
                if len(t) >= 2 and t.lower() in g["ref"].lower():
                    t_all += 1
                    t_hit += t.lower() in fixed.lower()
            out_rows.append({"variant": v, "audio": g["audio"], "ref": g["ref"], "raw": o["raw"], "fixed": fixed, "ms": o["ms"]})
        ms.sort()
        print(f"{v:6s} CER raw {e_raw / n_chars:6.2%}  corrected {e_fix / n_chars:6.2%}  "
              f"dict words {t_hit}/{t_all}  ms p50 {ms[len(ms) // 2]} p90 {ms[int(len(ms) * 0.9)]}")
    with open(D + "bench/eval_gold.jsonl", "w", encoding="utf-8") as f:
        for r in out_rows:
            f.write(json.dumps(r, ensure_ascii=False) + "\n")


if __name__ == "__main__":
    main()
