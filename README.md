# Tavern

Tavern is a self-hostable chat app, with each deployment representing exactly one chat server.

This repo currently contains the Phoenix bootstrap plus local infrastructure for:

- PostgreSQL for durable app state
- Valkey for ephemeral state (presence, typing, rate limits, fanout helpers)
- Phoenix/Bandit as the core realtime web app
- a first single-server chat domain with channels, users, and messages
- a minimal LiveView server shell wired to real database records

## Local bootstrap

Postgres comes from the platform (`server-ansible`), which reads `cartridge.json`. `ops dev db up` starts a local Valkey; the S3 store for uploads runs in Docker.

1. Copy the env file, then add the database URLs to it:

   ```bash
   cp .env.example .env
   ops dev db up
   ```

   `ops dev db up` creates `tavern_dev` and `tavern_dev_test`, starts the local Valkey, and writes `DATABASE_URL`, `TEST_DATABASE_URL`, `DATABASE_VISITOR`, `VALKEY_URL` and `VALKEY_KEY_PREFIX` to `.env`.

2. Start the S3 store and load the env:

   ```bash
   docker compose up -d
   set -a; source .env; set +a
   ```

3. Install the app, run the migrations and add the seed data:

   ```bash
   mix setup
   ```

4. Start Phoenix:

   ```bash
   mix phx.server
   ```

