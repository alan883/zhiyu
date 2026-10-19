#!/usr/bin/env python3
"""Personal dictionary learner for the zhiyu dictation app (Python 3.12 stdlib only).

Run as `python -I learner.py`. Idempotent: consumes only rows past the cursors.
"""
import difflib
import functools
import json
import math
import os
import re
import subprocess
import sys
import tempfile
import time
import urllib.request
from collections import Counter
from datetime import datetime
from urllib.parse import urlsplit

D = os.path.expanduser("~/.config/zhiyu")
CONFIG_PATH = os.path.join(D, "config.json")
MODEL = "deepseek-v4.1-flash"
LLM_TIMEOUT_S = 120   # gemini-3.8-flash-high took 52 s for a 40-row batch (10-19)
MAX_BATCH = 40
MAX_TERMS = 300
MAX_CORRECTIONS = 300
PROMOTE_AT = 2
LOCK_STALE_S = 600
SEED_PATH = os.path.join(D, "seed_corpus.txt")
SEED_TTL_S = 24 * 3600
SOURCE_CAP = 400 * 1024
HISTORY_TAIL_LINES = 3000
SEED_TERM_CAP = 250
SEED_STOP = set("The This That With From Error True False None JSON HTTP HTTPS API URL And For Not Are You Was Use Set Get New".split())
SEED_FIXED = "指语 Zhiyu Typeless Handy"
TERM_RE = re.compile(r"[A-Za-z][A-Za-z0-9.+\-]*(?: [A-Z][A-Za-z0-9.+\-]*)?")
SECRET_RES = (
    re.compile(r"sk-[A-Za-z0-9_\-]{8,}"),
    re.compile(r"[A-Fa-f0-9]{24,}"),
    re.compile(r"(?i)(password|passwd|sudo -S|api[_-]?key|token)\S*\s*\S+"),
    re.compile(r"AKIA[0-9A-Z]{16}"),
    re.compile(r"ghp_[A-Za-z0-9]{20,}"),
    re.compile(r"xox[baprs]-\S+"),
    re.compile(r"AIza[0-9A-Za-z_\-]{20,}"),
)
VOCAB_MAX_LEN = 40
VOCAB_BAD_CHARS = "/\\@="
VOCAB_ENTROPY_MIN = 3.5
STOPWORDS = set("的了是我你他它这那有在和就也都吗呢吧啊")
CJK = "㐀-鿿"
TOKEN_RE = re.compile(r"[A-Za-z0-9]+(?:['’][A-Za-z]+)*|[" + CJK + r"]|\s+|.", re.S)

SYSTEM_PROMPT = """你是个人语音输入的词汇学习器。你要分析【同一位用户】的语音识别转写记录（raw=识别器原始输出，clean=润色后的文本），学习他个人的词汇。
输入是JSON：known_terms(已知词条)、known_corrections(已知纠错，[wrong,right]数组)、transcripts(新的转写对)。
只输出一个JSON对象，格式：{"terms":["..."],"corrections":[{"wrong":"...","right":"...","why":"..."}]}
- terms：用户明显在使用的专有名词、产品名、行业术语，保持原始大小写。
- corrections：识别器的错误。wrong 是 right 的错误转写（同音、近音、品牌名被听错）。只有从上下文确信时才给。
- 绝不要纠正在其他语境下也正常的词（例如不要把 Python 映射成 Pi）。不要收录普通词汇。
- 没有就输出空数组。只输出JSON，不要解释。
reference_vocab and the user's typed text are ground truth spellings. A correction's `right` MUST be a spelling the user actually uses (from reference_vocab, known_terms, or clearly a standard spelling of a well-known product/term). Never output a misrecognized form as a term. If unsure, omit."""


# ---------- file helpers ----------

def read_jsonl(path):
    """One entry per complete line: dict, or None if malformed. Partial last line is ignored."""
    try:
        with open(path, encoding="utf-8", errors="replace") as f:
            pieces = f.read().split("\n")
    except FileNotFoundError:
        return []
    rows = []
    for line in pieces[:-1]:
        try:
            obj = json.loads(line)
        except ValueError:
            obj = None
        rows.append(obj if isinstance(obj, dict) else None)
    return rows


def str_field(row, key):
    value = row.get(key) if isinstance(row, dict) else None
    return value if isinstance(value, str) else ""


def load_dictionary(path):
    try:
        with open(path, encoding="utf-8") as f:
            lines = f.read().splitlines()
    except FileNotFoundError:
        return set()
    terms = set()
    for line in lines:
        s = line.strip()
        if s and not s.startswith("#"):
            terms.add(s)
    return terms


def fresh_lexicon():
    return {"version": 2, "terms": [], "corrections": [], "pending": [], "term_hits": {}, "candidates": {},
            "rejected": {"terms": [], "corrections": []},
            "cursor": {"history": 0, "edits": 0, "claude_bytes": None, "polish": 0, "redo": 0}, "updated": None}


def rejected_sets(lex):
    """(rejected terms, rejected (wrong, right) pairs) — items the user deleted from the dictionary UI."""
    rej = lex.get("rejected") if isinstance(lex.get("rejected"), dict) else {}
    terms = {t for t in rej.get("terms") or [] if isinstance(t, str)}
    pairs = {(c.get("wrong"), c.get("right")) for c in rej.get("corrections") or [] if isinstance(c, dict)}
    return terms, pairs


