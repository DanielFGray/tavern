defmodule TavernWeb.ServerLiveChannelEditorTest do
  @moduledoc "The sidebar's channel edit mode (docs/design/channel-management.md)."
  use TavernWeb.ConnCase, async: false

  import Phoenix.LiveViewTest
  import Tavern.ChatFixtures
  import TavernWeb.ServerLiveFixtures

  alias Tavern.Bootstrap
  alias Tavern.Chat
  alias Tavern.Chat.Channel
  alias Tavern.Repo

  setup %{conn: conn} do
    Bootstrap.ensure_seed_data!()
    %{conn: log_in_owner_user(conn)}
  end

  defp edit_mode(conn) do
    {:ok, view, _html} = live_hydrated(conn, ~p"/")
    view |> element("#toggle-channel-edit") |> render_click()
    view
  end

  test "a member without manage_channels sees no pencil and no topic field", %{conn: conn} do
    {:ok, view, _html} = live_hydrated(log_in_member_user(conn, "editor"), ~p"/")

    refute has_element?(view, "#toggle-channel-edit")
    refute has_element?(view, "#channel-topic-input")
    assert has_element?(view, "#channel-topic")

    general = channel_by_slug!("general")

    for event <- ~w(toggle_channel_edit delete_channel restore_channel open_channel_settings) do
      render_hook(view, event, %{"id" => general.id})
    end

    render_hook(view, "rename_channel", %{"id" => general.id, "value" => "Taken"})
    render_hook(view, "save_topic", %{"id" => general.id, "value" => "Taken"})

    render_hook(view, "place_channel", %{"id" => general.id, "parent_id" => "", "before_id" => ""})

    render_hook(view, "open_add_channel", %{"parent" => ""})

    render_hook(view, "create_channel", %{
      "new_channel" => %{"name" => "Sneaky", "kind" => "text"}
    })

    render_hook(view, "create_category", %{"new_category" => %{"name" => "Sneakier"}})

    refute has_element?(view, "#channel-edit-list")
    stored = Repo.get!(Channel, general.id)
    assert stored.deleted_at == nil

    assert {stored.name, stored.topic, stored.position} ==
             {general.name, general.topic, general.position}

    refute Repo.get_by(Channel, slug: "sneaky")
    refute Repo.get_by(Channel, slug: "sneakier")
  end

  test "the pencil switches the list into edit mode and Done leaves it", %{conn: conn} do
    view = edit_mode(conn)
    general = channel_by_slug!("general")

    assert has_element?(view, "#channel-edit-list")
    assert has_element?(view, "#drag-channel-#{general.id}")
    assert has_element?(view, "#rename-channel-#{general.id}")
    assert has_element?(view, "#add-channel-top")
    assert has_element?(view, "#add-category")
    refute has_element?(view, "#channel-link-general")

    view |> element("#toggle-channel-edit") |> render_click()

    refute has_element?(view, "#channel-edit-list")
    assert has_element?(view, "#channel-link-general")
  end

  test "an inline rename saves the name and keeps the slug", %{conn: conn} do
    view = edit_mode(conn)
    general = channel_by_slug!("general")

    assert render_hook(view, "rename_channel", %{"id" => general.id, "value" => "Lobby"})
    assert Repo.get!(Channel, general.id).name == "Lobby"
    assert Repo.get!(Channel, general.id).slug == "general"
    assert has_element?(view, "#rename-channel-#{general.id}[value=Lobby]")
  end

  test "+ add channel creates a channel of the chosen kind in its section", %{conn: conn} do
    view = edit_mode(conn)
    view |> element("#add-channel-top") |> render_click()

    view
    |> form("#new-channel-form", %{new_channel: %{name: "Show and tell", kind: "forum"}})
    |> render_submit()

    channel = channel_by_slug!("show-and-tell")
    assert channel.kind == :forum
    assert channel.parent_channel_id == nil
    assert has_element?(view, "#edit-channel-#{channel.id}")
    refute has_element?(view, "#new-channel-form")
    refute has_element?(view, "#new-channel-form option[value=voice]")
  end

  test "+ add category adds an empty category with its own + add channel", %{conn: conn} do
    view = edit_mode(conn)
    view |> element("#add-category") |> render_click()

    view
    |> form("#new-category-form", %{new_category: %{name: "Projects"}})
    |> render_submit()

    category = channel_by_slug!("projects")
    assert category.kind == :category
    assert has_element?(view, "#edit-section-#{category.id}")
    assert has_element?(view, "#add-channel-#{category.id}")
  end

  test "the ⚙ popover saves the topic and age gate, and deletes", %{conn: conn} do
    view = edit_mode(conn)
    general = channel_by_slug!("general")

    view |> element("#channel-settings-#{general.id}") |> render_click()
    assert has_element?(view, "#channel-settings-popover[data-anchor=edit-channel-#{general.id}]")

    view
    |> form("#channel-settings-form", %{
      channel_settings: %{name: "General", topic: "Say hi", nsfw: "true"}
    })
    |> render_submit()

    saved = Repo.get!(Channel, general.id)
    assert saved.topic == "Say hi"
    assert saved.nsfw

    view |> element("#channel-settings-delete") |> render_click()

    # The deleted channel was the open one, so the view moves to the first remaining channel.
    assert_patch(view, ~p"/?channel=engineering")
    refute has_element?(view, "#channel-topic-input[data-id=\"#{general.id}\"]")
    assert has_element?(view, "#channel-edit-list")
    refute has_element?(view, "#channel-settings-popover")
    refute has_element?(view, "#edit-channel-#{general.id}")
    assert has_element?(view, "#deleted-channel-#{general.id}")
  end

  test "🗑 deletes at once and Restore brings the channel back", %{conn: conn} do
    view = edit_mode(conn)
    engineering = channel_by_slug!("engineering")

    view |> element("#delete-channel-#{engineering.id}") |> render_click()

    refute has_element?(view, "#edit-channel-#{engineering.id}")
    assert has_element?(view, "#deleted-channel-#{engineering.id}")

    view |> element("#restore-channel-#{engineering.id}") |> render_click()

    assert has_element?(view, "#edit-channel-#{engineering.id}")
    refute has_element?(view, "#deleted-channels")
  end

  test "another member viewing a deleted channel moves to the first remaining one", %{conn: conn} do
    owner = current_user_from_conn(conn)
    random = channel_by_slug!("random")

    {:ok, view, _html} =
      live_hydrated(log_in_member_user(build_conn(), "viewer"), ~p"/?channel=random")

    {:ok, _} = Chat.delete_channel(scope_for(owner), random.id)

    assert_patch(view, ~p"/?channel=general")
    refute has_element?(view, "#channel-link-random")
  end

  test "a drop places the channel in the section it lands in", %{conn: conn} do
    view = edit_mode(conn)

    {:ok, category} =
      Chat.create_channel(scope_for(current_user_from_conn(conn)), %{
        "name" => "Box",
        "kind" => "category"
      })

    general = channel_by_slug!("general")

    render_hook(view, "place_channel", %{
      "id" => general.id,
      "parent_id" => category.id,
      "before_id" => ""
    })

    assert Repo.get!(Channel, general.id).parent_channel_id == category.id
    assert has_element?(view, "#edit-section-#{category.id} #edit-channel-#{general.id}")
  end

  test "the channel header's topic saves in place", %{conn: conn} do
    {:ok, view, _html} = live_hydrated(conn, ~p"/?channel=general")
    general = channel_by_slug!("general")

    assert has_element?(view, "#channel-topic-input")
    render_hook(view, "save_topic", %{"id" => general.id, "value" => "Fresh topic"})

    assert Repo.get!(Channel, general.id).topic == "Fresh topic"
  end
end
