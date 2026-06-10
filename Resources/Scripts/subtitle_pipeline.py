#!/usr/bin/env python3
from __future__ import annotations

import argparse
import json
import os
import re
import subprocess
import sys
import tempfile
import time
import unicodedata
import urllib.request
from dataclasses import dataclass
from difflib import SequenceMatcher
from pathlib import Path


SUPPORTED_LANGUAGES = {"zh", "en", "ko", "ja"}
LANGUAGE_ALIASES = {
    "chinese": "zh",
    "mandarin": "zh",
    "english": "en",
    "korean": "ko",
    "japanese": "ja",
}
PUNCTUATION = "，。！？；：、,.!?;:%)]}》」』”’\""
BAD_DASH_RE = re.compile(r"[—–―-]{2,}")
LATIN_RE = re.compile(r"[A-Za-z]")
HAN_RE = re.compile(r"[\u4e00-\u9fff]")
HANGUL_RE = re.compile(r"[\uac00-\ud7af\u1100-\u11ff\u3130-\u318f]")
KANA_RE = re.compile(r"[\u3040-\u30ff]")
TOKEN_RE = re.compile(
    r"[A-Za-zÀ-ÖØ-öø-ÿĀ-ɏ0-9]+(?:['’][A-Za-zÀ-ÖØ-öø-ÿĀ-ɏ0-9]+)?"
    r"|[\uac00-\ud7af]+"
    r"|[\u3400-\u4dbf\u4e00-\u9fff\u3040-\u30ff]"
)

# A compact deterministic safety net. The LLM is still responsible for prose
# quality, but these common conversions keep final artifacts from leaking obvious
# Traditional Chinese when the source is already Chinese.
TRADITIONAL_TO_SIMPLIFIED = str.maketrans({
    "寶": "宝", "們": "们", "聽": "听", "遠": "远", "種": "种", "裡": "里",
    "這": "这", "個": "个", "為": "为", "來": "来", "對": "对", "會": "会",
    "時": "时", "說": "说", "話": "话", "還": "还", "讓": "让", "麼": "么",
    "與": "与", "過": "过", "氣": "气", "聲": "声", "體": "体", "頭": "头",
    "開": "开", "關": "关", "點": "点", "應": "应", "當": "当", "將": "将",
    "從": "从", "學": "学", "實": "实", "發": "发", "現": "现", "覺": "觉",
    "輕": "轻", "鬆": "松", "準": "准", "壓": "压", "醫": "医", "護": "护",
    "請": "请", "嗎": "吗", "別": "别", "樣": "样", "處": "处", "裏": "里",
    "緊": "紧", "張": "张", "顏": "颜", "淨": "净", "乾": "干", "濕": "湿",
    "邊": "边", "雙": "双", "級": "级", "終": "终", "經": "经", "夢": "梦",
})


@dataclass
class Cue:
    index: int
    start_ms: int
    end_ms: int
    text: str


def log(message: str) -> None:
    print(message, flush=True)


def parse_time(value: str) -> int:
    match = re.match(r"(\d+):(\d{2}):(\d{2}),(\d{3})", value.strip())
    if not match:
        raise ValueError(f"bad srt timestamp: {value!r}")
    h, m, s, ms = map(int, match.groups())
    return ((h * 60 + m) * 60 + s) * 1000 + ms


def fmt_time(ms: int) -> str:
    ms = max(0, int(round(ms)))
    h, rem = divmod(ms, 3600000)
    m, rem = divmod(rem, 60000)
    s, ms = divmod(rem, 1000)
    return f"{h:02d}:{m:02d}:{s:02d},{ms:03d}"


def parse_srt(raw: str) -> list[Cue]:
    blocks = re.split(r"\n\s*\n", raw.replace("\r\n", "\n").replace("\r", "\n").strip())
    cues: list[Cue] = []
    for fallback_index, block in enumerate(blocks, 1):
        lines = [line.strip() for line in block.splitlines() if line.strip()]
        if not lines:
            continue
        time_index = next((idx for idx, line in enumerate(lines) if "-->" in line), -1)
        if time_index < 0:
            continue
        try:
            start_text, end_text = [part.strip().split()[0] for part in lines[time_index].split("-->", 1)]
            start_ms = parse_time(start_text)
            end_ms = parse_time(end_text)
        except Exception:
            continue
        text = re.sub(r"\s+", " ", " ".join(lines[time_index + 1:])).strip()
        if not text or end_ms <= start_ms:
            continue
        try:
            cue_id = int(lines[0]) if time_index > 0 and lines[0].isdigit() else fallback_index
        except Exception:
            cue_id = fallback_index
        cues.append(Cue(cue_id, start_ms, end_ms, text))
    return cues


