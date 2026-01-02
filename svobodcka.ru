from flask import Flask, request, jsonify
import requests
import os

# Токен бота берём из Render → Environment → BOT_TOKEN
BOT_TOKEN = os.environ.get("BOT_TOKEN")

app = Flask(__name__)

# Сюда будем сохранять последний входящий запрос от BotHelp (для отладки)
LAST = {}


@app.route("/bothelp/webhook", methods=["POST", "GET"])
def bothelp_webhook():
    global LAST

    # BotHelp/браузер иногда делает GET/HEAD проверку — отвечаем "ok"
    if request.method == "GET":
        return "ok", 200

    # Пытаемся прочитать JSON
    data = request.get_json(silent=True)

    # Если не JSON — читаем form-data / x-www-form-urlencoded
    if not data:
        data = request.form.to_dict()

    # Сохраняем "сырьё" последнего запроса для просмотра в /debug/last
    LAST = {
        "content_type": request.content_type,
        "form": request.form.to_dict(),
        "json": request.get_json(silent=True),
        "args": request.args.to_dict(),
        "data": data
    }

    # Пробуем достать file_id (пока ожидаем, что BotHelp пришлёт именно file_id)
    file_id = None

    # 1) Самый простой вариант
    if isinstance(data, dict):
        file_id = data.get("file_id")

    # 2) Если вдруг BotHelp прислал photo как список размеров (редко, но бывает)
    if not file_id and isinstance(data, dict) and isinstance(data.get("photo"), list) and len(data["photo"]) > 0:
        last_item = data["photo"][-1]
        if isinstance(last_item, dict):
            file_id = last_item.get("file_id")

    # Идентификатор карточки/квартиры (что пришлют — то и используем)
    listing_id = "unknown"
    if isinstance(data, dict):
        listing_id = data.get("listing_id") or data.get("item_id") or data.get("flat_id") or "unknown"

    # Если file_id не нашли — вернём 400 и покажем что пришло
    if not file_id:
        return jsonify({
            "error": "file_id not found",
            "hint": "Открой /debug/last и посмотри, какие поля реально присылает BotHelp",
            "received": LAST
        }), 400

    if not BOT_TOKEN:
        return jsonify({
            "error": "BOT_TOKEN is missing",
            "hint": "Render → Environment → добавь переменную BOT_TOKEN"
        }), 500

    # --- Скачиваем файл из Telegram по file_id ---
    try:
        # 1) Получаем file_path через getFile
        r = requests.get(
            f"https://api.telegram.org/bot{BOT_TOKEN}/getFile",
            params={"file_id": file_id},
            timeout=20
        )
        r.raise_for_status()
        j = r.json()
        if not j.get("ok"):
            return jsonify({"error": "Telegram getFile failed", "telegram": j}), 502

        file_path = j["result"]["file_path"]

        # 2) Скачиваем файл
        file_url = f"https://api.telegram.org/file/bot{BOT_TOKEN}/{file_path}"
        photo_resp = requests.get(file_url, timeout=40)
        photo_resp.raise_for_status()

        # Сохраняем на диск (для тестов ок; для продакшна лучше S3/облако)
        os.makedirs("photos", exist_ok=True)

        # Расширение берём из file_path если есть
        ext = os.path.splitext(file_path)[1] or ".jpg"
        filename = f"photos/{listing_id}_{file_id}{ext}"

        with open(filename, "wb") as f:
            f.write(photo_resp.content)

        return jsonify({
            "ok": True,
            "saved_as": filename,
            "listing_id": listing_id,
            "file_id": file_id
        }), 200

    except Exception as e:
        return jsonify({
            "error": "download/save failed",
            "detail": str(e)
        }), 500


@app.route("/debug/last", methods=["GET"])
def debug_last():
    """
    Показывает последний входящий запрос от BotHelp.
    Открой в браузере:
    https://твой-сервис.onrender.com/debug/last
    """
    return jsonify(LAST), 200


@app.route("/", methods=["GET"])
def root():
    # Просто чтобы главная не пугала 404
    return "ok", 200


if __name__ == "__main__":
    # Render даёт порт в переменной окружения PORT
    port = int(os.environ.get("PORT", 10000))
    app.run(host="0.0.0.0", port=port)
