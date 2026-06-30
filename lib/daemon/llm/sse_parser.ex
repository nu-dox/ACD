defmodule Daemon.LLM.SSEParser do
  @spec parse_line(String.t()) :: {:ok, map()} | :done | :ignore
  def parse_line("data: [DONE]"), do: :done

  def parse_line("data: " <> json) do
    case Jason.decode(json) do
      {:ok, decoded} -> {:ok, decoded}
      {:error, _} -> :ignore
    end
  end

  def parse_line(_), do: :ignore
end
