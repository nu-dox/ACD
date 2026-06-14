defmodule Daemon.LLM.Client do
  def complete(plan, messages) do
    provider(plan).complete(plan, messages)
  end

  defp provider(%{provider: :anthropic}), do: Daemon.LLM.Anthropic
  defp provider(_), do: Daemon.LLM.OpenAI
end
