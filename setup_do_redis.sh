#!/usr/bin/env bash

set -euo pipefail

usage() {
    cat <<'EOF'
Usage:
  ./setup_do_redis.sh --name NAME [options]

Creates a DigitalOcean Valkey/Redis database, waits for it to become online,
optionally updates firewall rules, writes connection details to an env file,
and can provision a Droplet that runs the benchmark API service.

Options:
  --name NAME                 Database name. Required.
  --region REGION             Database region. Default: fra1
  --size SIZE                 Database size slug. Default: db-s-1vcpu-1gb
  --nodes COUNT               Number of DB nodes. Default: 1
  --engine ENGINE             Database engine. Default: valkey
  --env-file PATH             Read token from and write outputs to this env file. Default: .env
  --skip-env-update           Do not write Redis/Droplet outputs to the env file.
  --skip-ip-firewall          Do not add the current public IP to the DB firewall.
  --app-id ID                 Add an App Platform app firewall rule.
  --eviction-policy POLICY    Eviction policy to apply. Default: noeviction
  --poll-interval SECONDS     Wait time between status checks. Default: 15
  --timeout SECONDS           Max wait time for DB or Droplet readiness. Default: 1800
  --reuse-existing            Reuse an existing DB with the same name instead of failing.

Droplet options:
  --create-droplet            Create a Droplet and deploy the benchmark API service to it.
  --droplet-name NAME         Droplet name. Default: <db-name>-bench
  --droplet-region REGION     Droplet region. Default: same as DB region
  --droplet-size SIZE         Droplet size slug. Default: s-1vcpu-1gb
  --droplet-image IMAGE       Droplet image slug. Default: ubuntu-24-04-x64
  --droplet-ssh-keys KEYS     Comma-separated SSH key IDs or fingerprints.
  --droplet-port PORT         API port on the droplet. Default: 8000
  --reuse-existing-droplet    Reuse an existing Droplet with the same name instead of failing.

  --help                      Show this help.

Environment:
  DIGITALOCEAN_TOKEN          Accepted for API calls and mapped to doctl auth.
  DIGITALOCEAN_ACCESS_TOKEN   Accepted for doctl and API calls.

Examples:
  ./setup_do_redis.sh --name my-redis
  ./setup_do_redis.sh --name my-redis --create-droplet --droplet-ssh-keys 123456
  ./setup_do_redis.sh --name my-redis --region ams3 --app-id 12345678
EOF
}

require_cmd() {
    local cmd=$1
    if ! command -v "$cmd" >/dev/null 2>&1; then
        echo "Error: required command not found: $cmd" >&2
        exit 1
    fi
}

load_env_file() {
    local env_file=$1

    if [[ ! -f "$env_file" ]]; then
        return 0
    fi

    echo "Loading environment from $env_file"
    set -a
    # shellcheck disable=SC1090
    source "$env_file"
    set +a
}

api_request() {
    local method=$1
    local url=$2
    local body=${3:-}
    local curl_args=(
        -fsS
        -X "$method"
        -H "Authorization: Bearer ${DIGITALOCEAN_TOKEN}"
        -H "Content-Type: application/json"
    )

    if [[ -n "$body" ]]; then
        curl_args+=(-d "$body")
    fi

    curl "${curl_args[@]}" "$url"
}

quote_for_shell() {
    printf '%q' "$1"
}

get_db_id_by_name() {
    doctl databases list --format ID,Name --no-header | awk -v db_name="$DB_NAME" '$2 == db_name {print $1; exit}'
}

get_db_status() {
    local db_id=$1
    doctl databases get "$db_id" --format Status --no-header
}

get_db_uri() {
    local db_id=$1
    doctl databases get "$db_id" --format URI --no-header
}

wait_for_db_online() {
    local db_id=$1
    local started_at
    started_at=$(date +%s)

    echo "Waiting for database to become online..."

    while true; do
        local status
        status=$(get_db_status "$db_id")
        echo "Current status: $status"

        if [[ "$status" == "online" ]]; then
            return 0
        fi

        if (( "$(date +%s)" - started_at >= TIMEOUT_SECONDS )); then
            echo "Error: timed out waiting for database $db_id to become online" >&2
            exit 1
        fi

        sleep "$POLL_INTERVAL"
    done
}

