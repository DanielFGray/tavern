defmodule Tavern.Observability do
  @moduledoc """
  Sends traces and log records to the platform's OpenObserve over OTLP
  (`docs/design/observability.md`).

  A deploy exports when the platform sets `OTEL_EXPORTER_OTLP_ENDPOINT`: `config/runtime.exs`
  then turns on the trace exporter, and `setup/0` attaches the instrumentation and the log
  handler. A checkout and the tests export nothing and attach nothing.

  Traces: one span per HTTP request (Bandit, named by Phoenix route), per LiveView mount,
  `handle_params` and `handle_event`, and per Ecto query.

  Logs: every `Logger` record at `:info` and above, and one record per product event
  (`Tavern.ProductEvents`).

  `Tavern.Observability.Redaction` removes secrets and personal data from both on their way out.
  """

  require Logger

  alias Tavern.Observability.Redaction

  @log_handler :otel

  @doc "Whether this node exports to OpenObserve: `config/runtime.exs` decides."
  def export?, do: Application.get_env(:opentelemetry, :traces_exporter) != :none

  @doc """
  Attaches the trace instrumentation, the product event log writer and the OTLP log handler,
  when `export?/0`. Runs once, from `Tavern.Application.start/2`, before the endpoint starts.
  """
  def setup do
    if export?() do
      # Tavern's route is private, so a caller's `traceparent` starts a new, sampled trace with
      # a link to the caller's, instead of inheriting the caller's sampling decision.
      OpentelemetryBandit.setup(public_endpoint: true)
      OpentelemetryPhoenix.setup(adapter: :bandit)
      # The statement holds `$n` placeholders, never the values bound to them.
      OpentelemetryEcto.setup([:tavern, :repo], db_statement: :enabled)

      :ok =
        :telemetry.attach(
          {__MODULE__, :product_event},
          Tavern.ProductEvents.event(),
          &__MODULE__.log_product_event/4,
          nil
        )

      :ok =
        :logger.add_handler(@log_handler, :otel_log_handler, %{
          level: :info,
          filters: [redaction: {&Redaction.filter_log_event/2, nil}],
          exporter: {:otel_exporter_logs_otlp, %{}}
        })
    end

    :ok
  end

  @doc false
  # A `:telemetry` handler. Each field becomes a log record attribute; the message names the
  # event so a plain log search finds it too.
  def log_product_event(_event, _measurements, %{event: name} = fields, _config) do
    Logger.info("product event #{name}", Map.to_list(fields))
  end
end
