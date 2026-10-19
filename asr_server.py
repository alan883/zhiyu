#!/usr/bin/env python3
"""zhiyu ASR server: Qwen3-ASR via mlx_audio, plus local text polish via mlx_lm, on 127.0.0.1."""
import base64
import difflib
import gc
import inspect
import io
import json
import os
import re
import subprocess
import sys
import threading
import time
import wave
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import parse_qs, urlparse

import numpy as np
from huggingface_hub import hf_hub_download, try_to_load_from_cache
from huggingface_hub.constants import HF_HUB_CACHE
from mlx_audio.stt.utils import load_model

MODEL = os.environ.get("ZHIYU_ASR_MODEL", "mlx-community/Qwen3-ASR-0.6B-4bit")
LLM_MODEL = os.environ.get("ZHIYU_LLM_MODEL", "mlx-community/Qwen3-4B-Instruct-2507-4bit")
PORT = int(os.environ.get("ZHIYU_ASR_PORT", "8776"))
TARGET_SR = 16000
CHARS_PER_SEC = 14
LOCK_WAIT_S = 3.0
CLEAN_LOCK_WAIT_S = 8.0
LLM_IDLE_S = 600.0
LLM_CHECK_S = 30.0
MODELS_FILE = os.path.join(os.path.expanduser("~"), ".config", "zhiyu", "models.json")
MIRROR_ENDPOINT = "https://hf-mirror.com"
DOWNLOAD_FAIL_MSG = "下载失败（网络或磁盘），可重试或换镜像"
SERVER_VERSION = 9
STREAM_REPO = "csukuangfj/sherpa-onnx-streaming-paraformer-bilingual-zh-en"
STREAM_FILES = ("encoder.int8.onnx", "decoder.int8.onnx", "tokens.txt")
STREAM_IDLE_S = 60.0
STREAM_TAIL_S = 0.66

CATALOG = [
    # speech recognition — every entry below loads and transcribes with the bundled mlx-audio (M1, 2026-10-12)
    {"id": "mlx-community/Qwen3-ASR-0.6B-4bit", "kind": "asr", "name": "Qwen3-ASR 0.6B · 4-bit",
     "desc": "默认 · 快", "size_gb": 0.71, "recommended": True, "tested": True,
     "intro": "阿里通义千问语音识别。中英混说准，自带标点，支持个人词典热词。M1 实测每句约 0.6 秒。"},
    {"id": "mlx-community/SenseVoiceSmall", "kind": "asr", "name": "SenseVoice Small",
     "desc": "极快 · 无标点", "size_gb": 0.94, "recommended": True, "tested": True,
     "intro": "阿里 FunAudioLLM。速度最快，M1 实测每句约 0.3 秒；支持中、英、日、韩、粤语。不输出标点，靠润色补全。"},
    {"id": "mlx-community/GLM-ASR-Nano-2512-4bit", "kind": "asr", "name": "GLM-ASR Nano · 4-bit",
     "desc": "口语更稳 · 较慢", "size_gb": 1.29, "recommended": False, "tested": True,
     "intro": "智谱 GLM 语音识别。对口语和含糊发音更稳，实测把 Qwen 听错的「重按」听对了。M1 实测每句约 1.6 秒。"},
    {"id": "mlx-community/Qwen3-ASR-0.6B-8bit", "kind": "asr", "name": "Qwen3-ASR 0.6B · 8-bit",
     "desc": "略准 · 略慢", "size_gb": 1.01, "recommended": False, "tested": False,
     "intro": "与默认模型同款，8 位精度：准确度略高，速度略慢，占用更大。"},
    {"id": "mlx-community/Qwen3-ASR-1.7B-4bit", "kind": "asr", "name": "Qwen3-ASR 1.7B · 4-bit",
     "desc": "更准 · 慢", "size_gb": 1.61, "recommended": False, "tested": False,
     "intro": "千问语音识别大号版本，专有名词和长句更准；速度约为默认模型的一半，建议 16 GB 以上内存。"},
    {"id": "mlx-community/Qwen3-ASR-1.7B-8bit", "kind": "asr", "name": "Qwen3-ASR 1.7B · 8-bit",
     "desc": "最准 · 最慢", "size_gb": 2.47, "recommended": False, "tested": False,
     "intro": "千问语音识别最高精度版本；最慢、最占内存。"},
    # local polish
    {"id": "mlx-community/Qwen3-4B-Instruct-2507-4bit", "kind": "llm", "name": "Qwen3 4B Instruct · 4-bit",
     "desc": "本地润色 · 约 3 秒/句", "size_gb": 2.28, "recommended": True, "tested": True,
     "intro": "去口头语、补标点、纠同音错字、语音改写，全部在本机完成。完全离线模式需要它。"},
]

HF_ID_RE = re.compile(r"[A-Za-z0-9][\w.-]*/[\w.-]+")
ASR_ARCHS = ("qwen3_asr", "whisper", "parakeet", "sensevoice", "voxtral", "canary", "moonshine", "granite")
FORMAT_GUIDE = (
    "自定义模型格式要求（只接受 MLX 格式，仅限 Apple Silicon）\n"
    "\n"
    "1. 文件夹必须包含 config.json 和一个或多个 *.safetensors 权重文件，另需 tokenizer / preprocessor 配置文件\n"
    "2. 语音识别（ASR）：架构需被 mlx-audio 支持，例如 Qwen3-ASR、Whisper、Parakeet、SenseVoice、Voxtral、Canary、Moonshine 等\n"
    "3. 本地润色（LLM）：必须是 mlx-lm 支持的聊天模型，且包含 tokenizer.json 或 tokenizer_config.json\n"
    "4. 不支持：GGUF、PyTorch .bin、ONNX\n"
    "\n"
    "如何获得：\n"
    "· 在 Hugging Face 搜索 “mlx-community” + 模型名，直接填仓库名（组织/模型名）导入\n"
    "· 或自行转换：ASR 用 mlx_audio.convert，润色模型用 mlx_lm.convert，把输出文件夹选为本地导入\n"
)