def load_lexicon(path):
    try:
        with open(path, encoding="utf-8") as f:
            data = json.load(f)
    except FileNotFoundError:
        return fresh_lexicon()
    except ValueError:
        data = None
    if not isinstance(data, dict):
        os.replace(path, f"{path}.corrupt-{int(time.time())}")
        return fresh_lexicon()
    lex = fresh_lexicon()
    lex.update(data)
    cur = lex["cursor"] if isinstance(lex["cursor"], dict) else {}
    cb = cur.get("claude_bytes")
    lex["cursor"] = {"history": int(cur.get("history", 0)), "edits": int(cur.get("edits", 0)),
                     "claude_bytes": cb if isinstance(cb, int) and not isinstance(cb, bool) else None,
                     "polish": int(cur.get("polish", 0)), "redo": int(cur.get("redo", 0))}
    if not isinstance(lex["terms"], list):
        lex["terms"] = []
    if not isinstance(lex["corrections"], list):
        lex["corrections"] = []
    if not isinstance(lex["candidates"], dict):
        lex["candidates"] = {}
    rej = lex["rejected"] if isinstance(lex["rejected"], dict) else {}
    lex["rejected"] = {"terms": rej.get("terms") if isinstance(rej.get("terms"), list) else [],
                       "corrections": rej.get("corrections") if isinstance(rej.get("corrections"), list) else []}
    if not isinstance(lex.get("pending"), list):
        lex["pending"] = []
    if not isinstance(lex.get("term_hits"), dict):
        lex["term_hits"] = {}
    if not isinstance(data.get("version"), int) or data["version"] < 2:
        # v2: a correction is a silent, global text replacement, so only rules the user confirmed may be one.
        # Rules learned before v2 by the LLM or from polish go back to the review queue.
        keep = []
        for c in lex["corrections"]:
            if isinstance(c, dict) and c.get("source") in ("llm", "polish", "redo"):
                lex["pending"].append({"wrong": c.get("wrong"), "right": c.get("right"),
                                       "hits": c.get("hits", 1), "source": c.get("source")})
            else:
                keep.append(c)
        lex["corrections"] = keep
        lex["version"] = 2
    return lex


def merge_user_changes(path, lex):
    """The app edits lexicon.json while a learner run (up to ~1 min with the LLM) holds an older copy.
    The user's decisions win: rules and rejections made meanwhile are kept, and confirmed or rejected
    pairs leave the pending queue."""
    try:
        with open(path, encoding="utf-8") as f:
            disk = json.load(f)
    except (OSError, ValueError):
        return
    if not isinstance(disk, dict):
        return
    if isinstance(disk.get("corrections"), list):
        mine = {(c.get("wrong"), c.get("right")) for c in lex["corrections"]}
        for c in disk["corrections"]:
            if isinstance(c, dict) and c.get("confirmed") and (c.get("wrong"), c.get("right")) not in mine:
                lex["corrections"].append(c)
        # unless lists are edited in the app only
        unl = {(c.get("wrong"), c.get("right")): c.get("unless") for c in disk["corrections"]
               if isinstance(c, dict) and c.get("unless")}
        for c in lex["corrections"]:
            if (c.get("wrong"), c.get("right")) in unl:
                c["unless"] = unl[(c.get("wrong"), c.get("right"))]
    rej = disk.get("rejected") if isinstance(disk.get("rejected"), dict) else {}
    for key in ("terms", "corrections"):
        for item in rej.get(key) or []:
            if item not in lex["rejected"][key]:
                lex["rejected"][key].append(item)
    rej_pairs = rejected_sets(lex)[1]
    lex["corrections"] = [c for c in lex["corrections"] if (c.get("wrong"), c.get("right")) not in rej_pairs]
    rules = {(c.get("wrong"), c.get("right")) for c in lex["corrections"]}
    lex["pending"] = [c for c in lex["pending"] if (c.get("wrong"), c.get("right")) not in rules | rej_pairs]
    rej_terms = rejected_sets(lex)[0]
    lex["terms"] = [t for t in lex["terms"] if t not in rej_terms]


def write_lexicon(path, lex):
    merge_user_changes(path, lex)
    fd, tmp = tempfile.mkstemp(dir=os.path.dirname(path), prefix=".lexicon-", suffix=".tmp")
    try:
        with os.fdopen(fd, "w", encoding="utf-8") as f:
            json.dump(lex, f, ensure_ascii=False, indent=2)
            f.flush()
            os.fsync(f.fileno())
        os.replace(tmp, path)
    except BaseException:
        if os.path.exists(tmp):
            os.unlink(tmp)
        raise


def append_log(path, stamp, added_terms, added_corr, n_cand, err, seed_n=None, claude_n=None, note=None):
    parts = [stamp,
             "+terms[" + ", ".join(added_terms) + "]",
             "+corr[" + ", ".join(added_corr) + "]",
             f"cand={n_cand}"]
    if claude_n is not None:
        parts.append(f"claude={claude_n}")
    if seed_n is not None:
        parts.append(f"seed={seed_n}")
    if note:
        parts.append(note)
    if err:
        parts.append(f"ERR[{err}]")
    with open(path, "a", encoding="utf-8") as f:
        f.write(" ".join(parts) + "\n")


# ---------- lock ----------

def _try_create_lock(path):
    try:
        fd = os.open(path, os.O_CREAT | os.O_EXCL | os.O_WRONLY, 0o644)
    except FileExistsError:
        return False
    os.write(fd, str(os.getpid()).encode())
    os.close(fd)
    return True


def acquire_lock(path):
    if _try_create_lock(path):
        return True
    try:
        age = time.time() - os.path.getmtime(path)
    except FileNotFoundError:
        return _try_create_lock(path)
    if age < LOCK_STALE_S:
        return False
    release_lock(path)
    return _try_create_lock(path)


def release_lock(path):
    try:
        os.unlink(path)
    except FileNotFoundError:
        pass


# ---------- acceptance guards ----------

def is_valid_side(s):
    return 1 <= len(s) <= 12


def is_meaningful(s):
    return re.search(r"[\w" + CJK + "]", s) is not None


def is_term_like(s):
    return re.search(r"[A-Za-z]", s) is not None or re.fullmatch("[" + CJK + "]{2,6}", s) is not None


def term_ok(t):
    return 2 <= len(t) <= 40 and t not in STOPWORDS and not t.isspace() and "\n" not in t and t == t.strip()


def trusted_terms(lex, dict_terms):
    return list(dict_terms) + lex["terms"]


def correction_allowed(wrong, right, lex, dict_terms):
    if not wrong or not right or wrong == right:
        return False
    if wrong in STOPWORDS or wrong in dict_terms:
        return False
    return not any(wrong in t for t in trusted_terms(lex, dict_terms))


CJK_RE_CLASS = "[\u4e00-\u9fff]"


