defmodule Daemon.LLM.OpenAI do
  @behaviour Daemon.LLM.Provider
  require Logger

  @impl true
  def complete(plan, messages) do
    tools = Enum.map(plan.tools, &tool_definition/1)

    body = %{
      model: plan.model || "gpt-4o",
      messages: format_messages(messages),
      tools: tools
    }

    case Req.post("https://api.openai.com/v1/chat/completions",
           json: body,
           headers: [
             {"authorization", "Bearer #{System.get_env("OPENAI_API_KEY")}"},
             {"content-type", "application/json"}
           ]
         ) do
      {:ok, %{status: 200, body: body}} ->
        {:ok, parse_response(body)}

      {:ok, %{status: status, body: body}} ->
        Logger.error("OpenAI API error status=#{status} body=#{inspect(body)}")
        {:error, %{status: status, body: body}}

      {:error, reason} ->
        Logger.error("OpenAI request failed reason=#{inspect(reason)}")
        {:error, reason}
    end
  end

  defp parse_response(body) do
    message = get_in(body, ["choices", Access.at(0), "message"])
    finish_reason = get_in(body, ["choices", Access.at(0), "finish_reason"])

    %{
      finish_reason: parse_finish_reason(finish_reason),
      content: message["content"] || "",
      tool_calls: extract_tool_calls(message["tool_calls"])
    }
  end

  defp parse_finish_reason("stop"), do: :end_turn
  defp parse_finish_reason("tool_calls"), do: :tool_calls
  defp parse_finish_reason(_), do: :end_turn

  defp extract_tool_calls(nil), do: []

  defp extract_tool_calls(tool_calls) do
    Enum.map(tool_calls, fn call ->
      %{
        id: call["id"],
        name: call["function"]["name"],
        args: Jason.decode!(call["function"]["arguments"])
      }
    end)
  end

  defp tool_definition(name) do
    base = Daemon.Tool.definition(name)

    %{
      type: "function",
      function: %{
        name: base.name,
        description: base.description,
        parameters: base.input_schema
      }
    }
  end

  defp format_messages(messages) do
    Enum.map(messages, fn
      %{role: :tool, tool_use_id: id, name: name, content: content} ->
        %{role: "tool", tool_call_id: id, name: name, content: content}

      %{role: :assistant, content: text, tool_calls: tool_calls} when tool_calls != [] ->
        openai_tool_calls =
          Enum.map(tool_calls, fn call ->
            %{
              id: call.id,
              type: "function",
              function: %{
                name: call.name,
                arguments: Jason.encode!(call.args)
              }
            }
          end)

        %{role: "assistant", content: text, tool_calls: openai_tool_calls}

      %{role: role, content: content} ->
        %{role: to_string(role), content: content}
    end)
  end
end
