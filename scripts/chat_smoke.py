"""Talk to the deployed line over a real Connect chat contact.

Runs the same flow, Lex bot and AI agent a phone call uses, and prints the
conversation. MCP tools only run on a real contact, so this exercises the whole
tool path, not just the model.

    python scripts/chat_smoke.py                        # built-in scenario
    python scripts/chat_smoke.py "turn one" "turn two"  # your own turns
"""

import argparse
import asyncio
import json
import subprocess
import sys

import boto3
import websockets

DEFAULT_TURNS = [
    "Hi, I want to check on my case.",
    "My case number is 20591847.",
    "Yes, that's right.",
    "The ZIP code is 20002.",
    "How long do I have to appeal a decision if I disagree with it?",
    "Can I talk to a person?",
]

CHAT_ENDED = "application/vnd.amazonaws.connect.event.chat.ended"


def terraform_output(name):
    out = subprocess.run(["terraform", "output", "-raw", name], capture_output=True, text=True, check=True)
    return out.stdout.strip()


async def read_events(ws, events):
    async for raw in ws:
        message = json.loads(raw)
        if message.get("topic") == "aws/chat":
            await events.put(json.loads(message["content"]))


async def collect_replies(events, quiet_seconds, timeout):
    replies, ended = [], False
    loop = asyncio.get_running_loop()
    deadline = loop.time() + timeout
    while loop.time() < deadline:
        wait = quiet_seconds if replies else deadline - loop.time()
        try:
            item = await asyncio.wait_for(events.get(), timeout=max(wait, 0.1))
        except TimeoutError:
            if replies:
                break
            continue
        if item.get("ContentType") == CHAT_ENDED:
            ended = True
            break
        if item.get("Type") == "MESSAGE" and item.get("ParticipantRole") != "CUSTOMER":
            replies.append(item["Content"])
    return replies, ended


async def run(turns, region, quiet_seconds, timeout):
    connect = boto3.client("connect", region_name=region)
    participant = boto3.client("connectparticipant", region_name=region)

    contact = connect.start_chat_contact(
        InstanceId=terraform_output("instance_id"),
        ContactFlowId=terraform_output("contact_flow_id"),
        ParticipantDetails={"DisplayName": "Smoke test"},
    )
    connection = participant.create_participant_connection(
        Type=["WEBSOCKET", "CONNECTION_CREDENTIALS"], ParticipantToken=contact["ParticipantToken"]
    )
    token = connection["ConnectionCredentials"]["ConnectionToken"]
    print(f"contact {contact['ContactId']}")

    events = asyncio.Queue()
    async with websockets.connect(connection["Websocket"]["Url"]) as ws:
        await ws.send(json.dumps({"topic": "aws/subscribe", "content": {"topics": ["aws/chat"]}}))
        reader = asyncio.create_task(read_events(ws, events))

        replies, ended = await collect_replies(events, quiet_seconds, timeout)
        for reply in replies:
            print(f"LINE:   {reply}")

        for turn in turns:
            if ended:
                break
            print(f"CALLER: {turn}")
            participant.send_message(ConnectionToken=token, ContentType="text/plain", Content=turn)
            replies, ended = await collect_replies(events, quiet_seconds, timeout)
            for reply in replies:
                print(f"LINE:   {reply}")
            if not replies and not ended:
                print("LINE:   (no reply)")

        if ended:
            print("(the line ended the contact)")
        else:
            participant.disconnect_participant(ConnectionToken=token)
        reader.cancel()


def main():
    parser = argparse.ArgumentParser(
        description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter
    )
    parser.add_argument("turns", nargs="*", help="What the caller says, one argument per turn.")
    parser.add_argument("--region", default=None)
    parser.add_argument("--quiet-seconds", type=float, default=6, help="Silence that ends a reply.")
    parser.add_argument("--timeout", type=float, default=60, help="Longest wait for a reply.")
    args = parser.parse_args()
    asyncio.run(run(args.turns or DEFAULT_TURNS, args.region, args.quiet_seconds, args.timeout))
    return 0


if __name__ == "__main__":
    sys.exit(main())
