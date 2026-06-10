# Hermes Agent Observability with NeMo Relay

Run Hermes Agent with the built-in NeMo Relay plugin and inspect ATOF, ATIF,
and OpenInference traces in Phoenix.

This demo keeps Hermes in control of the agent loop, model provider setup,
tools, and CLI UX. NeMo Relay observes the LLM and tool boundaries through the
canonical `plugins.toml` path.

`run.sh` creates an isolated Hermes home for each run, enables the bundled
`observability/nemo_relay` plugin in that generated config, writes a NeMo Relay
`plugins.toml`, and points Hermes at it with `HERMES_NEMO_RELAY_PLUGINS_TOML`.
You do not need to modify your normal `~/.hermes` config or run
`hermes plugins enable` for this demo.

## Quickstart

This demo expects a local Hermes Agent checkout. NeMo Relay can come from either
a local source checkout or an installed `nemo-relay` Python package in the
Hermes environment. The Hermes checkout must include the bundled
`observability/nemo_relay` plugin. If you already have that setup, skip to the
demo setup below.

Create the sibling checkout layout:

```bash
mkdir -p hermes-nemo-relay-workspace
cd hermes-nemo-relay-workspace

git clone https://github.com/NousResearch/hermes-agent.git
git clone https://github.com/mnajafian-nv/hermes-nemo-relay-demo.git
```

Install Hermes Agent:

```bash
cd hermes-agent
uv venv venv --python 3.11
export VIRTUAL_ENV="$(pwd)/venv"
uv pip install -e ".[all,dev]"
cd ..
```

Install NeMo Relay into the Hermes environment. For the released package:

```bash
cd hermes-agent
export VIRTUAL_ENV="$(pwd)/venv"
uv pip install nemo-relay
cd ..
```

For a local NeMo Relay source checkout instead:

```bash
git clone https://github.com/NVIDIA/NeMo-Relay.git
cd hermes-agent
export VIRTUAL_ENV="$(pwd)/venv"
uv pip install -e ../NeMo-Relay
cd ..
```

The script checks both forms at startup. If `nemo_relay` is not importable from
the Hermes Python environment and no source checkout is available, it exits with
a setup error before running the model.

Demo setup:

```bash
cd hermes-nemo-relay-demo
cp keys.env.example keys.env
chmod 600 keys.env
```

Edit `keys.env` and add your provider key.

For the default NVIDIA Inference setup:

```bash
NVIDIA_API_KEY=replace-with-your-nvidia-inference-key
```

For the web-search demo, also set:

```bash
TAVILY_API_KEY=replace-with-your-tavily-key
```

Run the demo:

```bash
./run.sh research
```

Use `./run.sh research` for the best visual walkthrough with web search. Use
`./run.sh` when you want to exercise all three Hermes request families:
`/v1/messages`, `/v1/chat/completions`, and `/v1/responses`.

Open Phoenix:

```text
http://127.0.0.1:6006/projects
```

## Commands

| Command | What it runs | Best use |
| --- | --- | --- |
| `./run.sh research` | `/v1/messages` with Tavily web search | Best live walkthrough |
| `./run.sh` | `/v1/messages`, `/v1/chat/completions`, `/v1/responses` | Full request-family check |
| `./run.sh messages` | `/v1/messages` | Anthropic Messages lane |
| `./run.sh chat` | `/v1/chat/completions` | OpenAI-compatible chat lane |
| `./run.sh responses` | `/v1/responses` | OpenAI Responses lane |
| `./run.sh research-all` | Web-search demo across all three lanes | Deeper live walkthrough |

The script starts or reuses Phoenix and creates one project per selected lane:

```text
nemo-relay-hermes-demo-<run-id>-<lane>
```

## What This Proves

- Hermes emits observability through the bundled `observability/nemo_relay`
  plugin.
- NeMo Relay receives the LLM and tool boundary events through `plugins.toml`.
- ATOF JSONL is written for LLM and tool lifecycle events.
- ATIF trajectory JSON is written for the agent run.
- OpenInference traces reach Phoenix and show the Hermes LLM/tool tree.
- The demo can exercise `/v1/messages`, `/v1/chat/completions`, and
  `/v1/responses`.

Cost is provider-payload gated. If the provider returns explicit cost fields,
Relay surfaces them. If the provider returns usage tokens only, the artifacts
show usage and Phoenix may estimate display cost depending on its model rules.

## Prerequisites

- Local Hermes Agent checkout with a working virtual environment and the bundled
  `observability/nemo_relay` plugin.
- NeMo Relay installed in the Hermes environment, or a local NeMo Relay source
  checkout.
- Docker for Phoenix.
- `curl` on `PATH`.
- NVIDIA Inference key for the default setup, or direct provider keys for the
  lanes you want to run.
- Tavily key for `research` or `research-all`.

The default sibling-checkout layout is:

```text
<workspace>/
  hermes-agent/
  NeMo-Relay/                  # optional when nemo-relay is installed
  hermes-nemo-relay-demo/
```

If your NeMo Relay source checkout is in a different location, set this in
`keys.env`:

```bash
NEMO_RELAY_REPO=/path/to/NeMo-Relay
```

If your Hermes checkout is in a different location, also set:

```bash
HERMES_REPO=/path/to/hermes-agent
```

## Provider Setup

The NVIDIA Inference defaults are configured for all three request families
when the model is enabled for your account:

```bash
NVIDIA_API_KEY=replace-with-your-nvidia-inference-key
NVIDIA_MODEL_ID=aws/anthropic/bedrock-claude-sonnet-4-6
```

For direct Anthropic Messages:

```bash
ANTHROPIC_API_KEY=replace-with-your-anthropic-key
MESSAGES_API_KEY_ENV=ANTHROPIC_API_KEY
MESSAGES_BASE_URL=https://api.anthropic.com
MESSAGES_MODEL_ID=replace-with-anthropic-model-id
```

For direct OpenAI-compatible Chat Completions and Responses:

```bash
OPENAI_API_KEY=replace-with-your-openai-key
CHAT_API_KEY_ENV=OPENAI_API_KEY
CHAT_BASE_URL=https://api.openai.com/v1
CHAT_MODEL_ID=replace-with-openai-chat-model-id

RESPONSES_API_KEY_ENV=OPENAI_API_KEY
RESPONSES_BASE_URL=https://api.openai.com/v1
RESPONSES_MODEL_ID=replace-with-openai-responses-model-id
```

Keep `keys.env` private. Generated outputs can contain prompts, model
responses, traces, and provider metadata.

## Inspect Results

For a quick walkthrough in Phoenix:

1. Open `http://127.0.0.1:6006/projects`.
2. Select the generated `nemo-relay-hermes-demo-<run-id>-<lane>` project.
3. Open the trace.
4. Show the trace tree with LLM spans and tool spans.
5. Select an LLM span and show input, output, usage, latency, and cost.

For local artifacts:

```text
outputs/<run-id>/<lane>/atof/events.jsonl
outputs/<run-id>/<lane>/atif/*.json
outputs/<run-id>/<lane>/nemo-relay/plugins.toml
outputs/<run-id>/<lane>/hermes-home/config.yaml
outputs/<run-id>/summary.txt
```

## Stop And Clean Up

Phoenix is reusable. Leaving it running makes repeated demos faster.

To stop the Phoenix container:

```bash
docker stop nemo-relay-phoenix
```

Generated run data is written under `outputs/`. Delete old run directories when
you no longer need the local evidence.

## Script Checks

Before sharing local edits:

```bash
bash -n run.sh
uvx --from shellcheck-py shellcheck run.sh
./run.sh --help
```
