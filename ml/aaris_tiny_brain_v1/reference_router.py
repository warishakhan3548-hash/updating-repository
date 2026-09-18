"""Reference inference for Aaris Tiny Brain v1.

Requires numpy + scikit-learn. This file does not perform inventory writes.
"""
from __future__ import annotations

import base64
import json
import re
from pathlib import Path

import numpy as np
from sklearn.pipeline import FeatureUnion
from sklearn.feature_extraction.text import HashingVectorizer

ROOT = Path(__file__).resolve().parent


def _load(name: str) -> dict:
    return json.loads((ROOT / name).read_text(encoding="utf-8"))


INTENT = _load("intent_hybrid_int8.json")
OCR = _load("ocr_role_hybrid_int8.json")


def _dequantized_linear(model: dict) -> tuple[np.ndarray, np.ndarray]:
    linear = model["linear"]
    shape = tuple(linear["shape"])
    q = np.frombuffer(base64.b64decode(linear["weight_b64"]), dtype=np.int8).reshape(shape)
    scales = np.asarray(linear["scale"], dtype=np.float32)[:, None]
    weights = q.astype(np.float32) * scales
    intercept = np.asarray(linear["intercept"], dtype=np.float32)
    return weights, intercept


INTENT_W, INTENT_B = _dequantized_linear(INTENT)
OCR_W, OCR_B = _dequantized_linear(OCR)

INTENT_VEC = FeatureUnion([
    ("char", HashingVectorizer(
        analyzer="char_wb", ngram_range=(2, 5), n_features=128,
        alternate_sign=True, norm="l2", lowercase=True,
    )),
    ("word", HashingVectorizer(
        analyzer="word", ngram_range=(1, 2), n_features=64,
        alternate_sign=True, norm="l2", lowercase=True,
        token_pattern=r"(?u)\b\w+\b",
    )),
])

OCR_VEC = HashingVectorizer(
    analyzer="char_wb", ngram_range=(2, 5), n_features=256,
    alternate_sign=True, norm="l2", lowercase=True,
)


def _norm(text: str) -> str:
    return re.sub(r"\s+", " ", text.lower().strip())


def _linear_predict(text: str, model: dict, vec, weights: np.ndarray, bias: np.ndarray) -> str:
    x = vec.transform([text]).toarray()[0].astype(np.float32)
    scores = weights @ x + bias
    return model["classes"][int(np.argmax(scores))]


