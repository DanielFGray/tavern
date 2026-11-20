defmodule Tavern.RateLimitTest do
  use ExUnit.Case, async: false

  alias Tavern.RateLimit

  # Windows of an hour or more: each test finishes far inside one, so no count crosses its end.
  @hour 3_600
  @day 86_400

  setup do
    on_exit(fn -> RateLimit.reset!("test:") end)
    %{key: "test:#{System.unique_integer([:positive])}"}
  end

  test "admits up to the limit, then refuses with the wait until the window ends", %{key: key} do
    bucket = [{key, 2, @hour}]

    assert :ok = RateLimit.hit(bucket, :refuse)
    assert :ok = RateLimit.hit(bucket, :refuse)
    assert {:error, {:rate_limited, seconds}} = RateLimit.hit(bucket, :refuse)
    assert seconds in (@hour - 60)..@hour
  end

  test "a refused hit leaves no trace in a bucket that had room", %{key: key} do
    roomy = {key <> ":roomy", 2, @hour}
    full = {key <> ":full", 1, @hour}

    assert :ok = RateLimit.hit([full], :refuse)

    for _ <- 1..3,
        do: assert({:error, {:rate_limited, _}} = RateLimit.hit([roomy, full], :refuse))

    assert :ok = RateLimit.hit([roomy], :refuse)
    assert :ok = RateLimit.hit([roomy], :refuse)
    assert {:error, {:rate_limited, _}} = RateLimit.hit([roomy], :refuse)
  end

  test "the wait is the longest among the buckets over their limit", %{key: key} do
    short = {key <> ":short", 1, @hour}
    long = {key <> ":long", 1, @day}

    assert :ok = RateLimit.hit([short, long], :refuse)
    assert {:error, {:rate_limited, seconds}} = RateLimit.hit([short, long], :refuse)
    assert seconds > @hour
  end

  describe "with Valkey unreachable" do
    # The module is not async, so no other test runs while the Valkey client is stopped.
    setup do
      :ok = Supervisor.terminate_child(Tavern.Supervisor, Tavern.Valkey)
      on_exit(fn -> {:ok, _pid} = Supervisor.restart_child(Tavern.Supervisor, Tavern.Valkey) end)
    end

    test ":refuse refuses every hit", %{key: key} do
      assert {:error, :unavailable} = RateLimit.hit([{key, 5, @hour}], :refuse)
    end

    test ":count_locally counts on this node, up to the same limit", %{key: key} do
      bucket = [{key, 2, @hour}]

      assert :ok = RateLimit.hit(bucket, :count_locally)
      assert :ok = RateLimit.hit(bucket, :count_locally)
      assert {:error, {:rate_limited, seconds}} = RateLimit.hit(bucket, :count_locally)
      assert seconds in (@hour - 60)..@hour
    end
  end

  test "release hands a hit back, and clear ends the window", %{key: key} do
    bucket = {key, 1, @hour}

    assert :ok = RateLimit.hit([bucket], :refuse)
    :ok = RateLimit.release([bucket])
    assert :ok = RateLimit.hit([bucket], :refuse)
    assert {:error, {:rate_limited, _}} = RateLimit.hit([bucket], :refuse)

    :ok = RateLimit.clear(key)
    assert :ok = RateLimit.hit([bucket], :refuse)
  end
end