SYSTEM_PROMPT = (
    "你是语音输入的文字清理器，不是助手。逐字保留原文，只允许三种改动：\n"
    "1. 删除纯口头语：呃、嗯、额、唔，以及口吃造成的重复字（如“识识别”→“识别”）；\n"
    "2. 补全或修正标点；英文单词两侧加空格；\n"
    "3. 把发音相近的错词改成【用户词典】里的写法。\n"
    "除此之外一个字都不许改：不许删实义词、不许换同义词、不许删语气词“啊/吧/嘛/呢”、不许缩句或总结、不许回答问题。只输出结果。"
)

REPEAT_RE = re.compile(r"(.{1,12}?)\1{3,}")
FILLER_RE = re.compile(
    r"(?:^|(?<=[，。！？、\s]))(?:呃|嗯|唔|额(?=[，,、\s]|$)|(?i:emm+|um+|uh+)(?![A-Za-z]))[，,、]?\s*"
)
EN_FILLER_RE = re.compile(r"(?<!\w)(?:um|umm|uh|uhh|uhm|erm|hmm)(?!\w)[,，、]?\s*", re.IGNORECASE)
STUTTER_RE = re.compile(r"(我|他|它|这|那|就|不|是|的)\1")
LEAD_RE = re.compile(r"^(清理后|清理结果|输出)\s*[：:]\s*")
QUOTES = "\"'“”‘’「」『』"

_lock = threading.Lock()
_asr_waiting = threading.Event()
model = None
llm_model = None
llm_tok = None
_lm_stream_generate = None
_make_sampler = None
_llm_failed = False
_last_clean = 0.0
_phonetic = None
_phonetic_failed = False
_dl_lock = threading.Lock()
_downloads: dict[str, subprocess.Popen] = {}
_download_errors: dict[str, str] = {}
_auto_activate: dict[str, bool] = {}
_watcher_running = False
_gen_cache: tuple | None = None  # (id of loaded ASR model, accepted generate() kw names, has **kwargs)
# live preview (sherpa-onnx streaming Paraformer, CPU); guarded by _stream_lock only, never by _lock
_stream_rec = None
_streams: dict[str, tuple] = {}  # session id -> (stream, last used time.monotonic())
_stream_lock = threading.Lock()
_stream_downloading = False


def decode_wav(data: bytes) -> np.ndarray:
    with wave.open(io.BytesIO(data), "rb") as w:
        channels, width, rate, n = w.getnchannels(), w.getsampwidth(), w.getframerate(), w.getnframes()
        raw = w.readframes(n)
    if width != 2:
        raise ValueError(f"expected PCM16, got {width * 8}-bit")
    x = np.frombuffer(raw, dtype="<i2").astype(np.float32) / 32768.0
    if channels > 1:
        x = x.reshape(-1, channels).mean(axis=1)
    if rate != TARGET_SR and x.size:
        t_out = np.linspace(0, x.size - 1, int(round(x.size * TARGET_SR / rate)))
        x = np.interp(t_out, np.arange(x.size), x).astype(np.float32)
    return x


def decode_hotwords(header: str | None) -> list[str]:
    if not header:
        return []
    try:
        value = json.loads(base64.b64decode(header).decode("utf-8"))
    except Exception:
        return []
    if not isinstance(value, list):
        return []
    return [s for s in value if isinstance(s, str) and s.strip()]


def result_text(r) -> str:
    if hasattr(r, "text"):
        t = r.text
    elif isinstance(r, dict) and "text" in r:
        t = r["text"]
    else:
        t = str(r)
    return str(t or "").strip()


def generate_audio(m, model_id: str, audio: np.ndarray, **wanted):
    # Model-agnostic: pass only the kwargs this model's generate() accepts.
    # Unknown kwargs go through only for qwen3 models that take **kwargs.
    global _gen_cache
    if _gen_cache is None or _gen_cache[0] != id(m):
        try:
            params = list(inspect.signature(m.generate).parameters.values())
            names = {p.name for p in params if p.kind in (p.POSITIONAL_OR_KEYWORD, p.KEYWORD_ONLY)}
            var_kw = any(p.kind == p.VAR_KEYWORD for p in params)
        except (TypeError, ValueError):
            names, var_kw = set(), False
        _gen_cache = (id(m), names, var_kw)
    _, names, var_kw = _gen_cache
    accept_extra = var_kw and "qwen3" in model_id.lower()
    kw = {k: v for k, v in wanted.items() if k in names or accept_extra}
    return m.generate(audio, **kw)


def collapse_repeats(text: str) -> str:
    while True:
        new = REPEAT_RE.sub(r"\1", text)
        if new == text:
            return text
        text = new


def _squash(s: str) -> str:
    return re.sub(r"[\W_]+", "", s).lower()


