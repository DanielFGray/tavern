defmodule Tavern.Chat.InviteRequests do
  @moduledoc """
  The invite request queue of an invite-only server (`docs/design/invite-requests.md`).

  Anyone may ask for an invite with an email address while the server accepts requests. The
  request sends no mail. A member with `manage_applications` approves or denies it; approval
  binds a one-use invite and mails its link, after the deciding transaction commits.

  The form answers "Request received" for a new, duplicate, already-member or over-limit
  address alike, so it reveals neither who is registered nor where the limits sit.
  """

  use Phoenix.VerifiedRoutes, endpoint: TavernWeb.Endpoint, router: TavernWeb.Router

  import Ecto.Query, warn: false

  alias Ecto.Changeset
  alias Tavern.Accounts.Scope
  alias Tavern.Chat.AuditLog
  alias Tavern.Chat.Invite
  alias Tavern.Chat.InviteRequest
  alias Tavern.Chat.InviteRequestLimits
  alias Tavern.Chat.Invites
  alias Tavern.Chat.ServerConfig
  alias Tavern.Chat.User
  alias Tavern.Chat.Visibility
  alias Tavern.Mailer
  alias Tavern.Repo

  @statuses [:pending, :approved, :denied]

  @doc """
  Whether the request form is open: registration is invite-only, the setting is on, and mail
  is configured.
  """
  def accepting_requests? do
    settings = ServerConfig.get_server_settings()

    settings.registration_mode == :invite_only and settings.accept_invite_requests and
      Mailer.configured?()
  end

  @doc "An empty changeset for the request form."
  def change_invite_request(attrs \\ %{}),
    do: InviteRequest.request_changeset(%InviteRequest{}, attrs)

  @doc """
  Records a request for `email` from `ip_address`, and sends nothing.

  Returns `{:ok, :received}` for every well-formed address, whether it was stored or not: a
  duplicate pending request, an existing member, and a request over an intake limit store
  nothing and answer the same. A malformed address returns `{:error, changeset}`, and a server
  that does not accept requests returns `{:error, :not_accepting}`.
  """
  def request_invite(attrs, ip_address) when is_map(attrs) and is_binary(ip_address) do
    changeset = change_invite_request(attrs)

    cond do
      not accepting_requests?() ->
        {:error, :not_accepting}

      not changeset.valid? ->
        {:error, Map.put(changeset, :action, :insert)}

      true ->
        store_request(changeset, ip_address)
        {:ok, :received}
    end
  end

  defp store_request(changeset, ip_address) do
    email = Changeset.get_field(changeset, :email)

    with :ok <- InviteRequestLimits.admit_ip(ip_address),
         false <- known_address?(email),
         :ok <- InviteRequestLimits.admit_pending() do
      changeset
      |> Changeset.change(ip_address: ip_address, requested_at: DateTime.utc_now())
      |> Repo.insert()
    end
  end

  defp known_address?(email) do
    Repo.exists?(from(user in User, where: user.email == ^email)) or
      Repo.exists?(
        from(request in InviteRequest,
          where: request.email == ^email and request.status == :pending
        )
      )
  end

  @doc """
  The requests with `status` (`:pending`, `:approved`, `:denied` or `:all`), pending first and
  then newest first. Each carries `ip_request_count`, the number of requests from its IP, so a
  moderator can spot a flood. Needs `manage_applications`.
  """
  def list_invite_requests(%Scope{} = scope, status \\ :all) when status in [:all | @statuses] do
    if Visibility.can?(scope, :manage_applications, :server) do
      ip_counts =
        from(request in InviteRequest,
          group_by: request.ip_address,
          select: %{ip_address: request.ip_address, count: count(request.id)}
        )

      query =
        from(request in InviteRequest,
          join: ip in subquery(ip_counts),
          on: ip.ip_address == request.ip_address,
          order_by: [desc: request.status == :pending, desc: request.requested_at],
          limit: 200,
          select_merge: %{ip_request_count: ip.count}
        )

      query = if status == :all, do: query, else: where(query, [r], r.status == ^status)

      {:ok, query |> Repo.all() |> Repo.preload([:decided_by, :invite])}
    else
      {:error, :forbidden}
    end
  end

  @doc """
  Approves a pending request: binds a one-use invite that expires after the configured days,
  records an audit entry, and after the commit mails the invite link. The approval stands
  whatever the mail does; the returned request carries `delivered_at` or `delivery_error`.
  Needs `manage_applications`.
  """
  def approve_invite_request(%Scope{} = scope, request_id) do
    decide(scope, request_id, fn request, now ->
      expires_at = DateTime.add(now, expiry_days() * 86_400, :second)
      invite = Invites.insert_single_use!(scope.user_id, expires_at)

      request =
        request
        |> Changeset.change(
          status: :approved,
          decided_at: now,
          decided_by_id: scope.user_id,
          invite_id: invite.id
        )
        |> Repo.update!()

      AuditLog.record!(
        scope.user_id,
        "invite_request_approved",
        nil,
        {"invite_request", request.id}, metadata: %{"email" => request.email})

      %{request | invite: invite}
    end)
    |> case do
      {:ok, request} -> {:ok, deliver(request)}
      error -> error
    end
  end

  @doc "Denies a pending request and records an audit entry. No mail. Needs `manage_applications`."
  def deny_invite_request(%Scope{} = scope, request_id) do
    decide(scope, request_id, fn request, now ->
      request =
        request
        |> Changeset.change(status: :denied, decided_at: now, decided_by_id: scope.user_id)
        |> Repo.update!()

      AuditLog.record!(
        scope.user_id,
        "invite_request_denied",
        nil,
        {"invite_request", request.id}, metadata: %{"email" => request.email})

      request
    end)
  end

  @doc """
  Denies every pending request from `ip_address`, for a flood, with one audit entry. Returns
  `{:ok, count}`. Needs `manage_applications`.
  """
  def deny_invite_requests_from_ip(%Scope{} = scope, ip_address) when is_binary(ip_address) do
    Repo.transact(fn ->
      with :ok <- Visibility.authorize_write(scope, :manage_applications, :server) do
        now = DateTime.utc_now()

        {count, _} =
          from(request in InviteRequest,
            where: request.ip_address == ^ip_address and request.status == :pending
          )
          |> Repo.update_all(
            set: [status: :denied, decided_at: now, decided_by_id: scope.user_id]
          )

        AuditLog.record!(
          scope.user_id,
          "invite_requests_denied_by_ip",
          nil,
          {"invite_request", nil}, metadata: %{"ip_address" => ip_address, "count" => count})

        {:ok, count}
      end
    end)
  end

  @doc """
  Mails the invite link of an approved request again, under the same send limits. Returns
  `{:error, :invite_unusable}` when its invite was revoked, used or expired. Needs
  `manage_applications`.
  """
  def resend_invite(%Scope{} = scope, request_id) do
    Repo.transact(fn ->
      with :ok <- Visibility.authorize_write(scope, :manage_applications, :server),
           %InviteRequest{status: :approved} = request <- get_request(request_id),
           %Invite{} = invite <- Repo.preload(request, :invite).invite,
           true <- usable?(invite) do
        {:ok, %{request | invite: invite}}
      else
        {:error, reason} -> {:error, reason}
        nil -> {:error, :not_found}
        %InviteRequest{} -> {:error, :not_approved}
        false -> {:error, :invite_unusable}
      end
    end)
    |> case do
      {:ok, request} -> {:ok, deliver(request)}
      error -> error
    end
  end

  # Authorises, locks the request row and checks it is still pending, then runs `fun` with the
  # locked request, all in one transaction, so two moderators cannot both decide one request.
  defp decide(scope, request_id, fun) do
    Repo.transact(fn ->
      with :ok <- Visibility.authorize_write(scope, :manage_applications, :server),
           %InviteRequest{status: :pending} = request <- get_request(request_id, lock: true) do
        {:ok, fun.(request, DateTime.utc_now())}
      else
        {:error, reason} -> {:error, reason}
        nil -> {:error, :not_found}
        %InviteRequest{} -> {:error, :not_pending}
      end
    end)
  end

  defp get_request(request_id, opts \\ []) do
    case Ecto.UUID.cast(request_id) do
      {:ok, id} ->
        query = from(request in InviteRequest, where: request.id == ^id)
        query = if opts[:lock], do: lock(query, "FOR UPDATE"), else: query
        Repo.one(query)

      :error ->
        nil
    end
  end

  defp usable?(%Invite{} = invite) do
    is_nil(invite.revoked_at) and invite.uses < (invite.max_uses || 1) and
      (is_nil(invite.expires_at) or DateTime.compare(invite.expires_at, DateTime.utc_now()) == :gt)
  end

  # Sends the invite mail under the send limits and records the outcome on the request. A
  # reservation whose send fails is handed back, so a failed send does not use up the address's
  # daily allowance and Resend works at once.
  defp deliver(%InviteRequest{invite: %Invite{} = invite} = request) do
    result =
      with :ok <- InviteRequestLimits.reserve_mail(request.email) do
        case Mailer.deliver(invite_email(request.email, invite)) do
          :ok ->
            :ok

          {:error, reason} ->
            InviteRequestLimits.release_mail(request.email)
            {:error, reason}
        end
      end

    changes =
      case result do
        :ok -> [delivered_at: DateTime.utc_now(), delivery_error: nil]
        {:error, reason} -> [delivery_error: reason]
      end

    request |> Changeset.change(changes) |> Repo.update!()
  end

  defp invite_email(to, %Invite{} = invite) do
    server_name = ServerConfig.get_server_settings().name
    link = url(~p"/register?#{[code: invite.code]}")
    expires = Calendar.strftime(invite.expires_at, "%B %-d, %Y")

    text = """
    Your request to join #{server_name} was approved.

    Create your account with this link: #{link}

    The link works once and expires on #{expires}. If you did not ask to join, ignore this email.
    """

    html =
      [
        "<p>Your request to join ",
        escape(server_name),
        " was approved.</p><p><a href=\"",
        escape(link),
        "\">Create your account</a></p><p>The link works once and expires on ",
        escape(expires),
        ". If you did not ask to join, ignore this email.</p>"
      ]
      |> IO.iodata_to_binary()

    %{to: to, subject: "Your invite to #{server_name}", text: text, html: html}
  end

  defp escape(text), do: text |> Phoenix.HTML.html_escape() |> Phoenix.HTML.safe_to_string()

  defp expiry_days do
    :tavern |> Application.fetch_env!(__MODULE__) |> Keyword.fetch!(:invite_expiry_days)
  end
end
