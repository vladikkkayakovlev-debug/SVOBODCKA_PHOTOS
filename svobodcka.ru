from flask import Flask, request, jsonify
import requests
import os

BOT_TOKEN = os.environ.get("BOT_TOKEN")

app = Flask(__name__)


@app.route("/bothelp/webhook", methods=["POST", "GET"])
def webhook():
    # Проверочный GET
    if request.method == "GET":
        return "ok", 200

    # Пытаемся прочитать JSON
    data = request.get_json(silent=True)

    # Если не JSON — читаем form-data
    if not data:
        data = request.form.to_dict()

    file_id = data.get("file_id")
    listing_id = data.get("listing_id", "unknown")

    if not file_id:
        return jsonify({
            "error": "file_id not found",
            "content_type": request.content_type,
            "form": request.form.to_dict(),
            "json": request.get_json(silent=True),
            "args": request.args.to_dict()
        }), 400

    # Получаем путь файла в Telegram
    r = requests.get(
        f"https://api.telegram.org/bot{BOT_TOKEN}/getFile",
        params={"file_id": file_id}
    ).json()

    file_path = r["result"]["file_path"]
    file_url = f"https://api.telegram.org/file/bot{BOT_TOKEN}/{file_path}"

    # Скачиваем фото
    photo = requests.get(file_url).content

    os.makedirs("photos", exist_ok=True)
    filename = f"photos/{listing_id}_{file_id}.jpg"

    with open(filename, "wb") as f:
        f.write(photo)

    return jsonify({
        "ok": True,
        "saved_as": filename
    })


if __name__ == "__main__":
    port = int(os.environ.get("PORT", 10000))
    app.run(host="0.0.0.0", port=port)