def echoes_hotwords(text: str, hotwords: list[str] | None) -> bool:
    """Qwen3-ASR sometimes reads the hotword list back instead of the speech
    ("Fable 5.1, GPT-6-Astra, Handy, …"). Real speech almost never says three list
    entries back to back in list order, so that pattern marks an echo."""
    if not hotwords or len(hotwords) < 3:
        return False
    t = _squash(text)
    for i in range(len(hotwords) - 2):
        run = _squash("".join(hotwords[i:i + 3]))
        if len(run) >= 6 and run in t:
            return True
    return False


CONTEXT_TERMS = 24      # words given to the recognizer per take (the rest only feed the sound-alike fixer)
CONTEXT_HEARD_MAX = 8   # of those, at most this many picked because the live preview contains them


def select_context(terms: list[str], preview: str) -> list[str]:
    """Qwen3-ASR gets worse as unrelated words pile up in its context (Huber & Waibel 2026: +39–570% errors with
    250 distractors, fine with 10) and sometimes reads the list back (Qwen3-ASR #106/#140). So it gets the
    words the live preview already heard (exact or sound-alike), then the client's most-used words."""
    heard = []
    if preview:
        p = _squash(preview)
        heard = [t for t in terms if len(_squash(t)) >= 2 and _squash(t) in p]
        _, events = phonetic_fix(preview, terms)
        heard += [e["to"] for e in events if e.get("to") in terms]
    out = []
    for t in heard[:CONTEXT_HEARD_MAX] + terms:
        if t not in out:
            out.append(t)
        if len(out) >= CONTEXT_TERMS:
            break
    return out


def cap_length(text: str, dur: float) -> str:
    limit = int(dur * CHARS_PER_SEC) + 30
    return text[:limit] if len(text) > limit else text


def parse_corrections(raw) -> list[tuple[str, str, list[str]]]:
    out = []
    for c in raw or []:
        if isinstance(c, dict) and isinstance(c.get("wrong"), str) and c["wrong"] and isinstance(c.get("right"), str):
            unless = [u for u in c.get("unless") or [] if isinstance(u, str) and u]
            out.append((c["wrong"], c["right"], unless))
    return out


def replace_word(text: str, wrong: str, right: str) -> str:
    """Replace `wrong`, but never inside a Latin word: Cloud→Claude must leave iCloud alone."""
    pat = re.escape(wrong)
    if re.match(r"[A-Za-z0-9]", wrong[0]):
        pat = r"(?<![A-Za-z0-9])" + pat
    if re.match(r"[A-Za-z0-9]", wrong[-1]):
        pat += r"(?![A-Za-z0-9])"
    return re.sub(pat, lambda _: right, text)


def rules_clean(text: str, corrections: list[tuple[str, str, list[str]]]) -> str:
    for wrong, right, unless in sorted(corrections, key=lambda c: len(c[0]), reverse=True):
        if any(u.lower() in text.lower() for u in unless):
            continue   # blacklist: a word nearby says this is not the misheard term
        text = replace_word(text, wrong, right)
    text = FILLER_RE.sub("", text)
    text = EN_FILLER_RE.sub("", text)
    text = collapse_repeats(text)
    text = STUTTER_RE.sub(r"\1", text)
    text = re.sub(r" {2,}", " ", text)
    return text.strip()


def phonetic_fix(text: str, terms: list[str]) -> tuple[str, list[dict]]:
    # Lazy import; if the sibling module is unavailable, skip correction (logged once).
    global _phonetic, _phonetic_failed
    if not terms or not text:
        return text, []
    if _phonetic is None and not _phonetic_failed:
        try:
            # python -I does not put the script dir on sys.path
            sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
            import phonetic as _mod
            _phonetic = _mod
        except Exception as e:
            _phonetic_failed = True
            print(f"phonetic disabled: {e}", file=sys.stderr, flush=True)
    if _phonetic is None:
        return text, []
    try:
        return _phonetic.corrector_for(tuple(terms)).correct(text)
    except Exception as e:
        print(f"phonetic correction failed: {e}", file=sys.stderr, flush=True)
        return text, []


def _chat_prompt(messages: list[dict]) -> str:
    try:
        return llm_tok.apply_chat_template(messages, add_generation_prompt=True, tokenize=False, enable_thinking=False)
    except TypeError:
        return llm_tok.apply_chat_template(messages, add_generation_prompt=True, tokenize=False)


def build_user_prompt(rules_text: str, context: str, terms: list[str], style_hint: str = "") -> str:
    parts = []
    if terms:
        parts.append("【用户词典】" + "、".join(terms[:80]))
    if context:
        parts.append("【输入框前文】" + context[-150:])
    if style_hint:
        parts.append("【风格】" + style_hint)
    parts.append("【识别原文】\n" + rules_text)
    return "\n".join(parts)


def clean_llm_output(out: str) -> str:
    out = LEAD_RE.sub("", out.strip())
    return out.strip().strip(QUOTES).strip()


LLM_BUDGET_S = 6.0


def llm_polish(rules_text: str, context: str, terms: list[str], style_hint: str = "") -> str | None:
    # Returns None when abandoned (ASR request waiting, or over time budget).
    messages = [
        {"role": "system", "content": SYSTEM_PROMPT},
        {"role": "user", "content": build_user_prompt(rules_text, context, terms, style_hint)},
    ]
    pieces = []
    t0 = time.monotonic()
    for resp in _lm_stream_generate(
        llm_model,
        llm_tok,
        prompt=_chat_prompt(messages),
        max_tokens=len(rules_text) * 2 + 48,
        sampler=_make_sampler(temp=0.0),
    ):
        pieces.append(resp.text)
        if _asr_waiting.is_set() or time.monotonic() - t0 > LLM_BUDGET_S:
            return None
    return clean_llm_output("".join(pieces))


