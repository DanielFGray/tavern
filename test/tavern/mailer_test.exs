defmodule Tavern.MailerTest do
  # Some tests change the global mailer config.
  use ExUnit.Case, async: false

  alias Tavern.Mailer

  @email %{to: "to@example.com", subject: "Hi", text: "Hello", html: "<p>Hello</p>"}

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
        assert {:error, "permanently bounced: to@example.com"} = Mailer.deliver(@email)
      end)
    end

    test "a transport error becomes the reason" do
      Req.Test.stub(__MODULE__, &Req.Test.transport_error(&1, :econnrefused))

      with_config(cloudflare_config(), fn ->
        assert {:error, "Cloudflare unreachable: " <> _} = Mailer.deliver(@email)
      end)
    end
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