parse_uri() {
    local uri=$1
    REDIS_SCHEME=$(python3 -c 'import sys, urllib.parse as u; p=u.urlparse(sys.argv[1]); print(p.scheme or "")' "$uri")
    REDIS_USERNAME=$(python3 -c 'import sys, urllib.parse as u; p=u.urlparse(sys.argv[1]); print(u.unquote(p.username or ""))' "$uri")
    REDIS_PASSWORD=$(python3 -c 'import sys, urllib.parse as u; p=u.urlparse(sys.argv[1]); print(u.unquote(p.password or ""))' "$uri")
    REDIS_HOST=$(python3 -c 'import sys, urllib.parse as u; p=u.urlparse(sys.argv[1]); print(p.hostname or "")' "$uri")
    REDIS_PORT=$(python3 -c 'import sys, urllib.parse as u; p=u.urlparse(sys.argv[1]); print(p.port or "")' "$uri")
    REDIS_DB=$(python3 -c 'import sys, urllib.parse as u; p=u.urlparse(sys.argv[1]); print((p.path or "").lstrip("/"))' "$uri")

    if [[ "$REDIS_SCHEME" == "rediss" ]]; then
        REDIS_SSL="true"
    else
        REDIS_SSL="false"
    fi
}

update_env_file() {
    local env_file=$1
    local tmp_file
    tmp_file=$(mktemp "${TMPDIR:-/tmp}/redis-env.XXXXXX")

    if [[ -f "$env_file" ]]; then
        awk '
            !/^REDIS_USERNAME=/ &&
            !/^REDIS_PASSWORD=/ &&
            !/^REDIS_HOST=/ &&
            !/^REDIS_PORT=/ &&
            !/^REDIS_DB=/ &&
            !/^REDIS_SSL=/ &&
            !/^REDIS_URL=/ &&
            !/^DROPLET_ID=/ &&
            !/^DROPLET_NAME=/ &&
            !/^DROPLET_IP=/ &&
            !/^BENCHMARK_BASE_URL=/
        ' "$env_file" > "$tmp_file"
    else
        : > "$tmp_file"
    fi

    {
        echo ""
        echo "# Redis Database Configuration"
        echo "REDIS_USERNAME=$(quote_for_shell "$REDIS_USERNAME")"
        echo "REDIS_PASSWORD=$(quote_for_shell "$REDIS_PASSWORD")"
        echo "REDIS_HOST=$(quote_for_shell "$REDIS_HOST")"
        echo "REDIS_PORT=$(quote_for_shell "$REDIS_PORT")"
        echo "REDIS_DB=$(quote_for_shell "$REDIS_DB")"
        echo "REDIS_SSL=$(quote_for_shell "$REDIS_SSL")"
        echo "REDIS_URL=$(quote_for_shell "$REDIS_URL")"

        if [[ -n "$DROPLET_ID" ]]; then
            echo ""
            echo "# Benchmark Droplet"
            echo "DROPLET_ID=$(quote_for_shell "$DROPLET_ID")"
            echo "DROPLET_NAME=$(quote_for_shell "$DROPLET_NAME")"
            echo "DROPLET_IP=$(quote_for_shell "$DROPLET_IP")"
            echo "BENCHMARK_BASE_URL=$(quote_for_shell "$BENCHMARK_BASE_URL")"
        fi
    } >> "$tmp_file"

    mv "$tmp_file" "$env_file"
    echo "Updated env file: $env_file"
}

add_current_ip_firewall() {
    echo "Getting current public IP..."
    local current_ip
    current_ip=$(curl -fsS ifconfig.me)
    echo "Adding firewall rule for IP: $current_ip"
    doctl databases firewalls append "$DB_ID" --rule "ip_addr:${current_ip}"
}

set_eviction_policy() {
    local db_id=$1
    local policy=$2
    echo "Setting eviction policy to: $policy"
    api_request PUT \
        "https://api.digitalocean.com/v2/databases/${db_id}/eviction_policy" \
        "{\"eviction_policy\":\"${policy}\"}" >/dev/null
}

