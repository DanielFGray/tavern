defmodule Tavern.Mailer do
  @moduledoc """
  Sends one email through the provider the config names.

  `config :tavern, Tavern.Mailer` holds `:provider` (`:cloudflare`, `:smtp` or `:capture`),
  `:from`, for Cloudflare `:account_id`, `:api_token` and `:req_options`, and for SMTP the
  `:smtp_*` settings (`Tavern.Mailer.Smtp`). Production reads them from `MAIL_PROVIDER`,
  `EMAIL_FROM`, `CLOUDFLARE_ACCOUNT_ID`, `CLOUDFLARE_EMAIL_API_TOKEN` and the `SMTP_*` variables
  (`config/runtime.exs`). With no provider, or a provider without its settings, `configured?/0`
  is false and `deliver/1` refuses; there is no fallback provider.
  """

  require Logger

  @type email :: %{to: String.t(), subject: String.t(), text: String.t(), html: String.t()}

  @doc "Sends `email` from the configured sender. Returns `:ok` or `{:error, reason}`."
  @spec deliver(email()) :: :ok | {:error, String.t()}
  def deliver(%{to: _, subject: _, text: _, html: _} = email) do
    config = config()

    case missing_settings(config) do
      [] ->
        email = Map.put(email, :from, config[:from])
        result = provider_module(config[:provider]).deliver(email, config)
        log_result(result, email)
        result

      missing ->
        {:error, "mail is not configured: #{Enum.join(missing, ", ")} unset"}
    end
  end

  @doc "Whether mail can be sent with the current config."
  def configured?, do: missing_settings(config()) == []

  @doc """
  The environment variables that stop mail from working, empty when it works. Settings shows
  them, so an operator knows what to set.
  """
  def missing_settings, do: missing_settings(config())

  defp missing_settings(config) do
    case config[:provider] do
      :capture ->
        []

      :cloudflare ->
        [
          {"EMAIL_FROM", config[:from]},
          {"CLOUDFLARE_ACCOUNT_ID", config[:account_id]},
          {"CLOUDFLARE_EMAIL_API_TOKEN", config[:api_token]}
        ]
        |> Enum.filter(fn {_name, value} -> value in [nil, ""] end)
        |> Enum.map(&elem(&1, 0))

      :smtp ->
        [
          {"EMAIL_FROM", config[:from]},
          {"SMTP_HOST", config[:smtp_host]}
        ]
        |> Enum.filter(fn {_name, value} -> value in [nil, ""] end)
        |> Enum.map(&elem(&1, 0))
        |> Kernel.++(half_login(config))

      _none ->
        ["MAIL_PROVIDER"]
    end
  end

  # A login needs both halves; neither means the server takes mail without one.
  defp half_login(config) do
    case {config[:smtp_username] in [nil, ""], config[:smtp_password] in [nil, ""]} do
      {false, true} -> ["SMTP_PASSWORD"]
      {true, false} -> ["SMTP_USERNAME"]
      _both_or_neither -> []
    end
  end

  defp provider_module(:cloudflare), do: Tavern.Mailer.Cloudflare
  defp provider_module(:smtp), do: Tavern.Mailer.Smtp
  defp provider_module(:capture), do: Tavern.Mailer.Capture

  defp config, do: Application.get_env(:tavern, __MODULE__, [])

  defp log_result(:ok, email), do: Logger.info("Sent mail #{inspect(email.subject)}")

  defp log_result({:error, reason}, email),
    do: Logger.warning("Mail #{inspect(email.subject)} not sent: #{reason}")
end
