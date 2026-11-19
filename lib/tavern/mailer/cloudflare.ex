defmodule Tavern.Mailer.Cloudflare do
  @moduledoc """
  Sends through Cloudflare Email Service's REST API:
  `POST /client/v4/accounts/{account_id}/email/sending/send`, with a Bearer token that holds
  the "Email Sending: Edit" permission. The sender's domain must be onboarded for Email
  Sending on the account that owns the token.

  Req does not retry: a failed send is shown to the moderator, who can resend.
  """

  @base_url "https://api.cloudflare.com/client/v4"

  def deliver(email, config) do
    request =
      Req.new(
        [
          base_url: @base_url,
          url: "/accounts/:account_id/email/sending/send",
          path_params: [account_id: config[:account_id]],
          auth: {:bearer, config[:api_token]},
          retry: false
        ] ++ Keyword.get(config, :req_options, [])
      )

    body = %{
      from: email.from,
      to: [email.to],
      subject: email.subject,
      text: email.text,
      html: email.html
    }

    case Req.post(request, json: body) do
      {:ok, %Req.Response{status: 200, body: %{"success" => true, "result" => result}}} ->
        bounced(result)

      {:ok, %Req.Response{status: status, body: body}} ->
        {:error, "Cloudflare answered #{status}: #{error_messages(body)}"}

      {:error, exception} ->
        {:error, "Cloudflare unreachable: #{Exception.message(exception)}"}
    end
  end

  defp bounced(%{"permanent_bounces" => [_ | _] = addresses}),
    do: {:error, "permanently bounced: #{Enum.join(addresses, ", ")}"}

  defp bounced(%{"suppressed_recipients" => [_ | _] = addresses}),
    do: {:error, "suppressed recipient: #{Enum.join(addresses, ", ")}"}

  defp bounced(_result), do: :ok

  defp error_messages(%{"errors" => [_ | _] = errors}),
    do: Enum.map_join(errors, "; ", &"#{&1["code"]} #{&1["message"]}")

  defp error_messages(_body), do: "no error detail"
end
