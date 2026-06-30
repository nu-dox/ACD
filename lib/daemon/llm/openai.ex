defmodule Daemon.LLM.OpenAI do
  @behaviour Daemon.LLM.Provider
  require Logger

  @impl true
  def stream(plan, messages, on_chunk) do
    api_key = get_in(plan, [:api_keys, "openai"]) || System.get_env("OPENAI_API_KEY")

    case api_key do
      key when key in [nil, ""] ->
        Logger.error("OPENAI_API_KEY not set")
        {:error, :missing_api_key}

      key ->
        do_stream(key, plan, messages, on_chunk)
    end
  end

  defp do_stream(api_key, plan, messages, on_chunk) do
    tools = Enum.map(plan.tools, &tool_definition/1)

    base = %{
      model: plan.model || "gpt-4o",
      messages: format_messages(messages),
      stream: true
    }

    body = if tools == [], do: base, else: Map.put(base, :tools, tools)

    ref = make_ref()
    parent = self()

    Task.start(fn ->
      result =
        Req.post("https://api.openai.com/v1/chat/completions",
          json: body,
          finch: Daemon.Finch,
          receive_timeout: 120_000,
          headers: [
            {"authorization", "Bearer #{api_key}"},
            {"content-type", "application/json"}
          ],
          into: fn {:data, data}, acc ->
            send(parent, {:openai_chunk, ref, data})
            {:cont, acc}
          end
        )

      case result do
        {:ok, %{status: status, body: body}} when status >= 400 ->
          Logger.error("openai stream error status=#{status} body=#{inspect(body)}")
          send(parent, {:openai_error, ref, "HTTP #{status}"})

        {:error, reason} ->
          Logger.error("openai stream request failed reason=#{inspect(reason)}")
          send(parent, {:openai_error, ref, inspect(reason)})

        _ ->
          :ok
      end

      send(parent, {:openai_done, ref})
    end)

    collect_stream(ref, on_chunk, "", %{}, nil, "")
  end

  defp collect_stream(ref, on_chunk, text, tool_bufs, finish_reason, line_buf) do
    receive do
      {:openai_chunk, ^ref, data} ->
        {new_text, new_bufs, new_fr, chunks, new_line_buf} =
          process_chunk(line_buf, data, text, tool_bufs, finish_reason)

        Enum.each(chunks, on_chunk)
        collect_stream(ref, on_chunk, new_text, new_bufs, new_fr, new_line_buf)

      {:openai_error, ^ref, reason} ->
        {:error, reason}

      {:openai_done, ^ref} ->
        tool_calls =
          tool_bufs
          |> Enum.sort_by(fn {idx, _} -> idx end)
          |> Enum.map(fn {_idx, buf} ->
            args =
              case Jason.decode(buf.args_acc) do
                {:ok, decoded} -> decoded
                _ -> %{}
              end

            %{id: buf.id, name: buf.name, args: args}
          end)

        fr =
          case finish_reason do
            "tool_calls" -> :tool_calls
            _ -> :end_turn
          end

        {:ok, %{finish_reason: fr, content: text, tool_calls: tool_calls}}
    after
      120_000 -> {:error, :timeout}
    end
  end

  defp process_chunk(line_buf, data, text, tool_bufs, finish_reason) do
    lines = String.split(line_buf <> data, "\n")
    {complete_lines, [remainder]} = Enum.split(lines, -1)

    {new_text, new_bufs, new_fr, chunks} =
      complete_lines
      |> Enum.map(&String.trim/1)
      |> Enum.reduce({text, tool_bufs, finish_reason, []}, fn line, acc ->
        case Daemon.LLM.SSEParser.parse_line(line) do
          {:ok, event} -> handle_event(event, acc)
          _ -> acc
        end
      end)

    {new_text, new_bufs, new_fr, chunks, remainder}
  end

  defp handle_event(
         %{"choices" => [%{"delta" => delta, "finish_reason" => fr} | _]},
         {text, bufs, _fr, chunks}
       )
       when not is_nil(fr) do
    {new_text, new_bufs, new_chunks} = apply_delta(delta, text, bufs, chunks)
    {new_text, new_bufs, fr, new_chunks}
  end

  defp handle_event(%{"choices" => [%{"delta" => delta} | _]}, {text, bufs, fr, chunks}) do
    {new_text, new_bufs, new_chunks} = apply_delta(delta, text, bufs, chunks)
    {new_text, new_bufs, fr, new_chunks}
  end

  defp handle_event(_event, acc), do: acc

  defp apply_delta(%{"content" => content}, text, bufs, chunks) when is_binary(content) do
    {text <> content, bufs, chunks ++ [content]}
  end

  defp apply_delta(%{"tool_calls" => tool_deltas}, text, bufs, chunks)
       when is_list(tool_deltas) do
    new_bufs =
      Enum.reduce(tool_deltas, bufs, fn delta, acc ->
        idx = delta["index"]

        case acc do
          %{^idx => buf} ->
            args_delta = get_in(delta, ["function", "arguments"]) || ""
            name = get_in(delta, ["function", "name"])
            buf = Map.update!(buf, :args_acc, &(&1 <> args_delta))
            buf = if name && name != "", do: %{buf | name: name}, else: buf
            Map.put(acc, idx, buf)

          _ ->
            id = delta["id"] || ""
            name = get_in(delta, ["function", "name"]) || ""
            initial_args = get_in(delta, ["function", "arguments"]) || ""
            Map.put(acc, idx, %{id: id, name: name, args_acc: initial_args})
        end
      end)

    {text, new_bufs, chunks}
  end

  defp apply_delta(_delta, text, bufs, chunks), do: {text, bufs, chunks}

  @impl true
  def complete(plan, messages) do
    api_key = get_in(plan, [:api_keys, "openai"]) || System.get_env("OPENAI_API_KEY")

    case api_key do
      nil ->
        Logger.error("OPENAI_API_KEY not set")
        {:error, :missing_api_key}

      "" ->
        Logger.error("OPENAI_API_KEY empty")
        {:error, :missing_api_key}

      key ->
        do_complete(key, plan, messages)
    end
  end

  defp do_complete(api_key, plan, messages) do
    tools = Enum.map(plan.tools, &tool_definition/1)

    base = %{
      model: plan.model || "gpt-4o",
      messages: format_messages(messages)
    }

    body = if tools == [], do: base, else: Map.put(base, :tools, tools)

    case Req.post("https://api.openai.com/v1/chat/completions",
           json: body,
           finch: Daemon.Finch,
           receive_timeout: 120_000,
           headers: [
             {"authorization", "Bearer #{api_key}"},
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
      %{role: :tool, tool_use_id: id, content: content} ->
        %{role: "tool", tool_call_id: id, content: content}

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
