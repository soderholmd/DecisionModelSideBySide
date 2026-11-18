"""Side-by-side classification demo: Azure OpenAI vs. Microsoft-Decision-1."""

import json
import os
import queue
import threading
import time

from dotenv import load_dotenv
from flask import Flask, Response, jsonify, request, send_from_directory

load_dotenv()

from classifiers import (  # noqa: E402
    CLASSIFIERS,
    build_decision_request,
    build_openai_messages,
    explain_openai,
    format_openai_prompt,
    missing_settings,
    mock_enabled,
)
from scenarios import SCENARIOS, load_data  # noqa: E402

app = Flask(__name__, static_folder="static", static_url_path="/static")
MAX_REQUEST_BYTES = 64 * 1024
MAX_LABELS = 100
MAX_LABEL_NAME_LENGTH = 100
MAX_LABEL_DESCRIPTION_LENGTH = 1000
MAX_CONCURRENT_BATCHES = 4
app.config["MAX_CONTENT_LENGTH"] = MAX_REQUEST_BYTES
_batch_slots = threading.BoundedSemaphore(MAX_CONCURRENT_BATCHES)


@app.get("/healthz")
def health():
    return jsonify({"status": "ok"})


@app.errorhandler(413)
def request_too_large(_error):
    return jsonify({"error": f"Request body must not exceed {MAX_REQUEST_BYTES} bytes."}), 413


@app.get("/")
def index():
    return send_from_directory(app.static_folder, "index.html")


@app.get("/compare")
@app.get("/consistency")
def classroom():
    return send_from_directory(app.static_folder, "classroom.html")


@app.get("/api/config")
def config():
    return jsonify(
        {
            "mock": mock_enabled(),
            "openai_model": os.getenv("AZURE_OPENAI_DEPLOYMENT", "") or "Azure OpenAI",
            "decision_model": os.getenv("DECISION_DEPLOYMENT", "") or "Microsoft-Decision-1",
            "scenarios": {
                key: {"name": s["name"], "description": s["description"], "labels": s["labels"]}
                for key, s in SCENARIOS.items()
            },
        }
    )


def normalize_labels(labels):
    return [
        {"name": str(l.get("name", "")).strip(), "description": str(l.get("description", "")).strip()}
        for l in labels or []
        if isinstance(l, dict) and str(l.get("name", "")).strip()
    ]


def validate_labels(raw_labels):
    if not isinstance(raw_labels, list):
        return None, "'labels' must be an array."
    if len(raw_labels) > MAX_LABELS:
        return None, f"At most {MAX_LABELS} labels are allowed."
    for label in raw_labels:
        if not isinstance(label, dict):
            continue
        if len(str(label.get("name", ""))) > MAX_LABEL_NAME_LENGTH:
            return None, f"Label names must not exceed {MAX_LABEL_NAME_LENGTH} characters."
        if len(str(label.get("description", ""))) > MAX_LABEL_DESCRIPTION_LENGTH:
            return None, f"Label descriptions must not exceed {MAX_LABEL_DESCRIPTION_LENGTH} characters."
    labels = normalize_labels(raw_labels)
    if not labels:
        return None, "At least one label is required."
    return labels, None


@app.route("/api/data/<scenario>", methods=["GET", "POST"])
def data(scenario):
    if scenario not in SCENARIOS:
        return jsonify({"error": "Unknown scenario"}), 404
    items = load_data(SCENARIOS[scenario]["data_file"])
    if request.method == "GET":
        return jsonify({"items": items})
    body = request.get_json(silent=True)
    if not isinstance(body, dict):
        return jsonify({"error": "The request body must be a JSON object."}), 400
    labels, error = validate_labels(body.get("labels", []))
    if error:
        return jsonify({"error": error}), 400
    prompts = [
        {
            "openai": format_openai_prompt(build_openai_messages(text, labels)),
            "decision": json.dumps(build_decision_request(text, labels)[0], indent=2),
        }
        for text in items
    ]
    return jsonify({"items": items, "prompts": prompts})


@app.post("/api/classify/<model>")
def classify(model):
    if model not in CLASSIFIERS:
        return jsonify({"error": "Unknown model"}), 404
    body = request.get_json(silent=True)
    if not isinstance(body, dict):
        return jsonify({"error": "The request body must be a JSON object."}), 400
    text = str(body.get("text", "")).strip()
    labels, error = validate_labels(body.get("labels", []))
    if error:
        return jsonify({"error": error}), 400
    if not text or not labels:
        return jsonify({"error": "Both 'text' and at least one label are required."}), 400
    return _model_call(model, CLASSIFIERS[model], text, labels)


