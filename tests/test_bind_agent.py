import sys
from pathlib import Path
from unittest.mock import MagicMock

import pytest

ROOT = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(ROOT / "lambda"))

import bind_agent  # noqa: E402

SESSION_ARN = "arn:aws:wisdom:us-east-1:123456789012:session/assistant-1/session-9"


@pytest.fixture
def qconnect(monkeypatch):
    monkeypatch.setenv("ASSISTANT_ID", "assistant-1")
    monkeypatch.setenv("AI_AGENT_ID", "agent-7:$LATEST")
    client = MagicMock()
    monkeypatch.setattr(bind_agent, "_client", lambda: client)
    return client


def flow_event(session_arn):
    return {"Details": {"Parameters": {"sessionArn": session_arn}}}


def test_binds_the_session_to_the_agent(qconnect):
    assert bind_agent.lambda_handler(flow_event(SESSION_ARN), None) == {"status": "ok"}
    agent = {"aiAgentId": "agent-7:$LATEST", "orchestratorUseCase": "Connect.SelfService"}
    qconnect.update_session.assert_called_once_with(
        assistantId="assistant-1", sessionId="session-9", orchestratorConfigurationList=[agent]
    )


def test_missing_session_is_an_error_without_a_call(qconnect):
    assert bind_agent.lambda_handler(flow_event(""), None) == {"status": "error"}
    assert bind_agent.lambda_handler({}, None) == {"status": "error"}
    qconnect.update_session.assert_not_called()


def test_api_failure_raises_so_the_flow_takes_its_error_branch(qconnect):
    qconnect.update_session.side_effect = RuntimeError("throttled")
    with pytest.raises(RuntimeError):
        bind_agent.lambda_handler(flow_event(SESSION_ARN), None)