def add_correction(lex, wrong, right, source, hits, dict_terms):
    """Queues wrong→right for the user to confirm (lexicon "pending"); the app turns a confirmed pair into a rule.
    Returns True if a new pending entry was created. A pair that is already a rule only gets its hits bumped."""
    if re.sub(r"\s+", "", wrong) == re.sub(r"\s+", "", right) or "\n" in wrong or "\n" in right:
        return False  # whitespace/soft-wrap differences are not recognition errors
    if (wrong, right) in rejected_sets(lex)[1]:
        return False  # user deleted this pair
    # Chinese -> English rewrites ("麦克风→Mac") are too easy to hallucinate: only the user's own edits may teach them
    if source != "edit" and re.search(CJK_RE_CLASS, wrong) and not re.search(CJK_RE_CLASS, right):
        return False
    if not correction_allowed(wrong, right, lex, dict_terms):
        return False
    for c in lex["corrections"]:
        if c.get("wrong") == wrong and c.get("right") == right:
            c["hits"] = c.get("hits", 0) + hits
            return False
    for c in lex["pending"]:
        if c.get("wrong") == wrong and c.get("right") == right:
            c["hits"] = c.get("hits", 0) + hits
            return False
    lex["pending"].append({"wrong": wrong, "right": right, "hits": hits, "source": source})
    return True


def suggest_term_only(lex, right, dict_terms):
    """AI-made fixes (LLM pass, cloud polish) never become rules: OpenLess #917 saw such rules loop and misfire.
    Only the corrected word is kept, as a hint term."""
    if is_term_like(right) and term_ok(right) and add_term(lex, right, dict_terms):
        return [right]
    return []


def add_term(lex, term, dict_terms):
    if term in lex["terms"] or term in dict_terms or term in rejected_sets(lex)[0]:
        return False
    lex["terms"].append(term)
    return True


# ---------- seed corpus (local ground truth: text the user typed or curated) ----------

def read_tail(path):
    """Last SOURCE_CAP bytes of a file, decoded leniently."""
    with open(path, "rb") as f:
        size = f.seek(0, os.SEEK_END)
        f.seek(max(0, size - SOURCE_CAP))
        return f.read().decode("utf-8", errors="ignore")


def safe_tail(path):
    try:
        return read_tail(path)
    except OSError:
        return ""


def cap_text(text):
    return text.encode("utf-8")[-SOURCE_CAP:].decode("utf-8", errors="ignore")


def history_displays():
    # the last piece is either empty or a partial line still being appended; the first line may be cut mid-row
    lines = safe_tail(os.path.expanduser("~/.claude/history.jsonl")).split("\n")[:-1]
    out = []
    for line in lines[-HISTORY_TAIL_LINES:]:
        try:
            obj = json.loads(line)
        except ValueError:
            continue
        if isinstance(obj, dict) and isinstance(obj.get("display"), str):
            out.append(obj["display"])
    return "\n".join(out)


def config_seed_text():
    """User-curated text from config.json "seed_paths": files, or directories read for *.md/*.txt (non-recursive)."""
    paths = read_config().get("seed_paths")
    if not isinstance(paths, list):
        return ""
    chunks = []
    for raw in paths:
        if not isinstance(raw, str) or not raw.strip():
            continue
        p = os.path.expanduser(raw.strip())
        if os.path.isdir(p):
            try:
                names = sorted(n for n in os.listdir(p) if n.endswith((".md", ".txt")))
            except OSError:
                continue
            chunks += [safe_tail(os.path.join(p, n)) for n in names]
        else:
            chunks.append(safe_tail(p))
    return "\n".join(chunks)


def app_names():
    try:
        return [n[:-4] for n in os.listdir("/Applications") if n.endswith(".app")]
    except OSError:
        return []


def dictionary_text():
    return safe_tail(os.path.join(D, "dictionary.txt"))


# Only curated text counts as ground truth. ~/.claude/history.jsonl is NOT used: much of it was itself
# dictated, so it contains exactly the misrecognitions we are trying to fix (they would verify themselves).
SEED_SOURCES = (
    config_seed_text,
    lambda: "\n".join(app_names()),
    dictionary_text,
    lambda: SEED_FIXED,
)


def gather(fn):
    try:
        return cap_text(fn())
    except Exception:
        return ""


def sanitize(text):
    kept = [ln for ln in text.splitlines() if not ("echo" in ln and "| sudo" in ln)]
    out = "\n".join(kept)
    for rx in SECRET_RES:
        out = rx.sub("", out)
    return out


def write_text(path, text):
    fd, tmp = tempfile.mkstemp(dir=os.path.dirname(path), prefix=".seed-", suffix=".tmp")
    try:
        with os.fdopen(fd, "w", encoding="utf-8") as f:
            f.write(text)
        os.replace(tmp, path)
    except BaseException:
        if os.path.exists(tmp):
            os.unlink(tmp)
        raise


def seed_cache_fresh():
    try:
        return time.time() - os.path.getmtime(SEED_PATH) < SEED_TTL_S
    except OSError:
        return False


def build_seed_corpus():
    if seed_cache_fresh():
        with open(SEED_PATH, encoding="utf-8", errors="ignore") as f:
            return f.read()
    text = sanitize("\n".join(gather(fn) for fn in SEED_SOURCES))
    try:
        write_text(SEED_PATH, text)
    except OSError:
        pass
    return text


def seed_terms(corpus):
    apps = set(app_names())
    always = apps | load_dictionary(os.path.join(D, "dictionary.txt"))
    freq = Counter(TERM_RE.findall(corpus))
    cands = {t for t, n in freq.items()
             if t not in SEED_STOP and len(t) >= 3 and n >= 2
             and (re.search(r"[A-Z0-9]", t) or t in apps)}
    cands |= always
    ranked = sorted(cands, key=lambda t: (t not in always, -freq[t], t))
    return ranked[:SEED_TERM_CAP]


def in_seed(s, seed_lower):
    """Case-insensitive. Latin/digit terms must match as whole words ('Pi' misses 'api'); CJK is exact substring."""
    if re.search(r"[A-Za-z0-9]", s) is None:
        return s.lower() in seed_lower
    pattern = r"(?<![A-Za-z0-9])" + re.escape(s) + r"(?![A-Za-z0-9])"
    return re.search(pattern, seed_lower, re.IGNORECASE) is not None


