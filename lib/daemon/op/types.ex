defmodule Daemon.Op do
  defmodule Program do
    defstruct [:acd, :manifest, :body]
  end

  defmodule Manifest do
    defstruct [:personality, slots: [], routines: %{}]
  end

  defmodule Personality do
    defstruct [:starter_prompt, :provider, :model, tools: [], use_llm: true]
  end

  defmodule Slot do
    defstruct [:name, :ty]
  end

  # ── values & state ────────────────────────────────────────────────

  defmodule Literal do
    defstruct [:value]
  end

  defmodule Nop do
    defstruct []
  end

  defmodule SlotGet do
    defstruct [:slot]
  end

  defmodule SlotSet do
    defstruct [:slot, :value]
  end

  defmodule ParamGet do
    defstruct [:param]
  end

  # ── time & resilience ─────────────────────────────────────────────

  defmodule Timeout do
    defstruct [:ms, :body]
  end

  defmodule Delay do
    defstruct [:ms]
  end

  defmodule TryUndo do
    defstruct [:body, :undo]
  end

  # ── sequencing & shaping ──────────────────────────────────────────

  defmodule Then do
    defstruct [:first, :second, :keep]
  end

  defmodule MapOp do
    defstruct [:inner, :transform]
  end

  defmodule Choice do
    defstruct [:branches]
  end

  defmodule Repeated do
    defstruct [:inner, :min, max: nil]
  end

  defmodule Ignore do
    defstruct [:inner]
  end

  defmodule Label do
    defstruct [:label, :body]
  end

  defmodule Thought do
    defstruct [:text]
  end

  defmodule Checkpoint do
    defstruct [:name]
  end

  # ── comparison & control ──────────────────────────────────────────

  defmodule Compare do
    defstruct [:kind, :lhs, :rhs]
  end

  # kept for backwards compat with existing test programs
  defmodule Eq do
    defstruct [:left, :right]
  end

  defmodule Lt do
    defstruct [:left, :right]
  end

  defmodule Gt do
    defstruct [:left, :right]
  end

  defmodule When do
    defstruct [:condition, :body]
  end

  defmodule While do
    defstruct [:condition, :body]
  end

  defmodule ForEach do
    defstruct [:over, :param, :body]
  end

  # ── tools & context ───────────────────────────────────────────────

  defmodule CallTool do
    defstruct [:name, :args, :output]
  end

  defmodule LoadContext do
    defstruct [:source]
  end

  defmodule CompactContext do
    defstruct []
  end

  defmodule ForgetAfter do
    defstruct [:mark]
  end

  defmodule Pin do
    defstruct [:fact]
  end

  # ── interrupts ────────────────────────────────────────────────────

  defmodule Interrupt do
    defstruct [:id, :kind, :prompt, :response]
  end

  # ── execution metadata ────────────────────────────────────────────

  defmodule Strategy do
    defstruct [:strategy, :body]
  end

  defmodule WithPersonality do
    defstruct [:personality, :body]
  end

  defmodule Budget do
    defstruct [:tokens, :body]
  end

  defmodule Sandbox do
    defstruct [:allowed_tools, :body]
  end

  # ── error recovery ────────────────────────────────────────────────

  defmodule Retry do
    defstruct [:policy, :body]
  end

  defmodule Recover do
    defstruct [:body, :fallback]
  end

  defmodule Skip do
    defstruct [:body]
  end

  # ── guards & steering ─────────────────────────────────────────────

  defmodule Guard do
    defstruct [:phase, :check, :feedback, :max_attempts, :on_exhausted, :body]
  end

  # ── concurrency ───────────────────────────────────────────────────

  defmodule Par do
    defstruct [:branches]
  end

  defmodule Race do
    defstruct [:branches]
  end

  defmodule FanOut do
    defstruct [:over, :param, :body, :join]
  end

  # ── routines ──────────────────────────────────────────────────────

  defmodule Invoke do
    defstruct [:routine, :args]
  end

  # ── signals ───────────────────────────────────────────────────────

  defmodule Emit do
    defstruct [:topic, :payload]
  end

  defmodule AwaitSignal do
    defstruct [:topic]
  end

  defmodule OnSignal do
    defstruct [:topic, :param, :body]
  end

  # ── advanced agentic ──────────────────────────────────────────────

  defmodule Shadow do
    defstruct [:threshold, :body]
  end

  defmodule Ensemble do
    defstruct [:count, :body, :voter]
  end

  defmodule Sample do
    defstruct [:choices]
  end

  defmodule OnChunk do
    defstruct [:body]
  end

  # ── agents ────────────────────────────────────────────────────────

  defmodule SpawnAgent do
    defstruct [:id, :personality, :input, :body]
  end
end