def polish(rules_text: str, context: str, terms: list[str], style_hint: str = "") -> tuple[str, str]:
    global _last_clean
    if LLM_MODEL == "none" or not rules_text:
        return rules_text, "rules"
    _last_clean = time.monotonic()
    if not _lock.acquire(timeout=CLEAN_LOCK_WAIT_S):
        return rules_text, "rules"
    try:
        if llm_model is None and not _llm_failed:
            load_llm()
        if llm_model is None:
            return rules_text, "rules"
        out = llm_polish(rules_text, context, terms, style_hint)
    except Exception as e:
        print(f"polish failed: {e}", file=sys.stderr, flush=True)
        return rules_text, "rules"
    finally:
        _lock.release()
    if out is None:
        return rules_text, "rules"
    if not out or len(out) > len(rules_text) * 1.6 + 20 or len(out) < len(rules_text) * 0.5:
        return rules_text, "rules"
    if difflib.SequenceMatcher(None, rules_text, out).ratio() < 0.85:
        return rules_text, "rules"
    return out, "llm"


COMMAND_SYSTEM_PROMPT = (
    "你是文字编辑助手。用户选中了一段文字，并用语音下达了修改指令。按指令改写选中文字，只输出改写后的完整文字，不要解释、不要引号。如果指令是提问，用简短中文回答。"
)
LLM_UNAVAILABLE_MSG = "本地润色模型未下载或不可用"


class LLMUnavailable(Exception):
    pass


def run_command(instruction: str, selected: str) -> str:
    global _last_clean
    if LLM_MODEL == "none":
        raise LLMUnavailable(LLM_UNAVAILABLE_MSG)
    _last_clean = time.monotonic()
    if not _lock.acquire(timeout=CLEAN_LOCK_WAIT_S):
        raise LLMUnavailable("busy")
    try:
        if llm_model is None and not _llm_failed:
            load_llm()
        if llm_model is None:
            raise LLMUnavailable(LLM_UNAVAILABLE_MSG)
        messages = [
            {"role": "system", "content": COMMAND_SYSTEM_PROMPT},
            {"role": "user", "content": "【指令】" + instruction + "\n【选中文字】\n" + selected},
        ]
        pieces = []
        for resp in _lm_stream_generate(
            llm_model,
            llm_tok,
            prompt=_chat_prompt(messages),
            max_tokens=min(2048, len(selected) * 2 + 200),
            sampler=_make_sampler(temp=0.0),
        ):
            pieces.append(resp.text)
        out = clean_llm_output("".join(pieces))
    finally:
        _lock.release()
    if not out:
        raise RuntimeError("empty output")
    return out


def load_llm() -> None:
    # Caller must hold _lock.
    global llm_model, llm_tok, _lm_stream_generate, _make_sampler, _llm_failed
    try:
        from mlx_lm import generate, load, stream_generate
        from mlx_lm.sample_utils import make_sampler

        t0 = time.perf_counter()
        m, tok = load(LLM_MODEL)
        _lm_stream_generate, _make_sampler = stream_generate, make_sampler
        llm_model, llm_tok = m, tok
        generate(m, tok, prompt=_chat_prompt([{"role": "user", "content": "你好"}]),
                 max_tokens=8, sampler=make_sampler(temp=0.0))
        print(f"polish loaded in {int((time.perf_counter() - t0) * 1000)} ms", flush=True)
    except Exception as e:
        llm_model = llm_tok = None
        _llm_failed = True
        print(f"polish disabled: {e}", file=sys.stderr, flush=True)


def _unload_idle_llm() -> None:
    global llm_model, llm_tok
    while True:
        time.sleep(LLM_CHECK_S)
        if llm_model is None or time.monotonic() - _last_clean < LLM_IDLE_S:
            continue
        if not _lock.acquire(timeout=LOCK_WAIT_S):
            continue
        try:
            if llm_model is not None and time.monotonic() - _last_clean >= LLM_IDLE_S:
                llm_model = llm_tok = None
                _free_memory()
                print("polish unloaded (idle)", flush=True)
        finally:
            _lock.release()


def _free_memory() -> None:
    gc.collect()
    try:
        import mlx.core as mx
        clear = getattr(mx, "clear_cache", None) or mx.metal.clear_cache
        clear()
    except Exception as e:
        print(f"cache clear failed: {e}", file=sys.stderr, flush=True)


class BadRequest(Exception):
    pass


def custom_records() -> list[dict]:
    raw = load_prefs().get("custom")
    if not isinstance(raw, list):
        return []
    return [
        r for r in raw
        if isinstance(r, dict) and isinstance(r.get("id"), str)
        and r.get("kind") in ("asr", "llm") and r.get("source") in ("hf", "local")
    ]


def catalog_item(model_id: str) -> dict | None:
    for c in CATALOG:
        if c["id"] == model_id:
            return {**c, "custom": False}
    for r in custom_records():
        if r["id"] == model_id:
            return {**r, "custom": True}
    return None


