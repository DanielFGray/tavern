defmodule TavernWeb.SettingsComponents.InviteTree do
  @moduledoc false

  use TavernWeb, :html

  alias Tavern.Chat

  def invite_tree_panel(assigns) do
    ~H"""
    <div id="settings-view-invites-tree" class="mt-5">
      <p class="text-[11px] font-bold uppercase tracking-[0.18em] text-base-content/50">
        Invite tree
      </p>
      <h3 class="mt-1 text-base font-semibold text-base-content">Who invited whom</h3>
      <p class="mt-1 text-sm text-base-content/60">
        <%= if @can_view_audit_log? or @can_manage_server? do %>
          Everyone who joined, under the member whose invite brought them in.
        <% else %>
          The member who invited you, you, and everyone who joined through you.
        <% end %>
      </p>

      <.form
        for={@tree_form}
        id="invite-tree-search-form"
        phx-change="search_invite_tree"
        phx-submit="search_invite_tree"
        class="mt-5"
      >
        <.input
          field={@tree_form[:q]}
          id="invite-tree-search"
          type="search"
          label="Find a member"
          placeholder="Username or name"
          autocomplete="off"
          phx-debounce="250"
        />
      </.form>

      <ul
        :if={@tree_results}
        id="invite-tree-results"
        class="mb-4 divide-y divide-base-300 rounded-xl border border-base-300 bg-base-200"
      >
        <li
          :if={@tree_results == []}
          id="invite-tree-no-results"
          class="p-3 text-sm text-base-content/60"
        >
          No member matches.
        </li>
        <li :for={node <- @tree_results} id={"invite-tree-result-#{node.user.id}"}>
          <button
            type="button"
            phx-click="jump_invite_node"
            phx-value-user_id={node.user.id}
            class="flex w-full items-center gap-3 p-3 text-left transition hover:bg-base-300"
          >
            <.tree_avatar user={node.user} />
            <span class="min-w-0 break-words text-sm text-base-content">
              {node.user.display_name}
              <span class="text-base-content/50">@{node.user.username}</span>
            </span>
          </button>
        </li>
      </ul>

      <% roots = Map.get(@tree_children, :roots, []) %>
      <p
        :if={roots == []}
        id="invite-tree-empty"
        class="mt-4 rounded-xl border border-dashed border-base-300 p-6 text-center text-sm text-base-content/50"
      >
        No members to show yet.
      </p>
      <.tree_level
        :if={roots != []}
        id="invite-tree"
        nodes={roots}
        tree_children={@tree_children}
        expanded={@tree_expanded}
        highlight={@tree_highlight}
        root?
      />
    </div>
    """
  end

  attr :id, :string, default: nil
  attr :nodes, :list, required: true
  attr :tree_children, :map, required: true
  attr :expanded, :any, required: true
  attr :highlight, :string, default: nil
  attr :root?, :boolean, default: false

  defp tree_level(assigns) do
    ~H"""
    <ul
      id={@id}
      class={["space-y-1.5", !@root? && "ml-3 mt-1.5 border-l border-base-300 pl-3 sm:ml-5 sm:pl-4"]}
    >
      <li :for={node <- @nodes} id={"invite-node-#{node.user.id}"}>
        <div
          id={"invite-node-row-#{node.user.id}"}
          class={[
            "flex items-start gap-2 rounded-xl border p-2.5 transition sm:gap-3",
            if(@highlight == node.user.id,
              do: "border-primary bg-primary/10",
              else: "border-base-300 bg-base-200"
            )
          ]}
        >
          <%= if node.child_count > 0 do %>
            <button
              id={"invite-toggle-#{node.user.id}"}
              type="button"
              phx-click="toggle_invite_node"
              phx-value-user_id={node.user.id}
              aria-expanded={to_string(MapSet.member?(@expanded, node.user.id))}
              aria-label={"Show who #{node.user.username} invited"}
              class="mt-0.5 inline-flex size-8 shrink-0 items-center justify-center rounded-lg text-base-content/70 transition hover:bg-base-300"
            >
              <.icon
                name={
                  if MapSet.member?(@expanded, node.user.id),
                    do: "hero-chevron-down",
                    else: "hero-chevron-right"
                }
                class="size-4"
              />
            </button>
          <% else %>
            <span class="size-8 shrink-0" aria-hidden="true"></span>
          <% end %>
          <.tree_avatar user={node.user} />
          <div class="min-w-0 flex-1">
            <div class="flex flex-wrap items-center gap-x-2 gap-y-0.5">
              <span class="break-words text-sm font-semibold text-base-content">
                {node.user.display_name}
              </span>
              <span class="break-all text-xs text-base-content/50">@{node.user.username}</span>
              <span
                :if={node.status && node.status != :active}
                id={"invite-status-#{node.user.id}"}
                class={[
                  "rounded-full px-2 py-0.5 text-[10px] font-bold uppercase tracking-wide",
                  if(node.status == :banned,
                    do: "bg-error/15 text-error",
                    else: "bg-warning/15 text-warning"
                  )
                ]}
              >
                {node.status}
              </span>
            </div>
            <p class="mt-0.5 break-words text-xs text-base-content/60">
              {origin(node)}
            </p>
            <p
              :for={rejoin <- node.rejoins}
              class="mt-0.5 break-words text-xs text-base-content/50"
            >
              rejoined via {rejoin.code}{if rejoin.inviter, do: " from @#{rejoin.inviter.username}"}, {date(
                rejoin.used_at
              )}
            </p>
          </div>
          <span
            :if={node.child_count > 0}
            id={"invite-count-#{node.user.id}"}
            class="shrink-0 rounded-full bg-base-300 px-2 py-0.5 text-xs font-semibold tabular-nums text-base-content/70"
            title="Members invited"
          >
            {node.child_count}
          </span>
        </div>
        <.tree_level
          :if={MapSet.member?(@expanded, node.user.id) and Map.has_key?(@tree_children, node.user.id)}
          id={"invite-children-#{node.user.id}"}
          nodes={Map.fetch!(@tree_children, node.user.id)}
          tree_children={@tree_children}
          expanded={@expanded}
          highlight={@highlight}
        />
      </li>
    </ul>
    """
  end

  attr :user, :map, required: true

  defp tree_avatar(assigns) do
    ~H"""
    <%= if @user.avatar_asset do %>
      <img
        src={Chat.asset_url(@user.avatar_asset)}
        alt=""
        class="size-8 shrink-0 rounded-full object-cover"
      />
    <% else %>
      <span
        class="inline-flex size-8 shrink-0 items-center justify-center rounded-full bg-base-300 text-xs font-bold uppercase text-base-content/70"
        aria-hidden="true"
      >
        {String.first(@user.display_name || @user.username)}
      </span>
    <% end %>
    """
  end

  defp origin(%{code: nil}), do: "joined without an invite"

  defp origin(%{inviter: nil, code: code, joined_at: joined_at}),
    do: "joined via #{code}, #{date(joined_at)}"

  defp origin(%{inviter: inviter, code: code, joined_at: joined_at}),
    do: "invited by @#{inviter.username} via #{code}, #{date(joined_at)}"

  defp date(%DateTime{} = at), do: Calendar.strftime(at, "%Y-%m-%d")
end
