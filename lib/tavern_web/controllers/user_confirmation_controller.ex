defmodule TavernWeb.UserConfirmationController do
  @moduledoc """
  Opens the links in verification mail. The token is the authority: the session is neither read
  nor changed, so a link opened in another browser works and signs nobody in. Both actions
  redirect to the app, which sends a visitor who is not signed in on to the login page.
  """
  use TavernWeb, :controller

  alias Tavern.Accounts

  def confirm(conn, %{"token" => token}) do
    case Accounts.confirm_user(token) do
      {:ok, _user} ->
        conn
        |> put_flash(:info, "Your email is confirmed.")
        |> redirect(to: ~p"/")

      {:error, :invalid} ->
        conn
        |> put_flash(:error, "That confirmation link is used, expired or not valid.")
        |> redirect(to: ~p"/")
    end
  end

  def confirm_email(conn, %{"token" => token}) do
    case Accounts.update_user_email_from_token(token) do
      {:ok, user} ->
        conn
        |> put_flash(:info, "Your sign-in email is now #{user.email}.")
        |> redirect(to: ~p"/settings")

      {:error, :email_taken} ->
        conn
        |> put_flash(:error, "Another account took that email first. Your email did not change.")
        |> redirect(to: ~p"/settings")

      {:error, :invalid} ->
        conn
        |> put_flash(:error, "That email change link is used, expired or not valid.")
        |> redirect(to: ~p"/settings")
    end
  end
end
