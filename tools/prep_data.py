#!/usr/bin/env python3
"""Builds dictionary and n-gram resources from FrequencyWords lists.

Inputs: data-raw/{ru,en,sk}_full.txt (word count per line).
Outputs: Resources/data/{lang}.dict (binary), {lang}.ngram (text),
and test word lists in Tests/data.
"""
import random, re, struct, sys, unicodedata
from collections import Counter, defaultdict
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
RAW = ROOT / "data-raw"
RES = ROOT / "Resources/data"
TESTS = ROOT / "Tests/data"

PATTERNS = {
    "ru": re.compile(r"^[а-яё]+(-[а-яё]+)*$"),
    "en": re.compile(r"^[a-z]+('[a-z]+)?(-[a-z]+)*$"),
    "sk": re.compile(r"^[a-záäčďéíĺľňóôŕšťúýž]+(-[a-záäčďéíĺľňóôŕšťúýž]+)*$"),
}
MIN_COUNT = {"ru": 3, "en": 3, "sk": 2}
NGRAM_ORDER = 4


def fnv1a(s: str) -> int:
    h = 0xcbf29ce484222325
    for b in s.encode("utf-8"):
        h ^= b
        h = (h * 0x100000001b3) & 0xFFFFFFFFFFFFFFFF
    return h


def norm(lang, w):
    w = unicodedata.normalize("NFC", w.lower())
    if lang == "ru":
        w = w.replace("ё", "е")
    return w


def strip_diacritics(w):
    return "".join(c for c in unicodedata.normalize("NFD", w) if unicodedata.category(c) != "Mn")


WIKI = {"en": "enwiki.txt", "ru": "ruwiki.txt"}
WIKI_MIN_COUNT = 10
WIKI_WEIGHT = 0.35  # share of Wikipedia in the merged frequency


def load(lang, fname=None):
    counts = Counter()
    for line in open(RAW / (fname or f"{lang}_full.txt"), encoding="utf-8"):
        parts = line.rstrip("\n").rsplit(" ", 1)
        if len(parts) != 2:
            continue
        w, c = parts
        w = unicodedata.normalize("NFC", w.lower())
        if not PATTERNS[lang].match(w):
            continue
        counts[norm(lang, w)] += int(c)
    return counts


def write_dict(lang, words):
    # words: dict normalized word -> count
    items = sorted((fnv1a(w), c) for w, c in words.items())
    # collapse hash collisions (practically none)
    merged = {}
    for h, c in items:
        merged[h] = max(merged.get(h, 0), c)
    keys = sorted(merged)
    total = sum(words.values())
    with open(RES / f"{lang}.dict", "wb") as f:
        f.write(b"WEKD")
        f.write(struct.pack("<IQ", len(keys), total))
        for h in keys:
            f.write(struct.pack("<Q", h))
        for h in keys:
            f.write(struct.pack("<I", min(merged[h], 0xFFFFFFFF)))
    return len(keys), total


def write_ngrams(lang, words):
    # Trained on word types (each dictionary word counts once): this models the
    # shape of rare words, which is exactly what the n-gram fallback is used for.
    grams = Counter()
    for w in words:
        s = "^" * (NGRAM_ORDER - 1) + w.replace("-", "") + "$"
        for n in range(1, NGRAM_ORDER + 1):
            for i in range(NGRAM_ORDER - n, len(s) - n + 1):
                g = s[i:i + n]
                if n > 1 or g != "^":
                    grams[g] += 1
    with open(RES / f"{lang}.ngram", "w", encoding="utf-8") as f:
        for g, c in sorted(grams.items()):
            f.write(f"{g}\t{c}\n")
    return len(grams)


def main():
    random.seed(20261108)
    RES.mkdir(parents=True, exist_ok=True)
    TESTS.mkdir(parents=True, exist_ok=True)
    for lang in ("ru", "en", "sk"):
        counts = load(lang)
        dict_words = {w: c for w, c in counts.items() if c >= MIN_COUNT[lang]}
        if lang in WIKI:
            # Subtitles give everyday speech, Wikipedia adds names and technical
            # vocabulary. Mix relative frequencies, store as parts per 1e9.
            # Short Wikipedia tokens are mostly abbreviations: take them only if
            # the subtitles know the word too.
            wiki = {w: c for w, c in load(lang, WIKI[lang]).items()
                    if c >= WIKI_MIN_COUNT and (len(w) > 3 or w in dict_words)}
            ts, tw = sum(dict_words.values()), sum(wiki.values())
            merged = {}
            for w in set(dict_words) | set(wiki):
                p = (1 - WIKI_WEIGHT) * dict_words.get(w, 0) / ts + WIKI_WEIGHT * wiki.get(w, 0) / tw
                c = round(p * 1e9)
                if c >= 1:
                    merged[w] = c
            dict_words = merged
        rare = [w for w, c in counts.items() if c < MIN_COUNT[lang] and w not in dict_words
                and len(w) >= 4 and "-" not in w and "'" not in w]
        ng_words = dict_words
        if lang == "sk":
            # Slovak typed without diacritics must be recognised too.
            stripped = defaultdict(int)
            for w, c in dict_words.items():
                s = strip_diacritics(w)
                if s != w:
                    stripped[s] += c
            for s, c in stripped.items():
                dict_words[s] = max(dict_words.get(s, 0), c)
        n, total = write_dict(lang, dict_words)
        g = write_ngrams(lang, ng_words if lang != "sk" else {w: 1 for w in dict_words})
        print(f"{lang}: dict {n} words, total {total}, ngrams {g}, rare pool {len(rare)}")

        # Test lists. Frequent: sampled proportionally to frequency (what a person
        # actually types). Mid: uniform over dictionary ranks 2k..100k. Rare: words
        # below the dictionary threshold, unseen by the model.
        base = {w: c for w, c in counts.items() if c >= MIN_COUNT[lang]}
        ranked = sorted(base.items(), key=lambda x: -x[1])
        pool = [w for w, _ in ranked[:20000]]
        weights = [c for _, c in ranked[:20000]]
        freq = set()
        while len(freq) < 500:
            freq.add(random.choices(pool, weights)[0])
        mid = random.sample([w for w, _ in ranked[2000:100000]], 1000)
        rare_s = random.sample(rare, 1000)
        for name, lst in (("freq", sorted(freq)), ("mid", mid), ("rare", rare_s)):
            (TESTS / f"{lang}_{name}.txt").write_text("\n".join(lst) + "\n", encoding="utf-8")


if __name__ == "__main__":
    main()
