defmodule Tavern.Chat.MessageTest do
  use ExUnit.Case, async: true

  alias Tavern.Chat.Message

  # The entity list is what `Tavern.Chat.Messages` keeps, so the bounds are tested on it.
  defp metadata_with_label(label_length) do
    %{"entities" => [%{"type" => "mention", "label" => String.duplicate("a", label_length)}]}
  end

  defp metadata_bytes(metadata), do: metadata |> Jason.encode!() |> byte_size()

  defp metadata_errors(metadata) do
    changeset = Message.changeset(%Message{}, %{body: "hello", metadata: metadata})
    Keyword.get_values(changeset.errors, :metadata)
  end

  test "metadata of exactly 16,384 encoded bytes is accepted" do
    base = metadata_bytes(metadata_with_label(0))
    at_limit = metadata_with_label(16_384 - base)

    assert metadata_bytes(at_limit) == 16_384
    assert metadata_errors(at_limit) == []
  end

  test "metadata one byte over 16,384 encoded bytes is refused" do
    base = metadata_bytes(metadata_with_label(0))
    over_limit = metadata_with_label(16_384 - base + 1)

    assert metadata_bytes(over_limit) == 16_385

    assert [{"is larger than %{max} bytes encoded", [max: 16_384]}] =
             metadata_errors(over_limit)
  end

  test "an entity list of the composer's shape is within the depth limit" do
    # Root map, entities array, entity object: three levels.
    assert metadata_errors(%{"entities" => [%{"type" => "mention", "id" => "x"}]}) == []
  end

  test "metadata nested deeper than three levels is refused" do
    deep = %{"entities" => [%{"type" => "mention", "label" => %{"nested" => "value"}}]}

    assert [{"nests deeper than %{max} levels", [max: 3]}] = metadata_errors(deep)
  end

  test "an edit that does not send metadata keeps the stored metadata unchecked" do
    stored = metadata_with_label(20_000)

    changeset = Message.changeset(%Message{metadata: stored}, %{body: "edited"})

    assert changeset.valid?
  end
end
