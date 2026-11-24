defmodule TavernWeb.ServerComponents.MessageAttachments do
  @moduledoc """
  A message's attachments under its text: images inline, each linked to the full file, and any
  other file as a card that downloads it. Every URL is `/attachments`, which serves only members
  who may view the message (`Tavern.Chat.Attachments`).
  """

  use TavernWeb, :html

  alias Tavern.Chat.Attachments

  attr :message, :map, required: true

  def message_attachments(assigns) do
    attachments = Enum.sort_by(assigns.message.attachments, & &1.position)

    assigns =
      assign(assigns,
        images: Enum.filter(attachments, &(&1.kind == :image)),
        files: Enum.reject(attachments, &(&1.kind == :image))
      )

    ~H"""
    <div
      :if={@images != [] or @files != []}
      id={"message-attachments-#{@message.id}"}
      class="mt-2 flex flex-col gap-2"
    >
      <div :if={@images != []} class="flex flex-wrap gap-2">
        <a
          :for={attachment <- @images}
          id={"attachment-#{attachment.id}"}
          href={Attachments.url(attachment)}
          target="_blank"
          rel="noopener"
          aria-label={"Open #{Attachments.filename(attachment.asset)}"}
          class="block w-fit overflow-hidden rounded-md bg-base-100 shadow-sm ring-1 ring-base-300/60 transition hover:ring-base-300 focus-visible:outline focus-visible:outline-2 focus-visible:outline-primary"
        >
          <img
            src={Attachments.url(attachment)}
            alt={attachment.description || ""}
            loading="lazy"
            class="block max-h-80 w-auto max-w-full object-contain sm:max-w-[28rem]"
          />
        </a>
      </div>
      <a
        :for={attachment <- @files}
        id={"attachment-#{attachment.id}"}
        href={Attachments.url(attachment)}
        download={Attachments.filename(attachment.asset)}
        class="group/file flex w-full max-w-[28rem] items-center gap-3 rounded-md bg-base-100 p-3 shadow-sm ring-1 ring-base-300/60 transition hover:ring-violet-400/50 focus-visible:outline focus-visible:outline-2 focus-visible:outline-primary"
      >
        <span class="flex size-10 shrink-0 items-center justify-center rounded-md bg-violet-500/10 text-violet-400">
          <.icon name="hero-document" class="size-5" />
        </span>
        <span class="min-w-0 flex-1">
          <span class="block truncate text-sm font-medium text-base-content group-hover/file:text-violet-300">
            {Attachments.filename(attachment.asset)}
          </span>
          <span class="block text-xs text-base-content/50">
            {format_bytes(attachment.asset.byte_size)}
          </span>
        </span>
        <.icon
          name="hero-arrow-down-tray"
          class="size-4 shrink-0 text-base-content/40 transition group-hover/file:text-base-content"
        />
      </a>
    </div>
    """
  end

  @doc "A byte count as a person reads it: `512 B`, `3.4 KB`, `12.0 MB`."
  def format_bytes(bytes) when bytes < 1_000, do: "#{bytes} B"
  def format_bytes(bytes) when bytes < 1_000_000, do: "#{Float.round(bytes / 1_000, 1)} KB"
  def format_bytes(bytes), do: "#{Float.round(bytes / 1_000_000, 1)} MB"
end
