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

  @starting_channels [
    %{name: "General", slug: "general", position: 0, topic: "Default lobby for the server"},
    %{
      name: "Engineering",
      slug: "engineering",
      position: 1,
      topic: "Build notes and technical chatter"
    },
    %{name: "Random", slug: "random", position: 2, topic: "Off-topic but still useful"}
  ]

  @doc """
  Runs on every deploy (`Tavern.Release.migrate`). It keeps what the code relies on: the system
  user, the two system roles, and the first-owner rule. A fresh server also gets its starting
  content: the server settings, the starting channels and the welcome message. The settings
  row is created once, with the server, so its absence is what marks a fresh server; after
  that the channels and the server name belong to the server's managers, and a deploy leaves
  them alone, deleted or renamed.
  """
  def ensure_seed_data! do
    {:ok, seed} = Repo.transact(&seed/0)
    seed
  end

  defp seed do
    user = ensure_system_user!()
    default_role = ensure_default_role!()
    unverified_role = ensure_unverified_role!()

    unless Repo.exists?(ServerSettings), do: create_starting_content!(user)

    Accounts.ensure_first_owner!()

    {:ok, %{system_user: user, default_role: default_role, unverified_role: unverified_role}}
  end

  defp create_starting_content!(user) do
    [general | _] = Enum.map(@starting_channels, &create_channel!/1)
    create_welcome_message!(general, user)
    create_server_settings!()
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

  defp create_channel!(attrs) do
    %Channel{}
    |> Channel.changeset(attrs)
    |> Repo.insert!()
  end

  defp create_welcome_message!(channel, user) do
    %Message{
      channel_id: channel.id,
      author_id: user.id,
      kind: :system,
      nonce: "bootstrap:welcome"
    }
    |> Message.changeset(%{
      body: "Welcome to Tavern. Register the first account to become this server's owner."
    })
    |> Repo.insert!()
  end

  defp create_server_settings! do
    %ServerSettings{}
    |> ServerSettings.changeset(%{
      singleton: true,
      name: Application.get_env(:tavern, :server_name, "Tavern")
    })
    |> Repo.insert!()
  end
end
