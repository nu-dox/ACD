defmodule Daemon.HTTP.Router do
  use Plug.Router
  require Logger

  plug(Plug.Parsers,
    parsers: [:json],
    json_decoder: Jason
  )

  plug(:match)
  plug(:dispatch)

  post "/sessions/:id/run" do
    with {:ok, raw_program} <- fetch_field(conn.body_params, "program"),
         {:ok, program} <- parse_program(raw_program),
         :ok <- ensure_session(id),
         :ok <- Daemon.Session.run(id, program, Map.get(conn.body_params, "message", ""), Map.get(conn.body_params, "api_keys", %{})) do
      Logger.info("session=#{id} run started")
      send_resp(conn, 200, Jason.encode!(%{status: "ok"}))
    else
      {:error, {:missing_field, field}} ->
        send_resp(conn, 400, Jason.encode!(%{error: "missing field: #{field}"}))

      {:error, {:parse_error, reason}} ->
        send_resp(conn, 400, Jason.encode!(%{error: "parse error: #{reason}"}))

      {:error, :busy} ->
        send_resp(conn, 409, Jason.encode!(%{error: "session is busy"}))

      {:error, reason} ->
        Logger.error("session=#{id} run failed reason=#{inspect(reason)}")
        send_resp(conn, 500, Jason.encode!(%{error: "internal error"}))
    end
  end

  get "/sessions/:id/events" do
    Logger.info("session=#{id} SSE stream opened")
    Daemon.HTTP.EventStream.call(conn, id)
  end

  post "/sessions/:id/resume" do
    with {:ok, interrupt_id} <- fetch_field(conn.body_params, "interrupt_id"),
         {:ok, reply} <- fetch_field(conn.body_params, "reply") do
      Logger.info("session=#{id} resume interrupt_id=#{interrupt_id}")
      Daemon.Session.resume(id, interrupt_id, reply)
      send_resp(conn, 200, Jason.encode!(%{status: "ok"}))
    else
      {:error, {:missing_field, field}} ->
        send_resp(conn, 400, Jason.encode!(%{error: "missing field: #{field}"}))
    end
  end

  post "/sessions/:id/cancel" do
    Logger.info("session=#{id} cancel requested")
    Daemon.Session.cancel(id)
    send_resp(conn, 200, Jason.encode!(%{status: "ok"}))
  end

  match _ do
    Logger.warning("404 #{conn.method} #{conn.request_path}")
    send_resp(conn, 404, "not found")
  end

  defp fetch_field(params, key) do
    case Map.fetch(params, key) do
      {:ok, value} -> {:ok, value}
      :error -> {:error, {:missing_field, key}}
    end
  end

  defp parse_program(raw) do
    {:ok, Daemon.Op.Parser.parse(raw)}
  rescue
    e -> {:error, {:parse_error, Exception.message(e)}}
  end

  defp ensure_session(id) do
    case DynamicSupervisor.start_child(Daemon.SessionSupervisor, {Daemon.Session, %{id: id}}) do
      {:ok, _pid} -> :ok
      {:error, {:already_started, _pid}} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end
end
