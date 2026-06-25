# Agent Control Daemon (ACD)

An Elixir runtime for agent op programs. ACD is the backend engine for coding agent harnesses — it receives structured JSON programs from a client, orchestrates LLM agents against those programs, manages tool execution, and streams state back to the client in real time via SSE.

```
client harness (laptop / IDE / phone)
        ↓
  JSON op program  (HTTP POST)
        ↓
  ┌─────────────────────────────┐
  │  Agent Control Daemon       │
  │  parses ops → executor      │
  │  → LLM (Anthropic / OpenAI) │
  │  → tool dispatch            │
  └─────────────────────────────┘
        ↓
  SSE event stream  (tokens, tool calls, interrupts)
        ↓
      client harness
```

The client runs nothing itself. All agent logic, LLM calls, and tool execution live in the daemon.

---

## Client libraries

Client harness libraries are in active development. These will be the primary way to build coding agent harnesses on top of ACD.

---

## Op programs

Programs are JSON documents with a manifest (personality, available tools) and a body (op tree). The daemon interprets ops, not the client.

```json
{
  "acd": 2,
  "manifest": {
    "personality": {
      "starter_prompt": "You are a helpful assistant.",
      "tools": ["read", "write", "shell"],
      "use_llm": true,
      "provider": "anthropic",
      "model": "claude-sonnet-4-6"
    },
    "slots": []
  },
  "body": {
    "op": "literal",
    "value": "Summarise the project in /tmp/myproject"
  }
}
```

### Implemented ops

| Op | Description |
|---|---|
| `literal` | Inject a static string value |
| `then` | Run `first`, then `second`; keep one result (`"first"` or `"second"`) |
| `slot_set` | Assign a named slot to the result of an op |
| `slot_get` | Read a named slot |
| `call_tool` | Execute a named tool with resolved args |
| `interrupt` | Pause and wait for human input via `/resume` |
| `par` | Run multiple op branches in parallel |
| `spawn_agent` | Spawn a sub-agent session and wait for its result |

---

## Architecture

```
Daemon.Application
├── Daemon.PubSub              Phoenix.PubSub — event fan-out for SSE
├── Daemon.SessionRegistry     Registry — look up sessions by ID
├── Daemon.SessionSupervisor   DynamicSupervisor — manages session processes
│   └── Daemon.Session         GenServer — one per active session
└── Daemon.HTTP                Bandit + Plug router
```

**Request lifecycle:**

```
POST /sessions/:id/run
  → router starts or resumes a session process
  → Op.Parser parses JSON → typed op structs
  → Op.Interpreter builds ExecutionPlan
  → Session.Executor walks the op tree
      → resolves slots
      → dispatches tool calls
      → blocks on interrupts until human replies via /resume
  → Session.Loop calls LLM (streaming)
  → tokens + events broadcast via PubSub → SSE client
```

### Project structure

```
lib/daemon/
├── application.ex         supervision tree entry point
├── tool.ex                tool registry and dispatch
├── op/
│   ├── types.ex           op structs
│   ├── parser.ex          JSON → op structs
│   └── interpreter.ex     builds ExecutionPlan from program
├── session/
│   ├── loop.ex            agent loop — calls LLM, handles tool turns
│   └── executor.ex        evaluates ops, manages slots
├── session.ex             GenServer — session lifecycle
├── llm/
│   ├── provider.ex        behaviour (complete/2, stream/3)
│   ├── client.ex          dispatcher — routes to correct provider
│   ├── anthropic.ex       Anthropic streaming + non-streaming
│   ├── openai.ex          OpenAI streaming + non-streaming
│   ├── gemini.ex          stub (not yet implemented)
│   └── sse_parser.ex      SSE line parser for streamed LLM responses
└── http/
    ├── router.ex          Plug router
    └── event_stream.ex    SSE handler
```

---

## HTTP API

### Start a session

```
POST /sessions/:id/run
Content-Type: application/json

{ "program": { ...op program... } }
```

### Stream session events

```
GET /sessions/:id/events
Accept: text/event-stream
```

| Event | Payload |
|---|---|
| `text_delta` | `{ "content": "..." }` — streaming token |
| `tool_started` | `{ "name": "shell" }` |
| `tool_completed` | `{ "name": "shell", "result": "..." }` |
| `agent_spawned` | `{ "agent_id": "..." }` |
| `agent_finished` | `{ "agent_id": "...", "result": "..." }` |
| `intervention_required` | `{ "id": "...", "prompt": "..." }` |
| `finished` | `{ "content": "..." }` |
| `cancelled` | `{}` |

### Resume after an interrupt

```
POST /sessions/:id/resume
Content-Type: application/json

{ "interrupt_id": "...", "reply": "user's answer" }
```

---

## Setup

**Requirements:** Elixir 1.18+, OTP 27+

```bash
mix deps.get
```

Set at least one LLM provider key:

```bash
export ANTHROPIC_API_KEY=sk-ant-...
export OPENAI_API_KEY=sk-...
```

Start the server:

```bash
iex -S mix
```

The HTTP server starts on port 4000.

### Quick smoke test

```bash
# Terminal 1 — open SSE stream
curl -N http://localhost:4000/sessions/s1/events

# Terminal 2 — send a program
cat <<'EOF' > /tmp/prog.json
{
  "program": {
    "acd": 2,
    "manifest": {
      "personality": {
        "starter_prompt": "You are a helpful assistant.",
        "tools": [],
        "use_llm": true,
        "provider": "anthropic",
        "model": "claude-haiku-4-5-20251001"
      },
      "slots": []
    },
    "body": { "op": "literal", "value": "Say hello in one sentence." }
  }
}
EOF
curl -X POST -H "Content-Type: application/json" -d @/tmp/prog.json http://localhost:4000/sessions/s1/run
```

---

## Dependencies

| Package | Purpose |
|---|---|
| `bandit` | HTTP server |
| `plug` | HTTP routing |
| `req` | HTTP client for LLM API calls |
| `jason` | JSON encoding/decoding |
| `phoenix_pubsub` | Internal event fan-out for SSE |

---

## License

MIT
