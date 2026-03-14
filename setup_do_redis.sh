#!/usr/bin/env bash

set -euo pipefail

usage() {
    cat <<'EOF'
Usage:
  ./setup_do_redis.sh --name NAME [options]

Creates a DigitalOcean Valkey/Redis database, waits for it to become online,
optionally updates firewall rules, writes connection details to an env file,
and can provision an App Platform function backed by a GitHub repo.

Options:
  --name NAME                 Database name. Required.
  --region REGION             Database region. Default: fra1
  --size SIZE                 Database size slug. Default: db-s-1vcpu-1gb
  --nodes COUNT               Number of DB nodes. Default: 1
  --engine ENGINE             Database engine. Default: valkey
  --env-file PATH             Read token from and write outputs to this env file. Default: .env
  --skip-env-update           Do not write Redis/App outputs to the env file.
  --skip-ip-firewall          Do not add the current public IP to the DB firewall.
  --app-id ID                 Add an existing App Platform app as a DB trusted source.
  --eviction-policy POLICY    Eviction policy to apply. Default: noeviction
  --poll-interval SECONDS     Wait time between status checks. Default: 15
  --timeout SECONDS           Max wait time for DB or app readiness. Default: 1800
  --reuse-existing            Reuse an existing DB with the same name instead of failing.

App Function options:
  --create-app-function       Create or update an App Platform function app.
  --function-app-name NAME    App Platform app name. Default: <db-name>-fn
  --function-repo REPO        Repo in owner/name format. Default: k00baPriv/redistest
  --function-git-url URL      Public git clone URL. Default: https://github.com/k00baPriv/redistest.git
  --function-branch BRANCH    Git branch to deploy. Default: master
  --function-source-dir DIR   Function source dir in repo. Default: do_functions
  --function-route PATH       Route prefix. Default: /api
  --reuse-existing-app        Reuse an existing App Platform app with the same name.
  --recreate-existing-app     Delete and recreate an existing App Platform app with the same name.

  --help                      Show this help.

Environment:
  DIGITALOCEAN_TOKEN          Accepted for API calls and mapped to doctl auth.
  DIGITALOCEAN_ACCESS_TOKEN   Accepted for doctl and API calls.

Examples:
  ./setup_do_redis.sh --name my-redis
  ./setup_do_redis.sh --name my-redis --reuse-existing --create-app-function
  ./setup_do_redis.sh --name my-redis --create-app-function --function-git-url https://github.com/k00baPriv/redistest.git
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

quote_for_yaml() {
    python3 -c 'import json, sys; print(json.dumps(sys.argv[1]))' "$1"
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

app_platform_region_from_db_region() {
    python3 -c 'import re, sys; print(re.sub(r"\d+$", "", sys.argv[1]))' "$1"
}

get_app_id_by_name() {
    local app_name=$1
    doctl apps list --output json | python3 -c '
import json, sys
apps = json.load(sys.stdin)
name = sys.argv[1]
for app in apps:
    spec = app.get("spec") or {}
    if spec.get("name") == name:
        print(app.get("id", ""))
        break
' "$app_name"
}

get_app_default_ingress() {
    local app_id=$1
    doctl apps get "$app_id" --output json | python3 -c '
import json, sys
app = json.load(sys.stdin)[0]
print(app.get("default_ingress", ""))
'
}

delete_app_and_wait() {
    local app_id=$1
    local started_at
    started_at=$(date +%s)

    echo "Deleting existing app: $app_id"
    doctl apps delete "$app_id" --force >/dev/null

    while true; do
        if [[ -z "$(doctl apps list --output json | python3 -c '
import json, sys
target = sys.argv[1]
apps = json.load(sys.stdin)
for app in apps:
    if app.get("id") == target:
        print(target)
        break
' "$app_id")" ]]; then
            return 0
        fi

        if (( "$(date +%s)" - started_at >= TIMEOUT_SECONDS )); then
            echo "Error: timed out waiting for app $app_id to be deleted" >&2
            exit 1
        fi

        sleep "$POLL_INTERVAL"
    done
}

get_app_phase() {
    local app_id=$1
    doctl apps get "$app_id" --output json | python3 -c '
import json, sys
app = json.load(sys.stdin)[0]
active = app.get("active_deployment") or {}
print(active.get("phase", ""))
'
}

wait_for_app_ready() {
    local app_id=$1
    local started_at
    started_at=$(date +%s)

    echo "Waiting for app deployment to become active..."

    while true; do
        local phase
        phase=$(get_app_phase "$app_id")
        echo "App deployment phase: ${phase:-unknown}"

        if [[ "$phase" == "ACTIVE" ]]; then
            return 0
        fi

        if [[ "$phase" == "ERROR" || "$phase" == "FAILED" || "$phase" == "CANCELED" ]]; then
            echo "Error: app deployment finished in phase '$phase'" >&2
            exit 1
        fi

        if (( "$(date +%s)" - started_at >= TIMEOUT_SECONDS )); then
            echo "Error: timed out waiting for app $app_id to become active" >&2
            exit 1
        fi

        sleep "$POLL_INTERVAL"
    done
}

set_eviction_policy() {
    local db_id=$1
    local policy=$2
    echo "Setting eviction policy to: $policy"
    api_request PUT \
        "https://api.digitalocean.com/v2/databases/${db_id}/eviction_policy" \
        "{\"eviction_policy\":\"${policy}\"}" >/dev/null
}

add_current_ip_firewall() {
    echo "Getting current public IP..."
    local current_ip
    current_ip=$(curl -fsS ifconfig.me)
    echo "Adding firewall rule for IP: $current_ip"
    doctl databases firewalls append "$DB_ID" --rule "ip_addr:${current_ip}"
}

create_app_spec() {
    APP_SPEC_FILE=$(mktemp "${TMPDIR:-/tmp}/app-spec.XXXXXX")

    local app_region
    app_region=$(app_platform_region_from_db_region "$REGION")
    local q_app_name q_git_url q_branch q_source_dir q_route q_redis_url
    q_app_name=$(quote_for_yaml "$FUNCTION_APP_NAME")
    q_git_url=$(quote_for_yaml "$FUNCTION_GIT_URL")
    q_branch=$(quote_for_yaml "$FUNCTION_BRANCH")
    q_source_dir=$(quote_for_yaml "$FUNCTION_SOURCE_DIR")
    q_route=$(quote_for_yaml "$FUNCTION_ROUTE")
    q_redis_url=$(quote_for_yaml "$REDIS_URL")

    cat > "$APP_SPEC_FILE" <<EOF
name: ${q_app_name}
region: ${app_region}
functions:
  - name: redis-bench
    git:
      repo_clone_url: ${q_git_url}
      branch: ${q_branch}
    source_dir: ${q_source_dir}
    routes:
      - path: ${q_route}
    envs:
      - key: REDIS_URL
        scope: RUN_TIME
        type: SECRET
        value: ${q_redis_url}
EOF
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
            !/^FUNCTION_APP_ID=/ &&
            !/^FUNCTION_APP_NAME=/ &&
            !/^FUNCTION_BASE_URL=/ &&
            !/^FUNCTION_ENDPOINT=/
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

        if [[ -n "$FUNCTION_APP_ID" ]]; then
            echo ""
            echo "# App Platform Function"
            echo "FUNCTION_APP_ID=$(quote_for_shell "$FUNCTION_APP_ID")"
            echo "FUNCTION_APP_NAME=$(quote_for_shell "$FUNCTION_APP_NAME")"
            echo "FUNCTION_BASE_URL=$(quote_for_shell "$FUNCTION_BASE_URL")"
            echo "FUNCTION_ENDPOINT=$(quote_for_shell "$FUNCTION_ENDPOINT")"
        fi
    } >> "$tmp_file"

    mv "$tmp_file" "$env_file"
    echo "Updated env file: $env_file"
}

cleanup() {
    if [[ -n "${APP_SPEC_FILE:-}" && -f "${APP_SPEC_FILE:-}" ]]; then
        rm -f "$APP_SPEC_FILE"
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
CREATE_APP_FUNCTION=false
FUNCTION_APP_NAME=""
FUNCTION_REPO="k00baPriv/redistest"
FUNCTION_GIT_URL="https://github.com/k00baPriv/redistest.git"
FUNCTION_BRANCH="master"
FUNCTION_SOURCE_DIR="do_functions"
FUNCTION_ROUTE="/api"
REUSE_EXISTING_APP=false
RECREATE_EXISTING_APP=false
FUNCTION_APP_ID=""
FUNCTION_BASE_URL=""
FUNCTION_ENDPOINT=""
APP_SPEC_FILE=""
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
        --create-app-function)
            CREATE_APP_FUNCTION=true
            shift
            ;;
        --function-app-name)
            FUNCTION_APP_NAME=${2:-}
            shift 2
            ;;
        --function-repo)
            FUNCTION_REPO=${2:-}
            FUNCTION_GIT_URL="https://github.com/${FUNCTION_REPO}.git"
            shift 2
            ;;
        --function-git-url)
            FUNCTION_GIT_URL=${2:-}
            shift 2
            ;;
        --function-branch)
            FUNCTION_BRANCH=${2:-}
            shift 2
            ;;
        --function-source-dir)
            FUNCTION_SOURCE_DIR=${2:-}
            shift 2
            ;;
        --function-route)
            FUNCTION_ROUTE=${2:-}
            shift 2
            ;;
        --reuse-existing-app)
            REUSE_EXISTING_APP=true
            shift
            ;;
        --recreate-existing-app)
            RECREATE_EXISTING_APP=true
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