def typed_as_word(wrong, seed_lower):
    """True if the user typed `wrong` as a standalone word (Latin) or anywhere (CJK)."""
    return in_seed(wrong, seed_lower)


def build_context(history):
    corpus = build_seed_corpus()
    raws = {r["raw"] for r in history if isinstance(r, dict) and isinstance(r.get("raw"), str)}
    return {"lower": corpus.lower(), "vocab": seed_terms(corpus), "raws": raws}


def verified_term(term, ctx):
    return in_seed(term, ctx["lower"])


def verified_pair(wrong, right, ctx, lex, dict_terms):
    right_ok = in_seed(right, ctx["lower"]) or right in trusted_terms(lex, dict_terms)
    return right_ok and not typed_as_word(wrong, ctx["lower"])


def candidate_ok(key, ctx, lex, dict_terms):
    rej_terms, rej_pairs = rejected_sets(lex)
    if key.startswith("term:"):
        term = key[len("term:"):]
        return term not in rej_terms and verified_term(term, ctx)
    if key.startswith("edit:"):
        # counted only after the edit gate passed; the user's own hand-fixes are ground truth
        wrong, _, right = key[len("edit:"):].partition("→")
        return "→" in key and (wrong, right) not in rej_pairs
    if key.startswith(("polish:", "redo:")):
        # counted by polish_pass / redo_pass after their gates; no seed check, same as edit: pairs
        wrong, sep, right = key.partition(":")[2].partition("→")
        return bool(sep) and (wrong, right) not in rej_pairs
    wrong, sep, right = key.partition("→")
    return bool(sep) and (wrong, right) not in rej_pairs and verified_pair(wrong, right, ctx, lex, dict_terms)


def purge_unverified(lex, ctx, dict_terms):
    # the user's own hand-fixes are ground truth even if the spelling never appears in the seed corpus
    rej_terms, rej_pairs = rejected_sets(lex)
    edit_rights = {c.get("right") for c in lex["corrections"] if c.get("source") == "edit" or c.get("confirmed")}
    lex["terms"] = [t for t in lex["terms"] if isinstance(t, str) and t not in rej_terms
                    and (t in edit_rights or verified_term(t, ctx))]
    lex["candidates"] = {k: n for k, n in lex["candidates"].items() if candidate_ok(k, ctx, lex, dict_terms)}
    lex["corrections"] = [c for c in lex["corrections"]
                          if isinstance(c.get("wrong"), str) and isinstance(c.get("right"), str)
                          and (c["wrong"], c["right"]) not in rej_pairs
                          and (c.get("source") == "edit" or c.get("confirmed") or verified_pair(c["wrong"], c["right"], ctx, lex, dict_terms))]


def shannon_entropy(s):
    n = len(s)
    return -sum(c / n * math.log2(c / n) for c in Counter(s).values())


def vocab_token_ok(tok):
    """Reject anything that could be a secret, path, or identifier before it leaves the machine."""
    if len(tok) > VOCAB_MAX_LEN or any(ch in tok for ch in VOCAB_BAD_CHARS):
        return False
    if re.search(r"\d{5}", tok) or any(rx.search(tok) for rx in SECRET_RES):
        return False
    mixed_alnum = re.fullmatch(r"[A-Za-z0-9]+", tok) and re.search(r"[A-Za-z]", tok) and re.search(r"[0-9]", tok)
    if len(tok) >= 20 and mixed_alnum and shannon_entropy(tok) >= VOCAB_ENTROPY_MIN:
        return False
    return True


def cloud_vocab(tokens):
    """Only short vocabulary tokens reach the cloud; corpus text itself never does."""
    return [t for t in dict.fromkeys(tokens) if vocab_token_ok(t)]


# ---------- edits pass (high trust, no LLM) ----------

@functools.lru_cache(maxsize=1)
def load_phonetic():
    """The sibling phonetic.py module, or None if it cannot be imported."""
    here = os.path.dirname(os.path.abspath(__file__))
    if here not in sys.path:
        sys.path.insert(0, here)
    try:
        import phonetic
    except Exception:
        return None
    return phonetic


def looks_misheard(wrong, right):
    """Wrong is a plausible mis-hearing of right, not a rewrite of the sentence."""
    if re.search("[" + CJK + "]", wrong + right):
        ph = load_phonetic()
        if ph is None:
            return difflib.SequenceMatcher(None, wrong, right).ratio() >= 0.5
        _, events = ph.corrector_for((right,)).correct(wrong)
        return any(ev.get("action") in ("replace", "suggest") for ev in events)
    return difflib.SequenceMatcher(None, wrong.lower(), right.lower()).ratio() >= 0.5


def edit_pair_plausible(wrong, right):
    if not (is_valid_side(wrong) and is_valid_side(right)) or wrong == right:
        return False
    if not 0.5 <= len(right) / len(wrong) <= 2.0:
        return False
    return looks_misheard(wrong, right)


def tokenize(text):
    return TOKEN_RE.findall(text)


def is_word(tok):
    return re.search(r"[A-Za-z0-9" + CJK + "]", tok) is not None


def is_cjk_char(c):
    return re.fullmatch("[" + CJK + "]", c) is not None


def _latin_term_pair(inserted, final, sa, sb, ops, start, end):
    """Aligned token span of `inserted` for final[start:end] (Latin term), or None."""
    j_lo = next((j for j, (s, e) in enumerate(sb) if e > start), None)
    j_hi = next((j for j in range(len(sb) - 1, -1, -1) if sb[j][0] < end), None)
    if j_lo is None or j_hi is None or j_hi < j_lo:
        return None
    i_lo = i_hi = None
    for tag, i1, i2, j1, j2 in ops:
        if i_lo is None and j1 <= j_lo < j2:
            i_lo = i1 + (j_lo - j1) if tag == "equal" else i1
        if j1 <= j_hi < j2:
            i_hi = (i1 + (j_hi - j1) if tag == "equal" else i2 - 1) + 1
    if i_lo is None or i_hi is None or i_hi <= i_lo:
        return None
    return inserted[sa[i_lo][0]:sa[i_hi - 1][1]]


