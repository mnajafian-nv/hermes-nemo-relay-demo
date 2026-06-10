#!/usr/bin/env bash
set -Eeuo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ENV_FILE="${ROOT}/keys.env"
WORKSPACE_ROOT="$(cd "${ROOT}/.." && pwd)"
HERMES_REPO="${HERMES_REPO:-${WORKSPACE_ROOT}/hermes-agent}"
PHOENIX_UI_PORT="${PHOENIX_UI_PORT:-6006}"
PHOENIX_CONTAINER_NAME="nemo-relay-phoenix"
PHOENIX_IMAGE="arizephoenix/phoenix:latest"

DEFAULT_NVIDIA_MODEL_ID="aws/anthropic/bedrock-claude-sonnet-4-6"
DEFAULT_ANTHROPIC_MODEL_ID="claude-sonnet-4-6"
DEFAULT_OPENAI_MODEL_ID="gpt-4.1"

die() {
  echo "ERROR: $*" >&2
  exit 1
}

usage() {
  cat <<'USAGE'
Usage:
  ./run.sh            Run the best visual demo for the selected provider
  ./run.sh all        Run every supported lane for the selected provider
  ./run.sh messages   Run /v1/messages
  ./run.sh chat       Run /v1/chat/completions
  ./run.sh responses  Run /v1/responses

Setup:
  cp keys.env.example keys.env
  chmod 600 keys.env
  edit keys.env, pick HERMES_DEMO_PROVIDER, and set that provider key

Providers:
  nvidia      supports messages, chat, responses
  anthropic   supports messages
  openai      supports chat, responses

Output:
  outputs/<run-id>/<lane>/
USAGE
}

load_env() {
  [[ -f "${ENV_FILE}" ]] || die "missing ${ENV_FILE}. Copy keys.env.example to keys.env first."
  [[ ! -L "${ENV_FILE}" ]] || die "${ENV_FILE} must not be a symlink"
  chmod 600 "${ENV_FILE}" 2>/dev/null || true

  set -a
  # shellcheck disable=SC1090
  source "${ENV_FILE}"
  set +a
}

provider() {
  case "${HERMES_DEMO_PROVIDER:-nvidia}" in
    nvidia|NVIDIA)
      echo "nvidia"
      ;;
    anthropic|ANTHROPIC)
      echo "anthropic"
      ;;
    openai|OPENAI)
      echo "openai"
      ;;
    *)
      die "HERMES_DEMO_PROVIDER must be one of: nvidia, anthropic, openai"
      ;;
  esac
}

require_env() {
  local name="$1"
  local value="${!name:-}"

  [[ -n "${value}" ]] || die "${name} must be set in keys.env"
  [[ "${value}" != replace-with-* ]] || die "${name} still has a placeholder value in keys.env"
}

hermes_bin() {
  for candidate in "${HERMES_REPO}/.venv/bin/hermes" "${HERMES_REPO}/venv/bin/hermes"; do
    if [[ -x "${candidate}" ]]; then
      echo "${candidate}"
      return
    fi
  done
  die "Hermes binary not found. Expected ${HERMES_REPO}/venv/bin/hermes or ${HERMES_REPO}/.venv/bin/hermes"
}

python_bin() {
  for candidate in "${HERMES_REPO}/.venv/bin/python" "${HERMES_REPO}/venv/bin/python"; do
    if [[ -x "${candidate}" ]]; then
      echo "${candidate}"
      return
    fi
  done
  die "Python binary not found. Expected ${HERMES_REPO}/venv/bin/python or ${HERMES_REPO}/.venv/bin/python"
}

check_prereqs() {
  HERMES_BIN="$(hermes_bin)"
  PYTHON_BIN="$(python_bin)"

  command -v curl >/dev/null 2>&1 || die "curl is required"
  command -v docker >/dev/null 2>&1 || die "Docker CLI is required"
  docker info >/dev/null 2>&1 || die "Docker is not running. Start Docker Desktop and rerun the demo."
  "${PYTHON_BIN}" -c 'import nemo_relay' >/dev/null 2>&1 || die "nemo-relay is not installed in the Hermes environment"
  require_env "TAVILY_API_KEY"
}

supported_lanes() {
  case "$(provider)" in
    nvidia)
      printf '%s\n' messages chat responses
      ;;
    anthropic)
      printf '%s\n' messages
      ;;
    openai)
      printf '%s\n' chat responses
      ;;
  esac
}

default_lane() {
  case "$(provider)" in
    nvidia|anthropic)
      echo "messages"
      ;;
    openai)
      echo "responses"
      ;;
  esac
}

lane_is_supported() {
  local lane="$1"
  while IFS= read -r supported; do
    [[ "${lane}" == "${supported}" ]] && return 0
  done < <(supported_lanes)
  return 1
}

