defmodule Tavern.Chat.Ids do
  @moduledoc """
  Casts an id a caller supplied. A value that is not a UUID names no row, so it is `:not_found`,
  the same answer as a row that does not exist.
  """

  @spec cast(term()) :: {:ok, Ecto.UUID.t()} | {:error, :not_found}
  def cast(id) do
    case Ecto.UUID.cast(id) do
      {:ok, id} -> {:ok, id}
      :error -> {:error, :not_found}
    end
  end
end
