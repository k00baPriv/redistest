#!/usr/bin/env python3

import argparse
import json
import statistics
import time
import urllib.request


def request(url: str, method: str) -> dict:
    req = urllib.request.Request(url, method=method)
    with urllib.request.urlopen(req, timeout=30) as response:
        return json.loads(response.read().decode("utf-8"))


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
    parser = argparse.ArgumentParser(description="Benchmark droplet -> Redis retrieval latency")
    parser.add_argument("--base-url", required=True, help="Example: http://203.0.113.10:8000")
    parser.add_argument("--requests", type=int, default=50, help="Number of GET requests to send")
    parser.add_argument("--count", type=int, default=10, help="Number of records to fetch each time")
    parser.add_argument("--seed-first", action="store_true", help="Seed records before benchmarking")
    parser.add_argument("--payload-size", type=int, default=100, help="Payload size to use when seeding")
    args = parser.parse_args()

    base_url = args.base_url.rstrip("/")

    if args.seed_first:
        seeded = request(
            f"{base_url}/seed?count={args.count}&payload_size={args.payload_size}",
            method="POST",
        )
        print(f"Seeded: {seeded['seeded']} records")

    samples_ms = []
    response_size_bytes = 0

    for _ in range(args.requests):
        started = time.perf_counter()
        response = request(f"{base_url}/records?count={args.count}", method="GET")
        elapsed_ms = (time.perf_counter() - started) * 1000
        samples_ms.append(elapsed_ms)
        response_size_bytes = len(json.dumps(response).encode("utf-8"))

    samples_ms.sort()

    print(f"Requests: {args.requests}")
    print(f"Records per request: {args.count}")
    print(f"Approx response size: {response_size_bytes} bytes")
    print(f"Average: {statistics.mean(samples_ms):.2f} ms")
    print(f"Median: {statistics.median(samples_ms):.2f} ms")
    print(f"P95: {percentile(samples_ms, 0.95):.2f} ms")
    print(f"Min: {samples_ms[0]:.2f} ms")
    print(f"Max: {samples_ms[-1]:.2f} ms")


if __name__ == "__main__":
    main()
