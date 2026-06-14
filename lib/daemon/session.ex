defmodule Daemon.Session do
  use GenServer
  require Logger

  defstruct [:id, :parent_id, messages: [], status: :idle, run_task_pid: nil]

  # public API

  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts, name: via(opts.id))
  end

  def run(session_id, program, message) do
    GenServer.call(via(session_id), {:run, program, message}, :infinity)
  end

  def resume(session_id, interrupt_id, reply) do
    GenServer.cast(via(session_id), {:resume, interrupt_id, reply})
  end

  def cancel(session_id) do
    GenServer.cast(via(session_id), :cancel)
  end

  # server callbacks

  def init(opts) do
    Logger.info("session=#{opts.id} started parent=#{inspect(opts[:parent_id])}")
    {:ok, struct(__MODULE__, opts)}
  end

  def handle_call({:run, _, _}, _from, %{status: :busy} = state) do
    Logger.warning("session=#{state.id} run rejected — already busy")
    {:reply, {:error, :busy}, state}
  end

  def handle_call({:run, program, message}, _from, state) do
    Logger.info("session=#{state.id} run starting")

    task =
      Task.async(fn ->
        Daemon.Session.Loop.run(state.id, program, state.messages, message)
      end)

    {:reply, :ok, %{state | status: :busy, run_task_pid: task.pid}}
  end

  def handle_info({ref, result}, state) do
    Process.demonitor(ref, [:flush])
    Logger.info("session=#{state.id} run completed")

    {:noreply,
     %{state | status: :idle, run_task_pid: nil}
     |> append_messages(result)}
  end

  def handle_info({:DOWN, _ref, :process, _pid, :normal}, state) do
    {:noreply, %{state | status: :idle, run_task_pid: nil}}
  end

  def handle_info({:DOWN, _ref, :process, _pid, reason}, state) do
    Logger.error("session=#{state.id} task crashed reason=#{inspect(reason)}")
    broadcast(state.id, %{type: :finished, content: "Task crashed: #{inspect(reason)}"})
    {:noreply, %{state | status: :idle, run_task_pid: nil}}
  end

  def handle_cast({:resume, interrupt_id, reply}, state) do
    if state.run_task_pid do
      Logger.info("session=#{state.id} resuming interrupt_id=#{interrupt_id}")
      send(state.run_task_pid, {:intervention_reply, interrupt_id, reply})
    else
      Logger.warning("session=#{state.id} resume received but no task running interrupt_id=#{interrupt_id}")
    end

    {:noreply, state}
  end

  def handle_cast(:cancel, state) do
    Logger.info("session=#{state.id} cancelled")

    if state.run_task_pid do
      Process.exit(state.run_task_pid, :kill)
    end

    broadcast(state.id, %{type: :cancelled})
    {:noreply, %{state | status: :idle, run_task_pid: nil}}
  end

  # helpers

  defp via(id), do: {:via, Registry, {Daemon.SessionRegistry, id}}

  defp broadcast(session_id, event) do
    Phoenix.PubSub.broadcast(Daemon.PubSub, "session:#{session_id}", event)
  end

  defp append_messages(state, {:ok, messages}), do: %{state | messages: messages}
  defp append_messages(state, _), do: state
end
