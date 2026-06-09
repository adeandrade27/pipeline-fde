"""Salesforce PSA reader for FDE Allocation Pipeline.

Reads:
1) Real hours per FDE (last 90 days, LATAM)
2) Active allocations
3) Open resource requests (pipeline)
"""

from __future__ import annotations

import os
from dataclasses import dataclass
from typing import Any, Dict, List

from simple_salesforce import Salesforce


TIMECARDS_QUERY = """
SELECT
    pse__Resource__c, Resource_Name__c, pse__Project__c,
    Project_Name__c, pse__Start_Date__c, pse__End_Date__c,
    pse__Total_Hours__c, pse__Approved__c, pse__Status__c,
    Project_Region__c
FROM pse__Timecard_Header__c
WHERE Project_Region__c = 'LATAM'
  AND pse__Start_Date__c >= LAST_N_DAYS:90
ORDER BY pse__Start_Date__c DESC LIMIT 200
"""


ASSIGNMENTS_QUERY = """
SELECT
    Name, pse__Resource__c, Resource_Name__c, pse__Project__c,
    pse__Status__c, pse__Start_Date__c, pse__End_Date__c,
    pse__Planned_Hours__c, Total_Billable_and_Credited_Hours__c,
    pse__Percent_Allocated__c, pse__Role__c, Project_Region__c
FROM pse__Assignment__c
WHERE Project_Region__c = 'LATAM'
  AND pse__Status__c != 'Cancelled'
ORDER BY pse__Start_Date__c DESC LIMIT 100
"""


RESOURCE_REQUESTS_QUERY = """
SELECT
    Name, pse__Resource_Request_Name__c, pse__Account__c,
    pse__Opportunity__c, pse__Project__c, pse__Status__c,
    pse__Start_Date__c, pse__End_Date__c, pse__SOW_Hours__c,
    pse__Resource_Role__c, pse__Primary_Skill_Certification__c,
    pse__Request_Priority__c, OpportunityStage__c, ProjectStage__c,
    StaffingOwner__c, StaffingOwnerComments__c
FROM pse__Resource_Request__c
WHERE pse__Status__c = 'Open'
ORDER BY pse__Start_Date__c ASC LIMIT 50
"""


@dataclass
class SalesforceConfig:
    username: str
    password: str
    security_token: str
    domain: str = "login"

    @classmethod
    def from_env(cls) -> "SalesforceConfig":
        return cls(
            username=os.environ["SF_USERNAME"],
            password=os.environ["SF_PASSWORD"],
            security_token=os.environ["SF_SECURITY_TOKEN"],
            domain=os.getenv("SF_DOMAIN", "login"),
        )


class SalesforcePSAReader:
    """Reader wrapper around simple-salesforce for PSA queries."""

    def __init__(self, config: SalesforceConfig):
        self.config = config
        self.sf = Salesforce(
            username=config.username,
            password=config.password,
            security_token=config.security_token,
            domain=config.domain,
        )

    @staticmethod
    def _extract_records(result: Dict[str, Any]) -> List[Dict[str, Any]]:
        return result.get("records", [])

    def fetch_timecards(self) -> List[Dict[str, Any]]:
        result = self.sf.query(TIMECARDS_QUERY)
        return self._extract_records(result)

    def fetch_assignments(self) -> List[Dict[str, Any]]:
        result = self.sf.query(ASSIGNMENTS_QUERY)
        return self._extract_records(result)

    def fetch_open_resource_requests(self) -> List[Dict[str, Any]]:
        result = self.sf.query(RESOURCE_REQUESTS_QUERY)
        return self._extract_records(result)

    def fetch_all(self) -> Dict[str, List[Dict[str, Any]]]:
        """Fetches all three datasets in one call."""
        return {
            "timecards": self.fetch_timecards(),
            "assignments": self.fetch_assignments(),
            "resource_requests": self.fetch_open_resource_requests(),
        }


def build_reader_from_env() -> SalesforcePSAReader:
    """Factory helper used by app/scheduler layers."""
    config = SalesforceConfig.from_env()
    return SalesforcePSAReader(config)
