# Empties the test database and seeds it for the Playwright suite:
#
#     MIX_ENV=test mix run priv/repo/e2e_reset.exs
#
# The ExUnit suite shares this database and empties it again when it starts.

alias Tavern.Accounts
alias Tavern.Bootstrap

Tavern.TestDatabase.truncate!()

Bootstrap.ensure_seed_data!()

# The seed user claims the fresh, invite-only server with its setup invite, as an operator does.
# The specs then start from an established server with open registration; a spec that needs
# invite-only switches it with the `set_registration_mode` command.
{:ok, owner} =
  Accounts.register_user(
    %{
      email: "e2e@example.com",
      username: "e2e_user",
      display_name: "E2E User",
      password: "supersecurepass"
    },
    invite_code: Accounts.ensure_setup_invite().code
  )

{:ok, _settings} =
  Tavern.Chat.update_server_settings(%Tavern.Accounts.Scope{user_id: owner.id}, %{
    "registration_mode" => "open"
  })
