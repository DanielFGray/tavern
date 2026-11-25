defmodule Tavern.WebPush.Encryption do
  @moduledoc """
  Encrypts a Web Push payload to one device, as RFC 8291 specifies (`aes128gcm`, one record).
  Only the device can read it: the push service relays bytes it cannot decrypt.
  """

  # The record size the header declares. The payload must fit in one record.
  @record_size 4096

  @doc """
  The request body for `plaintext`, encrypted to the device's `ua_public` key (65 bytes,
  uncompressed P-256) and `auth_secret` (16 bytes), with a fresh salt and sender key.
  """
  def encrypt(plaintext, ua_public, auth_secret) do
    encrypt(
      plaintext,
      ua_public,
      auth_secret,
      :crypto.strong_rand_bytes(16),
      :crypto.generate_key(:ecdh, :prime256v1)
    )
  end

  @doc """
  The request body from explicit inputs: `salt` (16 bytes) and the sender's one-use key pair
  `{as_public, as_private}`. `encrypt/3` draws both at random; RFC 8291's example fixes them.
  """
  def encrypt(plaintext, ua_public, auth_secret, salt, {as_public, as_private})
      when byte_size(plaintext) <= @record_size - 17 do
    ecdh_secret = :crypto.compute_key(:ecdh, ua_public, as_private, :prime256v1)

    key_info = "WebPush: info" <> <<0>> <> ua_public <> as_public
    ikm = hkdf(auth_secret, ecdh_secret, key_info, 32)

    cek = hkdf(salt, ikm, "Content-Encoding: aes128gcm" <> <<0>>, 16)
    nonce = hkdf(salt, ikm, "Content-Encoding: nonce" <> <<0>>, 12)

    # 0x02 marks the last (here the only) record.
    {ciphertext, tag} =
      :crypto.crypto_one_time_aead(:aes_128_gcm, cek, nonce, plaintext <> <<2>>, <<>>, true)

    header = salt <> <<@record_size::32, byte_size(as_public)::8>> <> as_public
    header <> ciphertext <> tag
  end

  # HKDF (RFC 5869) with SHA-256, for an output of at most one hash length.
  defp hkdf(salt, ikm, info, length) do
    prk = :crypto.mac(:hmac, :sha256, salt, ikm)
    :crypto.mac(:hmac, :sha256, prk, info <> <<1>>) |> binary_part(0, length)
  end
end