get_droplet_id_by_name() {
    local droplet_name=$1
    doctl compute droplet list --format ID,Name --no-header | awk -v name="$droplet_name" '$2 == name {print $1; exit}'
}

get_droplet_status() {
    local droplet_id=$1
    doctl compute droplet get "$droplet_id" --format Status --no-header
}

get_droplet_ip() {
    local droplet_id=$1
    doctl compute droplet get "$droplet_id" --format PublicIPv4 --no-header
}

wait_for_droplet_active() {
    local droplet_id=$1
    local started_at
    started_at=$(date +%s)

    echo "Waiting for droplet to become active..."

    while true; do
        local status
        status=$(get_droplet_status "$droplet_id")
        echo "Droplet status: $status"

        if [[ "$status" == "active" ]]; then
            return 0
        fi

        if (( "$(date +%s)" - started_at >= TIMEOUT_SECONDS )); then
            echo "Error: timed out waiting for droplet $droplet_id to become active" >&2
            exit 1
        fi

        sleep "$POLL_INTERVAL"
    done
}

create_droplet_user_data() {
    USER_DATA_FILE=$(mktemp "${TMPDIR:-/tmp}/droplet-user-data.XXXXXX")

    local q_redis_url q_redis_host q_redis_port q_redis_username q_redis_password q_redis_db q_redis_ssl q_port
    q_redis_url=$(quote_for_shell "$REDIS_URL")
    q_redis_host=$(quote_for_shell "$REDIS_HOST")
    q_redis_port=$(quote_for_shell "$REDIS_PORT")
    q_redis_username=$(quote_for_shell "$REDIS_USERNAME")
    q_redis_password=$(quote_for_shell "$REDIS_PASSWORD")
    q_redis_db=$(quote_for_shell "$REDIS_DB")
    q_redis_ssl=$(quote_for_shell "$REDIS_SSL")
    q_port=$(quote_for_shell "$DROPLET_PORT")

    cat > "$USER_DATA_FILE" <<EOF
#!/usr/bin/env bash
set -euo pipefail

export DEBIAN_FRONTEND=noninteractive

apt-get update
apt-get install -y python3 python3-venv

mkdir -p /opt/redis-bench

cat > /opt/redis-bench/requirements.txt <<'REQ'
redis>=5.0.0,<6.0.0
REQ

cat > /opt/redis-bench/redis_api.py <<'PY'
#!/usr/bin/env python3

import json
import os
import string
from http import HTTPStatus
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import parse_qs, urlparse

import redis


HOST = "0.0.0.0"
PORT = int(os.getenv("API_PORT", "8000"))
KEY_PREFIX = os.getenv("REDIS_KEY_PREFIX", "bench:item")
DEFAULT_COUNT = int(os.getenv("SEED_COUNT", "10"))
DEFAULT_PAYLOAD_SIZE = int(os.getenv("PAYLOAD_SIZE", "100"))


def get_client():
    redis_url = os.getenv("REDIS_URL")
    if redis_url:
        return redis.Redis.from_url(redis_url, decode_responses=True)

    return redis.Redis(
        host=os.environ["REDIS_HOST"],
        port=int(os.getenv("REDIS_PORT", "6379")),
        username=os.getenv("REDIS_USERNAME") or None,
        password=os.getenv("REDIS_PASSWORD") or None,
        db=int(os.getenv("REDIS_DB", "0")),
        ssl=os.getenv("REDIS_SSL", "true").lower() in {"1", "true", "yes"},
        decode_responses=True,
    )


REDIS = get_client()


def make_payload(index: int, size: int):
    alphabet = string.ascii_letters + string.digits
    payload = "".join(alphabet[(index + offset) % len(alphabet)] for offset in range(size))
    return {"id": index, "name": f"record-{index}", "payload": payload}


def seed_records(count: int, payload_size: int):
    keys = []
    pipe = REDIS.pipeline()
    for index in range(count):
        key = f"{KEY_PREFIX}:{index}"
        pipe.set(key, json.dumps(make_payload(index, payload_size), separators=(",", ":")))
        keys.append(key)
    pipe.execute()
    return keys


def fetch_records(count: int):
    keys = [f"{KEY_PREFIX}:{index}" for index in range(count)]
    values = REDIS.mget(keys)
    records = []
    for key, value in zip(keys, values):
        if value is None:
            records.append({"key": key, "missing": True})
        else:
            records.append(json.loads(value))
    return records


class Handler(BaseHTTPRequestHandler):
    def do_GET(self):
        parsed = urlparse(self.path)
        if parsed.path == "/health":
            self.send_json(HTTPStatus.OK, {"status": "ok"})
            return
        if parsed.path == "/records":
            query = parse_qs(parsed.query)
            count = int(query.get("count", [str(DEFAULT_COUNT)])[0])
            self.send_json(HTTPStatus.OK, {"count": count, "records": fetch_records(count)})
            return
        self.send_json(HTTPStatus.NOT_FOUND, {"error": "not found"})

    def do_POST(self):
        parsed = urlparse(self.path)
        if parsed.path == "/seed":
            query = parse_qs(parsed.query)
            count = int(query.get("count", [str(DEFAULT_COUNT)])[0])
            payload_size = int(query.get("payload_size", [str(DEFAULT_PAYLOAD_SIZE)])[0])
            keys = seed_records(count, payload_size)
            self.send_json(HTTPStatus.CREATED, {"seeded": len(keys), "keys": keys, "payload_size": payload_size})
            return
        self.send_json(HTTPStatus.NOT_FOUND, {"error": "not found"})

    def log_message(self, format, *args):
        return

    def send_json(self, status, body):
        payload = json.dumps(body).encode("utf-8")
        self.send_response(status)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(payload)))
        self.end_headers()
        self.wfile.write(payload)


