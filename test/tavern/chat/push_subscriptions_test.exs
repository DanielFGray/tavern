defmodule Tavern.Chat.PushSubscriptionsTest do
  use Tavern.DataCase, async: false

  import Tavern.ChatFixtures

  alias Tavern.Bootstrap
  alias Tavern.Chat.PushSubscription
  alias Tavern.Chat.PushSubscriptions

  setup do
    Bootstrap.ensure_seed_data!()
    %{member: user_fixture()}
  end

  defp session(user), do: user |> browser_session() |> elem(1)

  defp live_endpoints do
    Repo.all(from(s in PushSubscriptions.live(), select: s.endpoint))
  end

  defp endpoints(user) do
    Repo.all(from(s in PushSubscription, where: s.user_id == ^user.id, select: s.endpoint))
  end

  test "stores a browser's subscription with its keys decoded", %{member: member} do
    params = push_subscription_params("https://push.site.test/send/a")

    assert {:ok, subscription} =
             PushSubscriptions.subscribe(scope_for(member), session(member), params)

    assert byte_size(subscription.p256dh) == 65
    assert byte_size(subscription.auth) == 16
  end

  test "refuses an endpoint that is not https, and keys that are not keys", %{member: member} do
    scope = scope_for(member)
    session_id = session(member)

    assert {:error, %Ecto.Changeset{}} =
             PushSubscriptions.subscribe(
               scope,
               session_id,
               push_subscription_params("http://push.site.test/a")
             )

    bad_key =
      put_in(push_subscription_params("https://push.site.test/b")["keys"]["p256dh"], "AAAA")

    assert {:error, %Ecto.Changeset{}} = PushSubscriptions.subscribe(scope, session_id, bad_key)

    assert {:error, :invalid} =
             PushSubscriptions.subscribe(scope, session_id, %{"endpoint" => "x"})

    assert endpoints(member) == []
  end

  test "an endpoint subscribed again moves to the member signed in now", %{member: member} do
    other = user_fixture()
    params = push_subscription_params("https://push.site.test/shared")

    {:ok, _} = PushSubscriptions.subscribe(scope_for(member), session(member), params)
    {:ok, _} = PushSubscriptions.subscribe(scope_for(other), session(other), params)

    assert endpoints(member) == []
    assert endpoints(other) == ["https://push.site.test/shared"]
  end

  test "a member keeps at most ten devices, dropping the oldest", %{member: member} do
    for n <- 1..11 do
      {:ok, _} =
        PushSubscriptions.subscribe(
          scope_for(member),
          session(member),
          push_subscription_params("https://push.site.test/#{n}")
        )
    end

    kept = endpoints(member)
    assert length(kept) == 10
    refute "https://push.site.test/1" in kept
  end

  test "signing out stops push on that browser, and signing in there again restores it", ctx do
    {token, session_id} = browser_session(ctx.member)
    params = push_subscription_params("https://push.site.test/laptop")
    {:ok, _} = PushSubscriptions.subscribe(scope_for(ctx.member), session_id, params)
    assert live_endpoints() == ["https://push.site.test/laptop"]

    :ok = Tavern.Accounts.delete_user_session_token(token)
    assert live_endpoints() == []

    {:ok, _} = PushSubscriptions.subscribe(scope_for(ctx.member), session(ctx.member), params)
    assert live_endpoints() == ["https://push.site.test/laptop"]
  end

  test "a subscription needs a live session of the member's own", %{member: member} do
    params = push_subscription_params("https://push.site.test/borrowed")

    assert {:error, :forbidden} =
             PushSubscriptions.subscribe(scope_for(member), session(user_fixture()), params)

    assert {:error, :forbidden} = PushSubscriptions.subscribe(scope_for(member), nil, params)
  end

  test "unsubscribe deletes only the member's own subscription", %{member: member} do
    other = user_fixture()

    {:ok, _} =
      PushSubscriptions.subscribe(
        scope_for(member),
        session(member),
        push_subscription_params("https://push.site.test/m")
      )

    :ok = PushSubscriptions.unsubscribe(scope_for(other), "https://push.site.test/m")
    assert endpoints(member) == ["https://push.site.test/m"]

    :ok = PushSubscriptions.unsubscribe(scope_for(member), "https://push.site.test/m")
    assert endpoints(member) == []
  end
end
