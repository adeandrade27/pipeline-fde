"""Flask web app for FDE Allocation Pipeline."""

from __future__ import annotations

import json
import os
from pathlib import Path
from typing import Any, Dict

from dotenv import load_dotenv
from flask import Flask, jsonify, render_template, request

from scheduler import DEFAULT_OUTPUT_PATH, run_scoring_once, start_scheduler

load_dotenv()

app = Flask(__name__)
app.config["SECRET_KEY"] = os.getenv("SECRET_KEY", "dev-secret-change-me")
app.config["JSON_SORT_KEYS"] = False

_scheduler = None


def _read_latest_scorecards(path: str = DEFAULT_OUTPUT_PATH) -> Dict[str, Any]:
    file_path = Path(path)
    if not file_path.exists():
        return {"generated_at": None, "request_count": 0, "scorecards": []}
    return json.loads(file_path.read_text(encoding="utf-8"))


@app.route("/")
def dashboard() -> str:
    payload = _read_latest_scorecards()
    return render_template(
        "dashboard.html",
        generated_at=payload.get("generated_at"),
        request_count=payload.get("request_count", 0),
        scorecards=payload.get("scorecards", []),
    )


@app.route("/api/health")
def health() -> Any:
    return jsonify({"status": "ok"})


@app.route("/api/scorecards")
def scorecards() -> Any:
    return jsonify(_read_latest_scorecards())


@app.route("/api/score/run", methods=["POST"])
def score_run() -> Any:
    dry_run = request.args.get("dry_run", "").lower() in {"1", "true", "yes"}
    if dry_run:
        sample_payload = {
            "generated_at": None,
            "request_count": 1,
            "scorecards": [
                {
                    "account_name": "Sample Account",
                    "request_id": "RR-DRY-RUN",
                    "readiness_score": 75,
                    "business_score": 82,
                    "risk_score": 40,
                    "composite_score": 71,
                    "recommended_fde": "Sample FDE",
                    "recommendation_reason": "Dry-run mode for API validation.",
                    "similar_projects": ["Sample Project A", "Sample Project B"],
                    "blockers": ["No real integrations executed in dry_run"],
                    "summary": "Dry-run response generated successfully.",
                }
            ],
            "dry_run": True,
        }
        return jsonify(sample_payload), 200

    payload = run_scoring_once()
    return jsonify(payload), 201


@app.route("/api/scheduler/start", methods=["POST"])
def scheduler_start() -> Any:
    global _scheduler
    if _scheduler and _scheduler.running:
        return jsonify({"status": "already_running"}), 200
    _scheduler = start_scheduler()
    return jsonify({"status": "started"}), 201


if __name__ == "__main__":
    app.run(host="0.0.0.0", port=int(os.getenv("PORT", "5000")), debug=True)
