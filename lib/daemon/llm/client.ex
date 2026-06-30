defmodule Daemon.LLM.Client do
  def complete(plan, messages) do
    provider(plan).complete(plan, messages)
  end

  def stream(plan, messages, on_chunk) do
    provider(plan).stream(plan, messages, on_chunk)
  end

  defp provider(%{provider: :anthropic}), do: Daemon.LLM.Anthropic
  defp provider(_), do: Daemon.LLM.OpenAI
end