server = ThreadingHTTPServer((HOST, PORT), Handler)
server.serve_forever()
PY

chmod +x /opt/redis-bench/redis_api.py

cat > /opt/redis-bench/service.env <<ENV
REDIS_URL=${q_redis_url}
REDIS_HOST=${q_redis_host}
REDIS_PORT=${q_redis_port}
REDIS_USERNAME=${q_redis_username}
REDIS_PASSWORD=${q_redis_password}
REDIS_DB=${q_redis_db}
REDIS_SSL=${q_redis_ssl}
API_PORT=${q_port}
ENV

cat > /opt/redis-bench/run.sh <<'RUN'
#!/usr/bin/env bash
set -euo pipefail
source /opt/redis-bench/service.env
exec /opt/redis-bench/.venv/bin/python /opt/redis-bench/redis_api.py
RUN

chmod +x /opt/redis-bench/run.sh

python3 -m venv /opt/redis-bench/.venv
/opt/redis-bench/.venv/bin/pip install --no-cache-dir -r /opt/redis-bench/requirements.txt

cat > /etc/systemd/system/redis-bench.service <<'UNIT'
[Unit]
Description=Redis benchmark API
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
WorkingDirectory=/opt/redis-bench
ExecStart=/opt/redis-bench/run.sh
Restart=always
RestartSec=5

[Install]
WantedBy=multi-user.target
UNIT

systemctl daemon-reload
systemctl enable redis-bench.service
systemctl restart redis-bench.service
EOF
}

cleanup() {
    if [[ -n "${USER_DATA_FILE:-}" && -f "${USER_DATA_FILE:-}" ]]; then
        rm -f "$USER_DATA_FILE"
    fi
}

DB_NAME=""
REGION="fra1"
SIZE="db-s-1vcpu-1gb"
NODES="1"
ENGINE="valkey"
ENV_FILE=".env"
UPDATE_ENV_FILE=true
ADD_IP_FIREWALL=true
APP_ID=""
EVICTION_POLICY="noeviction"
POLL_INTERVAL=15
TIMEOUT_SECONDS=1800
REUSE_EXISTING=false
CREATE_DROPLET=false
DROPLET_NAME=""
DROPLET_REGION=""
DROPLET_SIZE="s-1vcpu-1gb"
DROPLET_IMAGE="ubuntu-24-04-x64"
DROPLET_SSH_KEYS=""
DROPLET_PORT="8000"
REUSE_EXISTING_DROPLET=false
DROPLET_ID=""
DROPLET_IP=""
BENCHMARK_BASE_URL=""
USER_DATA_FILE=""
REDIS_SCHEME=""
REDIS_SSL=""

trap cleanup EXIT

