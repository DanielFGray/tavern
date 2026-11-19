defmodule Tavern.Mailer.Capture do
  @moduledoc """
  The development and test provider. It sends nothing over the network. It logs each mail's text,
  so in development the link is in the server log.

  A process that calls `subscribe/0` also receives `{:mail_captured, email}` for each mail that it
  sends, or that a process it started sends (`$callers`, as for a LiveView or task a test
  drives). Only tests subscribe: the ExUnit case templates in their setup, and the e2e
  `capture_verification_mail` command. A server process that sends mail, such as a LiveView,
  never subscribes, so it never receives its own mail.
  """

  require Logger

  @registry __MODULE__

  @doc "The registry of subscribed processes. It is empty unless a test subscribes."
  def child_spec(_opts), do: Registry.child_spec(keys: :unique, name: @registry)

  @doc "Makes the calling process receive the mail it, or a process it started, sends."
  def subscribe do
    case Registry.register(@registry, self(), nil) do
      {:ok, _owner} -> :ok
      {:error, {:already_registered, _owner}} -> :ok
    end
  end

  @doc """
  Waits up to `timeout` milliseconds for a mail to `to` in the calling process's mailbox. Returns
  the mail, or nil. The process must have subscribed before the mail was sent.
  """
  def await(to, timeout) do
    receive do
      {:mail_captured, %{to: ^to} = email} -> email
    after
      timeout -> nil
    end
  end

  def deliver(email, _config) do
    for pid <- Enum.uniq([self() | Process.get(:"$callers", [])]),
        Registry.lookup(@registry, pid) != [],
        do: send(pid, {:mail_captured, email})

    Logger.info("Captured mail to #{email.to}: #{email.subject}\n#{email.text}")
    :ok
  end
end