Then visit [`localhost:4000`](http://localhost:4000).

The dev logins cannot create or drop databases. To start again from an empty dev database, run `ops dev db reset tavern_dev`.

## Environment

In dev and test, Phoenix reads:

- `DATABASE_URL`, `TEST_DATABASE_URL`, `DATABASE_VISITOR`: written by `ops dev db up`
- `VALKEY_URL`, `VALKEY_KEY_PREFIX`: the local Valkey, written by `ops dev db up`
- `S3_PORT`: the local S3 store (SeaweedFS) that holds uploads; `config/dev.exs` points at it
- `PORT`, `POOL_SIZE`, `TAVERN_SERVER_NAME`

A deploy gets its environment from `cartridge.json`: `DATABASE_URL`, `VALKEY_URL`, `SECRET_KEY_BASE`, `DATABASE_VISITOR` (the role each server connection switches to with `SET ROLE`), `PHX_URL` (the URL the service is served at), `VALKEY_KEY_PREFIX`, and the upload bucket: `S3_ENDPOINT`, `S3_BUCKET`, `S3_REGION`, `S3_ACCESS_KEY_ID`, `S3_SECRET_ACCESS_KEY`. Tests keep the bucket in memory.

## Self-host with Docker Compose

`selfhost/` runs one Tavern server on one Linux machine: the app, Postgres, Valkey, an S3 store
for uploads (SeaweedFS), and Caddy, which gets the HTTPS certificate.

You need Docker Engine with Compose v2, a domain name whose DNS points at the machine, and ports
80 and 443 open to the internet.

1. Get the code and write the settings file. `setup` generates every secret:

   ```bash
   git clone <this repository> tavern
   cd tavern/selfhost
   ./setup
   ```

2. Edit `selfhost/.env`: set `TAVERN_DOMAIN` to your domain. Mail and voice are optional:
   - Mail sends invites, email verification and password resets. Set `MAIL_PROVIDER=smtp`,
     `EMAIL_FROM` and the `SMTP_*` lines. Without mail, members need no email verification and
     password reset is off.
   - Voice and video channels need a Cloudflare Realtime app (`CLOUDFLARE_REALTIME_*`,
     `CLOUDFLARE_TURN_*`). Without them, voice is off.

3. Build and start. The first build compiles the app and takes several minutes:

   ```bash
   docker compose up -d --build
   ```

4. Read the setup link from the migrate step's log, open it and register. The first account
   registered owns the server, and a new server is invite only, so this one-use link is the only
   way in:

   ```bash
   docker compose logs migrate
   ```

   To let anyone register, set registration to open in Settings.

   A server with members but no owner (for example, after the owner deleted their account)
   gets one with `docker compose run --rm migrate /app/bin/make-owner you@example.com`.

To upgrade, run `git pull`, then `docker compose up -d --build`; the `migrate` service runs the
new migrations before the app starts. To back up, dump the database and keep the upload volume:

```bash
docker compose exec -T postgres pg_dump -U tavern tavern > tavern.sql
docker run --rm -v tavern-selfhost_s3-data:/data -v "$PWD":/out alpine tar czf /out/uploads.tgz -C /data .
```

Keep `selfhost/.env`. Its database and S3 secrets must match the data in the volumes, and a new
`SECRET_KEY_BASE` signs everyone out.

## Deploy to the author's platform

For tavern.danielfgray.com, a push to main is the only release. Before you push, run `ops promote [branch]` from a clean checkout on main. It merges the branch, runs `scripts/verify`, signs off, and prints the push command. The push builds the `Dockerfile` from the committed `HEAD` and deploys the image as `cartridge.json` declares. Its migrate step, `/app/bin/migrate`, runs the migrations and adds the seed data before the server starts. The platform generates the session secret, `SECRET_KEY_BASE`, on the first deploy or stage and keeps it at `secret/data/tavern/generated`; a staged copy reads the live value. The bucket comes from the platform's object store (`"objectStore": {}` in `cartridge.json`). The migrate step also gets the bucket key, because it loads `config/runtime.exs`, which requires the bucket variables in prod. A staged copy uses the live bucket with its own key, so deleting an upload in a staged copy deletes the live file.

## Initial architecture direction

Current bootstrap assumption:

- one deployed app instance = one server
- Phoenix handles HTTP + WebSocket realtime traffic
- Postgres is source of truth
- Valkey is used for ephemeral coordination, presence, and rate limiting
- keep it as a modular monolith first; split gateway/workers later only if load proves it necessary

## Useful commands

```bash
ops dev db up                  # create the dev and test databases, write their URLs to .env
ops dev db reset tavern_dev    # empty the dev database
docker compose up -d           # start the local S3 store
mix ecto.migrate
mix test
npm run test:e2e
mix phx.server
mix precommit
ops secret list                # each secret the cartridge reads: set or MISSING
ops promote [branch]           # from a clean main: merge, verify, sign off, print the push command
```

## Playwright E2E

Tavern now includes a Playwright smoke test that proves the main chat path works end to end:

- log in
- open the server shell
- switch to `engineering`
- send a persisted rich chat message with markdown, code blocks, and link rendering

Run it with:

```bash
npm run test:e2e
```

The Playwright config boots Phoenix on port `4001` in `MIX_ENV=test` with an isolated `MIX_BUILD_PATH`. Before the server starts, it runs the migrations and `priv/repo/e2e_reset.exs`, which empties every table of the test database, adds the seed data and a known browser-login user, and then builds the assets. The ExUnit suite uses the same database and empties it in `test/test_helper.exs` before it runs, so the two suites do not depend on each other's cleanup.

## Current app shape

The root route now serves a minimal server chat shell:

- seeded channels: `general`, `engineering`, `random`
- owners can open an in-app channel manager to create/edit categories and text channels
- channel list now renders grouped sections when channels belong to categories
- seeded system poster: `tavern_system`
- a new server is invite only; the first account, registered with the setup link that `bin/migrate` prints, owns it
- default `@everyone` role grants baseline channel visibility + messaging
- channel switching via LiveView patch params
- local message posting persisted to Postgres
- markdown rendering with code blocks and simple rich link cards in the transcript
- rich composer toolbar for bold, italic, inline code, code blocks, mentions, and slash commands
- permission-aware transcript/composer UX for sending, reacting, deleting, and role-mention guidance
- admins with emoji permission can upload/delete custom emoji and everyone can use them in a searchable full Unicode + custom reaction picker

Login is rate limited, session metadata stores IP/user-agent, and channel rendering/posting now respects membership + permission checks.

### The first owner

A new server is invite only. While it has no owner, `bin/migrate` (and `mix run priv/repo/seeds.exs`
in development) prints a one-use setup link, and the account registered with it owns the server.
A server with members but no owner gets one with this command from a development checkout:

```bash
mix run -e 'Tavern.Accounts.promote_first_owner("you@example.com")'
```

In a release install, run `bin/make-owner you@example.com` from the release directory.

This is intentionally barebones infra, not polished product UX.

## License

Tavern is licensed under the GNU Affero General Public License, version 3 or any later version
(AGPL-3.0-or-later). See [LICENSE](LICENSE). If you run a modified Tavern for other people,
section 13 requires you to offer those users the source of your version.

## Learn more

- Official website: https://www.phoenixframework.org/
- Guides: https://hexdocs.pm/phoenix/overview.html
- Docs: https://hexdocs.pm/phoenix
- Forum: https://elixirforum.com/c/phoenix-forum
- Source: https://github.com/phoenixframework/phoenix