while [[ $# -gt 0 ]]; do
    case "$1" in
        --name)
            DB_NAME=${2:-}
            shift 2
            ;;
        --region)
            REGION=${2:-}
            shift 2
            ;;
        --size)
            SIZE=${2:-}
            shift 2
            ;;
        --nodes)
            NODES=${2:-}
            shift 2
            ;;
        --engine)
            ENGINE=${2:-}
            shift 2
            ;;
        --env-file)
            ENV_FILE=${2:-}
            shift 2
            ;;
        --skip-env-update)
            UPDATE_ENV_FILE=false
            shift
            ;;
        --skip-ip-firewall)
            ADD_IP_FIREWALL=false
            shift
            ;;
        --app-id)
            APP_ID=${2:-}
            shift 2
            ;;
        --eviction-policy)
            EVICTION_POLICY=${2:-}
            shift 2
            ;;
        --poll-interval)
            POLL_INTERVAL=${2:-}
            shift 2
            ;;
        --timeout)
            TIMEOUT_SECONDS=${2:-}
            shift 2
            ;;
        --reuse-existing)
            REUSE_EXISTING=true
            shift
            ;;
        --create-droplet)
            CREATE_DROPLET=true
            shift
            ;;
        --droplet-name)
            DROPLET_NAME=${2:-}
            shift 2
            ;;
        --droplet-region)
            DROPLET_REGION=${2:-}
            shift 2
            ;;
        --droplet-size)
            DROPLET_SIZE=${2:-}
            shift 2
            ;;
        --droplet-image)
            DROPLET_IMAGE=${2:-}
            shift 2
            ;;
        --droplet-ssh-keys)
            DROPLET_SSH_KEYS=${2:-}
            shift 2
            ;;
        --droplet-port)
            DROPLET_PORT=${2:-}
            shift 2
            ;;
        --reuse-existing-droplet)
            REUSE_EXISTING_DROPLET=true
            shift
            ;;
        --help|-h)
            usage
            exit 0
            ;;
        *)
            echo "Error: unknown argument: $1" >&2
            usage
            exit 1
            ;;
    esac
done

if [[ -z "$DB_NAME" ]]; then
    echo "Error: --name is required" >&2
    usage
    exit 1
fi

if [[ -z "$DROPLET_NAME" ]]; then
    DROPLET_NAME="${DB_NAME}-bench"
fi

if [[ -z "$DROPLET_REGION" ]]; then
    DROPLET_REGION="$REGION"
fi

for cmd in doctl curl python3 awk; do
    require_cmd "$cmd"
done

load_env_file "$ENV_FILE"

if [[ -z "${DIGITALOCEAN_TOKEN:-}" && -n "${DIGITALOCEAN_ACCESS_TOKEN:-}" ]]; then
    DIGITALOCEAN_TOKEN=$DIGITALOCEAN_ACCESS_TOKEN
    export DIGITALOCEAN_TOKEN
fi

if [[ -z "${DIGITALOCEAN_ACCESS_TOKEN:-}" && -n "${DIGITALOCEAN_TOKEN:-}" ]]; then
    DIGITALOCEAN_ACCESS_TOKEN=$DIGITALOCEAN_TOKEN
    export DIGITALOCEAN_ACCESS_TOKEN
fi

if [[ -z "${DIGITALOCEAN_TOKEN:-}" || -z "${DIGITALOCEAN_ACCESS_TOKEN:-}" ]]; then
    echo "Error: no DigitalOcean API token found" >&2
    echo "Set DIGITALOCEAN_TOKEN or DIGITALOCEAN_ACCESS_TOKEN in your shell or in $ENV_FILE" >&2
    exit 1
fi

EXISTING_DB_ID=$(get_db_id_by_name || true)

if [[ -n "$EXISTING_DB_ID" ]]; then
    if [[ "$REUSE_EXISTING" == true ]]; then
        DB_ID=$EXISTING_DB_ID
        echo "Reusing existing database: $DB_NAME ($DB_ID)"
    else
        echo "Error: database already exists with name '$DB_NAME' (ID: $EXISTING_DB_ID)" >&2
        echo "Use --reuse-existing to use it instead of failing." >&2
        exit 1
    fi
