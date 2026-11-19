defmodule Tavern.Bootstrap do
  @moduledoc """
  Bootstrap helpers for provisioning a fresh single-server tavern instance.
  """

  alias Tavern.Accounts
  alias Tavern.Chat.Channel
  alias Tavern.Chat.Message
  alias Tavern.Chat.PermissionBits
  alias Tavern.Chat.Role
  alias Tavern.Chat.ServerSettings
  alias Tavern.Chat.User
  alias Tavern.Repo

  @default_seed_username "tavern_system"
  @default_seed_display_name "Tavern System"
  @default_seed_permissions [
    :view_channel,
    :send_messages,
    :create_public_threads,
    :send_messages_in_threads,
    :embed_links,
    :attach_files,
    :add_reactions
  ]

  # The Unverified role starts read only: it denies every bit that lets a member write something
  # other members see. A deny removes only what @everyone allows, and any other held role's allow
  # restores it. Invites need `manage_server`, which @everyone does not allow, so there is no
  # invite bit to deny.
  @unverified_denied_permissions [
    :send_messages,
    :send_messages_in_threads,
    :create_public_threads,
    :create_private_threads,
    :attach_files,
    :add_reactions,
    :mention_everyone
  ]
  @unverified_description "Held by every member who has not confirmed their email."

  def ensure_seed_data! do
    Repo.transaction(fn ->
      user =
        ensure_system_user!()

      default_role = ensure_default_role!()
      unverified_role = ensure_unverified_role!()

      channels =
        [
          %{name: "General", slug: "general", position: 0, topic: "Default lobby for the server"},
          %{
            name: "Engineering",
            slug: "engineering",
            position: 1,
            topic: "Build notes and technical chatter"
          },
          %{name: "Random", slug: "random", position: 2, topic: "Off-topic but still useful"}
        ]
        |> Enum.map(&ensure_channel!/1)

      general_channel = Enum.find(channels, &(&1.slug == "general"))

      ensure_welcome_message!(general_channel, user)
      ensure_server_settings!()
      Accounts.ensure_first_owner!()

      %{
        system_user: user,
        default_role: default_role,
        unverified_role: unverified_role,
        channels: channels
      }
    end)
    |> case do
      {:ok, result} -> result
      {:error, _step, reason, _changes} -> raise reason
    end
  end

  defp ensure_system_user! do
    now = DateTime.utc_now()

    %User{bot: true, system: true}
    |> User.account_changeset(%{
      email: "system@tavern.local",
      username: @default_seed_username,
      display_name: @default_seed_display_name,
      bio: "System actor for bootstrap and service messages."
    })
    |> Repo.insert!(
      on_conflict: [
        set: [
          username: @default_seed_username,
          display_name: @default_seed_display_name,
          bot: true,
          system: true,
          bio: "System actor for bootstrap and service messages.",
          updated_at: now
        ]
      ],
      conflict_target: :email,
      returning: true
    )
  end

  defp ensure_default_role! do
    ensure_system_role!(
      :is_default,
      %{name: "@everyone", description: "Default permissions for all members."},
      %{permissions: PermissionBits.combine(@default_seed_permissions)}
    )
  end

  defp ensure_unverified_role! do
    ensure_system_role!(
      :is_unverified,
      %{name: "Unverified", description: @unverified_description},
      %{permissions: 0, deny_permissions: PermissionBits.combine(@unverified_denied_permissions)}
    )
  end

  # Upserts the one role that has `flag` set. Both system roles sit at position 0, below every
  # ranked role. A deploy rewrites the fixed fields, but writes `bits` only when it creates the
  # row, so a manager's permission edits survive deploys.
  defp ensure_system_role!(flag, fixed, bits) do
    fixed =
      Map.merge(fixed, %{position: 0, mentionable: false, hoist: false, managed: true})

    %Role{}
    |> Role.changeset(fixed |> Map.merge(bits) |> Map.put(flag, true))
    |> Repo.insert!(
      on_conflict: [set: Map.to_list(fixed) ++ [updated_at: DateTime.utc_now()]],
      conflict_target: {:unsafe_fragment, "(#{flag}) WHERE #{flag} = true"},
      returning: true
    )
  end

  defp ensure_channel!(attrs) do
    now = DateTime.utc_now()

    %Channel{}
    |> Channel.changeset(attrs)
    |> Repo.insert!(
      on_conflict: [
        set: [
          name: attrs.name,
          position: attrs.position,
          topic: attrs.topic,
          updated_at: now
        ]
      ],
      # Only a live channel holds its slug (the partial index `channels_live_slug_index`).
      conflict_target: {:unsafe_fragment, "(slug) WHERE deleted_at IS NULL"},
      returning: true
    )
  end

  defp ensure_welcome_message!(channel, user) do
    %Message{
      channel_id: channel.id,
      author_id: user.id,
      kind: :system,
      nonce: "bootstrap:welcome"
    }
    |> Message.changeset(%{
      body: "Welcome to Tavern. Register the first account to become this server's owner."
    })
    |> Repo.insert!(
      on_conflict: :nothing,
      conflict_target: {:unsafe_fragment, "(channel_id, nonce) WHERE nonce IS NOT NULL"}
    )
  end

  defp ensure_server_settings! do
    now = DateTime.utc_now()

    %ServerSettings{}
    |> ServerSettings.changeset(%{
      singleton: true,
      name: Application.get_env(:tavern, :server_name, "Tavern")
    })
    |> Repo.insert!(
      on_conflict: [
        set: [
          name: Application.get_env(:tavern, :server_name, "Tavern"),
          updated_at: now
        ]
      ],
      conflict_target: :singleton,
      returning: true
    )
  end
end
