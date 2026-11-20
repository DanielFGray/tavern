defmodule Tavern.Observability.RedactionTest do
  @moduledoc """
  What a span or a log record may carry out of Tavern: `Redaction.redact_span/1`, which
  `Redaction.export/3` applies to every span, and the OTLP log handler's filter.
  """
  use ExUnit.Case, async: true

  require Record

  alias Tavern.Observability.Redaction

  Record.defrecordp(:span, Record.extract(:span, from_lib: "opentelemetry/include/otel_span.hrl"))

  Record.defrecordp(
    :event,
    Record.extract(:event, from_lib: "opentelemetry/include/otel_span.hrl")
  )

  Record.defrecordp(
    :status,
    Record.extract(:status, from_lib: "opentelemetry_api/include/opentelemetry.hrl")
  )

  describe "a span" do
    test "loses the secret and personal attributes, and keeps the rest" do
      redacted =
        Redaction.redact_span(
          sdk_span(%{
            "http.route": "/users/confirm/:token",
            "url.path": "/users/confirm/secret-token",
            "url.query": "invite=secret-code",
            "client.address": "203.0.113.7",
            "network.peer.address": "203.0.113.7",
            "db.url": "ecto://tavern:secret-password@db/tavern",
            "db.statement": "SELECT 1 WHERE id = $1"
          })
        )

      assert attributes(span(redacted, :attributes)) == %{
               "http.route": "/users/confirm/:token",
               "db.statement": "SELECT 1 WHERE id = $1"
             }
    end

    test "keeps an exception's type, and loses its message, its stacktrace and the status message" do
      span =
        sdk_span(%{})
        |> add_event(:exception, %{
          "exception.type": "Elixir.KeyError",
          "exception.message": "key :x not found in: %{email: \"someone@example.com\"}",
          "exception.stacktrace": "lib/tavern/chat.ex:9: Tavern.Chat.send(%{body: \"secret\"})"
        })
        |> add_event(:retry, %{attempt: 2})
        |> span(status: OpenTelemetry.status(:error, "Key (email)=(someone@example.com) exists"))
        |> :otel_span_utils.end_span()

      redacted = Redaction.redact_span(span)

      assert [
               {:exception, %{"exception.type": "Elixir.KeyError"}},
               {:retry, %{attempt: 2}}
             ] ==
               for(
                 event <- Enum.reverse(:otel_events.list(span(redacted, :events))),
                 do: {event(event, :name), attributes(event(event, :attributes))}
               )

      assert status(span(redacted, :status), :message) == ""
      assert status(span(redacted, :status), :code) == :error
    end
  end

  describe "a log record" do
    test "drops Phoenix's request lines, which print the raw path" do
      record =
        log_event("GET /users/confirm/token", %{mfa: {Phoenix.Logger, :phoenix_endpoint_start, 4}})

      assert Redaction.filter_log_event(record, nil) == :stop
    end

    test "passes a product event record unchanged" do
      record =
        log_event("product event session.seen", %{
          mfa: {Tavern.Observability, :log_product_event, 4},
          event: "session.seen",
          member: "0123"
        })

      assert Redaction.filter_log_event(record, nil) == record
    end

    test "keeps only the known metadata of any other record" do
      record =
        log_event("plain line", %{
          mfa: {Tavern.Mailer, :deliver, 1},
          request_id: "F1",
          conn: %{req_cookies: %{"session" => "secret"}},
          user: "someone@example.com"
        })

      assert %{msg: {:string, "plain line"}, meta: meta} = Redaction.filter_log_event(record, nil)
      assert Map.keys(meta) |> Enum.sort() == [:mfa, :request_id, :time]
    end

    test "replaces a crash record's message with the crash type and code locations" do
      stacktrace = [
        {Map, :fetch!, [%{user: "secret state"}, "secret key"], [file: ~c"lib/map.ex", line: 1]},
        {Tavern.Chat, :send, 2, [file: ~c"lib/tavern/chat.ex", line: 9]}
      ]

      record =
        log_event("GenServer terminating\nLast message: secret\nState: secret", %{
          crash_reason: {%KeyError{key: "secret key", term: %{user: "secret state"}}, stacktrace}
        })

      assert %{msg: {:string, body}, meta: meta} = Redaction.filter_log_event(record, nil)
      assert body =~ "crashed: KeyError"
      assert body =~ "Map.fetch!/2"
      assert body =~ "lib/tavern/chat.ex:9: Tavern.Chat.send/2"
      refute body =~ "secret"
      refute Map.has_key?(meta, :crash_reason)
    end

    test "names an exit by its reason's tag, never its detail" do
      record = log_event("Task terminating", %{crash_reason: {{:shutdown, "secret"}, []}})

      assert %{msg: {:string, "crashed: :shutdown"}} = Redaction.filter_log_event(record, nil)
    end
  end

  # A span as the SDK builds it when a span starts.
  defp sdk_span(attributes) do
    {_span_ctx, span} =
      :otel_span_utils.start_span(
        :otel_ctx.new(),
        "GET /users/confirm/:token",
        :otel_sampler.new(:always_on),
        :otel_id_generator,
        %{
          attributes: attributes,
          links: [],
          kind: :server,
          start_time: :opentelemetry.timestamp()
        }
      )

    span
  end

  # As `OpenTelemetry.Span.add_event/3` does through the SDK.
  defp add_event(span, name, attributes) do
    events = :otel_events.add([%{name: name, attributes: attributes}], span(span, :events))
    span(span, events: events)
  end

  defp attributes(attributes), do: :otel_attributes.map(attributes)

  defp log_event(message, meta) do
    %{level: :error, msg: {:string, message}, meta: Map.put(meta, :time, 1)}
  end
end