def _term_pair(inserted, final, sa, sb, ops, known, cws, cwe, crs, cre):
    """(wrong, right) with right = the longest known term overlapping the core in final."""
    for k in known:  # longest first
        start = final.find(k)
        while start != -1:
            end = start + len(k)
            overlap = (start < cre and end > crs) or (crs == cre and start <= crs < end)
            latin = re.match(r"[A-Za-z0-9]", k[0]) is not None
            bounded = not latin or not (
                (start > 0 and re.match(r"[A-Za-z0-9]", final[start - 1]))
                or (end < len(final) and re.match(r"[A-Za-z0-9]", final[end])))
            if overlap and bounded:
                if re.search("[" + CJK + "]", k):
                    ws_ = cws + (start - crs)
                    wrong = inserted[ws_:ws_ + len(k)] if ws_ >= 0 else ""
                    if len(wrong) == len(k):
                        return wrong, k
                else:
                    wrong = _latin_term_pair(inserted, final, sa, sb, ops, start, end)
                    if wrong:
                        return wrong, k
            start = final.find(k, start + 1)
    return None


def replace_pairs(inserted, final, known=(), corpus=""):
    """Yield canonical (wrong, right) for each 'replace' span of a token-level diff.

    Each replace span is first cut to its minimal core (common prefix/suffix stripped).
    The core is then expanded to a known term (K) that overlaps it in the final text;
    failing that, a single-char CJK core takes one equal CJK neighbour on the right,
    else on the left. So the same correction yields the same key in every sentence.
    """
    sa, sb = [m.span() for m in TOKEN_RE.finditer(inserted)], [m.span() for m in TOKEN_RE.finditer(final)]
    a, b = tokenize(inserted), tokenize(final)
    ops = difflib.SequenceMatcher(None, a, b, autojunk=False).get_opcodes()
    known = sorted({k for k in known if isinstance(k, str) and k and k == k.strip()},
                   key=len, reverse=True)
    for tag, i1, i2, j1, j2 in ops:
        if tag != "replace":
            continue
        ws, we = sa[i1][0], sa[i2 - 1][1]
        rs, re_ = sb[j1][0], sb[j2 - 1][1]
        wraw, rraw = inserted[ws:we], final[rs:re_]
        m = min(len(wraw), len(rraw))
        p = 0
        while p < m and wraw[p] == rraw[p]:
            p += 1
        s = 0
        while s < m - p and wraw[-1 - s] == rraw[-1 - s]:
            s += 1
        # never cut inside a Latin word: Cloud→Claude must not become oud→aude
        def alnum(t, k):
            return 0 <= k < len(t) and re.match(r"[A-Za-z0-9]", t[k]) is not None
        while p > 0 and alnum(wraw, p - 1) and (alnum(wraw, p) or alnum(rraw, p)):
            p -= 1
        while s > 0 and alnum(wraw, len(wraw) - s) and (alnum(wraw, len(wraw) - s - 1) or alnum(rraw, len(rraw) - s - 1)):
            s -= 1
        cws, cwe, crs, cre = ws + p, we - s, rs + p, re_ - s
        wc, rc = inserted[cws:cwe], final[crs:cre]
        pair = _term_pair(inserted, final, sa, sb, ops, known, cws, cwe, crs, cre)
        if pair is None and len(wc) == 1 and len(rc) == 1 and is_cjk_char(wc) and is_cjk_char(rc):
            options = []
            if cre < len(final) and cwe < len(inserted) and final[cre] == inserted[cwe] and is_cjk_char(final[cre]):
                options.append((wc + final[cre], rc + final[cre]))
            if crs > 0 and cws > 0 and final[crs - 1] == inserted[cws - 1] and is_cjk_char(final[crs - 1]):
                options.append((inserted[cws - 1] + wc, final[crs - 1] + rc))
            # prefer the expansion that is a word the user actually uses (子语→指语, not 语的→语的)
            options.sort(key=lambda o: o[1] not in corpus)
            pair = options[0] if options else None
        if pair is None:
            pair = (wc, rc)
        yield pair[0].strip(), pair[1].strip()


def process_edits(lex, rows, dict_terms):
    """Promote an edit pair only after it is seen in PROMOTE_AT distinct edit rows."""
    added_terms, added_corr = [], []
    known = set(trusted_terms(lex, dict_terms))  # K = lexicon terms ∪ dictionary terms
    try:
        corpus = build_seed_corpus()   # cached daily; used only to pick word boundaries
    except Exception:
        corpus = ""
    for row in rows:
        if not isinstance(row, dict):
            continue
        inserted, final = str_field(row, "inserted"), str_field(row, "final")
        if not inserted or not final or inserted == final:
            continue
        pairs = {(w, r) for w, r in replace_pairs(inserted, final, known, corpus)
                 if is_meaningful(r) and edit_pair_plausible(w, r)}
        for wrong, right in pairs:
            key = f"edit:{wrong}→{right}"
            n = lex["candidates"].get(key, 0) + 1
            lex["candidates"][key] = n
            if n < PROMOTE_AT:
                continue
            if add_correction(lex, wrong, right, "edit", 1, dict_terms):
                added_corr.append(f"{wrong}→{right}")
            if is_term_like(right) and term_ok(right) and add_term(lex, right, dict_terms):
                added_terms.append(right)
    return added_terms, added_corr


# ---------- Claude Code terminal pass (high trust, no LLM, purely local) ----------
# Terminals cannot be read back via Accessibility, so the submitted prompt in ~/.claude/history.jsonl
# is the only ground truth. Prompt text is never sent anywhere.

CLAUDE_HISTORY = os.path.expanduser("~/.claude/history.jsonl")
CLAUDE_BOOT_BYTES = 200 * 1024
CLAUDE_WINDOW_S = 15 * 60
CLAUDE_MIN_RATIO = 0.6
CLAUDE_MAX_LEN = 2000


