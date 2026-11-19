defmodule TavernWeb.SettingsComponents.Audit do
  @moduledoc false

  use TavernWeb, :html

  alias Tavern.Chat.AuditLogLine

  def audit_tab(assigns) do
    assigns =
      assigns
      |> assign(
        :action_type_options,
        Enum.map(AuditLogLine.action_types(), &{AuditLogLine.label(&1), &1})
      )
      |> assign(:actor_options, Enum.map(assigns.audit_actors, &{"@#{&1.username}", &1.id}))

    ~H"""
    <div id="settings-view-audit">
      <p class="text-[11px] font-bold uppercase tracking-[0.18em] text-base-content/50">
        Audit log
      </p>
      <h2 class="mt-1 text-xl font-semibold text-base-content">Server audit log</h2>
      <p class="mt-1 text-sm text-base-content/60">
        Every change made by an admin, newest first. Times are UTC.
      </p>

      <.form
        for={@audit_form}
        id="audit-filter-form"
        phx-change="filter_audit"
        phx-submit="filter_audit"
        class="mt-5 grid grid-cols-1 gap-x-3 rounded-xl border border-base-300 bg-base-200 p-4 sm:grid-cols-2 lg:grid-cols-4"
      >
        <.input
          field={@audit_form[:actor_user_id]}
          id="audit-filter-actor"
          type="select"
          label="Actor"
          prompt="Anyone"
          options={@actor_options}
        />
        <.input
          field={@audit_form[:action_type]}
          id="audit-filter-action"
          type="select"
          label="Action"
          prompt="Any action"
          options={@action_type_options}
        />
        <.input field={@audit_form[:from]} id="audit-filter-from" type="date" label="From" />
        <.input field={@audit_form[:to]} id="audit-filter-to" type="date" label="To" />
      </.form>

      <ul id="audit-entries" phx-update="stream" class="mt-4 divide-y divide-base-300">
        <li
          id="audit-empty"
          class="hidden py-6 text-center text-sm text-base-content/50 only:block"
        >
          No audit entries match.
        </li>
        <li
          :for={{id, entry} <- @streams.audit_entries}
          id={id}
          class="flex flex-col gap-0.5 py-2.5 sm:flex-row sm:items-baseline sm:gap-3"
        >
          <time
            datetime={DateTime.to_iso8601(entry.inserted_at)}
            class="shrink-0 text-xs tabular-nums text-base-content/50"
          >
            {Calendar.strftime(entry.inserted_at, "%Y-%m-%d %H:%M")}
          </time>
          <span class="min-w-0 break-words text-sm text-base-content">
            {AuditLogLine.format(entry)}
          </span>
        </li>
      </ul>

      <div :if={@audit_cursor} class="mt-4 flex justify-center">
        <button
          id="audit-load-more"
          type="button"
          phx-click="load_more_audit"
          class="rounded-md border border-base-300 px-3 py-1.5 text-xs font-semibold text-base-content/80 transition hover:bg-base-200"
        >
          Load more
        </button>
      </div>
    </div>
    """
  end
end
