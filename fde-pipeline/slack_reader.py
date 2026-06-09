"""Slack reader for FDE Allocation Pipeline.

Reads:
- Nominations List file content (by file ID)
- Command Center canvas/file content (by file ID)
- Recent messages from FDE LATAM channel
"""

from __future__ import annotations

import os
from dataclasses import dataclass
from typing import Any, Dict, List, Optional

from slack_sdk import WebClient
from slack_sdk.errors import SlackApiError


DEFAULT_NOMINATIONS_FILE_ID = "F08R8PC96KA"
DEFAULT_COMMAND_CENTER_FILE_ID = "F0AF8GR9UQ6"
DEFAULT_FDE_CHANNEL_ID = "C094HCKJBN3"


@dataclass
class SlackConfig:
    bot_token: str
    team_id: Optional[str] = None
    nominations_file_id: str = DEFAULT_NOMINATIONS_FILE_ID
    command_center_file_id: str = DEFAULT_COMMAND_CENTER_FILE_ID
    fde_channel_id: str = DEFAULT_FDE_CHANNEL_ID

    @classmethod
    def from_env(cls) -> "SlackConfig":
        return cls(
            bot_token=os.environ["SLACK_BOT_TOKEN"],
            team_id=os.getenv("SLACK_TEAM_ID"),
            nominations_file_id=os.getenv(
                "SLACK_NOMINATIONS_FILE_ID", DEFAULT_NOMINATIONS_FILE_ID
            ),
            command_center_file_id=os.getenv(
                "SLACK_COMMAND_CENTER_FILE_ID", DEFAULT_COMMAND_CENTER_FILE_ID
            ),
            fde_channel_id=os.getenv("SLACK_FDE_CHANNEL_ID", DEFAULT_FDE_CHANNEL_ID),
        )


class SlackReader:
    """Wrapper around Slack WebClient for relevant inputs."""

    def __init__(self, config: SlackConfig):
        self.config = config
        self.client = WebClient(token=config.bot_token)

    def _safe_api_call(self, fn_name: str, **kwargs: Any) -> Dict[str, Any]:
        fn = getattr(self.client, fn_name)
        try:
            return fn(**kwargs).data
        except SlackApiError as exc:
            raise RuntimeError(
                f"Slack API call failed for {fn_name}: {exc.response['error']}"
            ) from exc

    def get_file_metadata(self, file_id: str) -> Dict[str, Any]:
        response = self._safe_api_call("files_info", file=file_id)
        return response.get("file", {})

    def get_nominations_file_metadata(self) -> Dict[str, Any]:
        return self.get_file_metadata(self.config.nominations_file_id)

    def get_command_center_file_metadata(self) -> Dict[str, Any]:
        return self.get_file_metadata(self.config.command_center_file_id)

    def get_channel_messages(self, limit: int = 100) -> List[Dict[str, Any]]:
        response = self._safe_api_call(
            "conversations_history",
            channel=self.config.fde_channel_id,
            limit=limit,
        )
        return response.get("messages", [])

    def get_channel_metadata(self) -> Dict[str, Any]:
        response = self._safe_api_call(
            "conversations_info",
            channel=self.config.fde_channel_id,
        )
        return response.get("channel", {})

    def fetch_all(self, message_limit: int = 100) -> Dict[str, Any]:
        """Fetches all configured Slack sources in one call."""
        return {
            "nominations_file": self.get_nominations_file_metadata(),
            "command_center_file": self.get_command_center_file_metadata(),
            "fde_channel": self.get_channel_metadata(),
            "fde_messages": self.get_channel_messages(limit=message_limit),
        }


def build_reader_from_env() -> SlackReader:
    config = SlackConfig.from_env()
    return SlackReader(config)
