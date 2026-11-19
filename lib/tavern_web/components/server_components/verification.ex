defmodule TavernWeb.ServerComponents.Verification do
  @moduledoc """
  What a member who holds the Unverified role sees: the banner that names the address to check,
  with a resend button, and the notice the composer shows in place of the form.
  """

  use TavernWeb, :html

  alias Tavern.Accounts

  attr :user, :map, required: true

  @doc "The banner above the channel, shown only while the member holds the Unverified role."
  def banner(assigns) do
    ~H"""
    <div
      :if={Accounts.unverified?(@user)}
      id="verification-banner"
      role="status"
      class="flex flex-wrap items-center gap-x-3 gap-y-1 border-b border-amber-500/25 bg-amber-500/10 px-4 py-2 text-sm text-base-content"
    >
      <.icon name="hero-envelope" class="size-4 shrink-0 text-amber-500" />
      <p class="min-w-0 flex-1">
        Check <span class="font-semibold break-all">{@user.email}</span> to verify your account.
      </p>
      <button
        type="button"
        id="resend-verification"
        phx-click="resend_verification"
        phx-disable-with="Sending…"
        class="rounded-md px-2 py-1 text-xs font-semibold text-amber-600 transition hover:bg-amber-500/15 active:scale-[0.98] dark:text-amber-300"
      >
        Resend
      </button>
    </div>
    """
  end

  attr :user, :map, required: true
  attr :id, :string, required: true

  @doc """
  The notice in place of a composer the member cannot use. It names email verification as the
  reason when the member holds the Unverified role, since that is the restriction they can lift.
  """
  def send_notice(assigns) do
    ~H"""
    <div
      id={@id}
      class="rounded-lg border border-amber-500/30 bg-amber-500/10 px-4 py-3 text-sm text-base-content"
    >
      <%= if Accounts.unverified?(@user) do %>
        <span class="font-semibold">Verify your email to send messages.</span>
        We sent a link to <span class="break-all">{@user.email}</span>.
      <% else %>
        You can view this channel, but you do not have permission to send messages here.
      <% end %>
    </div>
    """
  end
end
