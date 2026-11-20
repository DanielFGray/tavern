defmodule Tavern.Accounts.VerificationMail do
  @moduledoc """
  The mails that carry an email link: the confirmation of a new account's address, the
  confirmation of a new address in an email change, and a password reset. Each holds a single-use token
  (`Tavern.Accounts`). The caller decides whether mail is on.
  """

  use Phoenix.VerifiedRoutes, endpoint: TavernWeb.Endpoint, router: TavernWeb.Router

  alias Tavern.Chat.ServerConfig
  alias Tavern.Mailer

  @doc "Mails `to` the link that confirms the account's email. Returns `:ok` or `{:error, reason}`."
  def deliver_confirmation(to, token) do
    server_name = ServerConfig.get_server_settings().name
    link = url(~p"/users/confirm/#{token}")

    deliver(to, "Confirm your email for #{server_name}", link, [
      "Confirm your email for your #{server_name} account.",
      "The link works once, within 7 days. If you did not create an account, ignore this mail."
    ])
  end

  @doc "Mails the new address `to` the link that applies an email change. Returns `:ok` or `{:error, reason}`."
  def deliver_email_change(to, token) do
    server_name = ServerConfig.get_server_settings().name
    link = url(~p"/users/confirm-email/#{token}")

    deliver(to, "Confirm your new email for #{server_name}", link, [
      "Open the link to make this address your #{server_name} sign-in email.",
      "Your email does not change until you do.",
      "The link works once, within 7 days. If you did not ask for this change, ignore this mail."
    ])
  end

  @doc "Mails `to` the link that sets a new password. Returns `:ok` or `{:error, reason}`."
  def deliver_password_reset(to, token) do
    server_name = ServerConfig.get_server_settings().name
    link = url(~p"/users/reset-password/#{token}")

    deliver(to, "Reset your password for #{server_name}", link, [
      "Open the link to choose a new password for your #{server_name} account.",
      "Signing in again is required afterwards: the reset ends every session of the account.",
      "The link works once, within 1 hour. If you did not ask for this, ignore this mail. Your password stays as it is."
    ])
  end

  defp deliver(to, subject, link, lines) do
    text = Enum.join(lines, "\n\n") <> "\n\n" <> link <> "\n"

    html =
      [
        Enum.map(lines, &["<p>", escape(&1), "</p>"]),
        "<p><a href=\"",
        escape(link),
        "\">",
        escape(link),
        "</a></p>"
      ]
      |> IO.iodata_to_binary()

    Mailer.deliver(%{to: to, subject: subject, text: text, html: html})
  end

  defp escape(text), do: text |> Phoenix.HTML.html_escape() |> Phoenix.HTML.safe_to_string()
end