def load_prefs() -> dict:
    try:
        with open(MODELS_FILE, encoding="utf-8") as f:
            data = json.load(f)
    except (OSError, ValueError):
        return {}
    return data if isinstance(data, dict) else {}


def save_prefs(custom: list[dict] | None = None) -> None:
    if custom is None:
        custom = custom_records()
    os.makedirs(os.path.dirname(MODELS_FILE), exist_ok=True)
    tmp = MODELS_FILE + ".tmp"
    with open(tmp, "w", encoding="utf-8") as f:
        json.dump({"asr": MODEL, "llm": LLM_MODEL, "custom": custom}, f, ensure_ascii=False)
    os.replace(tmp, MODELS_FILE)


def apply_startup_prefs() -> None:
    global MODEL, LLM_MODEL
    prefs = load_prefs()
    asr, llm = prefs.get("asr"), prefs.get("llm")
    item = catalog_item(asr) if isinstance(asr, str) else None
    if item and item["kind"] == "asr" and downloaded(asr):
        MODEL = asr
    if isinstance(llm, str) and llm:
        LLM_MODEL = llm


def _repo_dir(model_id: str) -> str:
    return os.path.join(HF_HUB_CACHE, "models--" + model_id.replace("/", "--"))


def _blobs_dir(model_id: str) -> str:
    return os.path.join(_repo_dir(model_id), "blobs")


def downloaded(model_id: str) -> bool:
    if model_id.startswith("/"):
        return os.path.isfile(os.path.join(model_id, "config.json"))
    if not isinstance(try_to_load_from_cache(repo_id=model_id, filename="config.json"), str):
        return False
    try:
        names = os.listdir(_blobs_dir(model_id))
    except OSError:
        return False
    return not any(n.endswith(".incomplete") for n in names)


def _dir_bytes(path: str) -> int:
    total = 0
    for root, _, files in os.walk(path):
        for name in files:
            try:
                total += os.path.getsize(os.path.join(root, name))
            except OSError:
                pass
    return total


def progress(model_id: str, size_gb: float) -> float | None:
    if size_gb <= 0:
        return None
    return min(0.99, _dir_bytes(_blobs_dir(model_id)) / (size_gb * 1e9))


def is_downloading(model_id: str) -> bool:
    proc = _downloads.get(model_id)
    return proc is not None and proc.poll() is None


def reap_downloads() -> None:
    with _dl_lock:
        for model_id, proc in list(_downloads.items()):
            rc = proc.poll()
            if rc is None:
                continue
            del _downloads[model_id]
            auto = _auto_activate.pop(model_id, False)
            if rc == 0:
                _download_errors.pop(model_id, None)
                if auto:
                    threading.Thread(target=_auto_activate_run, args=(model_id,), daemon=True).start()
            else:
                _download_errors[model_id] = DOWNLOAD_FAIL_MSG


def _auto_activate_run(model_id: str) -> None:
    try:
        activate_model(model_id)
    except Exception as e:
        with _dl_lock:
            _download_errors[model_id] = str(e) or type(e).__name__


def _watch_downloads() -> None:
    global _watcher_running
    while True:
        time.sleep(2.0)
        reap_downloads()
        with _dl_lock:
            if not _downloads:
                _watcher_running = False
                return


def start_download(model_id: str, mirror: bool, activate: bool = False) -> None:
    # Subprocess: the server runs with HF_HUB_OFFLINE=1, so in-process downloads are impossible.
    global _watcher_running
    with _dl_lock:
        if is_downloading(model_id):
            if activate:
                _auto_activate[model_id] = True
            return
        _download_errors.pop(model_id, None)
        _auto_activate[model_id] = activate
        env = dict(os.environ, HF_HUB_OFFLINE="0", HF_HUB_DISABLE_XET="1")
        if mirror:
            env["HF_ENDPOINT"] = MIRROR_ENDPOINT
        code = f"from huggingface_hub import snapshot_download as s; s({model_id!r})"
        _downloads[model_id] = subprocess.Popen(
            [sys.executable, "-I", "-c", code], env=env,
            stdin=subprocess.DEVNULL, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
        )
        if not _watcher_running:
            _watcher_running = True
            threading.Thread(target=_watch_downloads, daemon=True).start()


def _custom_size(rec: dict) -> float:
    if rec["source"] == "local":
        return round(_dir_bytes(rec["id"]) / 1e9, 2)
    if downloaded(rec["id"]):
        return round(_dir_bytes(_blobs_dir(rec["id"])) / 1e9, 2)
    return 0.0


def all_entries() -> list[dict]:
    entries = [{**c, "custom": False} for c in CATALOG]
    for r in custom_records():
        local = r["source"] == "local"
        entries.append({
            "id": r["id"],
            "kind": r["kind"],
            "name": r.get("name") or r["id"],
            "desc": "自定义 · 本地文件夹" if local else "自定义 · Hugging Face",
            "size_gb": _custom_size(r),
            "recommended": False,
            "tested": False,
            "custom": True,
            "source": r["source"],
        })
    return entries


def list_models() -> list[dict]:
    reap_downloads()
    items = []
    for entry in all_entries():
        model_id = entry["id"]
        downloading = is_downloading(model_id)
        current = MODEL if entry["kind"] == "asr" else LLM_MODEL
        items.append({
            **entry,
            "downloaded": downloaded(model_id),
            "active": model_id == current,
            "downloading": downloading,
            "progress": progress(model_id, entry["size_gb"]) if downloading else None,
            "error": _download_errors.get(model_id),
        })
    return items


