defmodule Daemon.LLM.Provider do
  @callback complete(plan :: map(), messages :: list()) ::
              {:ok, %{finish_reason: atom(), content: String.t(), tool_calls: list()}}
              | {:error, any()}
end
