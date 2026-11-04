"""Point a Q in Connect session at this line's AI agent.

The CreateWisdomSession flow block only takes an assistant, and an assistant
has one default self-service agent. When the assistant is shared with other
lines, the flow calls this right after creating the session to set the agent
for that one session.
"""

import json
import logging
import os

import boto3

logger = logging.getLogger()
logger.setLevel(logging.INFO)

USE_CASE = "Connect.SelfService"

_qconnect = None


def _client():
    global _qconnect
    if _qconnect is None:
        _qconnect = boto3.client("qconnect")
    return _qconnect


def lambda_handler(event, context):
    params = (event.get("Details") or {}).get("Parameters") or {}
    session_id = str(params.get("sessionArn") or "").rsplit("/", 1)[-1]
    if not session_id:
        logger.error(json.dumps({"bind": "missing_session"}))
        return {"status": "error"}

    agent = {"aiAgentId": os.environ["AI_AGENT_ID"], "orchestratorUseCase": USE_CASE}
    _client().update_session(
        assistantId=os.environ["ASSISTANT_ID"], sessionId=session_id, orchestratorConfigurationList=[agent]
    )
    logger.info(json.dumps({"bind": "ok", "session": session_id}))
    return {"status": "ok"}
