# Redis droplet benchmark

`setup_do_redis.sh` can now provision the whole benchmark path:

1. create the managed Redis/Valkey database
2. wait for it to become ready
3. configure the DB firewall
4. optionally create a Droplet
5. bootstrap the benchmark API on that Droplet
6. connect the Droplet to the managed DB

Example:

```bash
./setup_do_redis.sh \
  --name my-redis \
  --create-droplet \
  --droplet-ssh-keys 123456
```

The script writes `REDIS_*` values and, when a Droplet is created, `DROPLET_*` and `BENCHMARK_BASE_URL` into the env file unless `--skip-env-update` is set.

`redis_api.py` is a minimal HTTP service for a DigitalOcean droplet. It writes test records into your managed Redis/Valkey database and retrieves them over HTTP so you can measure latency from your own machine.

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
python3 benchmark_droplet.py --base-url http://YOUR_DROPLET_IP:8000 --seed-first --requests 50 --count 10 --payload-size 100
```

This measures end-to-end latency:

your computer -> droplet HTTP server -> Redis managed DB -> droplet -> your computer