def write_srt(cues: list[Cue], path: Path) -> None:
    with path.open("w", encoding="utf-8", newline="\n") as handle:
        for index, cue in enumerate(cues, 1):
            handle.write(f"{index}\n")
            handle.write(f"{fmt_time(cue.start_ms)} --> {fmt_time(cue.end_ms)}\n")
            for line in wrap_zh(cue.text):
                handle.write(line + "\n")
            handle.write("\n")


def char_width(ch: str) -> float:
    if ch.isspace():
        return 0.5
    return 1.0 if unicodedata.east_asian_width(ch) in ("W", "F", "A") else 0.55


def width(text: str) -> float:
    return sum(char_width(ch) for ch in text)


def wrap_zh(text: str, limit: float = 28.0) -> list[str]:
    text = clean_final_zh(text)
    if not text:
        return []
    if width(text) <= limit:
        return [text]
    lines: list[str] = []
    buf = ""
    for ch in text:
        candidate = buf + ch
        if buf and width(candidate) > limit and ch not in PUNCTUATION:
            lines.append(buf)
            buf = ch
        else:
            buf = candidate
    if buf:
        lines.append(buf)
    if len(lines) <= 2:
        return lines
    first = lines[0]
    rest = "".join(lines[1:])
    return [first, rest] if rest else [first]


def clean_final_zh(text: str) -> str:
    text = (text or "").translate(TRADITIONAL_TO_SIMPLIFIED)
    text = re.sub(r"\b(?:ok|okay)\b", "好的", text, flags=re.I)
    text = re.sub(r"\s+", "", text)
    text = text.replace("～", "~")
    text = BAD_DASH_RE.sub("，", text)
    text = re.sub(r"，{2,}", "，", text)
    text = re.sub(r"。{2,}", "。", text)
    text = text.strip(" \t\r\n,，。")
    return text


def filename_language_hint(path: Path) -> str:
    name = path.name
    if HANGUL_RE.search(name):
        return "ko"
    if KANA_RE.search(name):
        return "ja"
    if HAN_RE.search(name):
        return "zh"
    if len(LATIN_RE.findall(name)) >= 6:
        return "en"
    return ""


def normalize_language(value: str) -> str:
    raw = re.split(r"[-_]", (value or "").strip().lower(), maxsplit=1)[0]
    return LANGUAGE_ALIASES.get(raw, raw)


def parse_detect_line(line: str) -> tuple[str, float]:
    match = re.search(r"auto-detected language:\s*([A-Za-z_-]+)(?:\s*\(p\s*=\s*([0-9.]+)\))?", line, re.I)
    if not match:
        return "", 0.0
    lang = normalize_language(match.group(1))
    prob = float(match.group(2) or "0")
    return (lang if lang in SUPPORTED_LANGUAGES else "", prob)


def run_command(cmd: list[str], log_path: Path | None = None) -> subprocess.CompletedProcess:
    log(f"RUN: {' '.join(cmd)}")
    proc = subprocess.run(cmd, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True, errors="replace")
    if log_path is not None:
        log_path.write_text(proc.stdout, encoding="utf-8")
    if proc.stdout:
        print(proc.stdout, end="" if proc.stdout.endswith("\n") else "\n", flush=True)
    return proc


