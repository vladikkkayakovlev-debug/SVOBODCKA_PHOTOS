from flask import Flask, request, jsonify
import requests
import os
import time
from urllib.parse import unquote

# Render → Environment → BOT_TOKEN (нужен только если будешь скачивать через Telegram file_id)
BOT_TOKEN = os.environ.get("BOT_TOKEN")

app = Flask(__name__)

# Последний входящий запрос от BotHelp (для отладки)
LAST = {}


def _save_bytes(content: bytes, filename: str) -> str:
    os.makedirs(os.path.dirname(filename), exist_ok=True)
    with open(filename, "wb") as f:
        f.write(content)
    return filename


def _guess_ext_from_url(url: str) -> str:
    # Берём расширение из URL без query
    base = url.split("?", 1)[0]
    _, ext = os.path.splitext(base)
    return ext if ext else ".jpg"


@app.route("/", methods=["GET"])
def root():
    return "ok", 200


@app.route("/debug/last", methods=["GET"])
def debug_last():
    return jsonify(LAST), 200


@app.route("/bothelp/webhook", methods=["POST", "GET"])
def bothelp_webhook():
    global LAST

    # Проверочный GET (иногда сервисы стучатся)
    if request.method == "GET":
        return "ok", 200

    # 1) Пытаемся прочитать JSON
    data = request.get_json(silent=True)

    # 2) Если не JSON — читаем form-data / x-www-form-urlencoded
    if not data:
        data = request.form.to_dict()

    # Сохраняем всё для /debug/last
    LAST = {
        "content_type": request.content_type,
        "form": request.form.to_dict(),
        "json": request.get_json(silent=True),
        "args": request.args.to_dict(),
        "data": data
    }

    # --- Достаём поля ---
    image_url = None
    file_id = None
    listing_id = "unknown"

    if isinstance(data, dict):
        image_url = data.get("image_url") or data.get("url") or data.get("photo_url")
        file_id = data.get("file_id")

        # если у тебя есть ID квартиры — сюда же
        listing_id = data.get("listing_id") or data.get("flat_id") or data.get("item_id") or "unknown"

    # --- Вариант А: BotHelp дал ссылку (у тебя сейчас именно так) ---
    if image_url:
        try:
            # BotHelp иногда отдаёт url с двойной кодировкой (%252F -> %2F -> /)
            # unquote 2 раза — самый надёжный способ
            clean_url = unquote(unquote(image_url))

            resp = requests.get(clean_url, timeout=40)
            resp.raise_for_status()

            ext = _guess_ext_from_url(clean_url)
            filename = f"photos/{listing_id}_{int(time.time())}{ext}"

            _save_bytes(resp.content, filename)

            return jsonify({
                "ok": True,
                "mode": "image_url",
                "saved_as": filename,
                "listing_id": listing_id,
                "source_url": clean_url
            }), 200

        except Exception as e:
            return jsonify({
                "ok": False,
                "error": "Failed to download/save by image_url",
                "detail": str(e),
                "received": LAST
            }), 500

    # --- Вариант B: если когда-нибудь появится file_id (через Telegram API) ---
    if file_id:
        if not BOT_TOKEN:
            return jsonify({
                "ok": False,
                "error": "BOT_TOKEN is missing (Render → Environment)",
                "received": LAST
            }), 500

        try:
            r = requests.get(
                f"https://api.telegram.org/bot{BOT_TOKEN}/getFile",
                params={"file_id": file_id},
                timeout=20
            )
            r.raise_for_status()
            j = r.json()
            if not j.get("ok"):
                return jsonify({"ok": False, "error": "Telegram getFile failed", "telegram": j}), 502

            file_path = j["result"]["file_path"]
            file_url = f"https://api.telegram.org/file/bot{BOT_TOKEN}/{file_path}"

            photo_resp = requests.get(file_url, timeout=40)
            photo_resp.raise_for_status()

            ext = os.path.splitext(file_path)[1] or ".jpg"
            filename = f"photos/{listing_id}_{file_id}{ext}"
            _save_bytes(photo_resp.content, filename)

            return jsonify({
                "ok": True,
                "mode": "telegram_file_id",
                "saved_as": filename,
                "listing_id": listing_id,
                "file_id": file_id
            }), 200

        except Exception as e:
            return jsonify({
                "ok": False,
                "error": "Failed to download/save by file_id",
                "detail": str(e),
                "received": LAST
            }), 500

    # --- Если ни ссылки, ни file_id ---
    return jsonify({
        "ok": False,
        "error": "No image_url or file_id in request",
        "hint": "Проверь BotHelp: внешний запрос должен отправлять image_url (ссылку) или file_id",
        "received": LAST
    }), 400


if __name__ == "__main__":
    port = int(os.environ.get("PORT", 10000))
    app.run(host="0.0.0.0", port=port)
