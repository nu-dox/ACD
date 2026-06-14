defmodule Daemon.HTTP.EventStream do
  def call(conn, session_id) do
    Phoenix.PubSub.subscribe(Daemon.PubSub, "session:#{session_id}")

    conn
    |> Plug.Conn.put_resp_header("content-type", "text/event-stream")
    |> Plug.Conn.put_resp_header("cache-control", "no-cache")
    |> Plug.Conn.put_resp_header("connection", "keep-alive")
    |> Plug.Conn.send_chunked(200)
    |> stream_loop()
  end

  defp stream_loop(conn) do
    receive do
      %{type: :finished} = event ->
        Plug.Conn.chunk(conn, format(event))
        conn

      %{type: _} = event ->
        case Plug.Conn.chunk(conn, format(event)) do
          {:ok, conn} -> stream_loop(conn)
          {:error, _} -> conn
        end

      _ ->
        stream_loop(conn)
    after
      30_000 ->
        case Plug.Conn.chunk(conn, "event: ping\ndata: {}\n\n") do
          {:ok, conn} -> stream_loop(conn)
          {:error, _} -> conn
        end
    end
  end

  defp format(event) do
    "event: #{event.type}\ndata: #{Jason.encode!(event)}\n\n"
  end
end