def detect_language_samples(audio: Path, model: Path, duration_ms: int) -> list[dict]:
    offsets = [0]
    if duration_ms > 12 * 60 * 1000:
        offsets.extend([duration_ms // 3, (duration_ms * 2) // 3])
    elif duration_ms > 4 * 60 * 1000:
        offsets.append(duration_ms // 2)

    detections = []
    for offset in offsets:
        cmd = [
            "whisper-cli", "-m", str(model), "-f", str(audio),
            "-l", "auto", "-dl", "-ot", str(max(0, offset)), "-d", "90000",
        ]
        proc = run_command(cmd)
        lang, prob = "", 0.0
        for line in proc.stdout.splitlines():
            parsed_lang, parsed_prob = parse_detect_line(line)
            if parsed_lang:
                lang, prob = parsed_lang, parsed_prob
        detections.append({"offset_ms": offset, "language": lang, "probability": prob})
    return detections


def choose_language(configured: str, hint: str, detections: list[dict]) -> tuple[str, list[str]]:
    if configured in SUPPORTED_LANGUAGES:
        return configured, [configured]

    votes: dict[str, float] = {}
    for item in detections:
        lang = item.get("language") or ""
        prob = float(item.get("probability") or 0)
        if lang in SUPPORTED_LANGUAGES:
            votes[lang] = votes.get(lang, 0.0) + max(prob, 0.01)

    detected = max(votes, key=votes.get) if votes else ""
    best_prob = max((float(item.get("probability") or 0) for item in detections if item.get("language") == detected), default=0.0)

    candidates: list[str] = []
    if hint:
        candidates.append(hint)
    if detected:
        candidates.append(detected)
    if not candidates:
        candidates.append("en")

    # Whisper auto is weak for ASMR/no-speech. Treat low-confidence conflicts as
    # unresolved evidence and prefer the filename script, because titles are
    # stable metadata while low-confidence audio detection is known noisy here.
    if hint and detected and hint != detected and best_prob < 0.90:
        chosen = hint
    elif detected:
        chosen = detected
    elif hint:
        chosen = hint
    else:
        chosen = "en"

    ordered = [chosen] + [lang for lang in candidates if lang != chosen]
    high_confident_single = detected == chosen and best_prob >= 0.90
    metadata_agrees = bool(hint and detected and hint == detected == chosen)
    if high_confident_single or metadata_agrees:
        return chosen, [chosen]
    if not hint and not detected and "en" not in ordered:
        ordered.append("en")
    return chosen, list(dict.fromkeys(ordered))


def run_whisper(audio: Path, model: Path, language: str, output_base: Path) -> tuple[list[Cue], Path, Path]:
    log_path = output_base.with_suffix(f".{language}.whisper.log")
    cmd = [
        "whisper-cli", "-m", str(model), "-f", str(audio),
        "-l", language, "--suppress-nst", "-mc", "0", "-ml", "46",
        "-osrt", "-of", str(output_base),
    ]
    proc = run_command(cmd, log_path=log_path)
    srt_path = output_base.with_suffix(".srt")
    if proc.returncode != 0:
        raise RuntimeError(f"whisper failed for {language}: {proc.returncode}")
    if not srt_path.exists() or srt_path.stat().st_size == 0:
        raise RuntimeError(f"whisper produced no srt for {language}")
    cues = parse_srt(srt_path.read_text(encoding="utf-8-sig", errors="replace"))
    return cues, srt_path, log_path


def source_repeat_key(text: str) -> str:
    tokens = TOKEN_RE.findall((text or "").lower())
    if tokens:
        return " ".join(tokens)
    return re.sub(r"\s+", "", (text or "").lower())


def cue_quality(cues: list[Cue], *, source_mode: bool = False) -> dict:
    key_fn = source_repeat_key if source_mode else lambda value: normalized_repeat_key(value)
    texts = [key_fn(cue.text) for cue in cues if cue.text.strip()]
    counts: dict[str, int] = {}
    for text in texts:
        if text:
            counts[text] = counts.get(text, 0) + 1
    repeated_text, repeated_count = ("", 0)
    if counts:
        repeated_text, repeated_count = max(counts.items(), key=lambda item: item[1])
    total_chars = "".join(cue.text for cue in cues)
    distinct_count = len(counts)
    result = {
        "cue_count": len(cues),
        "distinct_text_count": distinct_count,
        "distinct_text_ratio": distinct_count / max(len(texts), 1),
        "latin_chars": len(LATIN_RE.findall(total_chars)),
        "kana_chars": len(KANA_RE.findall(total_chars)),
        "hangul_chars": len(HANGUL_RE.findall(total_chars)),
        "han_chars": len(HAN_RE.findall(total_chars)),
        "top_repeat_text": repeated_text,
        "top_repeat_count": repeated_count,
        "top_repeat_ratio": repeated_count / max(len(cues), 1),
        "dash_runs": len(BAD_DASH_RE.findall(total_chars)),
    }
    if source_mode:
        ngram_size = 5
        all_tokens = TOKEN_RE.findall(total_chars.lower())
        ngrams = [
            " ".join(all_tokens[index:index + ngram_size])
            for index in range(0, max(0, len(all_tokens) - ngram_size + 1))
        ]
        ngram_counts: dict[str, int] = {}
        for ngram in ngrams:
            ngram_counts[ngram] = ngram_counts.get(ngram, 0) + 1
        top_ngram, top_ngram_count = ("", 0)
        if ngram_counts:
            top_ngram, top_ngram_count = max(ngram_counts.items(), key=lambda item: item[1])
        result.update({
            "token_count": len(all_tokens),
            "top_ngram_text": top_ngram,
            "top_ngram_count": top_ngram_count,
            "top_ngram_ratio": top_ngram_count / max(len(ngrams), 1),
        })
    return result


def source_quality(cues: list[Cue], language: str) -> dict:
    text = "\n".join(cue.text for cue in cues)
    quality = cue_quality(cues, source_mode=True)
    if language == "ko":
        expected = quality["hangul_chars"]
    elif language == "ja":
        expected = quality["kana_chars"] + quality["han_chars"]
    elif language == "zh":
        expected = quality["han_chars"]
    else:
        expected = quality["latin_chars"]
    quality["expected_script_chars"] = expected
    quality["text_chars"] = len(re.sub(r"\s+", "", text))
    quality["expected_script_ratio"] = expected / max(quality["text_chars"], 1)
    return quality


def source_pathology_reasons(quality: dict) -> list[str]:
    cue_count = int(quality.get("cue_count") or 0)
    reasons: list[str] = []
    if cue_count == 0:
        reasons.append("raw Whisper candidate has no cues")
        return reasons
    if cue_count >= 20 and quality.get("top_repeat_count", 0) > max(24, cue_count * 0.18):
        reasons.append(
            f"raw Whisper candidate repeats one cue fragment {quality.get('top_repeat_count')} times"
        )
    if cue_count >= 40 and quality.get("distinct_text_ratio", 1.0) < 0.30:
        reasons.append(
            f"raw Whisper candidate has very low text diversity: {quality.get('distinct_text_ratio'):.2f}"
        )
    if quality.get("token_count", 0) >= 120 and quality.get("top_ngram_count", 0) > max(28, cue_count * 0.16):
        reasons.append(
            f"raw Whisper candidate repeats one token sequence {quality.get('top_ngram_count')} times"
        )
    if cue_count >= 20 and quality.get("dash_runs", 0) > max(10, cue_count * 0.12):
        reasons.append(
            f"raw Whisper candidate contains long dash hallucinations: {quality.get('dash_runs')}"
        )
    if cue_count >= 8 and quality.get("expected_script_ratio", 1.0) < 0.18:
        reasons.append(
            f"raw Whisper candidate has too little expected script: {quality.get('expected_script_ratio'):.2f}"
        )
    return reasons


def review_source_with_llm(
    cues: list[Cue],
    source_lang: str,
    source_video: Path,
    source_report: dict,
    base_url: str,
    model: str,
    api_key: str,
) -> dict:
    if not api_key:
        return {"usable": True, "reason": "no LLM API key; skipped source review"}
    sample_cues = cues[:120]
    transcript = [
        {
            "id": cue.index,
            "start": fmt_time(cue.start_ms),
            "end": fmt_time(cue.end_ms),
            "text": cue.text,
        }
        for cue in sample_cues
    ]
    system = (
        "You are a strict subtitle QA reviewer for ASMR videos. Return only JSON with shape "
        "{\"usable\":boolean,\"reason\":\"short reason\",\"confidence\":0.0}. "
        "You cannot hear the audio, so judge only whether this ASR transcript is credible text to edit. "
        "Mark usable=false when the transcript is dominated by generic filler, repeated loops, "
        "nonsensical phrases, obvious hallucination, long silence hallucinations, or very low content diversity. "
        "Be conservative: bad subtitles are worse than no subtitles. Do not reject merely because ASMR speech is soft, sparse, or naturally repetitive."
    )
    payload = {
        "model": model,
        "temperature": 0,
        "max_tokens": 700,
        "response_format": {"type": "json_object"},
        "messages": [
            {"role": "system", "content": system},
            {
                "role": "user",
                "content": json.dumps(
                    {
                        "video_filename": source_video.name,
                        "source_language": source_lang,
                        "source_quality": source_report,
                        "sampled_cue_count": len(sample_cues),
                        "total_cue_count": len(cues),
                        "transcript": transcript,
                    },
                    ensure_ascii=False,
                ),
            },
        ],
    }
    response = call_llm(base_url, model, api_key, payload)
    usable = bool(response.get("usable"))
    reason = str(response.get("reason") or "").strip()[:300]
    confidence = response.get("confidence")
    try:
        confidence = float(confidence)
    except Exception:
        confidence = 0.0
    return {"usable": usable, "reason": reason, "confidence": confidence}


def parse_json_content(content: str) -> dict:
    content = content.strip()
    if content.startswith("```"):
        content = re.sub(r"^```(?:json)?\s*", "", content)
        content = re.sub(r"\s*```$", "", content)
    try:
        return json.loads(content)
    except json.JSONDecodeError:
        pass
    candidates = []
    depth = 0
    start = None
    in_string = False
    escape = False
    for index, ch in enumerate(content):
        if in_string:
            if escape:
                escape = False
            elif ch == "\\":
                escape = True
            elif ch == '"':
                in_string = False
            continue
        if ch == '"':
            in_string = True
        elif ch == "{":
            if depth == 0:
                start = index
            depth += 1
        elif ch == "}" and depth:
            depth -= 1
            if depth == 0 and start is not None:
                candidates.append(content[start:index + 1])
                start = None
    for candidate in reversed(candidates):
        try:
            return json.loads(candidate)
        except json.JSONDecodeError:
            continue
    raise ValueError("no valid JSON object in LLM response")


def call_llm(base_url: str, model: str, api_key: str, payload: dict) -> dict:
    request = urllib.request.Request(
        base_url,
        data=json.dumps(payload).encode("utf-8"),
        headers={
            "Authorization": f"Bearer {api_key}",
            "Content-Type": "application/json",
            "Accept": "application/json",
            "User-Agent": "Orb/1.0 subtitle pipeline",
            "HTTP-Referer": "https://orb.local",
            "X-Title": "Orb Chinese Subtitle Editor",
        },
        method="POST",
    )
    with urllib.request.urlopen(request, timeout=90) as response:
        data = json.loads(response.read().decode("utf-8"))
    message = data["choices"][0]["message"]
    content = (message.get("content") or message.get("reasoning_content") or "").strip()
    return parse_json_content(content)


def language_name(lang: str) -> str:
    return {"zh": "Chinese", "en": "English", "ko": "Korean", "ja": "Japanese"}.get(lang, "source language")


def edit_batch_with_llm(
    cues: list[Cue],
    source_lang: str,
    base_url: str,
    model: str,
    api_key: str,
    start: int,
    end: int,
) -> dict[int, str]:
    targets = [
        {
            "id": cue.index,
            "start": fmt_time(cue.start_ms),
            "end": fmt_time(cue.end_ms),
            "text": cue.text,
        }
        for cue in cues[start:end]
    ]
    context_start = max(0, start - 5)
    context_end = min(len(cues), end + 5)
    context = [
        {"id": cue.index, "text": cue.text}
        for cue in cues[context_start:context_end]
    ]
    target_ids = [item["id"] for item in targets]
    system = (
        "You are a strict ASMR subtitle editor. Return only JSON with shape "
        "{\"items\":[{\"id\":number,\"keep\":boolean,\"zh\":\"...\"}]}. "
        "Return one item for every target id, and never edit context-only ids. "
        "The final subtitle must be Simplified Chinese only. Do not include the source language, "
        "English, Japanese, Korean, romaji, explanations, markdown, or notes. "
        "Delete hallucinated non-speech labels, music/noise labels, empty cues, and pathological loops by setting keep=false. "
        "For real repeated ASMR trigger words, keep a short natural Chinese phrase instead of repeating it many times. "
        "Convert all Traditional Chinese to Simplified Chinese. Avoid long dash runs; use normal Chinese punctuation. "
        f"The source cue language is {language_name(source_lang)}."
    )
    payload = {
        "model": model,
        "temperature": 0.1,
        "max_tokens": min(8000, max(1800, sum(len(item["text"]) for item in targets) * 3 + 1000)),
        "response_format": {"type": "json_object"},
        "messages": [
            {"role": "system", "content": system},
            {
                "role": "user",
                "content": json.dumps(
                    {
                        "target_ids": target_ids,
                        "context_for_reference_only": context,
                        "targets_to_return": targets,
                    },
                    ensure_ascii=False,
                ),
            },
        ],
    }
    expected = {cue.index for cue in cues[start:end]}
    last_error: Exception | None = None
    for attempt in range(2):
        try:
            response = call_llm(base_url, model, api_key, payload)
            items = response.get("items")
            if not isinstance(items, list):
                raise ValueError("missing items")
            edited: dict[int, str] = {}
            seen = set()
            for item in items:
                if not isinstance(item, dict):
                    raise ValueError("item is not object")
                cue_id = item.get("id")
                if cue_id not in expected:
                    continue
                if cue_id in seen:
                    continue
                seen.add(cue_id)
                keep = bool(item.get("keep"))
                text = clean_final_zh(str(item.get("zh") or ""))
                edited[cue_id] = text if keep and text else ""
            if seen != expected:
                raise ValueError("incomplete ids")
            return edited
        except Exception as error:
            last_error = error
            log(f"WARN LLM edit attempt {attempt + 1} failed for ids {min(expected)}-{max(expected)}: {error}")
    if end - start <= 1:
        raise RuntimeError(f"LLM edit failed for cue {next(iter(expected))}: {last_error}")
    mid = start + (end - start) // 2
    left = edit_batch_with_llm(cues, source_lang, base_url, model, api_key, start, mid)
    right = edit_batch_with_llm(cues, source_lang, base_url, model, api_key, mid, end)
    left.update(right)
    return left


def deterministic_source_to_zh(text: str, source_lang: str) -> str:
    text = clean_final_zh(text)
    if source_lang == "zh":
        return text
    return ""


def edit_to_chinese(
    cues: list[Cue],
    source_lang: str,
    base_url: str,
    model: str,
    api_key: str,
    batch_size: int,
) -> tuple[list[Cue], list[str]]:
    warnings: list[str] = []
    edited_by_id: dict[int, str] = {}
    if not api_key:
        warnings.append("missing LLM API key; Chinese source cleaned deterministically, non-Chinese cues dropped")
        for cue in cues:
            edited_by_id[cue.index] = deterministic_source_to_zh(cue.text, source_lang)
    else:
        for start in range(0, len(cues), batch_size):
            end = min(len(cues), start + batch_size)
            log(f"LLM_EDIT: cues {start + 1}-{end}")
            edited_by_id.update(edit_batch_with_llm(cues, source_lang, base_url, model, api_key, start, end))

    out: list[Cue] = []
    for cue in cues:
        text = clean_final_zh(edited_by_id.get(cue.index, ""))
        if not text:
            continue
        out.append(Cue(cue.index, cue.start_ms, cue.end_ms, text))
    out = remove_pathological_repeats(out)
    return out, warnings


def normalized_repeat_key(text: str) -> str:
    return re.sub(r"[，。！？；：、,.!?;:~\s]+", "", clean_final_zh(text).lower())


def similar_text(a: str, b: str) -> float:
    if not a or not b:
        return 0.0
    shorter, longer = sorted((a, b), key=len)
    if len(shorter) < 4:
        return 0.0
    if shorter in longer and len(shorter) / max(len(longer), 1) >= 0.55:
        return 1.0
    return SequenceMatcher(None, a, b).ratio()


def remove_pathological_repeats(cues: list[Cue]) -> list[Cue]:
    if len(cues) < 3:
        return cues
    out: list[Cue] = []
    counts: dict[str, int] = {}
    near_counts: list[tuple[str, int]] = []
    for cue in cues:
        key = normalized_repeat_key(cue.text)
        if not key:
            continue
        counts[key] = counts.get(key, 0) + 1
        # Keep a little intentional repetition, but stop global hallucination loops.
        if len(key) >= 4 and counts[key] > 3:
            continue
        if counts[key] > 1:
            out.append(cue)
            continue
        near_match_index = next(
            (
                index for index, (existing, _count) in enumerate(near_counts)
                if similar_text(key, existing) >= 0.72
            ),
            -1,
        )
        if near_match_index >= 0:
            existing, count = near_counts[near_match_index]
            near_counts[near_match_index] = (existing, count + 1)
            if count >= 2:
                continue
        elif len(key) >= 4:
            near_counts.append((key, 1))
        out.append(cue)
    return out


def near_repeat_summary(cues: list[Cue]) -> dict:
    clusters: list[tuple[str, int]] = []
    for cue in cues:
        key = normalized_repeat_key(cue.text)
        if len(key) < 4:
            continue
        match_index = next(
            (
                index for index, (existing, _count) in enumerate(clusters)
                if similar_text(key, existing) >= 0.68
            ),
            -1,
        )
        if match_index >= 0:
            existing, count = clusters[match_index]
            clusters[match_index] = (existing, count + 1)
        else:
            clusters.append((key, 1))
    top_text, top_count = ("", 0)
    if clusters:
        top_text, top_count = max(clusters, key=lambda item: item[1])
    return {
        "near_repeat_text": top_text,
        "near_repeat_count": top_count,
        "near_repeat_ratio": top_count / max(len(cues), 1),
    }


def validate_final(cues: list[Cue]) -> tuple[bool, list[str], dict]:
    quality = cue_quality(cues)
    quality.update(near_repeat_summary(cues))
    reasons: list[str] = []
    if not cues:
        reasons.append("no final Chinese cues")
    if quality["latin_chars"] > 0:
        reasons.append(f"final subtitle contains latin chars: {quality['latin_chars']}")
    if quality["kana_chars"] > 0:
        reasons.append(f"final subtitle contains kana chars: {quality['kana_chars']}")
    if quality["hangul_chars"] > 0:
        reasons.append(f"final subtitle contains hangul chars: {quality['hangul_chars']}")
    if quality["dash_runs"] > 0:
        reasons.append(f"final subtitle contains long dash runs: {quality['dash_runs']}")
    if quality["top_repeat_count"] > max(6, len(cues) * 0.05):
        reasons.append(
            f"pathological repeated cue: {quality['top_repeat_text']!r} x {quality['top_repeat_count']}"
        )
    if quality["near_repeat_count"] >= max(5, len(cues) * 0.35):
        reasons.append(
            f"pathological near-duplicate cues: {quality['near_repeat_text']!r} x {quality['near_repeat_count']}"
        )
    return not reasons, reasons, quality


def audio_duration_ms(audio: Path) -> int:
    raw = subprocess.check_output([
        "ffprobe", "-v", "error", "-show_entries", "format=duration",
        "-of", "default=nw=1:nk=1", str(audio),
    ], stderr=subprocess.DEVNULL).decode().strip()
    return int(float(raw) * 1000) if raw else 0


def run_pipeline(args: argparse.Namespace) -> int:
    source_video = Path(args.source_video)
    audio = Path(args.audio)
    model = Path(args.model)
    output = Path(args.output)
    report_path = Path(args.report)
    configured = normalize_language(args.language)
    if configured not in SUPPORTED_LANGUAGES and configured != "auto":
        configured = "auto"

    report: dict = {
        "sourceVideo": str(source_video),
        "audio": str(audio),
        "configuredLanguage": configured,
        "startedAt": int(time.time()),
    }
    try:
        duration_ms = audio_duration_ms(audio)
        hint = filename_language_hint(source_video)
        detections = detect_language_samples(audio, model, duration_ms) if configured == "auto" else []
        chosen, candidates = choose_language(configured, hint, detections)
        report.update({
            "durationMs": duration_ms,
            "filenameLanguageHint": hint,
            "languageDetections": detections,
            "chosenLanguage": chosen,
            "languageCandidates": candidates,
        })

        best: dict | None = None
        candidate_errors = []
        with tempfile.TemporaryDirectory(prefix="orb-subtitle-pipeline-") as tmpdir_text:
            tmpdir = Path(tmpdir_text)
            for candidate in candidates[:3]:
                base = tmpdir / f"candidate-{candidate}"
                try:
                    cues, raw_srt, whisper_log = run_whisper(audio, model, candidate, base)
                    source_report = source_quality(cues, candidate)
                    log(f"SOURCE_QUALITY {candidate}: {json.dumps(source_report, ensure_ascii=False)}")
                    source_reasons = source_pathology_reasons(source_report)
                    if source_reasons:
                        report.setdefault("candidateReports", []).append({
                            "language": candidate,
                            "rawCueCount": len(cues),
                            "rawSrt": str(raw_srt),
                            "whisperLog": str(whisper_log),
                            "sourceQuality": source_report,
                            "accepted": False,
                            "validationReasons": source_reasons,
                        })
                        log(f"REJECT_SOURCE {candidate}: {'; '.join(source_reasons)}")
                        continue
                    source_review = review_source_with_llm(
                        cues,
                        candidate,
                        source_video,
                        source_report,
                        args.llm_base_url,
                        args.llm_model,
                        args.api_key,
                    )
                    log(f"SOURCE_REVIEW {candidate}: {json.dumps(source_review, ensure_ascii=False)}")
                    if not source_review.get("usable", False):
                        report.setdefault("candidateReports", []).append({
                            "language": candidate,
                            "rawCueCount": len(cues),
                            "rawSrt": str(raw_srt),
                            "whisperLog": str(whisper_log),
                            "sourceQuality": source_report,
                            "sourceReview": source_review,
                            "accepted": False,
                            "validationReasons": [
                                f"LLM source review rejected candidate: {source_review.get('reason') or 'unusable ASR transcript'}"
                            ],
                        })
                        log(f"REJECT_SOURCE_REVIEW {candidate}: {source_review.get('reason')}")
                        continue
                    edited, warnings = edit_to_chinese(
                        cues,
                        candidate,
                        args.llm_base_url,
                        args.llm_model,
                        args.api_key,
                        args.batch_size,
                    )
                    ok, reasons, final_quality = validate_final(edited)
                    candidate_report = {
                        "language": candidate,
                        "rawCueCount": len(cues),
                        "rawSrt": str(raw_srt),
                        "whisperLog": str(whisper_log),
                        "sourceQuality": source_report,
                        "sourceReview": source_review,
                        "finalCueCount": len(edited),
                        "finalQuality": final_quality,
                        "warnings": warnings,
                        "validationReasons": reasons,
                        "accepted": ok,
                    }
                    report.setdefault("candidateReports", []).append(candidate_report)
                    score = (
                        final_quality.get("han_chars", 0)
                        - final_quality.get("latin_chars", 0) * 10
                        - final_quality.get("kana_chars", 0) * 10
                        - final_quality.get("hangul_chars", 0) * 10
                        - final_quality.get("top_repeat_count", 0) * 20
                    )
                    if best is None or score > best["score"]:
                        best = {"score": score, "cues": edited, "report": candidate_report}
                    if ok:
                        best = {"score": score, "cues": edited, "report": candidate_report}
                        break
                except Exception as error:
                    candidate_errors.append({"language": candidate, "error": str(error)})
                    log(f"WARN candidate {candidate} failed: {error}")

        report["candidateErrors"] = candidate_errors
        if best is None:
            report["status"] = "failed-quality"
            report["validationReasons"] = [
                reason
                for candidate_report in report.get("candidateReports", [])
                for reason in candidate_report.get("validationReasons", [])
            ] or ["all candidates failed quality checks"]
            report_path.write_text(json.dumps(report, ensure_ascii=False, indent=2), encoding="utf-8")
            log(f"QUALITY_FAILED: {report['validationReasons']}")
            return 3
        accepted_report = best["report"]
        accepted_cues = best["cues"]
        ok, reasons, final_quality = validate_final(accepted_cues)
        report["acceptedLanguage"] = accepted_report["language"]
        report["finalQuality"] = final_quality
        report["validationReasons"] = reasons
        if not ok and not args.allow_failed_quality:
            report["status"] = "failed-quality"
            report_path.write_text(json.dumps(report, ensure_ascii=False, indent=2), encoding="utf-8")
            log(f"QUALITY_FAILED: {reasons}")
            return 3
        write_srt(accepted_cues, output)
        report["status"] = "ok" if ok else "forced"
        report["output"] = str(output)
        report_path.write_text(json.dumps(report, ensure_ascii=False, indent=2), encoding="utf-8")
        log(f"PIPELINE_OK: {output}")
        return 0
    except Exception as error:
        report["status"] = "error"
        report["error"] = str(error)
        report_path.write_text(json.dumps(report, ensure_ascii=False, indent=2), encoding="utf-8")
        log(f"PIPELINE_ERROR: {error}")
        return 1


def self_test() -> int:
    assert filename_language_hint(Path("ASMR(Sub✔)더미.mkv")) == "ko"
    assert filename_language_hint(Path("ASMR 何気に優しい.mkv")) == "ja"
    assert filename_language_hint(Path("中文助眠.mp4")) == "zh"
    assert filename_language_hint(Path("Whispers & Hand Movement ASMR.mp4")) == "en"
    chosen, candidates = choose_language(
        "auto",
        "ko",
        [{"language": "en", "probability": 0.66}],
    )
    assert chosen == "ko", (chosen, candidates)
    chosen, candidates = choose_language(
        "auto",
        "",
        [{"language": "zh", "probability": 0.67}],
    )
    assert chosen == "zh", (chosen, candidates)
    chosen, candidates = choose_language(
        "auto",
        "en",
        [{"language": "zh", "probability": 0.67}],
    )
    assert chosen == "en", (chosen, candidates)
    assert clean_final_zh("寶寶們聽到了嗎——") == "宝宝们听到了吗"
    cues = [Cue(i, i * 1000, i * 1000 + 900, "就要做手指的方法") for i in range(10)]
    assert len(remove_pathological_repeats(cues)) == 3
    source_loop = source_quality(
        [
            Cue(i, i * 1000, i * 1000 + 900, "Okay, I'm going to show you what I'm going to do now.")
            for i in range(40)
        ],
        "en",
    )
    assert source_pathology_reasons(source_loop), source_loop
    varied_loop = [
        Cue(1, 0, 1000, "现在我要给你看我要做什么"),
        Cue(2, 1000, 2000, "我现在要给你看看我要做什么"),
        Cue(3, 2000, 3000, "我现在要向你展示我将要做什么"),
        Cue(4, 3000, 4000, "好的，我现在要给你看我要做什么"),
        Cue(5, 4000, 5000, "好了，我现在要给你看我要做什么"),
        Cue(6, 5000, 6000, "谢谢"),
    ]
    ok, reasons, _quality = validate_final(varied_loop)
    assert not ok and any("near-duplicate" in reason for reason in reasons), reasons
    ok, reasons, _quality = validate_final([Cue(1, 0, 1000, "hello")])
    assert not ok and any("latin" in reason for reason in reasons)
    ok, reasons, _quality = validate_final([Cue(1, 0, 1000, "你好")])
    assert ok, reasons
    print("subtitle_pipeline self-test passed")
    return 0


def main() -> int:
    parser = argparse.ArgumentParser(description="Orb Chinese subtitle pipeline")
    parser.add_argument("--self-test", action="store_true")
    parser.add_argument("--audio")
    parser.add_argument("--source-video")
    parser.add_argument("--model")
    parser.add_argument("--language", default="auto")
    parser.add_argument("--output")
    parser.add_argument("--report")
    parser.add_argument("--llm-base-url", default="https://opencode.ai/zen/go/v1/chat/completions")
    parser.add_argument("--llm-model", default="mimo-v2.5")
    parser.add_argument("--api-key", default="")
    parser.add_argument("--batch-size", type=int, default=50)
    parser.add_argument("--allow-failed-quality", action="store_true")
    args = parser.parse_args()
    if args.self_test:
        return self_test()
    required = ["audio", "source_video", "model", "output", "report"]
    missing = [name for name in required if not getattr(args, name)]
    if missing:
        parser.error(f"missing required arguments: {', '.join(missing)}")
    return run_pipeline(args)


if __name__ == "__main__":
    raise SystemExit(main())
