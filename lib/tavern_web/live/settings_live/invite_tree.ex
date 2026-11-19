defmodule TavernWeb.SettingsLive.InviteTree do
  @moduledoc """
  The Invite tree tab of SettingsLive: who invited whom. The tab loads one level at a time, as the
  viewer expands a member. `Chat` decides what each scope may see; a level it refuses stays
  empty.

  The loaded levels live in `:tree_children`, a map from a parent's user id (or `:roots`) to its
  nodes. A stream cannot hold a nested list, so the tree is a plain assign; it grows only by the
  levels the viewer opens.
  """

  import Phoenix.Component, only: [assign: 3, to_form: 2]

  alias Tavern.Chat

  @events ~w(toggle_invite_node search_invite_tree jump_invite_node)

  def events, do: @events

  def init(socket) do
    socket
    |> assign(:tree_children, %{})
    |> assign(:tree_expanded, MapSet.new())
    |> assign(:tree_highlight, nil)
    |> assign(:tree_results, nil)
    |> assign(:tree_form, to_form(%{"q" => ""}, as: :tree))
  end

  @doc "Reads the top level and closes every branch. Called when the tab opens."
  def load(socket) do
    socket
    |> init()
    |> load_level(:roots)
  end

  def handle_event("toggle_invite_node", %{"user_id" => user_id}, socket) do
    expanded = socket.assigns.tree_expanded

    if MapSet.member?(expanded, user_id) do
      {:noreply, assign(socket, :tree_expanded, MapSet.delete(expanded, user_id))}
    else
      {:noreply, socket |> expand(user_id) |> assign(:tree_highlight, nil)}
    end
  end

  def handle_event("search_invite_tree", %{"tree" => %{"q" => query}}, socket) do
    results =
      case Chat.invite_tree_search(socket.assigns.current_scope, query) do
        {:ok, nodes} -> if String.trim(query) == "", do: nil, else: nodes
        {:error, _reason} -> nil
      end

    {:noreply,
     socket
     |> assign(:tree_form, to_form(%{"q" => query}, as: :tree))
     |> assign(:tree_results, results)}
  end

  # Opens every branch above the member, so the row is on screen, and marks it.
  def handle_event("jump_invite_node", %{"user_id" => user_id}, socket) do
    case Chat.invite_tree_path_to(socket.assigns.current_scope, user_id) do
      {:ok, chain} ->
        {ancestors, [target]} = Enum.split(chain, -1)

        {:noreply,
         ancestors
         |> Enum.reduce(socket, &expand(&2, &1))
         |> assign(:tree_highlight, target)
         |> assign(:tree_results, nil)
         |> assign(:tree_form, to_form(%{"q" => ""}, as: :tree))}

      {:error, _reason} ->
        {:noreply, socket}
    end
  end

  defp expand(socket, user_id) do
    socket
    |> load_level(user_id)
    |> assign(:tree_expanded, MapSet.put(socket.assigns.tree_expanded, user_id))
  end

  defp load_level(socket, parent) do
    case Chat.invite_tree_children(socket.assigns.current_scope, parent) do
      {:ok, nodes} ->
        assign(socket, :tree_children, Map.put(socket.assigns.tree_children, parent, nodes))

      {:error, _reason} ->
        socket
    end
  end
end
