defmodule Tavern.WebPush.EncryptionTest do
  use ExUnit.Case, async: true

  alias Tavern.WebPush.Encryption
  alias Tavern.WebPush.Vapid

  defp decode(text), do: Base.url_decode64!(text, padding: false)

  # RFC 8291, section 5 and appendix A.
  test "encrypts RFC 8291's example to the bytes the RFC gives" do
    as_public =
      decode(
        "BP4z9KsN6nGRTbVYI_c7VJSPQTBtkgcy27mlmlMoZIIgDll6e3vCYLocInmYWAmS6TlzAC8wEqKK6PBru3jl7A8"
      )

    body =
      Encryption.encrypt(
        "When I grow up, I want to be a watermelon",
        decode(
          "BCVxsr7N_eNgVRqvHtD0zTZsEc6-VV-JvLexhqUzORcxaOzi6-AYWXvTBHm4bjyPjs7Vd8pZGH6SRpkNtoIAiw4"
        ),
        decode("BTBZMqHH6r4Tts7J_aSIgg"),
        decode("DGv6ra1nlYgDCS1FRnbzlw"),
        {as_public, decode("yfWPiYE-n46HLnH0KqZOF1fJJU3MYrct3AELtAQ-oRw")}
      )

    header =
      decode(
        "DGv6ra1nlYgDCS1FRnbzlwAAEABBBP4z9KsN6nGRTbVYI_c7VJSPQTBtkgcy27mlmlMoZIIgDll6e3vCYLocInmYWAmS6TlzAC8wEqKK6PBru3jl7A8"
      )

    ciphertext =
      decode("8pfeW0KbunFT06SuDKoJH9Ql87S1QUrdirN6GcG7sFz1y1sqLgVi1VhjVkHsUoEsbI_0LpXMuGvnzQ")

    assert body == header <> ciphertext
  end

  test "a random encryption decrypts with the device's key" do
    {ua_public, ua_private} = :crypto.generate_key(:ecdh, :prime256v1)
    auth = :crypto.strong_rand_bytes(16)

    <<salt::binary-16, 4096::32, 65, as_public::binary-65, sealed::binary>> =
      Encryption.encrypt("hello", ua_public, auth)

    ecdh = :crypto.compute_key(:ecdh, as_public, ua_private, :prime256v1)
    prk_key = :crypto.mac(:hmac, :sha256, auth, ecdh)
    info = "WebPush: info" <> <<0>> <> ua_public <> as_public
    ikm = :crypto.mac(:hmac, :sha256, prk_key, info <> <<1>>)
    prk = :crypto.mac(:hmac, :sha256, salt, ikm)

    cek =
      binary_part(
        :crypto.mac(:hmac, :sha256, prk, "Content-Encoding: aes128gcm" <> <<0, 1>>),
        0,
        16
      )

    nonce =
      binary_part(:crypto.mac(:hmac, :sha256, prk, "Content-Encoding: nonce" <> <<0, 1>>), 0, 12)

    size = byte_size(sealed) - 16
    <<ciphertext::binary-size(size), tag::binary-16>> = sealed

    assert :crypto.crypto_one_time_aead(:aes_128_gcm, cek, nonce, ciphertext, <<>>, tag, false) ==
             "hello\x02"
  end

  test "the VAPID token verifies with the public key and names the push service's origin" do
    {public_key, private_key} = :crypto.generate_key(:ecdh, :prime256v1)
    keys = %{public_key: public_key, private_key: private_key}

    "vapid t=" <> rest =
      Vapid.authorization("https://push.example/send/abc?x=1", keys, "https://tavern.test", 1000)

    [token, "k=" <> k] = String.split(rest, ", ")
    [header, claims, signature] = String.split(token, ".")

    assert decode(k) == public_key
    assert %{"alg" => "ES256"} = Jason.decode!(decode(header))

    assert %{"aud" => "https://push.example", "sub" => "https://tavern.test", "exp" => exp} =
             Jason.decode!(decode(claims))

    assert exp > 1000 and exp <= 1000 + 24 * 3600

    <<r::unsigned-big-256, s::unsigned-big-256>> = decode(signature)
    der = :public_key.der_encode(:"ECDSA-Sig-Value", {:"ECDSA-Sig-Value", r, s})

    assert :crypto.verify(:ecdsa, :sha256, header <> "." <> claims, der, [
             public_key,
             :prime256v1
           ])
  end
end
