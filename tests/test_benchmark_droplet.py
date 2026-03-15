import csv
import json
import sys
import urllib.error
from email.message import Message
from pathlib import Path
from types import SimpleNamespace
from typing import Any

import benchmark_droplet


def test_percentile_returns_interpolated_value() -> None:
    values = [10.0, 20.0, 30.0, 40.0]

    result = benchmark_droplet.percentile(values, 0.95)

    assert result == 38.5


def test_response_payload_length_sums_record_payload_bytes() -> None:
    response = {
        "records": [
            {"payload": "abc"},
            {"payload": "hello"},
            {"missing": True},
        ]
    }

    result = benchmark_droplet.response_payload_length(response)

    assert result == 8


def test_write_raw_results_creates_csv(tmp_path: Path) -> None:
    output_path = tmp_path / "raw.csv"
    rows = [
        {
            "request_number": 1,
            "http_status": 200,
            "start_time": "2026-03-15T00:00:00+00:00",
            "response_length": 123,
            "payload_length": 99,
            "latency_ms": 10.5,
        }
    ]

    benchmark_droplet.write_raw_results(output_path, rows)

    with output_path.open(newline="", encoding="utf-8") as handle:
        reader = csv.DictReader(handle)
        loaded_rows = list(reader)

    assert loaded_rows == [
        {
            "request_number": "1",
            "http_status": "200",
            "start_time": "2026-03-15T00:00:00+00:00",
            "response_length": "123",
            "payload_length": "99",
            "latency_ms": "10.5",
        }
    ]


def test_request_rejects_malformed_url() -> None:
    try:
        benchmark_droplet.request("not-a-url", "GET")
    except ValueError as exc:
        assert "Unsupported or malformed URL" in str(exc)
    else:
        raise AssertionError("Expected ValueError for malformed URL")


def test_request_returns_http_error_payload(monkeypatch: Any) -> None:
    class FakeHTTPError(urllib.error.HTTPError):
        def read(self, _amt: int | None = None) -> bytes:
            return b'{"error":"rate-limited"}'

    error = FakeHTTPError(
        url="https://example.com",
        code=429,
        msg="Too Many Requests",
        hdrs=Message(),
        fp=None,
    )

    def fake_urlopen(_req: Any, timeout: int) -> Any:
        assert timeout == 30
        raise error

    monkeypatch.setattr(benchmark_droplet.urllib.request, "urlopen", fake_urlopen)

    status_code, body = benchmark_droplet.request("https://example.com", "GET")

    assert status_code == 429
    assert body == b'{"error":"rate-limited"}'


def test_main_writes_csv_and_summary(monkeypatch: Any, tmp_path: Path, capsys: Any) -> None:
    output_path = tmp_path / "results.csv"
    seed_response = {
        "seeded": 5,
        "payload_size_min": 90,
        "payload_size_max": 110,
    }
    records_response = {
        "records": [
            {"id": 1, "payload": "abc"},
            {"id": 2, "payload": "hello"},
        ]
    }
    responses = [
        (200, json.dumps(seed_response).encode("utf-8")),
        (200, json.dumps(records_response).encode("utf-8")),
        (200, json.dumps(records_response).encode("utf-8")),
    ]
    perf_values = iter([10.0, 10.05, 20.0, 20.08])

    monkeypatch.setattr(
        benchmark_droplet,
        "request",
        lambda _url, method="GET": responses.pop(0),
    )
    monkeypatch.setattr(benchmark_droplet.time, "perf_counter", lambda: next(perf_values))
    monkeypatch.setattr(
        benchmark_droplet.dt,
        "datetime",
        SimpleNamespace(
            now=lambda _tz=None: SimpleNamespace(isoformat=lambda: "2026-03-15T00:00:00+00:00"),
            timezone=benchmark_droplet.dt.timezone,
        ),
    )
    monkeypatch.setattr(
        sys,
        "argv",
        [
            "benchmark_droplet.py",
            "--base-url",
            "https://example.com/api",
            "--seed-first",
            "--requests",
            "2",
            "--count",
            "2",
            "--population-size",
            "5",
            "--payload-size",
            "100",
            "--payload-stddev",
            "10",
            "--raw-output",
            str(output_path),
        ],
    )

    benchmark_droplet.main()

    captured = capsys.readouterr()
    assert "Seeded: 5 records" in captured.out
    assert "Population size: 5" in captured.out
    with output_path.open(newline="", encoding="utf-8") as handle:
        rows = list(csv.DictReader(handle))
    assert len(rows) == 2
    assert rows[0]["http_status"] == "200"
    assert rows[0]["payload_length"] == "8"


def test_main_raises_on_seed_failure(monkeypatch: Any, tmp_path: Path) -> None:
    monkeypatch.setattr(
        benchmark_droplet,
        "request",
        lambda _url, method="GET": (400, b'{"error":"bad seed"}'),
    )
    monkeypatch.setattr(
        sys,
        "argv",
        [
            "benchmark_droplet.py",
            "--base-url",
            "https://example.com/api",
            "--seed-first",
            "--raw-output",
            str(tmp_path / "results.csv"),
        ],
    )

    try:
        benchmark_droplet.main()
    except RuntimeError as exc:
        assert "Seed request failed with HTTP 400" in str(exc)
    else:
        raise AssertionError("Expected RuntimeError for failed seed request")


def test_main_raises_on_benchmark_failure(monkeypatch: Any, tmp_path: Path) -> None:
    responses = [
        (200, b'{"records": [{"payload": "abc"}]}'),
        (429, b'{"error":"rate limited"}'),
    ]
    perf_values = iter([1.0, 1.01, 2.0, 2.02])

    monkeypatch.setattr(
        benchmark_droplet,
        "request",
        lambda _url, method="GET": responses.pop(0),
    )
    monkeypatch.setattr(benchmark_droplet.time, "perf_counter", lambda: next(perf_values))
    monkeypatch.setattr(
        benchmark_droplet.dt,
        "datetime",
        SimpleNamespace(
            now=lambda _tz=None: SimpleNamespace(isoformat=lambda: "2026-03-15T00:00:00+00:00"),
            timezone=benchmark_droplet.dt.timezone,
        ),
    )
    monkeypatch.setattr(
        sys,
        "argv",
        [
            "benchmark_droplet.py",
            "--base-url",
            "https://example.com/api",
            "--requests",
            "2",
            "--raw-output",
            str(tmp_path / "results.csv"),
        ],
    )

    try:
        benchmark_droplet.main()
    except RuntimeError as exc:
        assert "Benchmark request 2 failed with HTTP 429" in str(exc)
    else:
        raise AssertionError("Expected RuntimeError for failed benchmark request")
