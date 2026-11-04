"""Usage caps for a public demo line.

gate_handler runs first in the contact flow. It counts contacts per UTC day
and refuses new ones past the limit. Anything other than an explicit "true"
sends the caller to a closing message, so a failure here fails closed.

sweep_handler runs every minute and stops any contact that has been up
longer than the per-call limit.
"""

import json
import logging
import os
import time
from datetime import UTC, datetime

import boto3
from botocore.exceptions import ClientError

logger = logging.getLogger()
logger.setLevel(logging.INFO)

ALREADY_ENDED = ("ContactNotFoundException", "InvalidRequestException")

_table = None
_connect = None


def _get_table():
    global _table
    if _table is None:
        _table = boto3.resource("dynamodb").Table(os.environ["TABLE_NAME"])
    return _table


def _get_connect():
    global _connect
    if _connect is None:
        _connect = boto3.client("connect")
    return _connect


def _now():
    return int(time.time())


def gate_handler(event, context):
    contact = event["Details"]["ContactData"]
    contact_id = contact["ContactId"]
    limit = int(os.environ["DAILY_CONTACT_LIMIT"])
    now = _now()
    day = datetime.fromtimestamp(now, UTC).strftime("%Y-%m-%d")
    table = _get_table()

    try:
        result = table.update_item(
            Key={"pk": f"day#{day}"},
            UpdateExpression="ADD contacts :one SET expires_at = :expires",
            ConditionExpression="attribute_not_exists(contacts) OR contacts < :limit",
            ExpressionAttributeValues={":one": 1, ":limit": limit, ":expires": now + 3 * 86400},
            ReturnValues="UPDATED_NEW",
        )
    except ClientError as err:
        if err.response["Error"]["Code"] != "ConditionalCheckFailedException":
            raise
        logger.info(json.dumps({"gate": "refused", "day": day, "limit": limit}))
        return {"allowed": "false"}

    table.put_item(Item={"pk": f"contact#{contact_id}", "started_at": now, "expires_at": now + 86400})
    count = int(result["Attributes"]["contacts"])
    logger.info(json.dumps({"gate": "allowed", "day": day, "count": count, "limit": limit}))
    return {"allowed": "true"}


def sweep_handler(event, context):
    max_seconds = int(os.environ["MAX_CONTACT_SECONDS"])
    instance_id = os.environ["INSTANCE_ID"]
    table = _get_table()
    now = _now()
    stopped = 0

    scan = {"FilterExpression": "begins_with(pk, :p)", "ExpressionAttributeValues": {":p": "contact#"}}
    while True:
        page = table.scan(**scan)
        for item in page.get("Items", []):
            if now - int(item["started_at"]) < max_seconds:
                continue
            contact_id = item["pk"].split("#", 1)[1]
            try:
                _get_connect().stop_contact(ContactId=contact_id, InstanceId=instance_id)
                stopped += 1
                logger.info(json.dumps({"sweep": "stopped", "contact": contact_id}))
            except ClientError as err:
                if err.response["Error"]["Code"] not in ALREADY_ENDED:
                    raise
            table.delete_item(Key={"pk": item["pk"]})
        if "LastEvaluatedKey" not in page:
            break
        scan["ExclusiveStartKey"] = page["LastEvaluatedKey"]

    return {"stopped": stopped}