def read_claude_rows(path, lex):
    """Complete JSON rows appended since the byte cursor; advances the cursor past the last complete line."""
    cur = lex["cursor"]
    try:
        size = os.path.getsize(path)
        if cur["claude_bytes"] is None:
            cur["claude_bytes"] = max(0, size - CLAUDE_BOOT_BYTES)
        start = cur["claude_bytes"] if cur["claude_bytes"] <= size else 0  # truncated or rotated
        with open(path, "rb") as f:
            f.seek(start)
            data = f.read()
    except OSError:
        return []
    end = data.rfind(b"\n")
    if end < 0:
        return []  # no complete line yet
    cur["claude_bytes"] = start + end + 1
    rows = []
    for line in data[:end].split(b"\n"):
        try:
            obj = json.loads(line)
        except ValueError:
            continue
        if isinstance(obj, dict):
            rows.append(obj)
    return rows


def claude_epoch(value):
    """Claude Code timestamps are epoch milliseconds, as int or str."""
    try:
        return float(value) / 1000.0
    except (TypeError, ValueError):
        return None


def dictation_epoch(value):
    """Our log rows carry ISO-8601 UTC such as 2026-10-12T05:12:45Z."""
    try:
        return datetime.fromisoformat(value.replace("Z", "+00:00")).timestamp()
    except (AttributeError, ValueError):
        return None


def aligned_prompt_region(clean, prompt):
    """The span of `prompt` that the dictation `clean` became, or None if not a plausible hand-edit."""
    if clean in prompt or len(clean) > CLAUDE_MAX_LEN or len(prompt) > CLAUDE_MAX_LEN:
        return None
    sm = difflib.SequenceMatcher(None, clean, prompt, autojunk=False)
    blocks = [b for b in sm.get_matching_blocks() if b.size]
    if not blocks:
        return None
    start = min(b.b for b in blocks)
    n = len(clean)
    best, best_ratio = None, 0.0
    for length in range(max(1, math.ceil(n * 0.7)), math.floor(n * 1.3) + 1):
        region = prompt[start:start + length]
        if not region:
            break
        ratio = difflib.SequenceMatcher(None, clean, region, autojunk=False).ratio()
        if ratio > best_ratio:
            best, best_ratio = region, ratio
    return best if best_ratio >= CLAUDE_MIN_RATIO else None


def claude_edits_pass(lex, dict_terms, history):
    """Returns (matched pairs, added_terms, added_corr). Reuses process_edits and its gates."""
    rows = read_claude_rows(CLAUDE_HISTORY, lex)
    dictations = []
    for r in history:
        clean = str_field(r, "clean")
        ts = dictation_epoch(str_field(r, "ts"))
        if clean and ts is not None:
            dictations.append((ts, clean))
    pairs = []
    for row in rows:
        prompt = str_field(row, "display")
        t_sub = claude_epoch(row.get("timestamp"))
        if len(prompt) < 4 or t_sub is None:
            continue
        for ts, clean in dictations:
            if 0 <= t_sub - ts <= CLAUDE_WINDOW_S:
                region = aligned_prompt_region(clean, prompt)
                if region is not None:
                    pairs.append({"inserted": clean, "final": region})
    added_terms, added_corr = process_edits(lex, pairs, dict_terms)
    return len(pairs), added_terms, added_corr


# ---------- polish / redo passes (silent, no LLM, purely local) ----------
# polish: the cloud polish changed the raw text and the result reached the screen (swap terminal:polished* or ax,
#         or a refined_unapplied text). Learns only sound-alike fixes, never semantic rewrites (算子→算力).
# redo:   the user said the same thing again within REDO_WINDOW_S in the same app, so the first text was misheard.

REDO_WINDOW_S = 60
REDO_MIN_RATIO = 0.6


def known_and_corpus(lex, dict_terms):
    known = set(trusted_terms(lex, dict_terms))  # K, as in process_edits
    try:
        corpus = build_seed_corpus()  # cached daily; used only to pick word boundaries
    except Exception:
        corpus = ""
    return known, corpus


def gated_pairs(inserted, final, known, corpus):
    """Set of (wrong, right) from one row that passed the polish/redo gates."""
    pairs = set()
    for wrong, right in replace_pairs(inserted, final, known, corpus):
        if not right or not is_meaningful(wrong) or not is_meaningful(right):
            continue  # empty right = filler removal (呃/嗯/额 dropped); punctuation/space-only sides
        if grammar_only(wrong, right):
            continue  # 的/地/得/了 edits are grammar, not mishearing: "的不→得不" would break "我的不对" everywhere
        if looks_misheard(wrong, right) and edit_pair_plausible(wrong, right):
            pairs.add((wrong, right))
    return pairs


PARTICLES = set("的地得了着过吗呢吧啊呀嘛么")


def grammar_only(wrong, right):
    """True when the two sides differ only in particle characters (measured: 4 of 9 polish pairs on 10-13 were these)."""
    import difflib
    sm = difflib.SequenceMatcher(None, wrong, right)
    changed = [wrong[i1:i2] + right[j1:j2] for op, i1, i2, j1, j2 in sm.get_opcodes() if op != "equal"]
    return all(set(c) <= PARTICLES for c in changed)


def count_pending(lex, pairs, source, dict_terms):
    """process_edits' pending-count-then-promote logic, with candidate keys prefixed by source."""
    added_terms, added_corr = [], []
    for wrong, right in sorted(pairs):
        key = f"{source}:{wrong}→{right}"
        n = lex["candidates"].get(key, 0) + 1
        lex["candidates"][key] = n
        if n < PROMOTE_AT:
            continue
        if source == "polish":
            added_terms += suggest_term_only(lex, right, dict_terms)
            continue
        if add_correction(lex, wrong, right, source, 1, dict_terms):
            added_corr.append(f"{wrong}→{right}")
        if is_term_like(right) and term_ok(right) and add_term(lex, right, dict_terms):
            added_terms.append(right)
    return added_terms, added_corr


def polish_pass(lex, rows, dict_terms):
    """rows: history rows past the polish cursor. Source name: "polish"."""
    known, corpus = known_and_corpus(lex, dict_terms)
    added_terms, added_corr = [], []
    for row in rows:
        if not isinstance(row, dict):
            continue
        refined = str_field(row, "refined_unapplied")
        swap = str_field(row, "swap")
        if refined:
            final = refined
        elif swap.startswith("terminal:polished") or swap == "ax":
            final = str_field(row, "clean")
        else:
            continue
        inserted = str_field(row, "raw")
        if not inserted or not final or inserted == final:
            continue
        t, c = count_pending(lex, gated_pairs(inserted, final, known, corpus), "polish", dict_terms)
        added_terms += t
        added_corr += c
    return added_terms, added_corr