else
    echo "Creating database '$DB_NAME'..."
    doctl databases create "$DB_NAME" \
        --engine "$ENGINE" \
        --region "$REGION" \
        --size "$SIZE" \
        --num-nodes "$NODES" >/dev/null

    DB_ID=$(get_db_id_by_name)
    if [[ -z "$DB_ID" ]]; then
        echo "Error: database '$DB_NAME' was not found after creation" >&2
        exit 1
    fi

    echo "Database created with ID: $DB_ID"
fi

wait_for_db_online "$DB_ID"
set_eviction_policy "$DB_ID" "$EVICTION_POLICY"

if [[ "$ADD_IP_FIREWALL" == true ]]; then
    add_current_ip_firewall
fi

if [[ -n "$APP_ID" ]]; then
    echo "Adding firewall rule for app: $APP_ID"
    doctl databases firewalls append "$DB_ID" --rule "app:${APP_ID}"
fi

REDIS_URL=$(get_db_uri "$DB_ID")
parse_uri "$REDIS_URL"

if [[ "$CREATE_DROPLET" == true ]]; then
    EXISTING_DROPLET_ID=$(get_droplet_id_by_name "$DROPLET_NAME" || true)

    if [[ -n "$EXISTING_DROPLET_ID" ]]; then
        if [[ "$REUSE_EXISTING_DROPLET" == true ]]; then
            DROPLET_ID=$EXISTING_DROPLET_ID
            echo "Reusing existing droplet: $DROPLET_NAME ($DROPLET_ID)"
        else
            echo "Error: droplet already exists with name '$DROPLET_NAME' (ID: $EXISTING_DROPLET_ID)" >&2
            echo "Use --reuse-existing-droplet to use it instead of failing." >&2
            exit 1
        fi
    else
        create_droplet_user_data

        echo "Creating droplet '$DROPLET_NAME'..."
        droplet_create_args=(
            compute droplet create "$DROPLET_NAME"
            --region "$DROPLET_REGION"
            --size "$DROPLET_SIZE"
            --image "$DROPLET_IMAGE"
            --user-data-file "$USER_DATA_FILE"
            --wait
        )

        if [[ -n "$DROPLET_SSH_KEYS" ]]; then
            droplet_create_args+=(--ssh-keys "$DROPLET_SSH_KEYS")
        fi

        doctl "${droplet_create_args[@]}" >/dev/null

        DROPLET_ID=$(get_droplet_id_by_name "$DROPLET_NAME")
        if [[ -z "$DROPLET_ID" ]]; then
            echo "Error: droplet '$DROPLET_NAME' was not found after creation" >&2
            exit 1
        fi

        echo "Droplet created with ID: $DROPLET_ID"
    fi

    wait_for_droplet_active "$DROPLET_ID"
    DROPLET_IP=$(get_droplet_ip "$DROPLET_ID")
    BENCHMARK_BASE_URL="http://${DROPLET_IP}:${DROPLET_PORT}"

    echo "Adding firewall rule for droplet: $DROPLET_ID"
    doctl databases firewalls append "$DB_ID" --rule "droplet:${DROPLET_ID}"
fi

echo ""
echo "Database connection details:"
echo "REDIS_USERNAME=$REDIS_USERNAME"
echo "REDIS_PASSWORD=$REDIS_PASSWORD"
echo "REDIS_HOST=$REDIS_HOST"
echo "REDIS_PORT=$REDIS_PORT"
echo "REDIS_DB=$REDIS_DB"
echo "REDIS_SSL=$REDIS_SSL"
echo "REDIS_URL=$REDIS_URL"

if [[ -n "$DROPLET_ID" ]]; then
    echo ""
    echo "Droplet details:"
    echo "DROPLET_ID=$DROPLET_ID"
    echo "DROPLET_NAME=$DROPLET_NAME"
    echo "DROPLET_IP=$DROPLET_IP"
    echo "BENCHMARK_BASE_URL=$BENCHMARK_BASE_URL"
    echo "Health check: ${BENCHMARK_BASE_URL}/health"
fi

if [[ "$UPDATE_ENV_FILE" == true ]]; then
    update_env_file "$ENV_FILE"
fi

echo ""
echo "Done."