@app.post("/api/explain")
def explain():
    body = request.get_json(silent=True)
    if not isinstance(body, dict):
        return jsonify({"error": "The request body must be a JSON object."}), 400
    labels, error = validate_labels(body.get("labels", []))
    if error:
        return jsonify({"error": error}), 400
    text = str(body.get("text", "")).strip()
    selected_label = body.get("label")
    if not text or selected_label not in [label["name"] for label in labels]:
        return jsonify({"error": "Text and a label from the supplied categories are required."}), 400
    return _model_call("openai", explain_openai, text, labels, selected_label)


def _model_call(model, function, *args):
    missing = missing_settings(model)
    if missing:
        return jsonify({"error": f"Missing configuration: set {', '.join(missing)} in your .env file."}), 500
    if not _batch_slots.acquire(blocking=False):
        return jsonify({"error": "Too many model requests are running. Retry shortly."}), 429, {"Retry-After": "5"}
    try:
        return jsonify(function(*args))
    except Exception as exc:  # details go to the server log, not the browser
        app.logger.exception("Classification failed")
        status = getattr(exc, "status_code", None) or getattr(getattr(exc, "response", None), "status_code", None)
        detail = f" (HTTP {int(status)})" if isinstance(status, int) else ""
        return jsonify({"error": f"Model call failed{detail}. See the server console for details."}), 502
    finally:
        _batch_slots.release()


@app.post("/api/run/<model>/<scenario>")
def run_batch(model, scenario):
    if model not in CLASSIFIERS or scenario not in SCENARIOS:
        return jsonify({"error": "Unknown model or scenario"}), 404
    body = request.get_json(silent=True)
    if not isinstance(body, dict) or not isinstance(body.get("labels"), list):
        return jsonify({"error": "'labels' must be an array in a JSON object."}), 400
    labels, error = validate_labels(body["labels"])
    if error:
        return jsonify({"error": error}), 400
    missing = missing_settings(model)
    if missing:
        return jsonify({"error": f"Missing configuration: set {', '.join(missing)}."}), 500
    items = load_data(SCENARIOS[scenario]["data_file"])
    if not _batch_slots.acquire(blocking=False):
        return jsonify({"error": "Too many batches are running. Retry shortly."}), 429, {"Retry-After": "5"}
    events = queue.SimpleQueue()
    cancelled = threading.Event()
    completion_lock = threading.Lock()
    pending = {"producer", "stream"}

    def finish(part):
        # A disconnected stream and its in-flight producer can finish in either order.
        with completion_lock:
            if part not in pending:
                return
            pending.remove(part)
            if not pending:
                _batch_slots.release()

    def close_stream():
        cancelled.set()
        finish("stream")

    def execute():
        start = time.perf_counter()
        try:
            for index, text in enumerate(items):
                if cancelled.is_set():
                    return
                prompt = (
                    format_openai_prompt(build_openai_messages(text, labels))
                    if model == "openai"
                    else json.dumps(build_decision_request(text, labels)[0], indent=2)
                )
                events.put({"type": "calling", "prompt": prompt})
                result = CLASSIFIERS[model](text, labels)
                events.put({
                    **result, "type": "result", "text": text,
                    "wall_ms": (time.perf_counter() - start) * 1000,
                    "total": len(items), "index": index,
                })
            events.put({"type": "done", "wall_ms": (time.perf_counter() - start) * 1000})
        except Exception:
            app.logger.exception("Batch classification failed")
            events.put({"type": "error", "error": "Model call failed. See the server logs for details."})
        finally:
            events.put(None)
            finish("producer")

    def stream():
        try:
            while True:
                try:
                    event = events.get(timeout=10)
                except queue.Empty:
                    event = {"type": "heartbeat"}
                if event is None:
                    break
                yield json.dumps(event) + "\n"
        finally:
            # An in-flight model request may finish, but no new calls start after disconnect.
            close_stream()

    # Start immediately so the admitted slot is always owned by a running producer.
    try:
        worker = threading.Thread(target=execute, daemon=True)
        worker.start()
    except Exception:
        finish("producer")
        close_stream()
        raise
    response = Response(
        stream(), mimetype="application/x-ndjson",
        headers={"Cache-Control": "no-store", "X-Accel-Buffering": "no"},
    )
    response.call_on_close(close_stream)
    return response


if __name__ == "__main__":
    app.run(host="127.0.0.1", port=int(os.getenv("PORT", "5000")), threaded=True)
