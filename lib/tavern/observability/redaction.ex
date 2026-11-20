defmodule Tavern.Observability.Redaction do
  @moduledoc """
  Decides what leaves Tavern for OpenObserve. Every span and every log record passes through
  here on its way out; stdout keeps the full detail, as before.

  Spans, through `export/3`, an exporter that wraps `opentelemetry_exporter`:

  - `url.path` goes: it can hold an email confirmation token (`/users/confirm/:token`). Phoenix
    names each request span by its route and sets `http.route`, so a span still says which page
    it served.
  - `url.query` goes: it can hold an invite code or the LiveView socket's CSRF token.
  - `client.address` and `network.peer.address` go: each is the member's IP address when no
    proxy stands in front.
  - `db.url` goes: `opentelemetry_ecto` copies the Repo's URL, password included.
  - An exception event keeps only `exception.type`. Its message and stacktrace print values: a
    `KeyError` prints the whole map, a function clause error its arguments.
  - The status keeps its code and loses its message: `opentelemetry_ecto` puts the database
    error there, whose detail can quote a row (`Key (email)=(...) already exists`).

  Log records, through `filter_log_event/2`, the OTLP log handler's filter:

  - Phoenix's request lines are dropped: they print the raw path.
  - Product event records pass unchanged: `Tavern.ProductEvents` builds their fields.
  - Every other record keeps only the metadata in `@log_metadata`. Other metadata can hold a
    `Plug.Conn` (Bandit sets `conn`), a crash reason, or whatever a caller passed.
  - A crash record (it has `crash_reason`) gets a new message: the exception or exit type and
    the code locations of its stacktrace. The original prints the process state and its last
    message, which hold message text, emails and usernames.
  """

  @behaviour :otel_exporter_traces

  require Record

  Record.defrecordp(:span, Record.extract(:span, from_lib: "opentelemetry/include/otel_span.hrl"))

  Record.defrecordp(
    :event,
    Record.extract(:event, from_lib: "opentelemetry/include/otel_span.hrl")
  )

  Record.defrecordp(
    :status,
    Record.extract(:status, from_lib: "opentelemetry_api/include/opentelemetry.hrl")
  )

  @span_attributes [
    :"url.path",
    :"url.query",
    :"client.address",
    :"network.peer.address",
    :"db.url"
  ]
  @exception_attributes [:"exception.message", :"exception.stacktrace"]

  # `time` and `report_cb` are read by the OTLP handler; the `otel_*` keys link a record to its
  # span.
  @log_metadata [
    :time,
    :report_cb,
    :mfa,
    :file,
    :line,
    :domain,
    :application,
    :pid,
    :request_id,
    :otel_trace_id,
    :otel_span_id,
    :otel_trace_flags
  ]

  @impl :otel_exporter_traces
  def init(config), do: :opentelemetry_exporter.init(config)

  @impl :otel_exporter_traces
  def export(spans, resource, state) do
    redacted = :ets.new(__MODULE__, [:duplicate_bag, keypos: :ets.info(spans, :keypos)])

    try do
      :ets.foldl(
        fn span, :ok ->
          :ets.insert(redacted, redact_span(span))
          :ok
        end,
        :ok,
        spans
      )

      :opentelemetry_exporter.export(:traces, redacted, resource, state)
    after
      :ets.delete(redacted)
    end
  end

  @impl :otel_exporter_traces
  def shutdown(state), do: :opentelemetry_exporter.shutdown(state)

  @doc false
  # A `:logger` filter; `Tavern.Observability.setup/0` puts it on the OTLP handler.
  def filter_log_event(%{meta: %{mfa: {Phoenix.Logger, _function, _arity}}}, _arg), do: :stop

  def filter_log_event(
        %{meta: %{mfa: {Tavern.Observability, :log_product_event, 4}}} = log_event,
        _arg
      ),
      do: log_event

  def filter_log_event(%{meta: meta} = log_event, _arg) do
    redacted = %{log_event | meta: Map.take(meta, @log_metadata)}

    case meta do
      %{crash_reason: crash_reason} ->
        %{redacted | msg: {:string, crash_summary(crash_reason)}}

      _ ->
        redacted
    end
  end

  @doc """
  The span `export/3` sends in place of `span`, an SDK span record: the same span without the
  attributes, exception detail and status message listed above.
  """
  def redact_span(span) do
    span(span,
      attributes: drop_attributes(span(span, :attributes), @span_attributes),
      events: redact_events(span(span, :events)),
      status: redact_status(span(span, :status))
    )
  end

  defp redact_events(:undefined), do: :undefined

  defp redact_events(events) do
    redacted =
      for event <- :otel_events.list(events) do
        attributes = event(event, :attributes)

        attributes =
          if event(event, :name) in [:exception, "exception"],
            do: drop_attributes(attributes, @exception_attributes),
            else: attributes

        %{
          system_time_native: event(event, :system_time_native),
          name: event(event, :name),
          attributes: :otel_attributes.map(attributes)
        }
      end

    # `list/1` gives the events newest first, and `add/2` prepends each one.
    :otel_events.add(
      Enum.reverse(redacted),
      :otel_events.new(
        :otel_span_limits.event_count_limit(),
        :otel_span_limits.attribute_per_event_limit(),
        :otel_span_limits.attribute_value_length_limit()
      )
    )
  end

  defp redact_status(status(code: code)), do: status(code: code)
  defp redact_status(status), do: status

  # The SDK builds a span's attributes with these same limits.
  defp drop_attributes(attributes, keys) do
    :otel_attributes.new(
      Map.drop(:otel_attributes.map(attributes), keys),
      :otel_span_limits.attribute_count_limit(),
      :otel_span_limits.attribute_value_length_limit()
    )
  end

  defp crash_summary({reason, stacktrace}) do
    locations =
      if is_list(stacktrace),
        do:
          Enum.map(stacktrace, &["\n    ", Exception.format_stacktrace_entry(without_args(&1))]),
        else: []

    IO.iodata_to_binary(["crashed: ", reason_type(reason) | locations])
  end

  defp crash_summary(_crash_reason), do: "crashed"

  defp reason_type(%{__exception__: true} = exception), do: inspect(exception.__struct__)
  defp reason_type({:nocatch, _value}), do: "throw"
  defp reason_type(reason) when is_atom(reason), do: inspect(reason)
  defp reason_type({tag, _detail}) when is_atom(tag), do: inspect(tag)
  defp reason_type(_reason), do: "exit"

  # A stacktrace's top entry can hold the call's arguments instead of its arity.
  defp without_args({module, function, args, location}) when is_list(args),
    do: {module, function, length(args), location}

  defp without_args(entry), do: entry
end
