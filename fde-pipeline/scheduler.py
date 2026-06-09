"""APScheduler orchestration for daily scoring run."""

from __future__ import annotations

import json
import os
from datetime import datetime, timezone
from pathlib import Path
from typing import Any, Dict, List

from apscheduler.schedulers.background import BackgroundScheduler
from apscheduler.triggers.cron import CronTrigger

from scorer import build_scorer_from_env
from sf_reader import build_reader_from_env
from slack_reader import build_reader_from_env as build_slack_reader_from_env


DEFAULT_OUTPUT_PATH = "fde-pipeline/data/latest_scorecards.json"


def run_scoring_once(output_path: str = DEFAULT_OUTPUT_PATH) -> Dict[str, Any]:
    sf_reader = build_reader_from_env()
    slack_reader = build_slack_reader_from_env()
    scorer = build_scorer_from_env()

    sf_data = sf_reader.fetch_all()
    slack_data = slack_reader.fetch_all(message_limit=200)

    scorecards = scorer.score_open_requests(
        requests=sf_data["resource_requests"],
        timecards=sf_data["timecards"],
        assignments=sf_data["assignments"],
        slack_context=slack_data,
    )

    payload: Dict[str, Any] = {
        "generated_at": datetime.now(timezone.utc).isoformat(),
        "request_count": len(sf_data["resource_requests"]),
        "scorecards": [s.to_dict() for s in scorecards],
    }

    out_file = Path(output_path)
    out_file.parent.mkdir(parents=True, exist_ok=True)
    out_file.write_text(json.dumps(payload, ensure_ascii=False, indent=2), encoding="utf-8")
    return payload


def build_scheduler() -> BackgroundScheduler:
    scheduler = BackgroundScheduler(timezone=os.getenv("SCHEDULER_TZ", "America/Sao_Paulo"))
    scheduler.add_job(
        run_scoring_once,
        trigger=CronTrigger(hour=8, minute=0),
        id="daily_fde_scoring",
        replace_existing=True,
    )
    return scheduler


def start_scheduler() -> BackgroundScheduler:
    scheduler = build_scheduler()
    scheduler.start()
    return scheduler
