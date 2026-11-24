defmodule Tavern.SmtpSink do
  @moduledoc """
  A local SMTP server for tests. It sends each mail it receives, as
  `{:smtp_received, from, to, data}`, to the process that started it.

  `start/1` takes `login: {username, password}` to offer AUTH and accept only that login. It has
  no certificate, so it never offers STARTTLS. A recipient starting `reject@` is refused.
  """

  @behaviour :gen_smtp_server_session

  @doc "Starts a sink on a free port owned by the calling test. Returns the port."
  def start(opts \\ []) do
    name = {__MODULE__, make_ref()}
    session = [callbackoptions: [parent: self()] ++ opts]

    {:ok, _pid} =
      :gen_smtp_server.start(name, __MODULE__,
        address: {127, 0, 0, 1},
        port: 0,
        domain: ~c"sink.test",
        sessionoptions: session
      )

    ExUnit.Callbacks.on_exit(fn -> :gen_smtp_server.stop(name) end)
    :ranch.get_port(name)
  end

  @impl true
  def init(hostname, _count, _peer, opts), do: {:ok, [hostname, " ESMTP sink"], Map.new(opts)}

  @impl true
  def handle_HELO(_host, state), do: {:ok, state}

  @impl true
  def handle_EHLO(_host, extensions, state) do
    extensions =
      if state[:login], do: extensions ++ [{~c"AUTH", ~c"PLAIN LOGIN"}], else: extensions

    {:ok, extensions, state}
  end

  @impl true
  def handle_AUTH(type, user, password, %{login: {user, password}} = state)
      when type in [:plain, :login],
      do: {:ok, state}

  def handle_AUTH(_type, _user, _password, _state), do: :error

  @impl true
  def handle_MAIL(_from, state), do: {:ok, state}

  @impl true
  def handle_MAIL_extension(_extension, state), do: {:ok, state}

  @impl true
  def handle_RCPT(<<"reject@", _::binary>>, state),
    do: {:error, "550 5.1.1 reject@example.com no such user", state}

  def handle_RCPT(_to, state), do: {:ok, state}

  @impl true
  def handle_RCPT_extension(_extension, state), do: {:ok, state}

  @impl true
  def handle_DATA(from, to, data, state) do
    send(state.parent, {:smtp_received, from, to, data})
    {:ok, "queued", state}
  end

  @impl true
  def handle_RSET(state), do: state

  @impl true
  def handle_VRFY(_address, state), do: {:error, "252 VRFY disabled", state}

  @impl true
  def handle_other(verb, _args, state),
    do: {["500 Error: command not recognized : '", verb, "'"], state}

  @impl true
  def handle_STARTTLS(state), do: state

  @impl true
  def code_change(_old, state, _extra), do: {:ok, state}

  @impl true
  def terminate(reason, state), do: {:ok, reason, state}
end
