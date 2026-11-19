defmodule Tavern.Accounts.DeletionNotice do
  @moduledoc """
  The mail that tells a kicked member their account will be deleted on a date unless they rejoin
  with an invite. With no mail provider configured, or an account with no email, nothing is sent.
  """

  use Phoenix.VerifiedRoutes, endpoint: TavernWeb.Endpoint, router: TavernWeb.Router

  alias Tavern.Chat.ServerConfig
  alias Tavern.Chat.User
  alias Tavern.Mailer

  @doc "Mails `user` that their account is deleted on `deletion_at`. Returns `:ok` or `{:error, reason}`."
  def deliver(%User{email: email} = _user, %DateTime{} = deletion_at) when is_binary(email) do
    if Mailer.configured?(), do: Mailer.deliver(email(email, deletion_at)), else: :ok
  end

  def deliver(%User{}, _deletion_at), do: :ok

  defp email(to, deletion_at) do
    server_name = ServerConfig.get_server_settings().name
    date = Calendar.strftime(deletion_at, "%B %-d, %Y")
    link = url(~p"/login")

    text = """
    You were removed from #{server_name}. Your account will be deleted on #{date} unless you rejoin with an invite before then. Messages you wrote stay, shown as "Deleted user".

    To rejoin, sign in at #{link} and enter an invite code.
    """

    html =
      [
        "<p>You were removed from ",
        escape(server_name),
        ". Your account will be deleted on ",
        escape(date),
        " unless you rejoin with an invite before then. Messages you wrote stay, shown as \"Deleted user\".</p>",
        "<p>To rejoin, <a href=\"",
        escape(link),
        "\">sign in</a> and enter an invite code.</p>"
      ]
      |> IO.iodata_to_binary()

    %{
      to: to,
      subject: "Your #{server_name} account will be deleted on #{date}",
      text: text,
      html: html
    }
  end

  defp escape(text), do: text |> Phoenix.HTML.html_escape() |> Phoenix.HTML.safe_to_string()
end