def load_error_text(e: Exception) -> str:
    first = (str(e).strip().splitlines() or [type(e).__name__])[0]
    return "加载失败：" + first[:120]


def switch_asr(model_id: str) -> None:
    global model, MODEL, _gen_cache
    with _lock:
        try:
            new = load_model(model_id)
            _gen_cache = None
            generate_audio(new, model_id, np.zeros(16000, dtype=np.float32), hotwords=None)
        except Exception as e:
            raise BadRequest(load_error_text(e)) from e
        old, model, MODEL = model, new, model_id
        del old
        _free_memory()


def _load_llm(model_id: str):
    from mlx_lm import generate, load, stream_generate
    from mlx_lm.sample_utils import make_sampler

    m, tok = load(model_id)
    generate(m, tok, prompt="你好", max_tokens=8, sampler=make_sampler(temp=0.0))
    return m, tok, stream_generate, make_sampler


def switch_llm(model_id: str) -> None:
    global LLM_MODEL, llm_model, llm_tok, _llm_failed, _lm_stream_generate, _make_sampler
    with _lock:
        try:
            m, tok, stream, sampler = _load_llm(model_id)
        except Exception as e:
            raise BadRequest(load_error_text(e)) from e
        LLM_MODEL = model_id
        llm_model, llm_tok = m, tok
        _lm_stream_generate, _make_sampler = stream, sampler
        _llm_failed = False
        _free_memory()


def validate_local_model(path: str, kind: str) -> None:
    if not os.path.isdir(path):
        raise BadRequest("不是文件夹")
    if not os.path.isfile(os.path.join(path, "config.json")):
        raise BadRequest("缺少 config.json")
    if not any(n.endswith(".safetensors") for n in os.listdir(path)):
        raise BadRequest("没有 .safetensors 权重（不是 MLX 格式）")
    if kind == "llm":
        if not any(os.path.isfile(os.path.join(path, n)) for n in ("tokenizer.json", "tokenizer_config.json")):
            raise BadRequest("缺少 tokenizer.json 或 tokenizer_config.json")
        return
    try:
        with open(os.path.join(path, "config.json"), encoding="utf-8") as f:
            cfg = json.load(f)
    except (OSError, ValueError):
        raise BadRequest("config.json 不是有效 JSON")
    if not isinstance(cfg, dict):
        raise BadRequest("config.json 格式不对")
    hint = f"{cfg.get('model_type', '')} {cfg.get('architectures', '')}".lower()
    if not any(arch in hint for arch in ASR_ARCHS):
        print(f"warning: model_type/architectures not in known ASR list: {hint!r}", file=sys.stderr, flush=True)


def import_model(body: dict) -> str:
    source = body.get("source")
    value = str(body.get("value") or "").strip()
    kind = body.get("kind")
    if kind not in ("asr", "llm"):
        raise BadRequest("类型必须是 asr 或 llm")
    if source == "hf":
        if not HF_ID_RE.fullmatch(value):
            raise BadRequest("Hugging Face 仓库格式应为 组织/模型名")
        model_id = value
    elif source == "local":
        if not value or not os.path.isabs(os.path.expanduser(value)):
            raise BadRequest("需要绝对路径")
        model_id = os.path.abspath(os.path.expanduser(value))
        validate_local_model(model_id, kind)
    else:
        raise BadRequest("来源只能是 hf 或 local")
    if catalog_item(model_id) is not None:
        raise BadRequest("已存在")
    name = str(body.get("name") or "").strip() or (os.path.basename(model_id) if source == "local" else model_id)
    if source == "hf":
        start_download(model_id, bool(body.get("mirror")))
    save_prefs(custom_records() + [{"id": model_id, "kind": kind, "name": name, "source": source}])
    return model_id


def remove_model(model_id: str) -> None:
    item = catalog_item(model_id)
    if item is None or not item["custom"]:
        raise BadRequest("只能删除自定义模型")
    if model_id in (MODEL, LLM_MODEL):
        raise BadRequest("正在使用，不能删除")
    if is_downloading(model_id):
        raise BadRequest("正在下载，不能删除")
    with _dl_lock:
        _download_errors.pop(model_id, None)
    save_prefs([r for r in custom_records() if r["id"] != model_id])


def api_download(body: dict) -> dict:
    item = catalog_item(str(body.get("id") or ""))
    if item is None:
        raise BadRequest("未知模型")
    start_download(item["id"], bool(body.get("mirror")), bool(body.get("activate", True)))
    return {"ok": True}


def activate_model(model_id: str) -> None:
    item = catalog_item(model_id)
    if item is None:
        raise BadRequest("未知模型")
    if not downloaded(item["id"]):
        raise BadRequest("尚未下载")
    if item["kind"] == "asr":
        switch_asr(item["id"])
    else:
        switch_llm(item["id"])
    save_prefs()


def api_activate(body: dict) -> dict:
    activate_model(str(body.get("id") or ""))
    return {"ok": True}


def api_import(body: dict) -> dict:
    return {"ok": True, "id": import_model(body)}


def api_remove(body: dict) -> dict:
    remove_model(str(body.get("id") or ""))
    return {"ok": True}


def _stream_paths(local_only: bool) -> dict[str, str] | None:
    try:
        return {f: hf_hub_download(repo_id=STREAM_REPO, filename=f, local_files_only=local_only)
                for f in STREAM_FILES}
    except Exception:
        return None


