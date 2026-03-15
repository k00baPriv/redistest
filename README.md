# Redis droplet benchmark

`setup_do_redis.sh` can now provision the whole benchmark path:

1. create the managed Redis/Valkey database
2. wait for it to become ready
3. configure the DB firewall
4. optionally create or update an App Platform function app
5. connect that app to the managed DB as a trusted source
6. expose a callable HTTPS endpoint for benchmarking

Example:

```bash
./setup_do_redis.sh \
  --name my-redis \
  --reuse-existing \
  --create-app-function \
  --reuse-existing-app
```

The script writes `REDIS_*` values and, when an App Platform function is created, `FUNCTION_*` values into the env file unless `--skip-env-update` is set.

Important: App Platform deploys from GitHub, not from your local working tree. Push the `do_functions/` directory to GitHub before running `--create-app-function`.

`redis_api.py` is a minimal HTTP service for a DigitalOcean droplet. It writes test records into your managed Redis/Valkey database and retrieves them over HTTP so you can measure latency from your own machine.

`do_functions/` is the App Platform Functions project for the same benchmark flow. The function endpoint supports:

- `GET ?action=seed&count=10&payload_size=100`
- `GET ?action=seed&count=10&payload_size=100&payload_stddev=20`
- `GET ?action=records&count=10`
- `GET ?action=health`

## 1. Install dependencies on the droplet

```bash
python3 -m venv .venv
source .venv/bin/activate
pip install -r requirements.txt
```

## 2. Configure Redis connection

Set either `REDIS_URL` or the split Redis variables:

```bash
export REDIS_URL='rediss://default:password@host:25061/0'
```

or:

```bash
export REDIS_HOST=your-host
export REDIS_PORT=25061
export REDIS_USERNAME=default
export REDIS_PASSWORD=your-password
export REDIS_DB=0
export REDIS_SSL=true
```

## 3. Run the API on the droplet

```bash
python3 redis_api.py
```

The service listens on `0.0.0.0:8000` by default.

Endpoints:

- `POST /seed?count=10&payload_size=100`
- `GET /records?count=10`
- `GET /health`

## 4. Benchmark from your computer

```bash
python3 benchmark_droplet.py \
  --base-url https://YOUR_APP_DOMAIN/api/bench/redis-bench \
  --seed-first \
  --requests 50 \
  --count 10 \
  --payload-size 100 \
  --payload-stddev 20
```

This measures end-to-end latency:

your computer -> App Platform function -> Redis managed DB -> function -> your computer

## Current limits

The App Platform function is currently configured in [do_functions/project.yml](/Users/kuba/PycharmProjects/PythonProject/redistest/do_functions/project.yml) with:

- `memory: 256`
- `timeout: 10000` ms

That means very large benchmark inputs will fail at the function layer before they become a meaningful Redis benchmark.

Example of an unrealistic request:

```bash
python3 benchmark_droplet.py --base-url "$FUNCTION_ENDPOINT" --seed-first --requests 50 --count 100000 --payload-size 10000
```

That attempts to seed roughly 1 GB of JSON payload, which exceeds the current function limits.

Use smaller values such as:

```bash
python3 benchmark_droplet.py --base-url "$FUNCTION_ENDPOINT" --seed-first --requests 50 --count 100 --payload-size 1000
```

or:

```bash
python3 benchmark_droplet.py --base-url "$FUNCTION_ENDPOINT" --seed-first --requests 20 --count 1000 --payload-size 500
```

If you want more realistic variation in response sizes, seed with a payload-size distribution instead of a fixed size:

```bash
python3 benchmark_droplet.py \
  --base-url "$FUNCTION_ENDPOINT" \
  --seed-first \
  --requests 50 \
  --count 100 \
  --payload-size 1000 \
  --payload-stddev 250
```

That uses `payload-size` as the mean and `payload-stddev` as the standard deviation for a normal distribution. Payload sizes are clamped to at least 1 byte.
