import sys
from pathlib import Path
from unittest.mock import MagicMock

import boto3
import pytest
from botocore.exceptions import ClientError
from moto import mock_aws

ROOT = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(ROOT / "lambda"))

import call_guard  # noqa: E402

NOW = 1_794_000_000


def contact_event(contact_id):
    return {"Details": {"ContactData": {"ContactId": contact_id, "Channel": "VOICE"}}}


@pytest.fixture(autouse=True)
def table(monkeypatch):
    monkeypatch.setenv("AWS_DEFAULT_REGION", "us-east-1")
    monkeypatch.setenv("TABLE_NAME", "guard-test")
    monkeypatch.setenv("DAILY_CONTACT_LIMIT", "3")
    monkeypatch.setenv("MAX_CONTACT_SECONDS", "480")
    monkeypatch.setenv("INSTANCE_ID", "instance-1")
    monkeypatch.setattr(call_guard, "_now", lambda: NOW)
    with mock_aws():
        tbl = boto3.resource("dynamodb").create_table(
            TableName="guard-test",
            KeySchema=[{"AttributeName": "pk", "KeyType": "HASH"}],
            AttributeDefinitions=[{"AttributeName": "pk", "AttributeType": "S"}],
            BillingMode="PAY_PER_REQUEST",
        )
        call_guard._table = None
        call_guard._connect = None
        yield tbl
        call_guard._table = None
        call_guard._connect = None


@pytest.fixture
def connect(monkeypatch):
    client = MagicMock()
    monkeypatch.setattr(call_guard, "_get_connect", lambda: client)
    return client


def test_contacts_under_the_limit_are_allowed():
    for n in range(3):
        assert call_guard.gate_handler(contact_event(f"c{n}"), None) == {"allowed": "true"}


def test_contact_past_the_daily_limit_is_refused():
    for n in range(3):
        call_guard.gate_handler(contact_event(f"c{n}"), None)
    assert call_guard.gate_handler(contact_event("c4"), None) == {"allowed": "false"}


def test_refused_contact_is_not_tracked(table):
    for n in range(4):
        call_guard.gate_handler(contact_event(f"c{n}"), None)
    assert "Item" not in table.get_item(Key={"pk": "contact#c3"})


def test_limit_resets_on_a_new_day(monkeypatch):
    for n in range(3):
        call_guard.gate_handler(contact_event(f"c{n}"), None)
    monkeypatch.setattr(call_guard, "_now", lambda: NOW + 86400)
    assert call_guard.gate_handler(contact_event("next-day"), None) == {"allowed": "true"}


def test_gate_fails_loudly_when_the_table_is_missing(table):
    table.delete()
    with pytest.raises(ClientError):
        call_guard.gate_handler(contact_event("c1"), None)


def test_sweep_stops_contacts_past_the_time_limit(monkeypatch, connect, table):
    call_guard.gate_handler(contact_event("old"), None)
    monkeypatch.setattr(call_guard, "_now", lambda: NOW + 481)
    call_guard.gate_handler(contact_event("new"), None)

    assert call_guard.sweep_handler({}, None) == {"stopped": 1}
    connect.stop_contact.assert_called_once_with(ContactId="old", InstanceId="instance-1")
    assert "Item" not in table.get_item(Key={"pk": "contact#old"})
    assert "Item" in table.get_item(Key={"pk": "contact#new"})


def test_sweep_clears_contacts_that_already_ended(monkeypatch, connect, table):
    call_guard.gate_handler(contact_event("ended"), None)
    monkeypatch.setattr(call_guard, "_now", lambda: NOW + 600)
    connect.stop_contact.side_effect = ClientError(
        {"Error": {"Code": "ContactNotFoundException", "Message": "gone"}}, "StopContact"
    )

    assert call_guard.sweep_handler({}, None) == {"stopped": 0}
    assert "Item" not in table.get_item(Key={"pk": "contact#ended"})


def test_sweep_ignores_the_daily_counter(monkeypatch, connect):
    call_guard.gate_handler(contact_event("c1"), None)
    monkeypatch.setattr(call_guard, "_now", lambda: NOW + 100)
    assert call_guard.sweep_handler({}, None) == {"stopped": 0}
    connect.stop_contact.assert_not_called()
