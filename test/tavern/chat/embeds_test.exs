defmodule Tavern.Chat.EmbedsTest do
  @moduledoc """
  A message's links get embeds from a background fetch after the write commits. The author's
  `embed_links` is decided when the fetch completes; a suppressed link, a removed embed and a
  deleted message keep none.
  """
  use Tavern.DataCase, async: false

  import Tavern.ChatFixtures
  import Tavern.EmbedTestHelpers

  alias Tavern.Bootstrap
  alias Tavern.Chat
  alias Tavern.Chat.MediaAsset
  alias Tavern.Chat.MediaAssets
  alias Tavern.Chat.PermissionBits
  alias Tavern.Chat.Topics
  alias Tavern.ObjectStore

  setup do
    Bootstrap.ensure_seed_data!()
    stub_link_previews(self())

    author = user_fixture()
    channel = channel_fixture(%{name: "Links"})
    Topics.sync_channel_subscriptions(MapSet.new(), MapSet.new([channel.id]))

    %{author: author, channel: channel}
  end

  test "a link gets an embed with its image copied into the store", ctx do
    message = message_fixture(ctx.channel, ctx.author, %{body: "read https://site.test/a"})
    assert message.embeds == []

    assert_receive {:message_updated, %{id: id, embeds: [embed]}}, 5_000
    assert id == message.id

    assert %{kind: :link, title: "Page A", description: "About a.", site_name: "site.test"} =
             embed

    assert {:ok, png_bytes, "image/png"} = MediaAssets.fetch_upload(embed.image_asset.storage_key)
    assert png_bytes == png()

    read = Chat.get_message(scope_for(ctx.author), message.id)
    assert [%{url: "https://site.test/a"}] = read.embeds

    image_url = "/uploads/" <> embed.image_asset.storage_key

    assert [%{kind: "link", title: "Page A", image_url: ^image_url}] =
             Tavern.Bots.serialize_message(read).embeds
  end

  test "a YouTube link gets a video embed", ctx do
    message_fixture(ctx.channel, ctx.author, %{body: "https://youtu.be/dQw4w9WgXcQ"})

    assert_receive {:message_updated, %{embeds: [embed]}}, 5_000

    assert %{kind: :video, provider: "youtube", video_id: "dQw4w9WgXcQ", title: "A video"} =
             embed

    assert embed.image_asset
  end

  test "a link in angle brackets starts no fetch", ctx do
    message_fixture(ctx.channel, ctx.author, %{body: "quiet <https://site.test/a>"})

    assert Task.Supervisor.children(Tavern.Embeds.TaskSupervisor) == []
    refute_received {:embed_request, _, _}
  end

  test "without embed_links in the channel, the fetch stores nothing", ctx do
    deny_embed_links(ctx.channel)

    message = message_fixture(ctx.channel, ctx.author, %{body: "https://site.test/a"})
    await_embed_fetches()

    refute_received {:message_updated, _}
    assert Chat.get_message(scope_for(ctx.author), message.id).embeds == []
    assert embed_asset_count() == 0
  end

  test "embed_links is decided when the fetch completes, not when the message is sent", ctx do
    hold_fetches()
    message = message_fixture(ctx.channel, ctx.author, %{body: "https://site.test/a"})
    assert_receive {:fetching, fetcher}, 5_000

    deny_embed_links(ctx.channel)
    send(fetcher, :continue)
    await_embed_fetches()

    assert Chat.get_message(scope_for(ctx.author), message.id).embeds == []
  end

  test "an edit fetches only the links it added and drops the ones it removed", ctx do
    message =
      message_fixture(ctx.channel, ctx.author, %{body: "https://site.test/a"})

    assert_receive {:message_updated, %{embeds: [%{image_asset: %{storage_key: a_key}}]}}, 5_000
    assert_received {:embed_request, "site.test", "/a"}

    {:ok, edited} =
      Chat.update_message(scope_for(ctx.author), message.id, %{
        body: "https://site.test/b then https://site.test/a"
      })

    assert [%{url: "https://site.test/a", position: 1}] = edited.embeds

    assert_receive {:message_updated, %{embeds: embeds}}, 5_000
    assert Enum.map(embeds, &{&1.position, &1.title}) == [{0, "Page B"}, {1, "Page A"}]
    assert_received {:embed_request, "site.test", "/b"}
    refute_received {:embed_request, "site.test", "/a"}

    {:ok, edited} =
      Chat.update_message(scope_for(ctx.author), message.id, %{body: "only https://site.test/b"})

    assert [%{title: "Page B", position: 0}] = edited.embeds
    assert ObjectStore.get(a_key) == {:error, :not_found}
    assert Task.Supervisor.children(Tavern.Embeds.TaskSupervisor) == []
  end

  test "the author removes the embeds, and a later edit does not bring them back", ctx do
    message = message_fixture(ctx.channel, ctx.author, %{body: "https://site.test/a"})
    assert_receive {:message_updated, %{embeds: [%{image_asset: %{storage_key: key}}]}}, 5_000

    assert {:ok, suppressed} = Chat.suppress_embeds(scope_for(ctx.author), message.id)
    assert suppressed.embeds == []
    assert suppressed.suppress_embeds
    assert ObjectStore.get(key) == {:error, :not_found}
    assert embed_asset_count() == 0

    {:ok, _edited} =
      Chat.update_message(scope_for(ctx.author), message.id, %{
        body: "https://site.test/a https://site.test/b"
      })

    assert Task.Supervisor.children(Tavern.Embeds.TaskSupervisor) == []
    assert Chat.get_message(scope_for(ctx.author), message.id).embeds == []
  end

  test "manage_messages lets another member remove the embeds; a plain member may not", ctx do
    message = message_fixture(ctx.channel, ctx.author, %{body: "https://site.test/a"})
    assert_receive {:message_updated, %{embeds: [_embed]}}, 5_000

    bystander = user_fixture()
    assert {:error, :forbidden} = Chat.suppress_embeds(scope_for(bystander), message.id)

    moderator = user_fixture()

    member_role_fixture(
      moderator,
      role_fixture(%{
        name: "Tidy",
        permissions: PermissionBits.combine([:view_channel, :manage_messages])
      })
    )

    assert {:ok, %{embeds: []}} = Chat.suppress_embeds(scope_for(moderator), message.id)
  end

  test "deleting a message deletes its embeds and their images", ctx do
    message = message_fixture(ctx.channel, ctx.author, %{body: "https://site.test/a"})
    assert_receive {:message_updated, %{embeds: [%{image_asset: %{storage_key: key}}]}}, 5_000

    assert {:ok, deleted} = Chat.delete_message(scope_for(ctx.author), message.id)
    assert deleted.embeds == []
    assert embed_asset_count() == 0
    assert ObjectStore.get(key) == {:error, :not_found}
  end

  test "a message deleted while its fetch runs keeps no embed or image", ctx do
    hold_fetches()
    message = message_fixture(ctx.channel, ctx.author, %{body: "https://site.test/a"})
    assert_receive {:fetching, fetcher}, 5_000

    {:ok, _deleted} = Chat.delete_message(scope_for(ctx.author), message.id)
    send(fetcher, :continue)
    await_embed_fetches()

    assert Repo.aggregate(Tavern.Chat.MessageEmbed, :count) == 0
  end

  # Each fetch reports `{:fetching, pid}` and waits for `:continue`, so a test can change
  # state while the fetch is in flight.
  defp hold_fetches do
    test_pid = self()

    Req.Test.stub(Tavern.Embeds.SafeHTTP, fn conn ->
      send(test_pid, {:fetching, self()})

      receive do
        :continue -> Req.Test.html(conn, ~s(<meta property="og:title" content="Late">))
      end
    end)
  end

  defp deny_embed_links(channel) do
    channel_permission_overwrite_fixture(channel, %{
      role_id: Chat.default_role().id,
      deny_permissions: PermissionBits.combine([:embed_links])
    })
  end

  defp embed_asset_count do
    Repo.aggregate(from(asset in MediaAsset, where: asset.kind == :embed), :count)
  end
end
