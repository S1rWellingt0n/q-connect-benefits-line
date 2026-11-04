import json
import os
import sys
from pathlib import Path
from types import SimpleNamespace

import boto3
import pytest
from moto import mock_aws

ROOT = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(ROOT / "lambda"))

import case_status  # noqa: E402

SAMPLE_CASES = json.loads((ROOT / "data" / "sample-cases.json").read_text())
CASE = SAMPLE_CASES[0]


def tool_context(name="casetools___get_case_status"):
    return SimpleNamespace(client_context=SimpleNamespace(custom={"bedrockAgentCoreToolName": name}))


@pytest.fixture(autouse=True)
def table(monkeypatch):
    monkeypatch.setenv("AWS_DEFAULT_REGION", "us-east-1")
    monkeypatch.setenv("TABLE_NAME", "cases-test")
    with mock_aws():
        resource = boto3.resource("dynamodb")
        tbl = resource.create_table(
            TableName=os.environ["TABLE_NAME"],
            KeySchema=[{"AttributeName": "case_number", "KeyType": "HASH"}],
            AttributeDefinitions=[{"AttributeName": "case_number", "AttributeType": "S"}],
            BillingMode="PAY_PER_REQUEST",
        )
        for case in SAMPLE_CASES:
            tbl.put_item(Item=case)
        case_status._table = None
        yield tbl
        case_status._table = None


def call(args, name="casetools___get_case_status"):
    return case_status.lambda_handler(args, tool_context(name))


def test_matching_case_and_zip_returns_status():
    result = call({"case_number": CASE["case_number"], "zip_code": CASE["zip_code"]})
    assert result["verified"] is True
    assert result["status"] == CASE["status"]
    assert result["next_step"] == CASE["next_step"]


def test_result_never_echoes_zip_code():
    result = call({"case_number": CASE["case_number"], "zip_code": CASE["zip_code"]})
    assert "zip_code" not in result
    assert CASE["zip_code"] not in json.dumps(result)


def test_spoken_formatting_is_normalized():
    spaced = " ".join(CASE["case_number"])
    dashed = CASE["zip_code"][:2] + "-" + CASE["zip_code"][2:]
    result = call({"case_number": spaced, "zip_code": dashed})
    assert result["verified"] is True


def test_wrong_zip_is_not_verified():
    result = call({"case_number": CASE["case_number"], "zip_code": "00000"})
    assert result == case_status.NOT_VERIFIED


def test_unknown_case_gives_same_answer_as_wrong_zip():
    unknown = call({"case_number": "99999999", "zip_code": CASE["zip_code"]})
    wrong_zip = call({"case_number": CASE["case_number"], "zip_code": "00000"})
    assert unknown == wrong_zip


@pytest.mark.parametrize(
    "args",
    [
        {"case_number": "1234", "zip_code": "12345"},
        {"case_number": "123456789", "zip_code": "12345"},
        {"case_number": "12345678", "zip_code": "1234"},
        {"case_number": "", "zip_code": ""},
        {},
    ],
)
def test_malformed_input_is_rejected_before_lookup(args, table):
    table.delete()
    result = call(args)
    assert result["verified"] is False
    assert "8 digits" in result["message"]


def test_unknown_tool_is_refused():
    assert call({}, name="casetools___delete_case") == {"error": "Unknown tool."}


def test_missing_client_context_is_refused():
    assert case_status.lambda_handler({}, SimpleNamespace(client_context=None)) == {"error": "Unknown tool."}


def test_logs_mask_the_case_number_and_omit_the_zip(caplog):
    caplog.set_level("INFO")
    call({"case_number": CASE["case_number"], "zip_code": CASE["zip_code"]})
    logged = caplog.text
    assert CASE["case_number"] not in logged
    assert CASE["zip_code"] not in logged
    assert CASE["case_number"][-2:] in logged


def test_mask_keeps_only_last_two_digits():
    assert case_status._mask("12345678") == "******78"
    assert case_status._mask("12") == "**"
