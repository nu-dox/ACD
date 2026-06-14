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
    %{"program" => raw_program} = conn.body_params
    message = Map.get(conn.body_params, "message", "")

    Logger.info("session=#{id} run requested")

    program = Daemon.Op.Parser.parse(raw_program)

    DynamicSupervisor.start_child(
      Daemon.SessionSupervisor,
      {Daemon.Session, %{id: id}}
    )

    Daemon.Session.run(id, program, message)
    send_resp(conn, 200, Jason.encode!(%{status: "ok"}))
  end

  get "/sessions/:id/events" do
    Logger.info("session=#{id} SSE stream opened")
    Daemon.HTTP.EventStream.call(conn, id)
  end

  post "/sessions/:id/resume" do
    %{"interrupt_id" => interrupt_id, "reply" => reply} = conn.body_params
    Logger.info("session=#{id} resume interrupt_id=#{interrupt_id}")
    Daemon.Session.resume(id, interrupt_id, reply)
    send_resp(conn, 200, Jason.encode!(%{status: "ok"}))
  end

  match _ do
    Logger.warning("404 #{conn.method} #{conn.request_path}")
    send_resp(conn, 404, "not found")
  end
end
