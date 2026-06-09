"""Claude-based scoring engine for FDE allocation requests."""

from __future__ import annotations

import json
import os
from dataclasses import asdict, dataclass
from typing import Any, Dict, List

from anthropic import Anthropic


DEFAULT_MODEL = "claude-3-5-sonnet-20241022"


@dataclass
class Scorecard:
    account_name: str
    request_id: str
    readiness_score: int
    business_score: int
    risk_score: int
    composite_score: int
    recommended_fde: str
    recommendation_reason: str
    similar_projects: List[str]
    blockers: List[str]
    summary: str

    def to_dict(self) -> Dict[str, Any]:
        return asdict(self)


class ClaudeScorer:
    """Builds scorecards for open resource requests using Claude."""

    def __init__(self, api_key: str, model: str = DEFAULT_MODEL):
        self.model = model
        self.client = Anthropic(api_key=api_key)

    @staticmethod
    def _extract_text(response: Any) -> str:
        chunks: List[str] = []
        for block in response.content:
            text = getattr(block, "text", None)
            if text:
                chunks.append(text)
        return "\n".join(chunks).strip()

    @staticmethod
    def _extract_json_payload(text: str) -> Dict[str, Any]:
        clean = text.strip()
        if clean.startswith("```"):
            clean = clean.strip("`")
            if clean.startswith("json"):
                clean = clean[4:].strip()
        try:
            return json.loads(clean)
        except json.JSONDecodeError:
            start = clean.find("{")
            end = clean.rfind("}")
            if start >= 0 and end > start:
                return json.loads(clean[start : end + 1])
            raise

    @staticmethod
    def _coerce_score(value: Any) -> int:
        try:
            score = int(value)
        except (TypeError, ValueError):
            score = 0
        return max(0, min(100, score))

    def _normalize_scorecard(self, payload: Dict[str, Any]) -> Scorecard:
        readiness = self._coerce_score(payload.get("readiness_score", 0))
        business = self._coerce_score(payload.get("business_score", 0))
        risk = self._coerce_score(payload.get("risk_score", 0))
        composite = self._coerce_score(
            payload.get("composite_score", round(readiness * 0.4 + business * 0.4 + risk * 0.2))
        )
        return Scorecard(
            account_name=str(payload.get("account_name", "")),
            request_id=str(payload.get("request_id", "")),
            readiness_score=readiness,
            business_score=business,
            risk_score=risk,
            composite_score=composite,
            recommended_fde=str(payload.get("recommended_fde", "")),
            recommendation_reason=str(payload.get("recommendation_reason", "")),
            similar_projects=[str(x) for x in payload.get("similar_projects", [])][:10],
            blockers=[str(x) for x in payload.get("blockers", [])][:10],
            summary=str(payload.get("summary", "")),
        )

    def _build_prompt(
        self,
        request_item: Dict[str, Any],
        timecards: List[Dict[str, Any]],
        assignments: List[Dict[str, Any]],
        slack_context: Dict[str, Any],
    ) -> str:
        request_json = json.dumps(request_item, ensure_ascii=False)
        timecards_json = json.dumps(timecards[:80], ensure_ascii=False)
        assignments_json = json.dumps(assignments[:80], ensure_ascii=False)
        slack_json = json.dumps(slack_context, ensure_ascii=False)
        return f"""
You are an expert LATAM Salesforce staffing analyst for FDE allocation.
Evaluate this open resource request and produce ONLY valid JSON.

Scoring guidance:
- readiness_score (0-100): technical prerequisites and delivery readiness
- business_score (0-100): ACV proxy × strategic fit × win probability
- risk_score (0-100): blockers, skill gaps, delivery/compliance risk
- composite_score: weighted average (40/40/20)

Open request:
{request_json}

Recent timecards (last 90 days):
{timecards_json}

Current allocations:
{assignments_json}

Slack context (nominations + command center + recent channel signals):
{slack_json}

Return exactly this schema:
{{
  "account_name": str,
  "request_id": str,
  "readiness_score": int,
  "business_score": int,
  "risk_score": int,
  "composite_score": int,
  "recommended_fde": str,
  "recommendation_reason": str,
  "similar_projects": list[str],
  "blockers": list[str],
  "summary": str
}}
"""

    def score_request(
        self,
        request_item: Dict[str, Any],
        timecards: List[Dict[str, Any]],
        assignments: List[Dict[str, Any]],
        slack_context: Dict[str, Any],
    ) -> Scorecard:
        prompt = self._build_prompt(request_item, timecards, assignments, slack_context)
        response = self.client.messages.create(
            model=self.model,
            max_tokens=1200,
            temperature=0,
            messages=[{"role": "user", "content": prompt}],
        )
        raw_text = self._extract_text(response)
        payload = self._extract_json_payload(raw_text)
        if not payload.get("account_name"):
            payload["account_name"] = request_item.get("pse__Account__c", "Unknown Account")
        if not payload.get("request_id"):
            payload["request_id"] = request_item.get("Name", "Unknown Request")
        return self._normalize_scorecard(payload)

    def score_open_requests(
        self,
        requests: List[Dict[str, Any]],
        timecards: List[Dict[str, Any]],
        assignments: List[Dict[str, Any]],
        slack_context: Dict[str, Any],
    ) -> List[Scorecard]:
        scorecards: List[Scorecard] = []
        for request_item in requests:
            scorecards.append(
                self.score_request(
                    request_item=request_item,
                    timecards=timecards,
                    assignments=assignments,
                    slack_context=slack_context,
                )
            )
        return scorecards


def build_scorer_from_env() -> ClaudeScorer:
    api_key = os.environ["ANTHROPIC_API_KEY"]
    model = os.getenv("ANTHROPIC_MODEL", DEFAULT_MODEL)
    return ClaudeScorer(api_key=api_key, model=model)