def _stream_available() -> bool:
    try:
        import sherpa_onnx  # noqa: F401
    except Exception:
        return False
    return _stream_paths(local_only=True) is not None


def stream_status() -> dict:
    ok = _stream_available()
    if ok and _stream_rec is None:
        # warm up in the background: the first load costs ~0.8 s and must not land on the first dictation
        def warm():
            with _stream_lock:
                _load_stream_rec()
        threading.Thread(target=warm, daemon=True).start()
    return {"available": ok, "downloading": _stream_downloading}


def _stream_download_run() -> None:
    global _stream_downloading
    try:
        # subprocess: this server runs with HF_HUB_OFFLINE=1 (same reason as start_download)
        env = dict(os.environ, HF_HUB_OFFLINE="0", HF_HUB_DISABLE_XET="1")
        code = ("from huggingface_hub import hf_hub_download as d\n"
                f"for f in {list(STREAM_FILES)!r}: d({STREAM_REPO!r}, f)")
        r = subprocess.run([sys.executable, "-I", "-c", code], env=env, stdin=subprocess.DEVNULL,
                           stdout=subprocess.DEVNULL, stderr=subprocess.PIPE, timeout=1800)
        if r.returncode != 0:
            raise RuntimeError(r.stderr.decode("utf-8", "replace")[-300:])
        print("preview model downloaded", file=sys.stderr, flush=True)
    except Exception as e:
        print(f"preview download failed: {e}", file=sys.stderr, flush=True)
    finally:
        _stream_downloading = False


def api_stream_download(body: dict) -> dict:
    global _stream_downloading
    if _stream_available():
        return {"ok": True}
    with _dl_lock:
        if _stream_downloading:
            return {"ok": True}
        _stream_downloading = True
    threading.Thread(target=_stream_download_run, daemon=True).start()
    return {"ok": True}


def _load_stream_rec():
    # Caller must hold _stream_lock. Returns None when the preview recognizer is unavailable.
    global _stream_rec
    if _stream_rec is not None:
        return _stream_rec
    try:
        import sherpa_onnx
        paths = _stream_paths(local_only=True)
        if paths is None:
            return None
        t0 = time.perf_counter()
        _stream_rec = sherpa_onnx.OnlineRecognizer.from_paraformer(
            tokens=paths["tokens.txt"], encoder=paths["encoder.int8.onnx"], decoder=paths["decoder.int8.onnx"],
            num_threads=2, provider="cpu", sample_rate=TARGET_SR, feature_dim=80, decoding_method="greedy_search")
        print(f"preview loaded in {int((time.perf_counter() - t0) * 1000)} ms", file=sys.stderr, flush=True)
    except Exception as e:
        print(f"preview disabled: {e}", file=sys.stderr, flush=True)
        return None
    return _stream_rec


def _stream_decode(rec, s) -> str:
    while rec.is_ready(s):
        rec.decode_stream(s)
    return str(rec.get_result(s))


def _prune_streams(now: float) -> None:
    # Caller must hold _stream_lock.
    for sid in [k for k, (_, used) in _streams.items() if now - used > STREAM_IDLE_S]:
        del _streams[sid]


def stream_feed(sid: str, body: bytes) -> tuple[int, dict]:
    with _stream_lock:
        now = time.monotonic()
        _prune_streams(now)
        rec = _load_stream_rec()
        if rec is None:
            return 409, {"error": "unavailable"}
        entry = _streams.get(sid)
        s = entry[0] if entry else rec.create_stream()
        samples = np.frombuffer(body, dtype="<f4").astype(np.float32)
        if samples.size:
            s.accept_waveform(TARGET_SR, samples)
        text = _stream_decode(rec, s)
        _streams[sid] = (s, now)
        return 200, {"text": text}


def stream_end(sid: str) -> dict:
    with _stream_lock:
        now = time.monotonic()
        entry = _streams.pop(sid, None)
        _prune_streams(now)
        if entry is None or _stream_rec is None:
            return {"text": ""}
        s = entry[0]
        s.accept_waveform(TARGET_SR, np.zeros(int(STREAM_TAIL_S * TARGET_SR), dtype=np.float32))
        s.input_finished()
        return {"text": _stream_decode(_stream_rec, s)}


