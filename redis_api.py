#!/usr/bin/env python3

import json
import os
import string
from http import HTTPStatus
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from typing import Any
from urllib.parse import parse_qs, urlparse

import redis


HOST = os.getenv("API_HOST", "0.0.0.0")
PORT = int(os.getenv("API_PORT", "8000"))
KEY_PREFIX = os.getenv("REDIS_KEY_PREFIX", "bench:item")
DEFAULT_COUNT = int(os.getenv("SEED_COUNT", "10"))
DEFAULT_PAYLOAD_SIZE = int(os.getenv("PAYLOAD_SIZE", "100"))


def get_redis_client() -> redis.Redis:
    redis_url = os.getenv("REDIS_URL")
    if redis_url:
        return redis.Redis.from_url(redis_url, decode_responses=True)

    redis_host = os.getenv("REDIS_HOST")
    redis_port = int(os.getenv("REDIS_PORT", "6379"))
    redis_username = os.getenv("REDIS_USERNAME") or None
    redis_password = os.getenv("REDIS_PASSWORD") or None
    redis_db = int(os.getenv("REDIS_DB", "0"))
    redis_ssl = os.getenv("REDIS_SSL", "true").lower() in {"1", "true", "yes"}

    if not redis_host:
        raise RuntimeError("REDIS_URL or REDIS_HOST must be set")

    return redis.Redis(
        host=redis_host,
        port=redis_port,
        username=redis_username,
        password=redis_password,
        db=redis_db,
        ssl=redis_ssl,
        decode_responses=True,
    )


REDIS = get_redis_client()


def make_payload(index: int, size: int) -> dict[str, Any]:
    alphabet = string.ascii_letters + string.digits
    value = "".join(alphabet[(index + offset) % len(alphabet)] for offset in range(size))
    return {
        "id": index,
        "name": f"record-{index}",
        "payload": value,
    }


def seed_records(count: int, payload_size: int) -> list[str]:
    keys = []
    pipe = REDIS.pipeline()

    for index in range(count):
        key = f"{KEY_PREFIX}:{index}"
        pipe.set(key, json.dumps(make_payload(index, payload_size), separators=(",", ":")))
        keys.append(key)

    pipe.execute()
    return keys


def fetch_records(count: int) -> list[dict[str, Any]]:
    keys = [f"{KEY_PREFIX}:{index}" for index in range(count)]
    raw_values = REDIS.mget(keys)
    records = []

    for key, raw_value in zip(keys, raw_values):
        if raw_value is None:
            records.append({"key": key, "missing": True})
            continue
        records.append(json.loads(raw_value))

    return records


class RedisAPIHandler(BaseHTTPRequestHandler):
    server_version = "RedisAPIServer/1.0"

    def do_GET(self) -> None:
        parsed = urlparse(self.path)

        if parsed.path == "/health":
            self.send_json(HTTPStatus.OK, {"status": "ok"})
            return

        if parsed.path == "/records":
            query = parse_qs(parsed.query)
            count = int(query.get("count", [str(DEFAULT_COUNT)])[0])
            records = fetch_records(count)
            self.send_json(
                HTTPStatus.OK,
                {
                    "count": len(records),
                    "key_prefix": KEY_PREFIX,
                    "records": records,
                },
            )
            return

        self.send_json(HTTPStatus.NOT_FOUND, {"error": "not found"})

    def do_POST(self) -> None:
        parsed = urlparse(self.path)

        if parsed.path == "/seed":
            query = parse_qs(parsed.query)
            count = int(query.get("count", [str(DEFAULT_COUNT)])[0])
            payload_size = int(query.get("payload_size", [str(DEFAULT_PAYLOAD_SIZE)])[0])
            keys = seed_records(count, payload_size)
            self.send_json(
                HTTPStatus.CREATED,
                {
                    "seeded": len(keys),
                    "payload_size": payload_size,
                    "key_prefix": KEY_PREFIX,
                    "keys": keys,
                },
            )
            return

        self.send_json(HTTPStatus.NOT_FOUND, {"error": "not found"})

    def log_message(self, format: str, *args: Any) -> None:
        return

    def send_json(self, status: HTTPStatus, body: dict[str, Any]) -> None:
        payload = json.dumps(body).encode("utf-8")
        self.send_response(status)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(payload)))
        self.end_headers()
        self.wfile.write(payload)


def main() -> None:
    server = ThreadingHTTPServer((HOST, PORT), RedisAPIHandler)
    print(f"Listening on http://{HOST}:{PORT}")
    server.serve_forever()


if __name__ == "__main__":
    main()
