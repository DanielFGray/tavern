defmodule Tavern.MailerTest do
  # Some tests change the global mailer config.
  use ExUnit.Case, async: false

  alias Tavern.Mailer

  @email %{to: "to@example.com", subject: "Hi", text: "Hello", html: "<p>Hello</p>"}

  setup do
    :ok = Tavern.Mailer.Capture.subscribe()
  end

  describe "the capture provider" do
    test "hands the email to the calling process, from the configured sender" do
      assert :ok = Mailer.deliver(@email)
      assert_received {:mail_captured, %{to: "to@example.com", from: "tavern@example.test"}}
    end

    test "hands the email to the processes in $callers" do
      task = Task.async(fn -> Mailer.deliver(@email) end)
      assert :ok = Task.await(task)
      assert_received {:mail_captured, %{subject: "Hi"}}
    end

    test "hands nothing to a sending process that did not subscribe" do
      task =
        Task.async(fn ->
          :ok = Mailer.deliver(@email)

          receive do
            {:mail_captured, _} -> :received
          after
            0 -> :none
          end
        end)

      assert Task.await(task) == :none
      assert_received {:mail_captured, %{subject: "Hi"}}
    end
  end

  describe "configuration" do
    test "with no provider, mail is not configured and deliver refuses" do
      with_config([provider: nil], fn ->
        refute Mailer.configured?()
        assert Mailer.missing_settings() == ["MAIL_PROVIDER"]
        assert {:error, "mail is not configured: MAIL_PROVIDER unset"} = Mailer.deliver(@email)
        refute_received {:mail_captured, _}
      end)
    end

    test "Cloudflare needs its sender, account id and token" do
      with_config(
        [provider: :cloudflare, from: "a@example.com", account_id: "", api_token: nil],
        fn ->
          assert Mailer.missing_settings() == [
                   "CLOUDFLARE_ACCOUNT_ID",
                   "CLOUDFLARE_EMAIL_API_TOKEN"
                 ]

          assert {:error, _} = Mailer.deliver(@email)
        end
      )
    end
  end

  describe "the Cloudflare provider" do
    test "posts the email to the account's send endpoint with the bearer token" do
      Req.Test.stub(__MODULE__, fn conn ->
        assert conn.method == "POST"
        assert conn.request_path == "/client/v4/accounts/acct-1/email/sending/send"
        assert Plug.Conn.get_req_header(conn, "authorization") == ["Bearer secret-token"]

        {:ok, body, conn} = Plug.Conn.read_body(conn)

        assert %{
                 "from" => "tavern@example.test",
                 "to" => ["to@example.com"],
                 "subject" => "Hi",
                 "text" => "Hello",
                 "html" => "<p>Hello</p>"
               } = Jason.decode!(body)

        Req.Test.json(conn, %{
          "success" => true,
          "errors" => [],
          "result" => %{"delivered" => ["to@example.com"], "permanent_bounces" => []}
        })
      end)

      with_config(cloudflare_config(), fn -> assert :ok = Mailer.deliver(@email) end)
    end

    test "an API error becomes the reason" do
      Req.Test.stub(__MODULE__, fn conn ->
        conn
        |> Plug.Conn.put_status(403)
        |> Req.Test.json(%{
          "success" => false,
          "errors" => [%{"code" => 10102, "message" => "token lacks permission"}],
          "result" => nil
        })
      end)

      with_config(cloudflare_config(), fn ->
        assert {:error, "Cloudflare answered 403: 10102 token lacks permission"} =
                 Mailer.deliver(@email)
      end)
    end

    test "a permanent bounce is a failure" do
      Req.Test.stub(__MODULE__, fn conn ->
        Req.Test.json(conn, %{
          "success" => true,
          "result" => %{"delivered" => [], "permanent_bounces" => ["to@example.com"]}
        })
      end)

      with_config(cloudflare_config(), fn ->
        assert {:error, "permanently bounced"} = Mailer.deliver(@email)
      end)
    end

    test "a transport error becomes the reason" do
      Req.Test.stub(__MODULE__, &Req.Test.transport_error(&1, :econnrefused))

      with_config(cloudflare_config(), fn ->
        assert {:error, "Cloudflare unreachable: " <> _} = Mailer.deliver(@email)
      end)
    end
  end

  describe "the SMTP provider" do
    test "sends a text and HTML mail from the configured sender" do
      port = Tavern.SmtpSink.start()

      email = %{@email | subject: "Héllo", text: "Hello ✓", html: "<p>Hello ✓</p>"}
      assert :ok = with_config(smtp_config(port), fn -> Mailer.deliver(email) end)

      assert_receive {:smtp_received, "tavern@example.test", ["to@example.com"], data}
      # Without the optional iconv library, decoding leaves the bytes as sent: UTF-8 bodies, and
      # the subject as an RFC 2047 encoded word.
      {"multipart", "alternative", headers, _params, [plain, html]} =
        :mimemail.decode(data, encoding: :none)

      assert {"Subject", "=?UTF-8?" <> _} = List.keyfind(headers, "Subject", 0)
      assert {"text", "plain", _, _, "Hello ✓"} = plain
      assert {"text", "html", _, _, "<p>Hello ✓</p>"} = html
    end

    test "logs in when a username and password are set" do
      port = Tavern.SmtpSink.start(login: {"mailer", "s3cret"})
      config = smtp_config(port) ++ [smtp_username: "mailer", smtp_password: "s3cret"]

      assert :ok = with_config(config, fn -> Mailer.deliver(@email) end)
      assert_receive {:smtp_received, _, _, _}

      config = smtp_config(port) ++ [smtp_username: "mailer", smtp_password: "wrong"]
      assert {:error, "SMTP login failed"} = with_config(config, fn -> Mailer.deliver(@email) end)
    end

    test "STARTTLS mode sends nothing to a server that cannot encrypt" do
      port = Tavern.SmtpSink.start()
      config = Keyword.put(smtp_config(port), :smtp_security, :starttls)

      assert {:error, "SMTP server does not offer STARTTLS"} =
               with_config(config, fn -> Mailer.deliver(@email) end)

      refute_receive {:smtp_received, _, _, _}
    end

    test "a refused recipient keeps only the reply code" do
      port = Tavern.SmtpSink.start()

      assert {:error, "SMTP refused: 550 5.1.1"} =
               with_config(smtp_config(port), fn ->
                 Mailer.deliver(%{@email | to: "reject@example.com"})
               end)
    end

    test "an unreachable server becomes the reason" do
      # A port that was free a moment ago has no listener.
      {:ok, socket} = :gen_tcp.listen(0, ip: {127, 0, 0, 1})
      {:ok, port} = :inet.port(socket)
      :ok = :gen_tcp.close(socket)

      assert {:error, "SMTP unreachable: :econnrefused"} =
               with_config(smtp_config(port), fn -> Mailer.deliver(@email) end)
    end

    test "needs a sender, a host, and both halves of a login" do
      with_config([provider: :smtp, from: "a@example.com", smtp_host: nil], fn ->
        assert Mailer.missing_settings() == ["SMTP_HOST"]
      end)

      with_config([provider: :smtp, from: nil, smtp_host: "mail.test", smtp_username: "u"], fn ->
        assert Mailer.missing_settings() == ["EMAIL_FROM", "SMTP_PASSWORD"]
      end)
    end
  end

  defp smtp_config(port) do
    [
      provider: :smtp,
      from: "tavern@example.test",
      smtp_host: "127.0.0.1",
      smtp_port: port,
      smtp_security: :none
    ]
  end

  defp cloudflare_config do
    [
      provider: :cloudflare,
      from: "tavern@example.test",
      account_id: "acct-1",
      api_token: "secret-token",
      req_options: [plug: {Req.Test, __MODULE__}]
    ]
  end

  defp with_config(config, fun) do
    previous = Application.fetch_env!(:tavern, Mailer)
    Application.put_env(:tavern, Mailer, config)

    try do
      fun.()
    after
      Application.put_env(:tavern, Mailer, previous)
    end
  end
end
