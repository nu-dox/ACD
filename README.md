# daemon

The Elixir backend for the Agent Control Daemon — an orchestration layer that receives structured op programs from clients, executes them against LLM providers, and streams state back in real time.

## What it does

Clients (laptops, phones, any registered machine) send JSON op programs to the daemon over HTTP. The daemon interprets the ops, calls LLM providers directly (Anthropic, OpenAI), handles tool execution, manages agent sessions, and streams events back to the client via SSE.

The client runs nothing itself. All agent logic lives here.

```
client (laptop/phone)
        ↓
  JSON op program (HTTP POST)
        ↓
  [daemon — this repo]
  parses ops → runs executor → calls LLM → dispatches tools
        ↓
  streams events back (SSE)
        ↓
      client
```

## Op program format

Programs are JSON documents with a manifest (personality, slots) and a body (op tree).

```json
{
  "acd": 2,
  "manifest": {
    "personality": {
      "starter_prompt": "You are a helpful assistant.",
      "tools": ["search", "read"]
    },
    "slots": [
      { "name": "query", "ty": { "type": "string" } }
    ]
  },
  "body": {
    "op": "label",
    "label": "answer-the-question",
    "body": {
      "op": "then",
      "first": {
        "op": "slot_set",
        "slot": "query",
        "value": {
          "op": "interrupt",
          "id": 0,
          "kind": "ask_human",
          "prompt": "What's your question?",
          "response": { "type": "string" }
        }
      },
      "second": {
        "op": "call_tool",
        "name": "search",
        "args": [{ "op": "slot_get", "slot": "query" }],
        "output": { "type": "json" }
      },
      "keep": "second"
    }
  }
}
```

### Supported ops

| Op | Description |
|---|---|
| `label` | Named entry point for a block of ops |
| `then` | Run `first`, then `second`, keep one result |
| `slot_set` | Set a named slot to a value |
| `slot_get` | Read a named slot |
| `call_tool` | Execute a tool by name with resolved args |
| `interrupt` | Pause and request human input |

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
  → router parses body, starts session process
  → Session GenServer spawns a Task
  → Op.Parser parses JSON → typed op structs
  → Op.Interpreter builds ExecutionPlan (slots, personality, tools)
  → Session.Executor walks the op tree
      → resolves slots
      → dispatches tool calls
      → blocks on interrupts until human replies
  → Session.Loop calls LLM with accumulated context
  → events broadcast via PubSub → SSE client receives in real time
```

## Project structure

```
lib/
├── daemon/
│   ├── application.ex         entry point, starts supervision tree
│   ├── tool.ex                tool dispatch
│   ├── op/
│   │   ├── types.ex           op structs
│   │   ├── parser.ex          JSON → op structs
│   │   └── interpreter.ex     builds ExecutionPlan from program
│   ├── session/
│   │   ├── loop.ex            runs program, calls LLM
│   │   └── executor.ex        evaluates individual ops, manages slots
│   ├── session.ex             GenServer — session state and lifecycle
│   ├── llm/
│   │   └── client.ex          HTTP calls to Anthropic/OpenAI
│   └── http/
│       ├── router.ex          Plug router
│       └── event_stream.ex    SSE handler
```

## HTTP API

### Run a session

```
POST /sessions/:id/run
Content-Type: application/json

{
  "program": { ...op program... },
  "message": "optional initial message"
}
```

### Stream session events

```
GET /sessions/:id/events
Accept: text/event-stream
```

Events:

| Event | Payload |
|---|---|
| `thinking` | `{}` |
| `tool_started` | `{ "name": "search" }` |
| `tool_completed` | `{ "name": "search", "result": "..." }` |
| `intervention_required` | `{ "id": 0, "prompt": "What's your question?" }` |
| `finished` | `{ "content": "..." }` |
| `cancelled` | `{}` |

### Resume after intervention

```
POST /sessions/:id/resume
Content-Type: application/json

{
  "interrupt_id": 0,
  "reply": "user's answer"
}
```

## Setup

**Requirements:** Elixir 1.18+, OTP 27+

```bash
mix deps.get
```

Set your API key:

```bash
export ANTHROPIC_API_KEY=your_key_here
```

Run:

```bash
iex -S mix
```

The HTTP server starts on port 4000.

## Dependencies

| Package | Purpose |
|---|---|
| `bandit` | HTTP server |
| `plug` | HTTP routing |
| `req` | HTTP client for LLM calls |
| `jason` | JSON encoding/decoding |
| `phoenix_pubsub` | Internal event fan-out for SSE |
