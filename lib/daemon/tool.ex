defmodule Daemon.Tool do
  require Logger

  @response_truncate_chars 4000

  @spec execute(String.t(), map() | list()) :: {:ok, String.t()} | {:error, any()}

  # http_get — called from LLM agent loop (args is a map)
  def execute("http_get", %{"url" => url}) do
    Logger.info("tool=http_get url=#{url}")
    http_get(url)
  end

  # http_get — called from op tree executor (args is a positional list)
  def execute("http_get", [url | _]) when is_binary(url) do
    Logger.info("tool=http_get url=#{url}")
    http_get(url)
  end

  # fallback stub for all other tools
  def execute(name, args) do
    Logger.info("tool=#{name} args=#{inspect(args)} (stubbed)")
    {:ok, "tool result for #{name}"}
  end

  # --- tool schemas ---

  def definition("search") do
    %{
      name: "search",
      description: "Search the web for information on a topic. Returns relevant text snippets.",
      input_schema: %{
        type: "object",
        properties: %{
          query: %{type: "string", description: "The search query"}
        },
        required: ["query"]
      }
    }
  end

  def definition("read") do
    %{
      name: "read",
      description: "Read the contents of a file at the given path.",
      input_schema: %{
        type: "object",
        properties: %{
          path: %{type: "string", description: "Absolute or relative file path"}
        },
        required: ["path"]
      }
    }
  end

  def definition("write") do
    %{
      name: "write",
      description: "Write content to a file at the given path.",
      input_schema: %{
        type: "object",
        properties: %{
          path: %{type: "string", description: "File path to write to"},
          content: %{type: "string", description: "Content to write"}
        },
        required: ["path", "content"]
      }
    }
  end

  def definition("http_get") do
    %{
      name: "http_get",
      description: "Make an HTTP GET request to a URL and return the response body.",
      input_schema: %{
        type: "object",
        properties: %{
          url: %{type: "string", description: "The URL to fetch"}
        },
        required: ["url"]
      }
    }
  end

  def definition(name) do
    %{
      name: name,
      description: "Executes the #{name} tool.",
      input_schema: %{
        type: "object",
        properties: %{
          input: %{type: "string", description: "Input for the #{name} tool"}
        },
        required: ["input"]
      }
    }
  end

  # --- private ---

  defp http_get(url) do
    case Req.get(url) do
      {:ok, %{status: 200, body: body}} ->
        text = if is_binary(body), do: body, else: Jason.encode!(body)
        {:ok, String.slice(text, 0, @response_truncate_chars)}

      {:ok, %{status: status}} ->
        Logger.warning("tool=http_get url=#{url} status=#{status}")
        {:error, "HTTP #{status}"}

      {:error, reason} ->
        Logger.error("tool=http_get url=#{url} error=#{inspect(reason)}")
        {:error, inspect(reason)}
    end
  end
end