if [[ -z "$FUNCTION_APP_NAME" ]]; then
    FUNCTION_APP_NAME="${DB_NAME}-fn"
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

REDIS_URL=$(get_db_uri "$DB_ID")
parse_uri "$REDIS_URL"

if [[ -n "$APP_ID" ]]; then
    echo "Adding firewall rule for existing app: $APP_ID"
    doctl databases firewalls append "$DB_ID" --rule "app:${APP_ID}"
fi

if [[ "$CREATE_APP_FUNCTION" == true ]]; then
    LOCAL_BRANCH=$(git branch --show-current 2>/dev/null || true)
    if [[ -n "$LOCAL_BRANCH" && "$LOCAL_BRANCH" != "$FUNCTION_BRANCH" ]]; then
        echo "Warning: local branch is '$LOCAL_BRANCH' but function deploy branch is '$FUNCTION_BRANCH'." >&2
    fi

    if [[ -n "$(git status --short -- do_functions 2>/dev/null)" ]]; then
        echo "Warning: local changes under do_functions are not pushed yet." >&2
        echo "App Platform deploys from GitHub, so push them before expecting the function build to succeed." >&2
    fi

    EXISTING_APP_ID=$(get_app_id_by_name "$FUNCTION_APP_NAME" || true)
    create_app_spec

    if [[ -n "$EXISTING_APP_ID" ]]; then
        if [[ "$RECREATE_EXISTING_APP" == true ]]; then
            delete_app_and_wait "$EXISTING_APP_ID"
            echo "Creating App Platform function app '$FUNCTION_APP_NAME'..."
            doctl apps create --spec "$APP_SPEC_FILE" >/dev/null
            FUNCTION_APP_ID=$(get_app_id_by_name "$FUNCTION_APP_NAME")
            if [[ -z "$FUNCTION_APP_ID" ]]; then
                echo "Error: app '$FUNCTION_APP_NAME' was not found after recreation" >&2
                exit 1
            fi
        elif [[ "$REUSE_EXISTING_APP" == true ]]; then
            FUNCTION_APP_ID=$EXISTING_APP_ID
            echo "Updating existing app: $FUNCTION_APP_NAME ($FUNCTION_APP_ID)"
            doctl apps update "$FUNCTION_APP_ID" --spec "$APP_SPEC_FILE" >/dev/null
        else
            echo "Error: app already exists with name '$FUNCTION_APP_NAME' (ID: $EXISTING_APP_ID)" >&2
            echo "Use --reuse-existing-app to update it or --recreate-existing-app to delete and recreate it." >&2
            exit 1
        fi
    else
        echo "Creating App Platform function app '$FUNCTION_APP_NAME'..."
        doctl apps create --spec "$APP_SPEC_FILE" >/dev/null
        FUNCTION_APP_ID=$(get_app_id_by_name "$FUNCTION_APP_NAME")
        if [[ -z "$FUNCTION_APP_ID" ]]; then
            echo "Error: app '$FUNCTION_APP_NAME' was not found after creation" >&2
            exit 1
        fi
    fi

    wait_for_app_ready "$FUNCTION_APP_ID"
    FUNCTION_BASE_URL=$(get_app_default_ingress "$FUNCTION_APP_ID")
    FUNCTION_ENDPOINT="${FUNCTION_BASE_URL}${FUNCTION_ROUTE}/bench/redis-bench"

    echo "Adding firewall rule for app: $FUNCTION_APP_ID"
    doctl databases firewalls append "$DB_ID" --rule "app:${FUNCTION_APP_ID}"
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

if [[ -n "$FUNCTION_APP_ID" ]]; then
    echo ""
    echo "Function app details:"
    echo "FUNCTION_APP_ID=$FUNCTION_APP_ID"
    echo "FUNCTION_APP_NAME=$FUNCTION_APP_NAME"
    echo "FUNCTION_BASE_URL=$FUNCTION_BASE_URL"
    echo "FUNCTION_ENDPOINT=$FUNCTION_ENDPOINT"
    echo "Health check: ${FUNCTION_ENDPOINT}/health"
fi

if [[ "$UPDATE_ENV_FILE" == true ]]; then
    update_env_file "$ENV_FILE"
fi

echo ""
echo "Done."