selected_lanes() {
  local command="$1"

  case "${command}" in
    "")
      default_lane
      ;;
    all)
      supported_lanes
      ;;
    messages|chat|responses)
      lane_is_supported "${command}" || die "$(provider) does not support the ${command} lane in this demo"
      echo "${command}"
      ;;
    -h|--help|help)
      usage
      exit 0
      ;;
    *)
      usage >&2
      exit 1
      ;;
  esac
}

validate_command() {
  local command="$1"

  case "${command}" in
    ""|all)
      return
      ;;
    messages|chat|responses)
      lane_is_supported "${command}" || die "$(provider) does not support the ${command} lane in this demo"
      ;;
    *)
      usage >&2
      exit 1
      ;;
  esac
}

lane_config() {
  local lane="$1"
  local selected_provider
  selected_provider="$(provider)"

  REQUEST_FAMILY=""
  API_MODE=""
  BASE_URL=""
  MODEL_ID=""
  KEY_ENV=""
  PROVIDER_NAME="${selected_provider}"

  case "${selected_provider}:${lane}" in
    nvidia:messages)
      REQUEST_FAMILY="/v1/messages"
      API_MODE="anthropic_messages"
      BASE_URL="https://inference-api.nvidia.com"
      MODEL_ID="${NVIDIA_MODEL_ID:-${DEFAULT_NVIDIA_MODEL_ID}}"
      KEY_ENV="NVIDIA_API_KEY"
      ;;
    nvidia:chat)
      REQUEST_FAMILY="/v1/chat/completions"
      API_MODE="chat_completions"
      BASE_URL="https://inference-api.nvidia.com/v1"
      MODEL_ID="${NVIDIA_MODEL_ID:-${DEFAULT_NVIDIA_MODEL_ID}}"
      KEY_ENV="NVIDIA_API_KEY"
      ;;
    nvidia:responses)
      REQUEST_FAMILY="/v1/responses"
      API_MODE="codex_responses"
      BASE_URL="https://inference-api.nvidia.com/v1"
      MODEL_ID="${NVIDIA_MODEL_ID:-${DEFAULT_NVIDIA_MODEL_ID}}"
      KEY_ENV="NVIDIA_API_KEY"
      ;;
    anthropic:messages)
      REQUEST_FAMILY="/v1/messages"
      API_MODE="anthropic_messages"
      BASE_URL="https://api.anthropic.com"
      MODEL_ID="${ANTHROPIC_MODEL_ID:-${DEFAULT_ANTHROPIC_MODEL_ID}}"
      KEY_ENV="ANTHROPIC_API_KEY"
      ;;
    openai:chat)
      REQUEST_FAMILY="/v1/chat/completions"
      API_MODE="chat_completions"
      BASE_URL="https://api.openai.com/v1"
      MODEL_ID="${OPENAI_MODEL_ID:-${DEFAULT_OPENAI_MODEL_ID}}"
      KEY_ENV="OPENAI_API_KEY"
      ;;
    openai:responses)
      REQUEST_FAMILY="/v1/responses"
      API_MODE="codex_responses"
      BASE_URL="https://api.openai.com/v1"
      MODEL_ID="${OPENAI_MODEL_ID:-${DEFAULT_OPENAI_MODEL_ID}}"
      KEY_ENV="OPENAI_API_KEY"
      ;;
    *)
      die "${selected_provider} does not support the ${lane} lane in this demo"
      ;;
  esac

  require_env "${KEY_ENV}"
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

  die "Phoenix did not become reachable at ${graphql_url}"
}

ensure_phoenix() {
  if curl -fsS "http://127.0.0.1:${PHOENIX_UI_PORT}/graphql" \
    -H 'Content-Type: application/json' \
    --data-binary '{"query":"{ projects(first: 1) { edges { node { name } } } }"}' \
    >/dev/null 2>&1; then
    echo "[phoenix] reusing http://127.0.0.1:${PHOENIX_UI_PORT}"
    return
  fi

  if docker ps -a --format '{{.Names}}' | grep -qx "${PHOENIX_CONTAINER_NAME}"; then
    echo "[phoenix] starting existing ${PHOENIX_CONTAINER_NAME}"
    docker start "${PHOENIX_CONTAINER_NAME}" >/dev/null
  else
    echo "[phoenix] starting ${PHOENIX_CONTAINER_NAME} on http://127.0.0.1:${PHOENIX_UI_PORT}"
    docker run -d \
      --name "${PHOENIX_CONTAINER_NAME}" \
      --restart unless-stopped \
      -p "${PHOENIX_UI_PORT}:6006" \
      "${PHOENIX_IMAGE}" \
      >/dev/null
  fi

  wait_for_phoenix
}

write_hermes_config() {
  local path="$1"

  cat > "${path}" <<EOF
model:
  provider: "${PROVIDER_NAME}"
  default: "${MODEL_ID}"
  base_url: "${BASE_URL}"
  api_mode: "${API_MODE}"

providers:
  ${PROVIDER_NAME}:
    name: "Hermes NeMo Relay demo"
    base_url: "${BASE_URL}"
    key_env: "${KEY_ENV}"
    api_mode: "${API_MODE}"
    default_model: "${MODEL_ID}"

plugins:
  enabled:
    - observability/nemo_relay

agent:
  max_turns: 6

web:
  backend: tavily
EOF
}