def predict_intent(text: str) -> str:
    t = _norm(text)

    if any(k in t for k in (
        "youtube", "instagram", "whatsapp", "spotify", "calendar", "maps",
        "browser", "email", "weather", "temperature", "मौसम", "चाँद",
        "alarm", "wifi", "facebook", "capital of", "pm kaun", "कहानी", "poem",
    )):
        return "unknown"

    if t in {
        "hello", "hi", "namaste", "नमस्ते", "namaskar", "नमस्कार",
        "aadab", "hey", "hello ji", "hey there",
    } or t.startswith((
        "hi bhai", "hello bhai", "hello dost", "namaste ", "namaskar ",
        "नमस्ते ", "नमस्कार ", "good morning", "good evening", "aadab ", "hey ",
    )):
        return "greeting"

    if any(k in t for k in ("bring back", "recover", "restore", "wapas lao", "वापस लाओ", "फिर से लाओ"))        or ("removed" in t and any(k in t for k in ("wapas", "वापस")))        or ("archive se" in t and any(k in t for k in ("wapas", "वापस"))):
        return "restore"

    if any(k in t for k in ("scan", "ocr", "barcode", "camera")) and        any(k in t for k in ("medicine", "med", "pack", "label", "packet", "दवा", "बारकोड")):
        return "scan"

    if any(k in t for k in ("expiry", "expire", "expired", "एक्सपायरी")):
        return "expiry"

    if any(k in t for k in (
        "inventory summary", "inventory totals", "overall inventory", "total stock",
        "stock summary", "stock ka overview", "कुल स्टॉक", "पूरे stock",
        "total overview", "stock ka hisab", "medicine stock summary",
    )):
        return "inventory_summary"

    if any(k in t for k in (
        "fully sold", "all stock", "sara stock", "sab stock", "poori bik",
        "पूरी तरह", "पूरा खत्म", "ek bhi stock nahi", "out of stock",
    )) and any(k in t for k in ("sold", "bik", "sell", "बिक", "खत्म")):
        return "mark_sold"

    if any(k in t for k in (
        "sale event", "sell event", "record sale", "sale hui", "ki sale",
        "बिक्री", " biki", " bechi", " bikri", "sold today",
    )):
        return "record_sale"

    if any(k in t for k in (
        "received ", "receive ", "restock", "naya stock", "naya maal",
        "fresh maal", "fresh stock", "aur units", "और आए", "और आई",
        "और मिली", "aur pieces", "more of",
    )) and re.search(r"\d", t):
        return "receive_stock"

    if any(k in t for k in (
        "qty", "quantity", "count", "ginti", "गिनती", "correct stock",
        "actual stock", "ab sirf", "ab keval", "सही गिनती",
    )) and re.search(r"\d", t):
        return "set_quantity"

    if any(k in t for k in (
        "edit", "modify", "details badal", "details बदल", "info change",
        "change medicine info", "information change", "record badlo",
        "रिकॉर्ड बदल", "जानकारी बदल", "details correction",
    )):
        return "edit"

    if any(k in t for k in (
        "hata do", "hata dena", "hatao", "हटा", "हटानी",
        "remove", "archive", "सूची से हट",
    )):
        return "remove"

    if any(k in t for k in (
        "add new", "new medicine", "nayi medicine", "नई दवा", "new entry",
        "nayi entry", "नई entry", "new item", "naya record", "fresh record",
        "नया record", "database me daal", "list me jod", "जोड़",
    )) and not any(k in t for k in ("stock", "units", "pieces")):
        return "add"

    if any(k in t for k in (
        "search", "dhundo", "ढूंढ", "dikhao", "दिखाओ", "kaha hai", "कहाँ है",
        "find", "kitni bachi", "कितनी बची", "stock bata", "stock check",
        "availability", "available", "mil rahi", "milegi", "pada hai",
        "maujood", "मौजूद", "balance bata",
    )):
        return "search"

    return _linear_predict(text, INTENT, INTENT_VEC, INTENT_W, INTENT_B)


def predict_ocr_role(text: str) -> str:
    raw = text.strip()
    t = _norm(text)

    if any(k in t for k in ("manufactured by", "mfd by", "mfg by", "manufacturer ", "made by", "marketed by")):
        return "manufacturer"
    if any(k in t for k in ("exp ", "expiry", "exp.", "use by", "best before", "use before")):
        return "expiry"
    if any(k in t for k in ("mfg ", "mfd ", "mfg.", "manuf date", "manufactured ")):
        return "mfg"
    if any(k in t for k in ("batch", "b.no", "lot no", " lot ")):
        return "batch"
    if any(k in t for k in ("mrp", "m.r.p", "max retail price", "maximum retail price", "price")) or "₹" in raw:
        return "price"
    if any(k in t for k in ("keep ", "store ", "prescription only", "schedule h", "protect from", "shake well", "not for retail")):
        return "noise"
    if any(k in t for k in ("barcode", "bar code", "gtin", "ean")):
        return "barcode"

    compact = re.sub(r"\D", "", t)
    if len(compact) in {8, 12, 13} and not any(ch.isalpha() for ch in t):
        return "barcode"

    if any(k in t for k in ("composition", "contains", "active ingredient", "each tablet contains")):
        return "salt"

    if f" {t} ".find(" ip ") >= 0 and re.search(r"\b\d+(?:\.\d+)?\s*(?:mg|mcg|g|ml|iu)\b", t) and raw != raw.upper():
        return "salt"

    if any(k in t for k in ("dosage form", "oral suspension", "film-coated", "film coated", "capsules", "tablets ip", "syrup", "injection")):
        return "form"

    if re.search(r"\b\d+(?:\.\d+)?\s*(?:mg|mcg|g|ml|iu)\b", t):
        if raw == raw.upper() and 2 <= len(t.split()) <= 4:
            alpha_words = [w for w in re.findall(r"[A-Z]+", raw) if w not in {"MG", "ML", "MCG", "IU", "IP"}]
            if alpha_words:
                return "product_name"
        return "strength"

    if raw == raw.upper() and 1 <= len(t.split()) <= 4 and re.search(r"[A-Z]", raw):
        return "product_name"

    return _linear_predict(text, OCR, OCR_VEC, OCR_W, OCR_B)
