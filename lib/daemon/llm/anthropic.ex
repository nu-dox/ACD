defmodule Daemon.LLM.Anthropic do
  @behaviour Daemon.LLM.Provider
  require Logger

  @impl true
  def stream(plan, messages, on_chunk) do
    api_key = get_in(plan, [:api_keys, "anthropic"]) || System.get_env("ANTHROPIC_API_KEY")

    case api_key do
      key when key in [nil, ""] ->
        Logger.error("ANTHROPIC_API_KEY not set")
        {:error, :missing_api_key}

      key ->
        do_stream(key, plan, messages, on_chunk)
    end
  end

  defp do_stream(api_key, plan, messages, on_chunk) do
    tools = Enum.map(plan.tools, &Daemon.Tool.definition/1)

    base = %{
      model: plan.model || "claude-sonnet-4-6",
      max_tokens: 8096,
      system: plan.system,
      messages: format_messages(messages),
      stream: true
    }

    body = if tools == [], do: base, else: Map.put(base, :tools, tools)

    ref = make_ref()
    parent = self()

    Task.start(fn ->
      result =
        Req.post("https://api.anthropic.com/v1/messages",
          json: body,
          finch: Daemon.Finch,
          receive_timeout: 120_000,
          headers: [
            {"x-api-key", api_key},
            {"anthropic-version", "2023-06-01"}
          ],
          into: fn {:data, data}, acc ->
            send(parent, {:anthropic_chunk, ref, data})
            {:cont, acc}
          end
        )

      case result do
        {:ok, %{status: status, body: body}} when status >= 400 ->
          Logger.error("anthropic stream error status=#{status} body=#{inspect(body)}")
          send(parent, {:anthropic_error, ref, "HTTP #{status}"})

        {:error, reason} ->
          Logger.error("anthropic stream request failed reason=#{inspect(reason)}")
          send(parent, {:anthropic_error, ref, inspect(reason)})

        _ ->
          :ok
      end

      send(parent, {:anthropic_done, ref})
    end)

    collect_stream(ref, on_chunk, "", [], nil, nil, "")
  end

  defp collect_stream(ref, on_chunk, text, tool_calls, curr_tool, stop_reason, line_buf) do
    receive do
      {:anthropic_chunk, ^ref, data} ->
        {new_text, new_calls, new_curr, new_sr, chunks, new_line_buf} =
          process_chunk(line_buf, data, text, tool_calls, curr_tool, stop_reason)

        Enum.each(chunks, on_chunk)
        collect_stream(ref, on_chunk, new_text, new_calls, new_curr, new_sr, new_line_buf)

      {:anthropic_error, ^ref, reason} ->
        {:error, reason}

      {:anthropic_done, ^ref} ->
        finish_reason =
          case stop_reason do
            "tool_use" -> :tool_calls
            _ -> :end_turn
          end

        {:ok, %{finish_reason: finish_reason, content: text, tool_calls: tool_calls}}
    after
      120_000 -> {:error, :timeout}
    end
  end

  defp process_chunk(line_buf, data, text, tool_calls, curr_tool, stop_reason) do
    lines = String.split(line_buf <> data, "\n")
    {complete_lines, [remainder]} = Enum.split(lines, -1)

    {new_text, new_calls, new_curr, new_sr, chunks} =
      complete_lines
      |> Enum.map(&String.trim/1)
      |> Enum.reduce({text, tool_calls, curr_tool, stop_reason, []}, fn line, acc ->
        case Daemon.LLM.SSEParser.parse_line(line) do
          {:ok, event} -> handle_event(event, acc)
          _ -> acc
        end
      end)

    {new_text, new_calls, new_curr, new_sr, chunks, remainder}
  end

  defp handle_event(
         %{
           "type" => "content_block_start",
           "content_block" => %{"type" => "tool_use", "id" => id, "name" => name}
         },
         {text, calls, _curr, sr, chunks}
       ) do
    {text, calls, %{id: id, name: name, args_acc: ""}, sr, chunks}
  end

  defp handle_event(
         %{
           "type" => "content_block_delta",
           "delta" => %{"type" => "text_delta", "text" => chunk}
         },
         {text, calls, curr, sr, chunks}
       ) do
    {text <> chunk, calls, curr, sr, chunks ++ [chunk]}
  end

  defp handle_event(
         %{
           "type" => "content_block_delta",
           "delta" => %{"type" => "input_json_delta", "partial_json" => partial}
         },
         {text, calls, curr_tool, sr, chunks}
       )
       when curr_tool != nil do
    {text, calls, Map.update!(curr_tool, :args_acc, &(&1 <> partial)), sr, chunks}
  end

  defp handle_event(%{"type" => "content_block_stop"}, {text, calls, curr_tool, sr, chunks})
       when curr_tool != nil do
    args =
      case Jason.decode(curr_tool.args_acc) do
        {:ok, decoded} -> decoded
        _ -> %{}
      end

    {text, calls ++ [%{id: curr_tool.id, name: curr_tool.name, args: args}], nil, sr, chunks}
  end

  defp handle_event(
         %{"type" => "message_delta", "delta" => %{"stop_reason" => reason}},
         {text, calls, curr, _sr, chunks}
       ) do
    {text, calls, curr, reason, chunks}
  end

  defp handle_event(_event, acc), do: acc

  @impl true
  def complete(plan, messages) do
    api_key = get_in(plan, [:api_keys, "anthropic"]) || System.get_env("ANTHROPIC_API_KEY")

    case api_key do
      nil ->
        Logger.error("ANTHROPIC_API_KEY not set")
        {:error, :missing_api_key}

      "" ->
        Logger.error("ANTHROPIC_API_KEY empty")
        {:error, :missing_api_key}

      key ->
        do_complete(key, plan, messages)
    end
  end

  defp do_complete(api_key, plan, messages) do
    tools = Enum.map(plan.tools, &Daemon.Tool.definition/1)

    base = %{
      model: plan.model || "claude-sonnet-4-6",
      max_tokens: 8096,
      system: plan.system,
      messages: format_messages(messages)
    }

    body = if tools == [], do: base, else: Map.put(base, :tools, tools)

    case Req.post("https://api.anthropic.com/v1/messages",
           json: body,
           finch: Daemon.Finch,
           receive_timeout: 120_000,
           headers: [
             {"x-api-key", api_key},
             {"anthropic-version", "2023-06-01"}
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