write_plugins_toml() {
  local path="$1"
  local atof_dir="$2"
  local atif_dir="$3"
  local project_name="$4"

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
endpoint = "http://127.0.0.1:${PHOENIX_UI_PORT}/v1/traces"
service_name = "hermes-nemo-relay-demo-${PROVIDER_NAME}"
instrumentation_scope = "hermes-nemo-relay-demo"

[components.config.openinference.resource_attributes]
"openinference.project.name" = "${project_name}"
"hermes.request_family" = "${REQUEST_FAMILY}"
"hermes.api_mode" = "${API_MODE}"
EOF
}

verify_outputs() {
  local lane_dir="$1"
  local project_name="$2"
  local atof_file="${lane_dir}/atof/events.jsonl"
  local atif_dir="${lane_dir}/atif"
  local response_path="${lane_dir}/logs/phoenix-projects.json"
  local graphql_url="http://127.0.0.1:${PHOENIX_UI_PORT}/graphql"
  local attempts=20

  [[ -s "${atof_file}" ]] || die "ATOF file was not written: ${atof_file}"
  find "${atif_dir}" -name '*.json' -print -quit | grep -q . || die "ATIF trajectory was not written under ${atif_dir}"

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
        raise SystemExit(0)
raise SystemExit(f"Phoenix project has no traces yet: {project_name}")
PY
    then
      return
    fi
    sleep 2
    attempts=$((attempts - 1))
  done

  die "Phoenix did not show traces for project ${project_name}"
}

run_lane() {
  local run_dir="$1"
  local run_id="$2"
  local lane="$3"
  local lane_dir="${run_dir}/${lane}"
  local hermes_home="${lane_dir}/hermes-home"
  local atof_dir="${lane_dir}/atof"
  local atif_dir="${lane_dir}/atif"
  local relay_dir="${lane_dir}/nemo-relay"
  local log_dir="${lane_dir}/logs"
  local project_name="nemo-relay-hermes-demo-${run_id}-${lane}"
  local prompt

  lane_config "${lane}"
  mkdir -p "${hermes_home}" "${atof_dir}" "${atif_dir}" "${relay_dir}" "${log_dir}"
  write_hermes_config "${hermes_home}/config.yaml"
  write_plugins_toml "${relay_dir}/plugins.toml" "${atof_dir}" "${atif_dir}" "${project_name}"

  prompt="Research three real AI, ML, or developer infrastructure conferences scheduled in 2026. Use web_search and prefer official event pages. Reply with a markdown table with columns Conference, Dates, Location, Official URL. Include exactly three rows."

  echo
  echo "[demo:${lane}] ${PROVIDER_NAME} ${REQUEST_FAMILY} (${API_MODE})"
  HERMES_HOME="${hermes_home}" \
    HERMES_NEMO_RELAY_PLUGINS_TOML="${relay_dir}/plugins.toml" \
    "${HERMES_BIN}" chat \
      --query "${prompt}" \
      --provider "${PROVIDER_NAME}" \
      --model "${MODEL_ID}" \
      --toolsets web \
      --max-turns 6 \
      --quiet \
      --accept-hooks \
      2>&1 | tee "${log_dir}/hermes.log"

  verify_outputs "${lane_dir}" "${project_name}"

  cat > "${lane_dir}/summary.txt" <<EOF
lane=${lane}
provider=${PROVIDER_NAME}
request_family=${REQUEST_FAMILY}
api_mode=${API_MODE}
model=${MODEL_ID}
phoenix_url=http://127.0.0.1:${PHOENIX_UI_PORT}/projects
phoenix_project=${project_name}
atof=${atof_dir}/events.jsonl
atif=${atif_dir}
EOF

  echo "[demo:${lane}] Phoenix project: ${project_name}"
}

main() {
  local command="${1:-}"
  local run_id run_dir lane

  [[ "$#" -le 1 ]] || {
    usage >&2
    exit 1
  }

  case "${command}" in
    -h|--help|help)
      usage
      exit 0
      ;;
  esac

  load_env
  validate_command "${command}"
  check_prereqs
  ensure_phoenix

  run_id="$(date -u '+%Y%m%dT%H%M%SZ')-$$"
  run_dir="${ROOT}/outputs/${run_id}"
  mkdir -p "${run_dir}"

  while IFS= read -r lane; do
    run_lane "${run_dir}" "${run_id}" "${lane}"
  done < <(selected_lanes "${command}")

  echo
  echo "Demo complete."
  echo "Open Phoenix: http://127.0.0.1:${PHOENIX_UI_PORT}/projects"
  echo "Run outputs: ${run_dir}"
}

main "$@"
