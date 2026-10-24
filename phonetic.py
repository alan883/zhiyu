"""Pronunciation-based correction of ASR output against a user vocabulary.

Port of the CapsWriter-Offline hotword idea: CJK terms are matched by pinyin
(initial / final / tone) distance, Latin terms by fuzzy string similarity.
"""

from __future__ import annotations

import functools
import logging
import re
import sys

from pypinyin import Style, lazy_pinyin
from rapidfuzz import fuzz

_CJK_RANGES = (("㐀", "䶿"), ("一", "鿿"))
_LATIN_TOKEN = re.compile(r"[A-Za-z][A-Za-z0-9.+\-]*")
_MAX_CHAR_COST = 2.25          # initial 1.0 + final 1.0 + tone 0.25
_TONE_COST = 0.25
_CONF_COST = 0.5
_LATIN_THRESHOLD = 0.86
_LATIN_MIN_LEN = 4
_LATIN_LEN_TOL = 0.30


def _pairs(*groups: tuple[str, str]) -> frozenset[frozenset[str]]:
    return frozenset(frozenset(p) for p in groups)


_INI_CONF = _pairs(("z", "zh"), ("c", "ch"), ("s", "sh"), ("l", "n"), ("f", "h"),
                   ("r", "l"), ("p", "b"), ("t", "d"), ("k", "g"))
_FIN_CONF = _pairs(("an", "ang"), ("en", "eng"), ("in", "ing"), ("ian", "iang"),
                   ("uan", "uang"), ("ai", "ei"), ("o", "uo"), ("e", "ie"))

_DEFAULT_PROTECT = frozenset(
    """直译 只有 知道 支持 指示 只是 是否 事实 时间 实际 世界 设置 设计 实现
    使用 数据 输入 输出 速度 算法 所以 但是 因为 这个 那个 一个 什么 怎么 可以
    我们 你们 他们 自己 问题 模型 系统 文件 代码 测试 功能 需要 应该 已经 还是
    或者 然后 现在 今天 明天 时候 感觉 觉得 比较 非常 其实 就是 直接 主要""".split()
)


# A replay of 2,783 real takes (10-24) found most pinyin replacements broke correct text: "你现在"→"逆向在",
# "自己深度"→"自寄生度", "上面帮我"→"上面板我", "想法"→"宪法", "的模型"→"大模型". A sound-alike match says nothing
# about whether the original was wrong, so a span that already reads as ordinary Chinese is left alone.
_COMMON_WORD_FREQ = 50          # surface is itself a dictionary word at least this frequent: keep it
_COMMON_CHAR_FREQ = 20000       # two-char span made of two everyday one-char words ("你/想"): keep it
_EN_WORDS_PATH = "/usr/share/dict/words"


@functools.lru_cache(maxsize=1)
def _jieba():
    """jieba tokenizer, or None when the package is missing (the corrector then runs without the word checks)."""
    try:
        import jieba
        jieba.setLogLevel(logging.ERROR)
        jieba.initialize()
        return jieba
    except Exception as e:
        print(f"phonetic: jieba unavailable, word checks off: {e}", file=sys.stderr, flush=True)
        return None


@functools.lru_cache(maxsize=1)
def _english_words() -> frozenset[str]:
    try:
        with open(_EN_WORDS_PATH, encoding="utf-8", errors="ignore") as f:
            return frozenset(w.strip().lower() for w in f if w.strip())
    except OSError:
        return frozenset()


def _is_cjk(ch: str) -> bool:
    return any(lo <= ch <= hi for lo, hi in _CJK_RANGES)


def _has_cjk(text: str) -> bool:
    return any(_is_cjk(c) for c in text)


@functools.lru_cache(maxsize=None)
def _char_phoneme(ch: str) -> tuple[str, str, str]:
    """(initial, final without tone, tone digit) for one CJK character."""
    ini = lazy_pinyin(ch, style=Style.INITIALS, strict=False)
    fin = lazy_pinyin(ch, style=Style.FINALS_TONE3, strict=False)
    initial = ini[0] if ini else ""
    full = fin[0] if fin else ""
    if full and full[-1].isdigit():
        return initial, full[:-1], full[-1]
    return initial, full, "5"


def _term_phonemes(term: str) -> list[tuple[str, str, str]]:
    return [_char_phoneme(c) if _is_cjk(c) else (c.lower(), "", "5") for c in term]


