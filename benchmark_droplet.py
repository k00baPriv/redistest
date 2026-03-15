#!/usr/bin/env python3

import argparse
import csv
import datetime as dt
import json
import statistics
import time
import urllib.error
import urllib.request
from pathlib import Path
from urllib.parse import urlparse


def request(url: str, method: str) -> tuple[int, bytes]:
    parsed = urlparse(url)
    if parsed.scheme not in {"http", "https"} or not parsed.netloc:
        raise ValueError(f"Unsupported or malformed URL: {url}")

    req = urllib.request.Request(url, method=method)
    try:
        with urllib.request.urlopen(req, timeout=30) as response:  # nosec B310
            return response.status, response.read()
    except urllib.error.HTTPError as exc:
        return exc.code, exc.read()


def parse_json(body: bytes) -> dict:
    return json.loads(body.decode("utf-8"))


def response_payload_length(response: dict) -> int:
    records = response.get("records")
    if not isinstance(records, list):
        return 0

    total = 0
    for record in records:
        if isinstance(record, dict):
            payload = record.get("payload")
            if isinstance(payload, str):
                total += len(payload.encode("utf-8"))
    return total


def write_raw_results(output_path: Path, rows: list[dict]) -> None:
    fieldnames = [
        "request_number",
        "http_status",
        "start_time",
        "response_length",
        "payload_length",
        "latency_ms",
    ]
    with output_path.open("w", encoding="utf-8", newline="") as handle:
        writer = csv.DictWriter(handle, fieldnames=fieldnames)
        writer.writeheader()
        writer.writerows(rows)


def percentile(values: list[float], ratio: float) -> float:
    if not values:
        return 0.0
    if len(values) == 1:
        return values[0]

    index = (len(values) - 1) * ratio
    lower = int(index)
    upper = min(lower + 1, len(values) - 1)
    weight = index - lower
    return values[lower] * (1 - weight) + values[upper] * weight


def main() -> None:
    parser = argparse.ArgumentParser(
        description="Benchmark HTTP endpoint -> Redis retrieval latency"
    )
    parser.add_argument(
        "--base-url",
        required=True,
        help="Example: http://203.0.113.10:8000 or https://app.example.com/api/bench/redis-bench",
    )
    parser.add_argument("--requests", type=int, default=50, help="Number of GET requests to send")
    parser.add_argument(
        "--count", type=int, default=10, help="Number of records to fetch each time"
    )
    parser.add_argument(
        "--population-size",
        type=int,
        default=None,
        help="Seeded pool size to fetch from. Defaults to --count",
    )
    parser.add_argument(
        "--seed-first", action="store_true", help="Seed records before benchmarking"
    )
    parser.add_argument(
        "--payload-size", type=int, default=100, help="Mean payload size to use when seeding"
    )
    parser.add_argument(
        "--payload-stddev",
        type=float,
        default=0.0,
        help="Standard deviation for seeded payload sizes. Default: 0.0 for fixed-size payloads",
    )
    parser.add_argument(
        "--raw-output",
        default="benchmark_raw.csv",
        help="Path to write per-request raw benchmark data as CSV. Default: benchmark_raw.csv",
    )
    args = parser.parse_args()

    base_url = args.base_url.rstrip("/")
    raw_output = Path(args.raw_output)
    population_size = args.population_size if args.population_size is not None else args.count

    if args.seed_first:
        seed_status, seed_body = request(
            f"{base_url}?action=seed&count={population_size}&payload_size={args.payload_size}&payload_stddev={args.payload_stddev}",
            method="GET",
        )
        seeded = parse_json(seed_body)
        if seed_status >= 400:
            raise RuntimeError(f"Seed request failed with HTTP {seed_status}: {json.dumps(seeded)}")
        print(f"Seeded: {seeded['seeded']} records")
        print(
            "Seed payload sizes:"
            f" mean={args.payload_size}, stddev={args.payload_stddev},"
            f" min={seeded.get('payload_size_min')}, max={seeded.get('payload_size_max')}"
        )

    samples_ms = []
    response_size_bytes = 0
    raw_rows = []

    for request_number in range(1, args.requests + 1):
        started_wall_time = dt.datetime.now(dt.timezone.utc).isoformat()
        started = time.perf_counter()
        status_code, body = request(
            f"{base_url}?action=records&count={args.count}&population_size={population_size}&randomize=true",
            method="GET",
        )
        elapsed_ms = (time.perf_counter() - started) * 1000
        response = parse_json(body)

        if status_code >= 400:
            raise RuntimeError(
                f"Benchmark request {request_number} failed with HTTP "
                f"{status_code}: {json.dumps(response)}"
            )

        samples_ms.append(elapsed_ms)
        response_size_bytes = len(body)
        raw_rows.append(
            {
                "request_number": request_number,
                "http_status": status_code,
                "start_time": started_wall_time,
                "response_length": len(body),
                "payload_length": response_payload_length(response),
                "latency_ms": round(elapsed_ms, 3),
            }
        )

    samples_ms.sort()
    write_raw_results(raw_output, raw_rows)

    print(f"Requests: {args.requests}")
    print(f"Records per request: {args.count}")
    print(f"Population size: {population_size}")
    print(f"Approx response size: {response_size_bytes} bytes")
    print(f"Average: {statistics.mean(samples_ms):.2f} ms")
    print(f"Median: {statistics.median(samples_ms):.2f} ms")
    print(f"P95: {percentile(samples_ms, 0.95):.2f} ms")
    print(f"Min: {samples_ms[0]:.2f} ms")
    print(f"Max: {samples_ms[-1]:.2f} ms")
    print(f"Raw results written to: {raw_output}")


if __name__ == "__main__":
    main()
