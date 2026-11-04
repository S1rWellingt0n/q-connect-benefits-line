"""Case status tool for the benefits line AI agent.

AgentCore Gateway invokes this function for MCP tool calls. The tool arguments
arrive flat in the event, and the tool name arrives in the client context as
"<target>___<tool>".
"""

import hmac
import json
import logging
import os
import re

import boto3

logger = logging.getLogger()
logger.setLevel(logging.INFO)

CASE_NUMBER = re.compile(r"^\d{8}$")
ZIP_CODE = re.compile(r"^\d{5}$")

NOT_VERIFIED = {
    "verified": False,
    "message": "No case matches that case number and ZIP code together.",
}

_table = None


def _get_table():
    global _table
    if _table is None:
        _table = boto3.resource("dynamodb").Table(os.environ["TABLE_NAME"])
    return _table


def _digits(value):
    return re.sub(r"\D", "", str(value or ""))


def _mask(case_number):
    if len(case_number) < 3:
        return "*" * len(case_number)
    return "*" * (len(case_number) - 2) + case_number[-2:]


def _tool_name(context):
    client_context = getattr(context, "client_context", None)
    custom = getattr(client_context, "custom", None) or {}
    full_name = custom.get("bedrockAgentCoreToolName", "")
    return full_name.split("___", 1)[-1]


def _log(tool, outcome, case_number=""):
    logger.info(json.dumps({"tool": tool, "outcome": outcome, "case": _mask(case_number)}))


def get_case_status(args):
    case_number = _digits(args.get("case_number"))
    zip_code = _digits(args.get("zip_code"))

    if not CASE_NUMBER.match(case_number) or not ZIP_CODE.match(zip_code):
        _log("get_case_status", "invalid_input", case_number)
        return {
            "verified": False,
            "message": "A case number is 8 digits and a ZIP code is 5 digits.",
        }

    item = _get_table().get_item(Key={"case_number": case_number}).get("Item")
    if not item or not hmac.compare_digest(item["zip_code"], zip_code):
        _log("get_case_status", "not_verified", case_number)
        return dict(NOT_VERIFIED)

    _log("get_case_status", "verified", case_number)
    return {
        "verified": True,
        "program": item["program"],
        "status": item["status"],
        "status_detail": item["status_detail"],
        "last_updated": item["last_updated"],
        "next_step": item["next_step"],
    }


TOOLS = {"get_case_status": get_case_status}


def lambda_handler(event, context):
    tool = _tool_name(context)
    handler = TOOLS.get(tool)
    if handler is None:
        _log(tool or "unknown", "unknown_tool")
        return {"error": "Unknown tool."}
    return handler(event or {})
