defmodule TavernWeb.SettingsComponents.InviteRequests do
  @moduledoc """
  The invite request parts of Settings > Server: the "Accept invite requests" setting inside
  the server settings form, and the queue for `manage_applications` holders.
  """

  use TavernWeb, :html

  attr :form, Phoenix.HTML.Form, required: true
  attr :mail_missing_settings, :list, required: true

  @doc "The setting. It is disabled, and says why, while mail is not configured."
  def accept_requests_setting(assigns) do
    ~H"""
    <div id="accept-invite-requests" class="rounded-xl border border-base-300 bg-base-100 p-3">
      <.input
        field={@form[:accept_invite_requests]}
        id="accept-invite-requests-input"
        type="checkbox"
        label="Accept invite requests (invite only: the sign-up page offers a request form)"
        disabled={@mail_missing_settings != []}
      />
      <p
        :if={@mail_missing_settings != []}
        id="accept-invite-requests-unavailable"
        class="mt-1 text-[11px] text-amber-300"
      >
        Needs mail to send approved invites. Set {Enum.join(@mail_missing_settings, ", ")} on the
        server first.
      </p>
    </div>
    """
  end

  attr :streams, :map, required: true

  @doc "The queue: pending requests first, each with its per-IP count and its delivery state."
  def queue_panel(assigns) do
    ~H"""
    <div id="invite-requests-panel" class="mt-5 rounded-xl border border-base-300 bg-base-200 p-4">
      <p class="text-[11px] font-bold uppercase tracking-[0.18em] text-base-content/50">
        Requests
      </p>
      <h3 class="mt-1 text-base font-semibold text-base-content">Invite requests</h3>
      <p class="mt-1 text-xs text-base-content/60">
        Approving mails a one-use invite link. A high count from one IP is a flood: deny them all.
      </p>

      <div id="invite-request-list" phx-update="stream" class="mt-3 space-y-2">
        <p id="invite-request-list-empty" class="hidden text-xs text-base-content/50 only:block">
          No invite requests.
        </p>
        <div
          :for={{dom_id, request} <- @streams.invite_requests}
          id={dom_id}
          class="rounded-lg border border-base-300 bg-base-100 p-3 transition hover:border-base-content/20"
        >
          <div class="flex flex-wrap items-start justify-between gap-3">
            <div class="min-w-0">
              <p class="truncate text-sm font-semibold text-base-content">
                {request.email}
                <span class={[
                  "ml-2 rounded px-1.5 py-0.5 text-[10px] font-semibold uppercase tracking-wide",
                  status_class(request.status)
                ]}>
                  {request.status}
                </span>
              </p>
              <p class="text-[11px] text-base-content/50">
                Requested {Calendar.strftime(request.requested_at, "%b %-d, %Y %H:%M")} · {ip_count_label(
                  request.ip_request_count
                )}
                <span :if={request.decided_by}>
                  · decided by {request.decided_by.display_name}
                </span>
              </p>
              <p
                :if={request.delivered_at}
                id={"invite-request-delivered-#{request.id}"}
                class="mt-1 text-[11px] text-emerald-300"
              >
                Invite sent {Calendar.strftime(request.delivered_at, "%b %-d, %H:%M")}
              </p>
              <p
                :if={request.delivery_error}
                id={"invite-request-error-#{request.id}"}
                class="mt-1 text-[11px] text-rose-300"
              >
                {request.delivery_error}
              </p>
            </div>

            <div class="flex flex-wrap items-center gap-2">
              <%= if request.status == :pending do %>
                <button
                  type="button"
                  id={"approve-invite-request-#{request.id}"}
                  phx-click="approve_invite_request"
                  phx-value-id={request.id}
                  phx-disable-with="Approving…"
                  class="rounded-md bg-emerald-500 px-3 py-1.5 text-[11px] font-semibold text-white transition hover:bg-emerald-400"
                >
                  Approve
                </button>
                <button
                  type="button"
                  id={"deny-invite-request-#{request.id}"}
                  phx-click="deny_invite_request"
                  phx-value-id={request.id}
                  class="rounded-md px-3 py-1.5 text-[11px] font-semibold text-rose-300 transition hover:bg-rose-500/10 hover:text-rose-100"
                >
                  Deny
                </button>
                <button
                  :if={request.ip_request_count > 1}
                  type="button"
                  id={"deny-invite-requests-from-ip-#{request.id}"}
                  phx-click="deny_invite_requests_from_ip"
                  phx-value-ip={request.ip_address}
                  data-confirm={"Deny every pending request from #{request.ip_address}?"}
                  class="rounded-md px-3 py-1.5 text-[11px] font-semibold text-rose-300 transition hover:bg-rose-500/10 hover:text-rose-100"
                >
                  Deny all from this IP
                </button>
              <% end %>
              <button
                :if={request.status == :approved}
                type="button"
                id={"resend-invite-request-#{request.id}"}
                phx-click="resend_invite_request"
                phx-value-id={request.id}
                phx-disable-with="Sending…"
                class="rounded-md bg-base-300 px-3 py-1.5 text-[11px] font-semibold text-base-content transition hover:bg-base-content/15"
              >
                Resend
              </button>
            </div>
          </div>
        </div>
      </div>
    </div>
    """
  end

  defp status_class(:pending), do: "bg-amber-500/15 text-amber-300"
  defp status_class(:approved), do: "bg-emerald-500/15 text-emerald-300"
  defp status_class(:denied), do: "bg-base-300 text-base-content/60"

  defp ip_count_label(1), do: "1 request from this IP"
  defp ip_count_label(count), do: "#{count} requests from this IP"
end