class Handler(BaseHTTPRequestHandler):
    def _send(self, code: int, obj: dict) -> None:
        body = json.dumps(obj, ensure_ascii=False).encode("utf-8")
        self.send_response(code)
        self.send_header("Content-Type", "application/json; charset=utf-8")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def _read_body(self) -> bytes:
        return self.rfile.read(int(self.headers.get("Content-Length", "0")))

    def do_GET(self) -> None:
        path = urlparse(self.path).path
        if path == "/health":
            self._send(200, {"ok": True, "version": SERVER_VERSION, "model": MODEL, "asr_model": MODEL, "llm_model": LLM_MODEL})
        elif path == "/models":
            self._send(200, {"items": list_models()})
        elif path == "/models/format":
            self._send(200, {"text": FORMAT_GUIDE})
        elif path == "/stream/status":
            self._send(200, stream_status())
        else:
            self._send(404, {"error": "not found"})

    def do_POST(self) -> None:
        path = urlparse(self.path).path
        if path == "/transcribe":
            self._transcribe()
        elif path == "/clean":
            self._clean()
        elif path == "/command":
            self._command()
        elif path == "/models/download":
            self._run_json(api_download)
        elif path == "/models/activate":
            self._run_json(api_activate)
        elif path == "/models/import":
            self._run_json(api_import)
        elif path == "/models/remove":
            self._run_json(api_remove)
        elif path == "/stream/download":
            self._run_json(api_stream_download)
        elif path == "/stream/feed":
            self._stream_feed()
        elif path == "/stream/end":
            self._stream_end()
        else:
            self._send(404, {"error": "not found"})

    def _json_body(self) -> dict:
        body = json.loads(self._read_body().decode("utf-8") or "{}")
        if not isinstance(body, dict):
            raise ValueError("body must be a JSON object")
        return body

    def _run_json(self, fn) -> None:
        try:
            self._send(200, fn(self._json_body()))
        except BadRequest as e:
            self._send(400, {"error": str(e)})
        except Exception as e:
            self._send(500, {"error": str(e)})

    def _transcribe(self) -> None:
        try:
            audio = decode_wav(self._read_body())
            hotwords = decode_hotwords(self.headers.get("X-Hotwords"))
            try:
                preview = base64.b64decode(self.headers.get("X-Preview") or "").decode("utf-8")
            except Exception:
                preview = ""
            context = select_context(hotwords, preview)
            dur = audio.size / TARGET_SR
            t0 = time.perf_counter()
            _asr_waiting.set()
            if not _lock.acquire(timeout=15):
                _asr_waiting.clear()
                self._send(503, {"error": "busy"})
                return
            _asr_waiting.clear()
            try:
                r = generate_audio(model, MODEL, audio, hotwords=context or None,
                                   max_tokens=int(dur * CHARS_PER_SEC) + 24)   # language: auto-detect (mixed zh/en)
                echoed = echoes_hotwords(result_text(r), context)
                if echoed:   # model read the hotword list back: redo without it
                    r = generate_audio(model, MODEL, audio, hotwords=None,
                                       max_tokens=int(dur * CHARS_PER_SEC) + 24)
            finally:
                _lock.release()
            raw = cap_length(collapse_repeats(result_text(r)), dur)
            if echoed:
                print(f"[asr] hotword echo, retried without hotwords: {raw[:60]}", file=sys.stderr, flush=True)
            text, events = phonetic_fix(raw, hotwords)
            similar = list(dict.fromkeys(e["to"] for e in events if e.get("action") == "suggest"))[:10]
            fixes = [[e["from"], e["to"]] for e in events if e.get("action") == "replace"]
            self._send(200, {
                "text": text,
                "raw": raw,
                "similar": similar,
                "fixes": fixes,
                "ms": int((time.perf_counter() - t0) * 1000),
                "dur": round(dur, 2),
            })
        except Exception as e:
            self._send(500, {"error": str(e)})

    def _clean(self) -> None:
        try:
            body = json.loads(self._read_body().decode("utf-8") or "{}")
            if not isinstance(body, dict):
                raise ValueError("body must be a JSON object")
            text = str(body.get("text") or "")
            context = str(body.get("context") or "")
            terms = [t for t in body.get("terms") or [] if isinstance(t, str) and t.strip()]
            style_hint = str(body.get("style_hint") or "").strip()
            rules_text = rules_clean(text, parse_corrections(body.get("corrections")))
            rules_text, _ = phonetic_fix(rules_text, terms)
            t0 = time.perf_counter()
            out, mode = polish(rules_text, context, terms, style_hint)
            self._send(200, {"text": out, "ms": int((time.perf_counter() - t0) * 1000), "mode": mode})
        except Exception as e:
            self._send(500, {"error": str(e)})

    def _command(self) -> None:
        try:
            body = json.loads(self._read_body().decode("utf-8") or "{}")
            if not isinstance(body, dict):
                raise ValueError("body must be a JSON object")
            instruction = str(body.get("instruction") or "")
            selected = str(body.get("selected") or "")
            t0 = time.perf_counter()
            out = run_command(instruction, selected)
            self._send(200, {"text": out, "ms": int((time.perf_counter() - t0) * 1000)})
        except LLMUnavailable as e:
            self._send(503, {"error": str(e)})
        except Exception as e:
            self._send(500, {"error": str(e)})

    def _stream_id(self) -> str:
        sid = parse_qs(urlparse(self.path).query).get("id", [""])[0]
        if not sid:
            raise BadRequest("missing id")
        return sid

    def _stream_feed(self) -> None:
        try:
            code, obj = stream_feed(self._stream_id(), self._read_body())
            self._send(code, obj)
        except BadRequest as e:
            self._send(400, {"error": str(e)})
        except Exception as e:
            self._send(500, {"error": str(e)})

    def _stream_end(self) -> None:
        try:
            self._send(200, stream_end(self._stream_id()))
        except BadRequest as e:
            self._send(400, {"error": str(e)})
        except Exception as e:
            self._send(500, {"error": str(e)})

    def log_message(self, format, *args) -> None:
        pass


if __name__ == "__main__":
    apply_startup_prefs()
    model = load_model(MODEL)
    with _lock:
        generate_audio(model, MODEL, np.zeros(16000, dtype=np.float32), hotwords=None)
    if LLM_MODEL != "none":
        threading.Thread(target=_unload_idle_llm, daemon=True).start()
    server = ThreadingHTTPServer(("127.0.0.1", PORT), Handler)
    print("ready", flush=True)
    server.serve_forever()