def redo_pass(lex, rows, dict_terms):
    """rows: history rows from (redo cursor - 1) on; each pair (rows[k-1], rows[k]) is judged once.
    Source name: "redo". Only pairs whose later row is past the cursor are new."""
    known, corpus = known_and_corpus(lex, dict_terms)
    added_terms, added_corr = [], []
    for k in range(1, len(rows)):
        a, b = rows[k - 1], rows[k]
        if not isinstance(a, dict) or not isinstance(b, dict) or str_field(a, "app") != str_field(b, "app"):
            continue
        ta, tb = dictation_epoch(str_field(a, "ts")), dictation_epoch(str_field(b, "ts"))
        if ta is None or tb is None or not 0 <= tb - ta <= REDO_WINDOW_S:
            continue
        ca, cb = str_field(a, "clean"), str_field(b, "clean")
        if not ca or not cb or ca == cb:
            continue
        if difflib.SequenceMatcher(None, ca, cb).ratio() < REDO_MIN_RATIO:
            continue
        t, c = count_pending(lex, gated_pairs(ca, cb, known, corpus), "redo", dict_terms)
        added_terms += t
        added_corr += c
    return added_terms, added_corr


# ---------- LLM pass ----------

def read_config():
    try:
        with open(CONFIG_PATH, encoding="utf-8") as f:
            data = json.load(f)
    except (OSError, ValueError):
        return {}
    return data if isinstance(data, dict) else {}


def keychain_key():
    try:
        r = subprocess.run(["security", "find-generic-password", "-s", "local.zhiyu.llm", "-a", "api_key", "-w"],
                           capture_output=True, text=True, timeout=5)
    except (OSError, subprocess.SubprocessError):
        return ""
    return r.stdout.strip() if r.returncode == 0 else ""


def load_llm_config():
    """(base_url, api_key, model, extra_headers), or None when no base URL or key can be found."""
    cfg = read_config()
    base = cfg.get("llm_base_url")
    if not isinstance(base, str) or not base.strip():
        return None
    # learner_model: the learner runs in the background, so it may use a slower, stronger model than polish
    model = cfg.get("learner_model") or cfg.get("llm_model")
    model = model.strip() if isinstance(model, str) and model.strip() else MODEL
    # the app passes the key in the environment; reading the Keychain from here would prompt the user
    key = os.environ.get("ZHIYU_LLM_KEY", "") or (cfg.get("llm_key") if isinstance(cfg.get("llm_key"), str) else "")
    if not key:
        return None
    headers = cfg.get("llm_headers") if isinstance(cfg.get("llm_headers"), dict) else {}
    return base.strip(), key, model, {str(k): str(v) for k, v in headers.items()}


def parse_llm_json(content):
    start = content.find("{")
    if start < 0:
        raise ValueError("no JSON object in LLM reply")
    obj, _ = json.JSONDecoder().raw_decode(content, start)
    if not isinstance(obj, dict):
        raise ValueError("LLM reply is not a JSON object")
    terms = []
    if isinstance(obj.get("terms"), list):
        terms = [t.strip() for t in obj["terms"] if isinstance(t, str) and t.strip()]
    corrections = []
    if isinstance(obj.get("corrections"), list):
        for c in obj["corrections"]:
            if isinstance(c, dict) and isinstance(c.get("wrong"), str) and isinstance(c.get("right"), str):
                corrections.append({"wrong": c["wrong"].strip(), "right": c["right"].strip()})
    return {"terms": terms, "corrections": corrections}


def call_llm(payload, creds):
    base, key, model, extra = creds
    url = base.rstrip("/")
    if not url.endswith("/chat/completions"):
        url += "/chat/completions"
    host = (urlsplit(url).hostname or "").lower()
    strict_host = "deepseek" in host or bool(read_config().get("llm_disable_thinking"))
    headers = {"Content-Type": "application/json", "Authorization": f"Bearer {key}"}
    headers.update({str(k): str(v) for k, v in extra.items()})
    body = {
        "model": model,
        "temperature": 0,
        "max_tokens": 2000,
        "messages": [
            {"role": "system", "content": SYSTEM_PROMPT},
            {"role": "user", "content": json.dumps(payload, ensure_ascii=False)},
        ],
    }
    if strict_host:
        body["thinking"] = {"type": "disabled"}
        body["response_format"] = {"type": "json_object"}
    req = urllib.request.Request(url, data=json.dumps(body, ensure_ascii=False).encode("utf-8"),
                                 headers=headers, method="POST")
    with urllib.request.urlopen(req, timeout=LLM_TIMEOUT_S) as resp:
        data = json.loads(resp.read().decode("utf-8"))
    return parse_llm_json(data["choices"][0]["message"]["content"])


def accept_terms(lex, terms, ctx, dict_terms):
    """Terms must occur in the seed corpus; verified terms are promoted at once."""
    added = []
    for term in terms:
        if term_ok(term) and verified_term(term, ctx) and add_term(lex, term, dict_terms):
            added.append(term)
    return added


def accept_corrections(lex, corrections, ctx, dict_terms):
    """`right` must be verified; `wrong` must not be a word the user typed.

    Promotes at PROMOTE_AT candidate hits, or at once when `wrong` appears verbatim
    in >=2 distinct raw texts across the whole history.
    """
    added_terms, added_corr = [], []
    for c in corrections:
        wrong, right = c["wrong"], c["right"]
        if not (is_valid_side(wrong) and is_valid_side(right)):
            continue
        if not verified_pair(wrong, right, ctx, lex, dict_terms):
            continue
        key = f"{wrong}→{right}"
        n = lex["candidates"].get(key, 0) + 1
        lex["candidates"][key] = n
        verbatim = sum(1 for raw in ctx["raws"] if wrong in raw)
        if n >= PROMOTE_AT or verbatim >= 2:
            added_terms += suggest_term_only(lex, right, dict_terms)
    return added_terms, added_corr


