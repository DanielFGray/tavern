defmodule Tavern.Mailer.Capture do
  @moduledoc """
  The development and test provider. It sends nothing over the network: it sends
  `{:mail_captured, email}` to the calling process and to each process in its `$callers`
  (so a test receives mail sent from a LiveView it drives), and logs the text body, so in
  development the link is in the server log.
  """

  require Logger

  def deliver(email, _config) do
    for pid <- [self() | Process.get(:"$callers", [])], do: send(pid, {:mail_captured, email})

    Logger.info("Captured mail to #{email.to}: #{email.subject}\n#{email.text}")
    :ok
  end
end
