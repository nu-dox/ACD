defmodule Daemon.LLM.Provider do
  @callback complete(plan :: map(), messages :: list()) ::
              {:ok, %{finish_reason: atom(), content: String.t(), tool_calls: list()}}
              | {:error, any()}

  @callback stream(plan :: map(), messages :: list(), on_chunk :: (String.t() -> any())) ::
              {:ok, %{finish_reason: atom(), content: String.t(), tool_calls: list()}}
              | {:error, any()}
end
