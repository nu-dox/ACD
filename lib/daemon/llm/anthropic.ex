defmodule Daemon.LLM.Anthropic do
  @behaviour Daemon.LLM.Provider
  require Logger

  @impl true
  def complete(plan, messages) do
    tools = Enum.map(plan.tools, &Daemon.Tool.definition/1)

    body = %{
      model: plan.model || "claude-opus-4-7",
      max_tokens: 8096,
      system: plan.system,
      tools: tools,
      messages: format_messages(messages)
    }

    case Req.post("https://api.anthropic.com/v1/messages",
           json: body,
           headers: [
             {"x-api-key", System.get_env("ANTHROPIC_API_KEY")},
             {"anthropic-version", "2023-06-01"},
             {"content-type", "application/json"}
           ]
         ) do
      {:ok, %{status: 200, body: body}} ->
        {:ok, parse_response(body)}

      {:ok, %{status: status, body: body}} ->
        Logger.error("Anthropic API error status=#{status} body=#{inspect(body)}")
        {:error, %{status: status, body: body}}

      {:error, reason} ->
        Logger.error("Anthropic request failed reason=#{inspect(reason)}")
        {:error, reason}
    end
  end

  defp parse_response(body) do
    %{
      finish_reason: parse_finish_reason(body["stop_reason"]),
      content: extract_text(body["content"]),
      tool_calls: extract_tool_calls(body["content"])
    }
  end

  defp parse_finish_reason("end_turn"), do: :end_turn
  defp parse_finish_reason("tool_use"), do: :tool_calls
  defp parse_finish_reason(_), do: :end_turn

  defp extract_text(content) do
    content
    |> Enum.filter(&(&1["type"] == "text"))
    |> Enum.map(& &1["text"])
    |> Enum.join("")
  end

  defp extract_tool_calls(content) do
    content
    |> Enum.filter(&(&1["type"] == "tool_use"))
    |> Enum.map(fn tool ->
      %{id: tool["id"], name: tool["name"], args: tool["input"]}
    end)
  end

  defp format_messages(messages) do
    Enum.map(messages, fn
      %{role: :tool, tool_use_id: id, name: _name, content: content} ->
        %{
          role: "user",
          content: [%{type: "tool_result", tool_use_id: id, content: content}]
        }

      %{role: :assistant, content: text, tool_calls: tool_calls} when tool_calls != [] ->
        text_blocks = if text != "", do: [%{type: "text", text: text}], else: []

        tool_blocks =
          Enum.map(tool_calls, fn call ->
            %{type: "tool_use", id: call.id, name: call.name, input: call.args}
          end)

        %{role: "assistant", content: text_blocks ++ tool_blocks}

      %{role: role, content: content} ->
        %{role: to_string(role), content: content}
    end)
  end
end