@functools.lru_cache(maxsize=65536)
def _sub_cost(a: tuple[str, str, str], b: tuple[str, str, str]) -> float:
    """Substitution cost between two phonemes (initial + final + tone)."""
    cost = 0.0
    if a[0] != b[0]:
        cost += _CONF_COST if frozenset((a[0], b[0])) in _INI_CONF else 1.0
    if a[1] != b[1]:
        cost += _CONF_COST if frozenset((a[1], b[1])) in _FIN_CONF else 1.0
    if a[2] != b[2]:
        cost += _TONE_COST
    return cost


def _cjk_runs(text: str) -> list[tuple[int, int]]:
    """Maximal [start, end) spans made only of CJK characters."""
    runs: list[tuple[int, int]] = []
    i, n = 0, len(text)
    while i < n:
        if _is_cjk(text[i]):
            j = i
            while j < n and _is_cjk(text[j]):
                j += 1
            runs.append((i, j))
            i = j
        else:
            i += 1
    return runs


class PhoneticCorrector:
    """Replaces near-homophone spans in text with vocabulary terms."""

    def __init__(self, terms: list[str], replace_threshold: float = 0.80,
                 suggest_threshold: float = 0.6, protect: set[str] | None = None, guard: bool = True):
        # guard=False: pure sound comparison, for the learner checking a user's own edit
        self.guard = guard
        self.replace_threshold = replace_threshold
        self.suggest_threshold = suggest_threshold
        self._protect = _DEFAULT_PROTECT | frozenset(protect or ())
        clean = list(dict.fromkeys(t.strip() for t in terms if t and t.strip()))
        self._terms = frozenset(clean)
        self._cjk_terms: list[tuple[str, list[tuple[str, str, str]]]] = []
        self._latin_terms: list[str] = []
        for t in clean:
            if _has_cjk(t):
                if len(t) >= 2:
                    self._cjk_terms.append((t, _term_phonemes(t)))
            elif len(t) >= _LATIN_MIN_LEN:
                self._latin_terms.append(t)

    def correct(self, text: str) -> tuple[str, list[dict]]:
        """Return (corrected_text, events). Events cover replace and suggest actions."""
        if not text:
            return text, []
        cands = self._cjk_candidates(text) + self._latin_candidates(text)
        cands.sort(key=lambda c: (-c[0], -len(c[1]), c[2]))

        occupied = [False] * len(text)
        chosen: list[tuple[int, int, str, float, str]] = []
        for score, term, s, e, action in cands:
            if any(occupied[s:e]):
                continue
            for k in range(s, e):
                occupied[k] = True
            chosen.append((s, e, term, score, action))

        out = text
        for s, e, term, _score, action in sorted(chosen, key=lambda c: c[0], reverse=True):
            if action == "replace":
                out = out[:s] + term + out[e:]

        events: list[dict] = []
        seen: set[tuple[str, str, str]] = set()
        for s, e, term, score, action in sorted(chosen, key=lambda c: c[0]):
            surface = text[s:e]
            key = (surface, term, action)
            if key in seen:
                continue
            seen.add(key)
            events.append({"from": surface, "to": term,
                           "score": round(score, 4), "action": action})
        return out, events

    def _cjk_candidates(self, text: str) -> list[tuple[float, str, int, int, str]]:
        if not self._cjk_terms:
            return []
        runs = [(s, [_char_phoneme(c) for c in text[s:e]]) for s, e in _cjk_runs(text)]
        jb = _jieba() if self.guard else None
        segs = [(w, a, b) for w, a, b in jb.tokenize(text, HMM=False)] if jb else []
        bounds = {a for _, a, _ in segs} | {b for _, _, b in segs}
        freq = jb.dt.FREQ if jb else {}
        out: list[tuple[float, str, int, int, str]] = []
        for term, tp in self._cjk_terms:
            length = len(tp)
            denom = _MAX_CHAR_COST * length
            max_cost = (1.0 - self.suggest_threshold) * denom
            for run_start, phs in runs:
                for i in range(len(phs) - length + 1):
                    s = run_start + i
                    e = s + length
                    surface = text[s:e]
                    if surface == term or surface in self._terms or surface in self._protect:
                        continue
                    cost = 0.0
                    for k in range(length):
                        cost += _sub_cost(tp[k], phs[i + k])
                        if cost > max_cost:
                            break
                    else:
                        score = 1.0 - cost / denom
                        if score < self.suggest_threshold or (
                                self.guard and self._reads_fine(term, surface, s, e, segs, bounds, freq)):
                            continue
                        if score >= self.replace_threshold:
                            action = "replace"
                        elif score >= self.suggest_threshold:
                            action = "suggest"
                        else:
                            continue
                        out.append((score, term, s, e, action))
        return out

    @staticmethod
    def _reads_fine(term: str, surface: str, s: int, e: int, segs, bounds, freq) -> bool:
        """True when the span already reads as ordinary text, so a sound-alike term must not replace it."""
        diff = [k for k in range(len(term)) if term[k] != surface[k]]
        # "的模型"→"大模型", "方案是"→"方案一": one edge character differs and the rest is the term itself
        if len(term) >= 3 and len(diff) == 1 and diff[0] in (0, len(term) - 1):
            return True
        if not segs:
            return False
        if freq.get(surface, 0) >= _COMMON_WORD_FREQ:              # "想法", "话说", "至于"
            return True
        if s not in bounds or e not in bounds:                      # "你|现在", "自己|深度", "上面|帮我"
            return True
        inside = [w for w, a, b in segs if a >= s and b <= e]
        if len(term) == 2 and len(inside) == 2 and all(freq.get(w, 0) >= _COMMON_CHAR_FREQ for w in inside):
            return True                                             # "你/想", "你/像", "你/向"
        return False

    @staticmethod
    def _latin_reads_fine(term: str, window_words: list[str]) -> bool:
        return _latin_reads_fine_impl(term, window_words)

    def _latin_candidates(self, text: str) -> list[tuple[float, str, int, int, str]]:
        if not self._latin_terms:
            return []
        toks = [(m.start(), m.end()) for m in _LATIN_TOKEN.finditer(text)]
        out: list[tuple[float, str, int, int, str]] = []
        for term in self._latin_terms:
            words = term.split()
            n = len(words)
            tl = term.lower()
            tl_ns = tl.replace(" ", "")
            tkey = re.sub(r"[A-Za-z\s]", "", tl)
            sizes = {n, n - 1, n + 1} if n >= 2 else {n, n + 1}  # "deep seek" -> DeepSeek
            for k in sorted(sizes):
                if k < 1 or k > len(toks):
                    continue
                for i in range(len(toks) - k + 1):
                    s = toks[i][0]
                    e = toks[i + k - 1][1]
                    # a multi-word window may only bridge spaces ("deep seek"), never other text:
                    # "A一百S的这个实际项目。我还需要你跟那个DeepSeek" once became "A一百DeepSeek" (10-13)
                    if any(text[toks[j][1]:toks[j + 1][0]].strip(" ") or toks[j + 1][0] - toks[j][1] > 1
                           for j in range(i, i + k - 1)):
                        continue
                    surface = text[s:e]
                    if surface == term or surface in self._terms:
                        continue
                    window_words = [text[a:b] for a, b in toks[i:i + k]]
                    if self.guard and self._latin_reads_fine(term, window_words):
                        continue
                    best, best_cand = 0.0, ""
                    for join in ("", " "):
                        cand = join.join(window_words).lower()
                        ratio = fuzz.ratio(cand, tl) / 100.0
                        if ratio > best:
                            best, best_cand = ratio, cand
                    if best < _LATIN_THRESHOLD:
                        continue
                    if re.sub(r"[A-Za-z\s]", "", best_cand) != tkey:
                        continue
                    cand_ns = best_cand.replace(" ", "")
                    if abs(len(cand_ns) - len(tl_ns)) > _LATIN_LEN_TOL * len(tl_ns):
                        continue
                    out.append((best, term, s, e, "replace"))
        return out


