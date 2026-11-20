defmodule Tavern.UploadFixtures do
  @moduledoc """
  Uploaded files as a LiveView upload hands them to the context: `%{path:, client_name:,
  client_type:}`, with the bytes written to a temporary file.
  """

  @doc """
  A PNG upload whose bytes are unique to this call, so a test can find its object in
  `Tavern.TestObjectStore` by the bytes. Returns the upload with its bytes under `:body`.
  """
  def png_upload(client_name \\ "image.png") do
    upload(client_name, "image/png", unique_png())
  end

  @doc "An upload of `body` that claims to be `client_type`."
  def upload(client_name, client_type, body) do
    path =
      Path.join(System.tmp_dir!(), "tavern-upload-#{System.unique_integer([:positive])}")

    File.write!(path, body)
    ExUnit.Callbacks.on_exit(fn -> File.rm(path) end)
    %{path: path, client_name: client_name, client_type: client_type, body: body}
  end

  @doc "PNG magic bytes followed by a unique tail."
  def unique_png do
    <<0x89, "PNG\r\n", 0x1A, "\n", "#{System.unique_integer([:positive])}">>
  end

  @doc "Whether the test bucket holds an object with exactly `body`."
  def stored?(body) do
    Tavern.TestObjectStore.objects() |> Map.values() |> Enum.any?(&match?({^body, _type}, &1))
  end
end
