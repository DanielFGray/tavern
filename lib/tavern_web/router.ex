defmodule TavernWeb.Router do
  use TavernWeb, :router

  pipeline :browser do
    plug(:accepts, ["html"])
    plug(:fetch_session)
    plug(:fetch_live_flash)
    plug(:put_root_layout, html: {TavernWeb.Layouts, :root})
    plug(:protect_from_forgery)
    plug(:put_secure_browser_headers)
    plug(TavernWeb.Plugs.ContentSecurityPolicy)
    plug(TavernWeb.UserAuth, :fetch_current_scope_for_user)
  end

  pipeline :require_authenticated_user do
    plug(TavernWeb.UserAuth, :require_authenticated_user)
  end

  pipeline :require_banned_user do
    plug(TavernWeb.UserAuth, :require_banned_user)
  end

  pipeline :redirect_if_user_is_authenticated do
    plug(TavernWeb.UserAuth, :redirect_if_user_is_authenticated)
  end

  pipeline :api do
    plug(:accepts, ["json"])
  end

  pipeline :bot_api do
    plug(:accepts, ["json"])
    plug(TavernWeb.Plugs.RequireBotAuth)
  end

  # The event stream answers `text/event-stream`, which every standard SSE client puts in Accept, so
  # it skips the JSON-only `:accepts` check. Its errors are still JSON bodies.
  pipeline :bot_stream do
    plug(TavernWeb.Plugs.RequireBotAuth)
  end

  # The platform health check: no session, no auth, no CSRF.
  get("/healthz", TavernWeb.HealthController, :show)

  # Uploaded files: public, like the static assets, with no session.
  get("/uploads/*key", TavernWeb.UploadController, :show)

  # Login-as-anyone commands for e2e specs. The controller lives in test/support, which only
  # MIX_ENV=test compiles, so dev and prod have neither the route nor the code.
  if Application.compile_env(:tavern, :env) == :test do
    pipeline :test_support do
      plug(:accepts, ["json", "html"])
      plug(:fetch_session)
    end

    scope "/api/testing", TavernWeb do
      pipe_through(:test_support)

      get("/command", TestSupportController, :command)
      post("/command", TestSupportController, :command)
    end
  end

  scope "/", TavernWeb do
    pipe_through(:browser)

    delete("/logout", UserSessionController, :delete)

    # Email links. Each works for anyone who holds it, signed in or not, and signs nobody in or
    # out (docs/design/accounts.md).
    get("/users/confirm/:token", UserConfirmationController, :confirm)
    get("/users/confirm-email/:token", UserConfirmationController, :confirm_email)

    # Password reset: the request page and the link's page. The link works signed in or not, so
    # neither redirects a signed-in visitor.
    live_session :password_reset,
      on_mount: [TavernWeb.ReloadOnNewBuild, {TavernWeb.UserAuth, :mount_current_scope}] do
      live("/users/reset-password", PasswordResetRequestLive, :new)
      live("/users/reset-password/:token", PasswordResetLive, :edit)
    end
  end

  scope "/", TavernWeb do
    pipe_through([:browser, :redirect_if_user_is_authenticated])

    post("/login", UserSessionController, :create)

    live_session :redirect_if_user_is_authenticated,
      on_mount: [
        TavernWeb.ReloadOnNewBuild,
        {TavernWeb.UserAuth, :redirect_if_user_is_authenticated}
      ] do
      live("/register", UserRegistrationLive, :new)
      live("/login", UserLoginLive, :new)
    end
  end

  scope "/", TavernWeb do
    pipe_through([:browser, :require_authenticated_user])

    live_session :require_authenticated_user,
      on_mount: [TavernWeb.ReloadOnNewBuild, {TavernWeb.UserAuth, :ensure_authenticated}] do
      live("/", ServerLive, :index)
      live("/settings", SettingsLive, :index)
    end
  end

  scope "/", TavernWeb do
    pipe_through([:browser, :require_banned_user])

    live_session :require_banned_user,
      on_mount: [TavernWeb.ReloadOnNewBuild, {TavernWeb.UserAuth, :ensure_banned_user}] do
      live("/banned", BannedLive, :index)
    end
  end

  scope "/api/v1", TavernWeb.API, as: :api do
    pipe_through([:api, :browser, :require_authenticated_user])

    get("/bots", BotController, :index)
    post("/bots", BotController, :create)
    patch("/bots/:id", BotController, :update)
    delete("/bots/:id", BotController, :delete)
    get("/bots/:id/tokens", BotController, :list_tokens)
    post("/bots/:id/tokens", BotController, :create_token)
    delete("/bot_tokens/:id", BotController, :revoke_token)

    post("/user/channels/:channel_id/messages", UserMessageController, :create)
  end

  scope "/api/v1", TavernWeb.API, as: :bot_api do
    pipe_through :bot_api

    get("/channels/:channel_id/messages", MessageController, :index)
    post("/channels/:channel_id/messages", MessageController, :create)
    patch("/channels/:channel_id/messages/:message_id", MessageController, :update)
    post("/channels/:channel_id/typing", MessageController, :typing)
    get("/messages/:message_id", MessageController, :show)
    get("/messages/:message_id/thread", MessageController, :thread)
    post("/channels/:channel_id/questions", QuestionController, :create)
    get("/messages/:message_id/question", QuestionController, :show)
    post("/messages/:message_id/question/close", QuestionController, :close)
    post("/messages/:message_id/threads", MessageController, :create_thread)
    post("/commands/execute", CommandController, :execute)
    get("/members/:user_id", MemberController, :show)
  end

  scope "/api/v1", TavernWeb.API, as: :bot_api do
    pipe_through :bot_stream

    get("/events", BotController, :events)
  end

  # Enable LiveDashboard in development
  if Application.compile_env(:tavern, :dev_routes) do
    # If you want to use the LiveDashboard in production, you should put
    # it behind authentication and allow only admins to access it.
    # If your application does not have an admins-only section yet,
    # you can use Plug.BasicAuth to set up some basic authentication
    # as long as you are also using SSL (which you should anyway).
    import Phoenix.LiveDashboard.Router

    scope "/dev" do
      pipe_through(:browser)

      live_dashboard("/dashboard", metrics: TavernWeb.Telemetry, csp_nonce_assign_key: :csp_nonce)
    end
  end
end
