#!/usr/bin/env bash
set -Eeuo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ENV_FILE="${ROOT}/keys.env"
DEFAULT_WORKSPACE_ROOT="$(cd "${ROOT}/.." && pwd)"
HERMES_REPO="${HERMES_REPO:-${DEFAULT_WORKSPACE_ROOT}/hermes-agent}"
NEMO_RELAY_REPO="${NEMO_RELAY_REPO:-${DEFAULT_WORKSPACE_ROOT}/NeMo-Relay}"
PHOENIX_CONTAINER_NAME="${PHOENIX_CONTAINER_NAME:-nemo-relay-phoenix}"
PHOENIX_IMAGE="${PHOENIX_IMAGE:-arizephoenix/phoenix:latest}"
PHOENIX_UI_PORT="${PHOENIX_UI_PORT:-6006}"
PHOENIX_PROJECT_PREFIX="${PHOENIX_PROJECT_PREFIX:-nemo-relay-hermes-demo}"
DEFAULT_NVIDIA_MODEL_ID="aws/anthropic/bedrock-claude-sonnet-4-6"
NEMO_RELAY_SOURCE_PYTHON=""

default_hermes_bin() {
  local candidate
  for candidate in "${HERMES_REPO}/.venv/bin/hermes" "${HERMES_REPO}/venv/bin/hermes"; do
    if [[ -x "${candidate}" ]]; then
      printf '%s\n' "${candidate}"
      return
    fi
  done
  printf '%s\n' "${HERMES_REPO}/.venv/bin/hermes"
}

default_python_bin() {
  local candidate
  for candidate in "${HERMES_REPO}/.venv/bin/python" "${HERMES_REPO}/venv/bin/python"; do
    if [[ -x "${candidate}" ]]; then
      printf '%s\n' "${candidate}"
      return
    fi
  done
  printf '%s\n' "${HERMES_REPO}/.venv/bin/python"
}

resolve_tool_paths() {
  HERMES_REPO="${HERMES_REPO:-${DEFAULT_WORKSPACE_ROOT}/hermes-agent}"
  NEMO_RELAY_REPO="${NEMO_RELAY_REPO:-${DEFAULT_WORKSPACE_ROOT}/NeMo-Relay}"
  HERMES_BIN="${HERMES_BIN:-$(default_hermes_bin)}"
  PYTHON_BIN="${PYTHON_BIN:-$(default_python_bin)}"
}

