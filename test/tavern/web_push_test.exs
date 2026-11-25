defmodule Tavern.WebPushTest do
  @moduledoc "Sending Web Push (docs/design/push-notifications.md)."
  use Tavern.DataCase, async: false

  import Tavern.ChatFixtures

  alias Tavern.Bootstrap
  alias Tavern.Chat.PushSubscription
  alias Tavern.WebPush
  alias Tavern.WebPush.Key

  setup do
    Bootstrap.ensure_seed_data!()
    %{member: user_fixture()}
  end

  # A device: its key pair and auth secret, and its row.
  defp device(member, path) do
    {public_key, private_key} = :crypto.generate_key(:ecdh, :prime256v1)
    auth = :crypto.strong_rand_bytes(16)

    {_token, session_id} = browser_session(member)

    Repo.insert!(%PushSubscription{
      user_id: member.id,
      session_id: session_id,
      endpoint: "https://push.site.test" <> path,
      p256dh: public_key,
      auth: auth
    })

    %{private_key: private_key, public_key: public_key, auth: auth}
  end

  # Reports each request to the test, and answers `status` for it.
  defp stub_push_service(status) do
    test_pid = self()

    Req.Test.stub(Tavern.Embeds.SafeHTTP, fn conn ->
      {:ok, body, conn} = Plug.Conn.read_body(conn)
      send(test_pid, {:push, conn.request_path, Map.new(conn.req_headers), body})
      Plug.Conn.send_resp(conn, status, "")
    end)
  end

  # The device's side of RFC 8291.
  defp decrypt(body, device) do
    <<salt::binary-16, _rs::32, 65, as_public::binary-65, sealed::binary>> = body
    ecdh = :crypto.compute_key(:ecdh, as_public, device.private_key, :prime256v1)
    info = "WebPush: info" <> <<0>> <> device.public_key <> as_public
    ikm = hmac(hmac(device.auth, ecdh), info <> <<1>>)
    prk = hmac(salt, ikm)
    cek = binary_part(hmac(prk, "Content-Encoding: aes128gcm" <> <<0, 1>>), 0, 16)
    nonce = binary_part(hmac(prk, "Content-Encoding: nonce" <> <<0, 1>>), 0, 12)
    size = byte_size(sealed) - 16
    <<ciphertext::binary-size(size), tag::binary-16>> = sealed

    :crypto.crypto_one_time_aead(:aes_128_gcm, cek, nonce, ciphertext, <<>>, tag, false)
    |> binary_part(0, size - 1)
    |> Jason.decode!()
  end

  defp hmac(key, data), do: :crypto.mac(:hmac, :sha256, key, data)

  test "posts the payload encrypted to the device, signed with the server's key", ctx do
    device = device(ctx.member, "/send/1")
    stub_push_service(201)

    WebPush.send_all([{ctx.member.id, %{title: "Ada in #general", body: "hi", path: "/"}}])

    assert_receive {:push, "/send/1", headers, body}
    # `Content-Encoding: aes128gcm` is sent, but Req's test adapter removes the header before the
    # stub sees it (it decodes request bodies by that header), so it cannot be asserted here.
    assert headers["ttl"] =~ ~r/^\d+$/
    assert "vapid t=" <> _ = headers["authorization"]

    {:ok, public_key} = WebPush.public_key()
    assert headers["authorization"] =~ "k=" <> Base.url_encode64(public_key, padding: false)
    assert %{"title" => "Ada in #general", "body" => "hi"} = decrypt(body, device)
  end

  test "a subscription the push service calls gone is deleted", ctx do
    device(ctx.member, "/gone")
    stub_push_service(410)

    WebPush.send_all([{ctx.member.id, %{title: "t"}}])

    assert_receive {:push, "/gone", _headers, _body}
    assert Repo.aggregate(PushSubscription, :count) == 0
  end

  test "a push key made for another server URL sends nothing", ctx do
    device(ctx.member, "/copy")
    stub_push_service(201)
    Repo.delete_all(Key)
    {public_key, private_key} = :crypto.generate_key(:ecdh, :prime256v1)

    Repo.insert!(%Key{
      id: 1,
      origin: "https://elsewhere.test",
      public_key: public_key,
      private_key: private_key
    })

    WebPush.send_all([{ctx.member.id, %{title: "t"}}])

    refute_received {:push, _, _, _}
    assert WebPush.public_key() == {:error, :other_origin}
  end
end