def _latin_reads_fine_impl(term: str, window_words: list[str]) -> bool:
    words = term.split()
    low = [w.lower() for w in window_words]
    # "DeepSeek V四点一"→"DeepSeek", "Python C"→"Python": the term is already there, the extra token is real speech
    n = len(words)
    tl = [w.lower() for w in words]
    if any(low[j:j + n] == tl for j in range(len(low) - n + 1)) and len(low) > n:
        return True
    joined = "".join(low)
    if joined == "".join(tl) + "s":                # "Skills"→"Skill", "Pi Agents"→"Pi Agent": plural is speech
        return True
    if len(window_words) != 1:
        return False
    w = window_words[0]
    plain = lambda x: x in (x.lower(), x.capitalize())
    # case only: "skill"→"Skill", "Coding"→"coding" is noise; "CODEX"/"CodeX"→"Codex" is a real fix
    if w.lower() == term.lower():
        return plain(w) and plain(term)
    # "Code"→"Codex", "Goal"→"goal": an English word is a word, not a misspelling
    return w.lower() in _english_words()


@functools.lru_cache(maxsize=32)
def corrector_for(terms: tuple[str, ...]) -> PhoneticCorrector:
    """Cached corrector factory keyed by the (hashable) term tuple."""
    return PhoneticCorrector(list(terms))