def llm_pass(lex, batch, dict_terms, ctx, creds):
    """Apply LLM proposals for a batch of history rows. Raises on network/parse error."""
    usable = [r for r in batch if str_field(r, "raw")]
    if not usable:
        return [], []
    payload = {
        "known_terms": trusted_terms(lex, dict_terms),
        "known_corrections": [[c["wrong"], c["right"]] for c in lex["corrections"]],
        "reference_vocab": cloud_vocab(ctx["vocab"] + ["指语"] + trusted_terms(lex, dict_terms)),
        "transcripts": [{"raw": str_field(r, "raw"), "clean": str_field(r, "clean"), "app": str_field(r, "app")}
                        for r in usable],
    }
    reply = call_llm(payload, creds)
    t_terms = accept_terms(lex, reply["terms"], ctx, dict_terms)
    t_corr, corr = accept_corrections(lex, reply["corrections"], ctx, dict_terms)
    return t_terms + t_corr, corr


# ---------- finalize ----------

TERM_HITS_ROWS = 1500


def count_term_hits(lex, dict_terms, history):
    """Uses of each term in recent dictations. The app sends the most-used terms to the recognizer first:
    in OpenLess #917 the three most-hit words never fit the hotword budget because the list was in insertion order."""
    terms = list(dict.fromkeys(list(dict_terms) + lex["terms"]))
    texts = [str_field(r, "clean").lower() for r in history[-TERM_HITS_ROWS:]]
    lex["term_hits"] = {t: n for t in terms if (n := sum(t.lower() in x for x in texts))}


def prune(lex, dict_terms):
    lex["corrections"] = [c for c in lex["corrections"] if c.get("wrong") not in dict_terms]
    rejected = rejected_sets(lex)[1]
    lex["pending"] = [c for c in lex["pending"] if isinstance(c, dict) and c.get("wrong") not in dict_terms
                      and (c.get("wrong"), c.get("right")) not in rejected][-MAX_CORRECTIONS:]
    if len(lex["terms"]) > MAX_TERMS:
        lex["terms"] = lex["terms"][-MAX_TERMS:]
    corr = lex["corrections"]
    if len(corr) > MAX_CORRECTIONS:
        ranked = sorted(range(len(corr)), key=lambda i: (corr[i].get("hits", 0), i), reverse=True)
        keep = set(ranked[:MAX_CORRECTIONS])
        lex["corrections"] = [c for i, c in enumerate(corr) if i in keep]


def process(paths):
    lex = load_lexicon(paths["lexicon"])
    history = read_jsonl(paths["history"])
    edits = read_jsonl(paths["edits"])
    new_hist = history[lex["cursor"]["history"]:]
    new_edits = edits[lex["cursor"]["edits"]:]

    dict_terms = load_dictionary(paths["dictionary"])
    claude_before = lex["cursor"]["claude_bytes"]
    added_terms, added_corr = process_edits(lex, new_edits, dict_terms)
    lex["cursor"]["edits"] = len(edits)
    n_claude, claude_terms, claude_corr = claude_edits_pass(lex, dict_terms, history)
    added_terms += claude_terms
    added_corr += claude_corr
    # polish reads rows past its cursor; redo starts one row back so a pair straddling the old cursor is judged
    polish_rows = history[lex["cursor"]["polish"]:]
    redo_rows = history[max(lex["cursor"]["redo"] - 1, 0):] if lex["cursor"]["redo"] < len(history) else []
    p_terms, p_corr = polish_pass(lex, polish_rows, dict_terms)
    r_terms, r_corr = redo_pass(lex, redo_rows, dict_terms)
    lex["cursor"]["polish"] = len(history)
    lex["cursor"]["redo"] = len(history)
    added_terms += p_terms + r_terms
    added_corr += p_corr + r_corr
    pass_note = f"polish=+{len(p_corr)} redo=+{len(r_corr)}"
    if (not new_hist and not new_edits and not n_claude and lex["cursor"]["claude_bytes"] == claude_before
            and not polish_rows and not redo_rows):
        return

    ctx = build_context(history)
    err = None
    note = None
    batch = new_hist[:MAX_BATCH]
    offline = read_config().get("offline_only") is True
    creds = None if offline else load_llm_config()  # offline: no keychain/config lookup, no network
    if offline:
        note = "llm=skip(offline)"  # history cursor kept, same as no credentials
    elif creds is None:
        note = "llm=skip(no credentials)"  # history cursor kept: rows are processed once credentials exist
    else:
        try:
            t, c = llm_pass(lex, batch, dict_terms, ctx, creds)
            added_terms += t
            added_corr += c
            lex["cursor"]["history"] += len(batch)
        except Exception as exc:  # network/auth/parse: keep history cursor, retry next run
            err = f"{type(exc).__name__}: {exc}"

    purge_unverified(lex, ctx, dict_terms)
    count_term_hits(lex, dict_terms, history)
    prune(lex, dict_terms)
    lex["updated"] = datetime.now().astimezone().isoformat(timespec="seconds")
    write_lexicon(paths["lexicon"], lex)
    append_log(paths["log"], datetime.now().strftime("%Y-%m-%dT%H:%M"),
               added_terms, added_corr, len(lex["candidates"]), err, len(ctx["vocab"]), n_claude,
               note=" ".join(x for x in (note, pass_note) if x))


def main():
    if not os.path.isdir(D):
        return 0
    paths = {
        "history": os.path.join(D, "history.jsonl"),
        "edits": os.path.join(D, "edits.jsonl"),
        "lexicon": os.path.join(D, "lexicon.json"),
        "dictionary": os.path.join(D, "dictionary.txt"),
        "log": os.path.join(D, "learner.log"),
        "lock": os.path.join(D, "learner.lock"),
    }
    if not acquire_lock(paths["lock"]):
        return 0
    try:
        process(paths)
    except Exception as exc:
        try:
            append_log(paths["log"], datetime.now().strftime("%Y-%m-%dT%H:%M"), [], [], 0,
                       f"fatal {type(exc).__name__}: {exc}")
        except OSError:
            pass
    finally:
        release_lock(paths["lock"])
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
