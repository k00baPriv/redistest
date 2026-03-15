import importlib.util
from pathlib import Path
from typing import Any


def load_function_module() -> Any:
    module_path = (
        Path(__file__).resolve().parents[1]
        / "do_functions"
        / "packages"
        / "bench"
        / "redis-bench"
        / "__main__.py"
    )
    spec = importlib.util.spec_from_file_location("do_function_main", module_path)
    assert spec is not None
    assert spec.loader is not None
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


def test_normalized_payload_size_with_zero_stddev_returns_mean() -> None:
    module = load_function_module()

    assert module.normalized_payload_size(100, 0.0) == 100


def test_build_fetch_indexes_randomized_path_uses_random_sample(monkeypatch: Any) -> None:
    module = load_function_module()

    monkeypatch.setattr(module.random, "sample", lambda _population, count: [5, 2, 9][:count])

    result = module.build_fetch_indexes(3, 10, True)

    assert result == [5, 2, 9]


def test_build_fetch_indexes_non_random_wraps_population() -> None:
    module = load_function_module()

    result = module.build_fetch_indexes(5, 3, False)

    assert result == [0, 1, 2, 0, 1]


def test_build_fetch_indexes_randomized_with_replacement(monkeypatch: Any) -> None:
    module = load_function_module()
    sequence = iter([1, 0, 1, 0])

    monkeypatch.setattr(module.random, "randrange", lambda population_size: next(sequence))

    result = module.build_fetch_indexes(4, 2, True)

    assert result == [1, 0, 1, 0]


def test_main_health_returns_ok() -> None:
    module = load_function_module()

    result = module.main({"action": "health"}, None)

    assert result["statusCode"] == 200
    assert result["body"]["status"] == "ok"


def test_main_records_randomizes_by_default(monkeypatch: Any) -> None:
    module = load_function_module()

    calls = {}

    def fake_fetch_records(
        count: int, population_size: int | None = None, randomize: bool = False
    ) -> list[dict]:
        calls["count"] = count
        calls["population_size"] = 0 if population_size is None else population_size
        calls["randomize"] = randomize
        return [{"id": 1, "payload": "abc"}]

    monkeypatch.setattr(module, "fetch_records", fake_fetch_records)

    result = module.main({"action": "records", "count": "5", "population_size": "20"}, None)

    assert result["statusCode"] == 200
    assert result["body"]["count"] == 1
    assert calls == {"count": 5, "population_size": 20, "randomize": True}


def test_main_records_respects_randomize_false(monkeypatch: Any) -> None:
    module = load_function_module()

    calls = {}

    def fake_fetch_records(
        count: int, population_size: int | None = None, randomize: bool = False
    ) -> list[dict]:
        calls["count"] = count
        calls["population_size"] = 0 if population_size is None else population_size
        calls["randomize"] = randomize
        return [{"id": 9, "payload": "xyz"}]

    monkeypatch.setattr(module, "fetch_records", fake_fetch_records)

    result = module.main(
        {
            "action": "records",
            "count": "3",
            "population_size": "10",
            "randomize": "false",
        },
        None,
    )

    assert result["statusCode"] == 200
    assert result["body"]["randomize"] is False
    assert calls == {"count": 3, "population_size": 10, "randomize": False}


def test_main_seed_returns_payload_distribution_metadata(monkeypatch: Any) -> None:
    module = load_function_module()

    monkeypatch.setattr(
        module,
        "seed_records",
        lambda count, _payload_size, _payload_stddev=0.0: (["bench:item:0"], [80, 120]),
    )

    result = module.main(
        {
            "action": "seed",
            "count": "2",
            "payload_size": "100",
            "payload_stddev": "20",
        },
        None,
    )

    assert result["statusCode"] == 200
    assert result["body"]["seeded"] == 1
    assert result["body"]["payload_size_min"] == 80
    assert result["body"]["payload_size_max"] == 120


def test_get_query_params_supports_query_string_input() -> None:
    module = load_function_module()

    result = module.get_query_params({"__ow_query": "action=records&count=7"})

    assert result == {"action": "records", "count": "7"}


def test_get_query_params_falls_back_to_scalar_event_values() -> None:
    module = load_function_module()

    result = module.get_query_params({"action": "records", "count": 5, "__ow_method": "GET"})

    assert result == {"action": "records", "count": "5"}
