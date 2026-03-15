import json
import os
import random
import string
from typing import Any
from urllib.parse import parse_qs, urlparse


KEY_PREFIX = os.getenv("REDIS_KEY_PREFIX", "bench:item")
DEFAULT_COUNT = int(os.getenv("SEED_COUNT", "10"))
DEFAULT_PAYLOAD_SIZE = int(os.getenv("PAYLOAD_SIZE", "100"))


def get_redis_client():
    import redis

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


def response(status_code: int, body: dict[str, Any]) -> dict[str, Any]:
    return {
        "statusCode": status_code,
        "headers": {"Content-Type": "application/json"},
        "body": body,
    }


def normalized_payload_size(mean: int, stddev: float) -> int:
    if stddev <= 0:
        return max(1, mean)
    return max(1, int(round(random.gauss(mean, stddev))))


def make_payload(index: int, size: int) -> dict[str, Any]:
    alphabet = string.ascii_letters + string.digits
    payload = "".join(alphabet[(index + offset) % len(alphabet)] for offset in range(size))
    return {
        "id": index,
        "name": f"record-{index}",
        "payload": payload,
    }


def seed_records(count: int, payload_size: int, payload_stddev: float = 0.0) -> tuple[list[str], list[int]]:
    redis_client = get_redis_client()
    keys = []
    payload_sizes = []
    pipe = redis_client.pipeline()

    for index in range(count):
        key = f"{KEY_PREFIX}:{index}"
        current_payload_size = normalized_payload_size(payload_size, payload_stddev)
        pipe.set(key, json.dumps(make_payload(index, current_payload_size), separators=(",", ":")))
        keys.append(key)
        payload_sizes.append(current_payload_size)

    pipe.execute()
    return keys, payload_sizes


def build_fetch_indexes(count: int, population_size: int, randomize: bool) -> list[int]:
    if population_size <= 0:
        return []

    if randomize:
        if count <= population_size:
            return random.sample(range(population_size), count)
        return [random.randrange(population_size) for _ in range(count)]

    return [index % population_size for index in range(count)]


def fetch_records(count: int, population_size: int | None = None, randomize: bool = False) -> list[dict[str, Any]]:
    redis_client = get_redis_client()
    effective_population = population_size if population_size is not None else count
    indexes = build_fetch_indexes(count, effective_population, randomize)
    keys = [f"{KEY_PREFIX}:{index}" for index in indexes]
    raw_values = redis_client.mget(keys)
    records = []

    for key, raw_value in zip(keys, raw_values):
        if raw_value is None:
            records.append({"key": key, "missing": True})
        else:
            records.append(json.loads(raw_value))

    return records


def get_method(event: dict[str, Any]) -> str:
    method = (
        event.get("http", {}).get("method")
        or event.get("__ow_method")
        or event.get("method")
        or "GET"
    )
    return str(method).upper()


def get_path(event: dict[str, Any]) -> str:
    path = (
        event.get("http", {}).get("path")
        or event.get("__ow_path")
        or event.get("path")
        or ""
    )
    return str(path)


def get_query_params(event: dict[str, Any]) -> dict[str, str]:
    query = event.get("http", {}).get("query") or event.get("__ow_query")
    if isinstance(query, dict):
        return {str(key): str(value) for key, value in query.items()}
    if isinstance(query, str) and query:
        return {key: values[-1] for key, values in parse_qs(query).items()}

    url = event.get("url")
    if isinstance(url, str) and url:
        return {key: values[-1] for key, values in parse_qs(urlparse(url).query).items()}

    params = {}
    for key, value in event.items():
        if key.startswith("__ow_"):
            continue
        if isinstance(value, (str, int, float, bool)):
            params[str(key)] = str(value)
    return params


def as_int(params: dict[str, str], key: str, default: int) -> int:
    value = params.get(key, str(default))
    return int(value)


def as_float(params: dict[str, str], key: str, default: float) -> float:
    value = params.get(key, str(default))
    return float(value)


def as_bool(params: dict[str, str], key: str, default: bool = False) -> bool:
    if key not in params:
        return default
    return params[key].strip().lower() in {"1", "true", "yes", "on"}


def main(event: dict[str, Any], context: Any) -> dict[str, Any]:
    try:
        method = get_method(event)
        path = get_path(event)
        params = get_query_params(event)
        action = params.get("action", "").lower()

        if action == "health" or path.endswith("/health"):
            return response(200, {"status": "ok", "path": path, "action": action or None})

        if action == "seed" or method == "POST" or path.endswith("/seed"):
            count = as_int(params, "count", DEFAULT_COUNT)
            payload_size = as_int(params, "payload_size", DEFAULT_PAYLOAD_SIZE)
            payload_stddev = as_float(params, "payload_stddev", 0.0)
            keys, payload_sizes = seed_records(count, payload_size, payload_stddev)
            return response(
                200,
                {
                    "seeded": len(keys),
                    "payload_size": payload_size,
                    "payload_stddev": payload_stddev,
                    "payload_size_min": min(payload_sizes) if payload_sizes else 0,
                    "payload_size_max": max(payload_sizes) if payload_sizes else 0,
                    "key_prefix": KEY_PREFIX,
                    "keys": keys,
                },
            )

        count = as_int(params, "count", DEFAULT_COUNT)
        population_size = as_int(params, "population_size", count)
        randomize = as_bool(params, "randomize", False)
        records = fetch_records(count, population_size=population_size, randomize=randomize)
        return response(
            200,
            {
                "count": len(records),
                "population_size": population_size,
                "randomize": randomize,
                "key_prefix": KEY_PREFIX,
                "records": records,
            },
        )
    except Exception as exc:
        return response(500, {"error": str(exc)})
