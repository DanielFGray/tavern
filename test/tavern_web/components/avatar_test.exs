defmodule TavernWeb.AvatarTest do
  use Tavern.DataCase, async: false

  import Phoenix.Component, only: [sigil_H: 2]
  import Phoenix.LiveViewTest
  import Tavern.ChatFixtures

  alias Tavern.Accounts
  alias Tavern.Chat
  alias Tavern.Chat.MediaAsset
  alias Tavern.UploadFixtures
  alias TavernWeb.CoreComponents

  setup do
    Tavern.Bootstrap.ensure_seed_data!()
    :ok
  end

  describe "avatar/1" do
    test "shows the image when the asset is loaded" do
      user = %{display_name: "Ada", avatar_asset: %MediaAsset{storage_key: "avatars/a.png"}}
      assigns = %{user: user}

      html = rendered_to_string(~H'<CoreComponents.avatar user={@user} id="av" />')

      assert html =~ ~s(src="/uploads/avatars/a.png")
      assert html =~ ~s(id="av")
    end

    test "shows the first letter without an asset, or when it is not loaded" do
      for user <- [
            %{display_name: "ada", avatar_asset: nil},
            %{display_name: "ada", avatar_asset: %Ecto.Association.NotLoaded{}}
          ] do
        assigns = %{user: user}
        html = rendered_to_string(~H"<CoreComponents.avatar user={@user} />")

        refute html =~ "<img"
        assert html =~ "ada" |> String.first()
      end
    end
  end

  describe "preloads" do
    setup do
      user = user_fixture()

      {:ok, user} =
        Accounts.update_profile_user(user, %{}, {:replace, UploadFixtures.png_upload()})

      %{user: user, channel: channel_fixture()}
    end

    test "a channel's messages carry their author's avatar asset", ctx do
      message_fixture(ctx.channel, ctx.user, %{body: "hello"})

      assert {:ok, [message]} = Chat.list_messages(scope_for(ctx.user), ctx.channel.id)
      assert %MediaAsset{} = message.author.avatar_asset
    end

    test "the member list carries each member's avatar asset", ctx do
      entry = Enum.find(Accounts.list_members(scope_for(ctx.user)), &(&1.user.id == ctx.user.id))
      assert %MediaAsset{} = entry.user.avatar_asset
    end
  end
end