usage() {
  local entrypoint
  entrypoint="./$(basename "$0")"
  cat <<USAGE
Usage:
  ${entrypoint} research        # run Tavily web-search demo on /v1/messages
  ${entrypoint}                 # run all three Hermes request-family lanes
  ${entrypoint} all             # same as default
  ${entrypoint} messages        # run /v1/messages
  ${entrypoint} chat            # run /v1/chat/completions
  ${entrypoint} responses       # run /v1/responses
  ${entrypoint} research-all    # run Tavily web-search demo on all three lanes

Setup:
  cp keys.env.example keys.env
  chmod 600 keys.env
  edit keys.env and set the API keys for the lanes you run

Outputs:
  outputs/<run-id>/<lane>/atof/events.jsonl
  outputs/<run-id>/<lane>/atif/*.json
  outputs/<run-id>/<lane>/nemo-relay/plugins.toml
  outputs/<run-id>/<lane>/hermes-home/config.yaml
  outputs/<run-id>/summary.txt
USAGE
}

load_env() {
  if [[ ! -f "${ENV_FILE}" ]]; then
    echo "ERROR: missing ${ENV_FILE}. Copy keys.env.example to keys.env first." >&2
    exit 1
  fi
  if [[ -L "${ENV_FILE}" ]]; then
    echo "ERROR: ${ENV_FILE} must not be a symlink" >&2
    exit 1
  fi
  chmod 600 "${ENV_FILE}" 2>/dev/null || true
  set -a
  # shellcheck disable=SC1090
  source "${ENV_FILE}"
  set +a
}

require_env_value() {
  local env_name="$1"
  local context="$2"
  local env_value

  if [[ ! "${env_name}" =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]]; then
    echo "ERROR: invalid API key variable '${env_name}' for ${context}" >&2
    exit 1
  fi
  env_value="${!env_name:-}"
  if [[ -z "${env_value}" ]]; then
    echo "ERROR: ${env_name} must be set in ${ENV_FILE} for ${context}" >&2
    exit 1
  fi
  if [[ "${env_value}" == replace-with-* ]]; then
    echo "ERROR: ${env_name} still has a placeholder value in ${ENV_FILE} for ${context}" >&2
    exit 1
  fi
}

require_config_value() {
  local value="$1"
  local label="$2"
  local context="$3"

  if [[ -z "${value}" || "${value}" == replace-with-* ]]; then
    echo "ERROR: ${label} must be configured for ${context}" >&2
    exit 1
  fi
}

require_tools() {
  local tool_mode="$1"

  command -v curl >/dev/null 2>&1 || {
    echo "ERROR: curl is required but was not found on PATH" >&2
    exit 1
  }
  [[ -x "${HERMES_BIN}" ]] || {
    echo "ERROR: Hermes binary not found or not executable: ${HERMES_BIN}" >&2
    exit 1
  }
  [[ -x "${PYTHON_BIN}" ]] || {
    echo "ERROR: Python binary not found or not executable: ${PYTHON_BIN}" >&2
    exit 1
  }
  resolve_nemo_relay_runtime
  if [[ "${tool_mode}" == "web" ]]; then
    require_env_value "TAVILY_API_KEY" "research mode"
  fi
}

resolve_nemo_relay_runtime() {
  if [[ -d "${NEMO_RELAY_REPO}/python/nemo_relay" ]]; then
    NEMO_RELAY_SOURCE_PYTHON="${NEMO_RELAY_REPO}/python"
    return
  fi

  if "${PYTHON_BIN}" -c 'import nemo_relay' >/dev/null 2>&1; then
    NEMO_RELAY_SOURCE_PYTHON=""
    return
  fi

  echo "ERROR: NeMo Relay is not available to Hermes." >&2
  echo "Install nemo-relay in the Hermes environment or set NEMO_RELAY_REPO to a source checkout." >&2
  exit 1
}

docker_bin() {
  if [[ -n "${DOCKER_BIN:-}" && -x "${DOCKER_BIN}" ]]; then
    printf '%s\n' "${DOCKER_BIN}"
    return
  fi
  command -v docker 2>/dev/null && return
  for candidate in \
    /usr/local/bin/docker \
    /opt/homebrew/bin/docker \
    /Applications/Docker.app/Contents/Resources/bin/docker
  do
    if [[ -x "${candidate}" ]]; then
      printf '%s\n' "${candidate}"
      return
    fi
  done
  return 1
}

wait_for_phoenix() {
  local graphql_url="http://127.0.0.1:${PHOENIX_UI_PORT}/graphql"
  local attempts=60

  while [[ "${attempts}" -gt 0 ]]; do
    if curl -fsS "${graphql_url}" \
      -H 'Content-Type: application/json' \
      --data-binary '{"query":"{ projects(first: 1) { edges { node { name } } } }"}' \
      >/dev/null 2>&1; then
      return
    fi
    sleep 2
    attempts=$((attempts - 1))
  done

  echo "ERROR: Phoenix did not become reachable at ${graphql_url}" >&2
  exit 1
}

ensure_phoenix() {
  local docker
  docker="$(docker_bin)" || {
    echo "ERROR: Docker CLI not found. Install Docker Desktop or set DOCKER_BIN." >&2
    exit 1
  }

  if ! "${docker}" info >/dev/null 2>&1; then
    if [[ -d /Applications/Docker.app ]]; then
      echo "[phoenix] starting Docker Desktop"
      open -a Docker >/dev/null 2>&1 || true
    fi
    wait_for_phoenix_docker "${docker}"
  fi

  if curl -fsS "http://127.0.0.1:${PHOENIX_UI_PORT}/graphql" \
    -H 'Content-Type: application/json' \
    --data-binary '{"query":"{ projects(first: 1) { edges { node { name } } } }"}' \
    >/dev/null 2>&1; then
    echo "[phoenix] reusing http://127.0.0.1:${PHOENIX_UI_PORT}"
    return
  fi

  if "${docker}" ps --format '{{.Names}}' | grep -qx "${PHOENIX_CONTAINER_NAME}"; then
    echo "[phoenix] waiting for existing ${PHOENIX_CONTAINER_NAME}"
  elif "${docker}" ps -a --format '{{.Names}}' | grep -qx "${PHOENIX_CONTAINER_NAME}"; then
    echo "[phoenix] starting existing ${PHOENIX_CONTAINER_NAME}"
    "${docker}" start "${PHOENIX_CONTAINER_NAME}" >/dev/null
  else
    echo "[phoenix] starting ${PHOENIX_CONTAINER_NAME} on http://127.0.0.1:${PHOENIX_UI_PORT}"
    "${docker}" run -d \
      --name "${PHOENIX_CONTAINER_NAME}" \
      --restart unless-stopped \
      -p "${PHOENIX_UI_PORT}:6006" \
      "${PHOENIX_IMAGE}" \
      >/dev/null
  fi

  wait_for_phoenix
}

wait_for_phoenix_docker() {
  local docker="$1"
  local attempts=45

  while [[ "${attempts}" -gt 0 ]]; do
    if "${docker}" info >/dev/null 2>&1; then
      return
    fi
    sleep 2
    attempts=$((attempts - 1))
  done

  echo "ERROR: Docker is installed but the Docker daemon is not reachable" >&2
  exit 1
}

lane_settings() {
  local lane="$1"
  REQUEST_FAMILY=""
  API_MODE=""
  BASE_URL=""
  MODEL_ID=""
  KEY_ENV=""
  PROVIDER=""
  PROVIDER_LABEL=""

  case "${lane}" in
    messages)
      REQUEST_FAMILY="/v1/messages"
      API_MODE="anthropic_messages"
      BASE_URL="${MESSAGES_BASE_URL:-${NVIDIA_MESSAGES_BASE_URL:-https://inference-api.nvidia.com}}"
      MODEL_ID="${MESSAGES_MODEL_ID:-${NVIDIA_MESSAGES_MODEL_ID:-${NVIDIA_MODEL_ID:-${DEFAULT_NVIDIA_MODEL_ID}}}}"
      KEY_ENV="${MESSAGES_API_KEY_ENV:-${HERMES_DEMO_API_KEY_ENV:-${HERMES_EVAL_API_KEY_ENV:-NVIDIA_API_KEY}}}"
      PROVIDER="${MESSAGES_PROVIDER:-hermes-demo-messages}"
      PROVIDER_LABEL="${MESSAGES_PROVIDER_LABEL:-Hermes demo Messages}"
      ;;
    chat)
      REQUEST_FAMILY="/v1/chat/completions"
      API_MODE="chat_completions"
      BASE_URL="${CHAT_BASE_URL:-${NVIDIA_CHAT_BASE_URL:-https://inference-api.nvidia.com/v1}}"
      MODEL_ID="${CHAT_MODEL_ID:-${NVIDIA_CHAT_MODEL_ID:-${NVIDIA_MODEL_ID:-${DEFAULT_NVIDIA_MODEL_ID}}}}"
      KEY_ENV="${CHAT_API_KEY_ENV:-${HERMES_DEMO_API_KEY_ENV:-${HERMES_EVAL_API_KEY_ENV:-NVIDIA_API_KEY}}}"
      PROVIDER="${CHAT_PROVIDER:-hermes-demo-chat}"
      PROVIDER_LABEL="${CHAT_PROVIDER_LABEL:-Hermes demo Chat Completions}"
      ;;
    responses)
      REQUEST_FAMILY="/v1/responses"
      API_MODE="codex_responses"
      BASE_URL="${RESPONSES_BASE_URL:-${NVIDIA_RESPONSES_BASE_URL:-https://inference-api.nvidia.com/v1}}"
      MODEL_ID="${RESPONSES_MODEL_ID:-${NVIDIA_RESPONSES_MODEL_ID:-${NVIDIA_MODEL_ID:-${DEFAULT_NVIDIA_MODEL_ID}}}}"
      KEY_ENV="${RESPONSES_API_KEY_ENV:-${HERMES_DEMO_API_KEY_ENV:-${HERMES_EVAL_API_KEY_ENV:-NVIDIA_API_KEY}}}"
      PROVIDER="${RESPONSES_PROVIDER:-hermes-demo-responses}"
      PROVIDER_LABEL="${RESPONSES_PROVIDER_LABEL:-Hermes demo Responses}"
      ;;
    *)
      echo "ERROR: unknown lane '${lane}'" >&2
      exit 1
      ;;
  esac

  BASE_URL="${BASE_URL%/}"
}

selected_lanes() {
  case "$1" in
    ""|all|research-all)
      printf '%s\n' messages chat responses
      ;;
    messages|chat|responses|research)
      [[ "$1" == "research" ]] && printf '%s\n' messages || printf '%s\n' "$1"
      ;;
    *)
      usage >&2
      exit 1
      ;;
  esac
}

preflight_lanes() {
  local command="$1"
  local lane

  while IFS= read -r lane; do
    lane_settings "${lane}"
    require_env_value "${KEY_ENV}" "${lane} lane"
    require_config_value "${MODEL_ID}" "model" "${lane} lane"
    require_config_value "${BASE_URL}" "base URL" "${lane} lane"
  done < <(selected_lanes "${command}")
}

write_hermes_config() {
  local config_path="$1"
  local tool_mode="$2"

  cat > "${config_path}" <<EOF
model:
  provider: ${PROVIDER}
  default: ${MODEL_ID}
  base_url: ${BASE_URL}
  api_mode: ${API_MODE}

providers:
  ${PROVIDER}:
    name: ${PROVIDER_LABEL}
    base_url: ${BASE_URL}
    key_env: ${KEY_ENV}
    api_mode: ${API_MODE}
    default_model: ${MODEL_ID}

plugins:
  enabled:
    - observability/nemo_relay

agent:
  max_turns: 4
EOF

  if [[ "${tool_mode}" == "web" ]]; then
    cat >> "${config_path}" <<'EOF'

web:
  backend: tavily
EOF
  fi
}

write_plugins_toml() {
  local path="$1"
  local atof_dir="$2"
  local atif_dir="$3"
  local project_name="$4"
  local phoenix_endpoint="http://127.0.0.1:${PHOENIX_UI_PORT}/v1/traces"

  cat > "${path}" <<EOF
version = 1

[[components]]
kind = "observability"
enabled = true

[components.config]
version = 1

[components.config.atof]
enabled = true
output_directory = "${atof_dir}"
filename = "events.jsonl"
mode = "overwrite"

[components.config.atif]
enabled = true
output_directory = "${atif_dir}"
filename_template = "trajectory-{session_id}.json"
agent_name = "Hermes Agent"
agent_version = "local"
model_name = "${MODEL_ID}"

[components.config.openinference]
enabled = true
transport = "http_binary"
endpoint = "${phoenix_endpoint}"
service_name = "hermes-nemo-relay-demo-${PROVIDER}"
instrumentation_scope = "hermes-nemo-relay-demo"

[components.config.openinference.resource_attributes]
"openinference.project.name" = "${project_name}"
"hermes.request_family" = "${REQUEST_FAMILY}"
"hermes.api_mode" = "${API_MODE}"
EOF
}

verify_artifacts() {
  local lane_dir="$1"
  local project_name="$2"
  local atof_file="${lane_dir}/atof/events.jsonl"
  local atif_dir="${lane_dir}/atif"

  [[ -s "${atof_file}" ]] || {
    echo "ERROR: missing or empty ATOF file: ${atof_file}" >&2
    exit 1
  }
  find "${atif_dir}" -name '*.json' -print -quit | grep -q . || {
    echo "ERROR: no ATIF trajectory JSON found under ${atif_dir}" >&2
    exit 1
  }

  "${PYTHON_BIN}" - "${atof_file}" <<'PY'
import json
import sys
from pathlib import Path

events = [
    json.loads(line)
    for line in Path(sys.argv[1]).read_text(encoding="utf-8").splitlines()
    if line.strip()
]

def event_category(event):
    return str(event.get("category") or event.get("scope_type") or "").lower()

def event_phase(event):
    return str(event.get("scope_category") or event.get("phase") or "").lower()

required = {
    ("llm", "start"),
    ("llm", "end"),
    ("tool", "start"),
    ("tool", "end"),
}
observed = {(event_category(event), event_phase(event)) for event in events}
missing = sorted(required - observed)
if missing:
    raise SystemExit(f"ERROR: ATOF missing expected lifecycle events: {missing}")
PY

  verify_phoenix_project "${lane_dir}" "${project_name}"
}

verify_phoenix_project() {
  local lane_dir="$1"
  local project_name="$2"
  local response_path="${lane_dir}/logs/phoenix-projects.json"
  local graphql_url="http://127.0.0.1:${PHOENIX_UI_PORT}/graphql"
  local attempts=20

  while [[ "${attempts}" -gt 0 ]]; do
    if curl -fsS "${graphql_url}" \
      -H 'Content-Type: application/json' \
      --data-binary '{"query":"{ projects(first: 1000) { edges { node { name traceCount } } } }"}' \
      > "${response_path}" \
      && "${PYTHON_BIN}" - "${response_path}" "${project_name}" <<'PY'
import json
import sys
from pathlib import Path

payload = json.loads(Path(sys.argv[1]).read_text(encoding="utf-8"))
project_name = sys.argv[2]
for edge in payload.get("data", {}).get("projects", {}).get("edges", []):
    project = edge.get("node", {})
    if project.get("name") == project_name and int(project.get("traceCount") or 0) > 0:
        print(f"phoenix_project={project_name}")
        print(f"phoenix_trace_count={project.get('traceCount')}")
        raise SystemExit(0)
raise SystemExit(1)
PY
    then
      return
    fi
    sleep 2
    attempts=$((attempts - 1))
  done

  echo "ERROR: Phoenix did not show traces for project ${project_name}" >&2
  exit 1
}

run_lane() {
  local run_dir="$1"
  local run_id="$2"
  local lane="$3"
  local tool_mode="$4"

  lane_settings "${lane}"
  require_env_value "${KEY_ENV}" "${lane} lane"

  local lane_dir="${run_dir}/${lane}"
  local hermes_home="${lane_dir}/hermes-home"
  local atof_dir="${lane_dir}/atof"
  local atif_dir="${lane_dir}/atif"
  local relay_dir="${lane_dir}/nemo-relay"
  local log_dir="${lane_dir}/logs"
  local project_name="${PHOENIX_PROJECT_PREFIX}-${run_id}-${lane}"
  local prompt toolsets pythonpath

  mkdir -p "${hermes_home}" "${atof_dir}" "${atif_dir}" "${relay_dir}" "${log_dir}"
  write_hermes_config "${hermes_home}/config.yaml" "${tool_mode}"
  write_plugins_toml "${relay_dir}/plugins.toml" "${atof_dir}" "${atif_dir}" "${project_name}"

  if [[ "${tool_mode}" == "web" ]]; then
    toolsets="web"
    prompt="Research three real AI, ML, or developer infrastructure conferences scheduled in 2026. Use web_search and prefer official event pages. Reply with a markdown table with columns Conference, Dates, Location, Official URL. Include exactly three rows."
  else
    toolsets="terminal"
    prompt="Use the terminal tool exactly once to run printf relay_hermes_${lane}_ok. Then reply with exactly the command output and nothing else."
  fi

  pythonpath="${PYTHONPATH:-}"
  if [[ -n "${NEMO_RELAY_SOURCE_PYTHON}" ]]; then
    pythonpath="${NEMO_RELAY_SOURCE_PYTHON}:${pythonpath}"
  fi

  echo
  echo "[demo:${lane}] ${REQUEST_FAMILY} via ${API_MODE}"
  HERMES_HOME="${hermes_home}" \
    HERMES_NEMO_RELAY_PLUGINS_TOML="${relay_dir}/plugins.toml" \
    PYTHONPATH="${pythonpath}" \
    TAVILY_API_KEY="${TAVILY_API_KEY:-}" \
    "${HERMES_BIN}" chat \
      --query "${prompt}" \
      --provider "${PROVIDER}" \
      --model "${MODEL_ID}" \
      --toolsets "${toolsets}" \
      --max-turns 4 \
      --quiet \
      --accept-hooks \
      > >(tee "${log_dir}/hermes.stdout") \
      2> >(tee "${log_dir}/hermes.stderr" >&2)

  verify_artifacts "${lane_dir}" "${project_name}"

  {
    echo "lane=${lane}"
    echo "request_family=${REQUEST_FAMILY}"
    echo "api_mode=${API_MODE}"
    echo "model=${MODEL_ID}"
    echo "atof=${atof_dir}/events.jsonl"
    echo "atif=${atif_dir}"
    echo "plugins_toml=${relay_dir}/plugins.toml"
    echo "phoenix_url=http://127.0.0.1:${PHOENIX_UI_PORT}/projects"
    echo "phoenix_project=${project_name}"
  } | tee "${lane_dir}/summary.txt"
}

main() {
  local command="${1:-}"
  local tool_mode="terminal"
  if [[ "$#" -gt 1 ]]; then
    usage >&2
    exit 1
  fi
  case "${command}" in
    -h|--help|help)
      usage
      return
      ;;
    ""|all|messages|chat|responses)
      ;;
    research|research-all)
      tool_mode="web"
      ;;
    *)
      usage >&2
      exit 1
      ;;
  esac

  load_env
  resolve_tool_paths
  require_tools "${tool_mode}"
  preflight_lanes "${command}"
  ensure_phoenix

  local run_id run_dir lane
  run_id="$(date -u '+%Y%m%dT%H%M%SZ')-$$"
  run_dir="${ROOT}/outputs/${run_id}"
  mkdir -p "${run_dir}"

  while IFS= read -r lane; do
    run_lane "${run_dir}" "${run_id}" "${lane}" "${tool_mode}"
  done < <(selected_lanes "${command}")

  {
    echo "run_dir=${run_dir}"
    echo "phoenix_url=http://127.0.0.1:${PHOENIX_UI_PORT}/projects"
    echo
    find "${run_dir}" -mindepth 2 -maxdepth 2 -name summary.txt -print
  } | tee "${run_dir}/summary.txt"

  echo
  echo "Demo complete."
  echo "Open Phoenix: http://127.0.0.1:${PHOENIX_UI_PORT}/projects"
  echo "Run outputs: ${run_dir}"
}

main "$@"
