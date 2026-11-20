# Backups, restore and migrations

Tavern holds strangers' data at a public address. This file says what is backed up, how often, for how long, where, who can restore it, and how to restore it, including a restore onto a newer schema and a rollback of a bad migration.

The platform (roamancer, `~/build/roamancer`) runs the backups. Tavern adds none. File and line references below are to that repository unless they start with `lib/`, `config/` or `cartridge.json`.

## What holds state

| Store | Holds | Backed up by the platform | Restore need |
| --- | --- | --- | --- |
| Postgres, database `tavern` (`cartridge.json:4`) | Accounts, memberships, channels, messages, roles, settings, bots, and the `media_assets` rows that name each upload | Yes: nightly `pg_dumpall` | Required |
| Object store bucket (`cartridge.json:6`) | Upload bytes: custom emoji, server and member avatars, banners, and cached link-preview images. `Tavern.Chat.MediaAssets.store_upload/4` writes them and `fetch_upload/1` reads them (`lib/tavern/chat/media_assets.ex:21-67`); `Tavern.Chat.Embeds` stores preview images (`lib/tavern/chat/embeds.ex:139`) | Yes: nightly restic copy of Garage's volume | Required |
| Valkey (`cartridge.json:5`) | Presence, typing and rate-limit counters | No | None |
| OpenBao | `secret_key_base`, the Postgres logins, the bucket key's secret | No | See "Secrets" |

**Valkey needs no backup.** Only `Tavern.Ephemeral` calls the Valkey client (`rg 'Valkey\.(command|pipeline)' lib` finds no other caller). Every key it writes expires: presence 3600 s (`lib/tavern/ephemeral.ex:31-37`), typing 8 s (`:15-17`, `:57-60`), a rate-limit counter at the end of its window (`:99-100`). Losing Valkey logs nobody out and loses no content. It resets the rate-limit counters and shows everyone offline for a moment.

## What the platform gives

| Fact | Value | Source |
| --- | --- | --- |
| Postgres method | A logical dump of the whole cluster (`pg_dumpall`: every database and role), written as `postgres.sql`. There is no WAL archiving and no base backup | `nixos/cynic/backups.nix:7-23`, `nixos/backup-operations.md:7` |
| Postgres schedule | Daily 03:00 on cynic, plus up to 30 minutes of random delay. A run missed while the host was off runs at the next boot | `nixos/cynic/backups.nix:59`, `nixos/modules/restic-r2.nix:15-18` |
| Object store method | `garage meta snapshot`, then restic copies the volume `/var/lib/nomad/garage-data` without the live LMDB database | `nixos/cynic/backups.nix:69-77`, `docs/design/object-store.md:66-70` |
| Object store schedule | Daily 04:00, one hour after the Postgres dump | `nixos/cynic/backups.nix:76` |
| Where | One restic repository in Cloudflare R2, encrypted on the host before upload. Off the host, off the machine | `nixos/backup-operations.md:3` |
| Retention | 14 daily, 8 weekly, 12 monthly snapshots for each host and path, so each of the two Tavern sources keeps up to a year of history | `nixos/cynic/backups.nix:56`, `nixos/backup-operations.md:14` |
| Integrity | Each backup reads a random 5% of the stored data. After each backup, `restore-check-postgres` restores the newest dump into a throwaway container and checks the databases and tables. `restore-check-garage` restores the newest Garage snapshot and checks its files. A failed check fails its own unit and leaves `/var/lib/restore-check/<name>.json` | `nixos/cynic/backups.nix:58`, `nixos/backup-operations.md:20-49` |
| Restore commands | Cluster restore, one-database restore, object store restore, all written and tested | `nixos/backup-operations.md:103-161`; `tools/alchemy/scripts/restore-database.sh` |
| Not backed up | OpenBao (its snapshot and secrets) | `nixos/backup-operations.md:163-166` |

From these facts:

- **Recovery point objective (RPO), the most data a restore can lose:** up to about 24 hours of Postgres writes, and the same for uploads. There is no point-in-time recovery.
- **Recovery time objective (RTO), time to be back:** a person with shell access to cynic and the restic password. The platform's data was "a few hundred megabytes" in its own estimate (`docs/design/postgres-upgrades.md:69`), so a Tavern restore is minutes of work, not hours. No restore of Tavern's own data has run on the platform yet.
- **Retention keeps deleted data.** A deleted account's rows and a deleted message stay in older snapshots for up to 12 months. See "After a restore".
- **The pair is consistent in one direction.** Garage's snapshot is taken after Postgres's dump, so a pair from one night has a bucket at least as new as the database. See "Restore the uploads".

## Who can restore

A restore needs all three:

1. Shell access to cynic (`ssh cynic`, then `sudo`), because Postgres and Garage run in the `nomad` user's rootless Podman (`nixos/cynic/backups.nix:62`).
2. The restic repository settings and `RESTIC_PASSWORD`, in `/var/lib/backups/restic.env` on the host, and in the operator's password store. Losing the password makes every backup unrecoverable (`nixos/backup-operations.md:73`).
3. For a database swap, the `ops` login that `restore-database.sh` uses through `ssh` and `sudo` (`restore-database.sh:25-29`).

Today that is the operator. An agent has no `ops` path to the production database (roamancer task "ops db: query, dump and load a production app database"), so an agent writes the commands and the operator runs them.

## Runbook

Every command that touches production is a step the operator runs. Nothing here has run against production or staging.

### 0. Before any restore

1. Find out whether the backups are healthy. On cynic:

   ```sh
   sudo jq . /var/lib/restore-check/postgres.json /var/lib/restore-check/garage.json
   sudo restic-postgres snapshots     # newest snapshot of postgres.sql
   sudo restic-garage snapshots
   ```

   `status` must be `ok` and `finishedAt` recent.
2. Decide the restore point. Newest is the default. For an older one, pick its snapshot id in place of `latest` below, and use the Garage snapshot taken after it.
3. Stop writes when the restore must not race users. A swap ends the app's database sessions anyway (`restore-database.sh:20-23`), and the app reconnects to the restored data.

### 1. Restore the database from last night's backup

This follows `nixos/backup-operations.md:103-135`. In short, restore the cluster dump into a scratch Postgres, cut Tavern's database out of it, and swap it in.

1. Restore the cluster into a scratch container, as `nixos/backup-operations.md:107-124` writes it (same major as `tools/alchemy/platform/data/postgres.json`, currently 18). The `role "postgres" already exists` error is expected. Any other error stops the restore.
2. Count rows before you trust it: `podman exec pg-restore psql -U postgres -d tavern -c 'select count(*) from messages'`, and the same for `users` and `media_assets`.
3. Dump the one database and swap it in:

   ```sh
   podman exec pg-restore pg_dump -U postgres -Fc tavern > tavern.dump
   tools/alchemy/scripts/restore-database.sh cynic tavern tavern.dump
   ```

   The script restores into `tavern_restore` in one transaction, then renames. The replaced database stays as `tavern_before_restore_<UTC time>`, closed to connections, until you drop it. It keeps the grants that the migration `20261108031103_grant_visitor_role` made, because the platform's visitor role for Tavern exists before the restore (`restore-database.sh:7-14`, `priv/repo/migrations/20261108031103_grant_visitor_role.exs`).
4. Check the app: sign in, open a channel, read the newest message.
5. Drop `tavern_before_restore_*` and remove the scratch container (`podman rm -f pg-restore`) once Tavern checks out.

### 2. Restore onto a newer schema

A dump older than the running release lacks the newest migrations. This is the normal case after a restore from a few nights ago.

1. Restore as in step 1. The restored `schema_migrations` table lists only the migrations the dump had.
2. Run the release's migrate step. The cartridge's `migrate` command is `/app/bin/migrate` (`cartridge.json:28-29`), and it calls `Tavern.Release.migrate/0`, which runs `Ecto.Migrator.run(repo, :up, all: true)` and then `Bootstrap.ensure_seed_data!/0` (`lib/tavern/release.ex:8-13`). The platform runs it on the next deploy of the release. Redeploy the same release to run it now.
3. Check `select count(*), max(version) from schema_migrations` against the migration files in `priv/repo/migrations`.

Proved on the dev machine (see "Drill record"): a dump at 19 migrations restored into a new database, migrated to 20, and every table's row count matched the source.

### 3. Roll back a bad migration

The platform's rollback changes the running image, not the database: "It does not reverse database writes or schema changes" (`docs/design/staged-releases.md:13`). So a bad migration has two ways back. Choose by what the migration did.

**A. It ran, nothing else wrote bad data, and it has a `down`.** Roll the schema back one step, then deploy the previous release.

- Only a migration with an explicit `def down` can roll back. In this repository four migrations have one (`rg -l 'def down' priv/repo/migrations`); the other 16 use `change`, and a `change` that calls `execute/1` with one SQL string cannot reverse. Read the migration first.
- `Tavern.Release` has no rollback function today, so the release image cannot do this step. The dev drill used `mix ecto.rollback --step 1`, which Ecto logs as `== Migrated <version>` although it reverts (the log wording is misleading; check `schema_migrations`). A `Release.rollback/1` is filed in the task store (see "Gaps").

**B. It destroyed or corrupted data, or has no `down`.** Restore the database from a backup taken before the migration, then deploy the previous release.

- The nightly dump loses up to a day of writes. To lose none, take a dump just before the deploy. On cynic, as the operator:

  ```sh
  c=$(sudo -u nomad env XDG_RUNTIME_DIR=/run/user/1001 podman ps \
    --filter label=com.hashicorp.nomad.job_name=postgres \
    --filter label=com.hashicorp.nomad.task_name=server --format '{{.ID}}')
  sudo -u nomad env XDG_RUNTIME_DIR=/run/user/1001 podman exec "$c" \
    pg_dump -U postgres -Fc tavern > tavern-pre-<release>.dump
  ```

  This is the container lookup `nixos/cynic/backups.nix:13` uses. Keep the file off cynic's own disk. Restore it with `restore-database.sh cynic tavern <file>` (step 1, part 3).
- Then deploy the previous release. Its schema matches the restored data.

**Prevention.** Write migrations as expand then contract: add a column or table in one release, stop using the old one in the next, and drop it in a third. Then the previous image runs on the new schema, and most rollbacks need no restore. The platform task "Dump an app's databases before a deploy that migrates" asks for the automatic dump.

### 4. Restore the uploads

The steps are `nixos/backup-operations.md:137-161`: stop the `garage` job, restore the volume, make the newest snapshot the live database, start the job. It was tested on 2026-11-08 with a bucket, a key and one object (`nixos/backup-operations.md:161`). It restores every app's bucket, not only Tavern's.

Keep the database and the bucket consistent:

- **Database newer than bucket** is the bad case: a `media_assets` row names an object the bucket lacks, and `/uploads/<key>` returns not found (`lib/tavern/chat/media_assets.ex:25-35`). Restoring Postgres alone, or restoring Garage from an older night than the database, does not cause this. Restoring Garage from a night older than the Postgres dump does.
- **Bucket newer than database** is harmless: the bucket holds objects that no row names.
- After restoring only the database, nothing more is needed when you used the pair from one night (Garage 04:00 follows Postgres 03:00).
- After restoring Garage alone, or when the pair is mismatched, list the rows that lack an object: dump `select storage_key from media_assets where storage_provider = 's3'`, list the bucket, and for each missing key re-upload the file or delete the row. The app has no tool for this check yet (see "Gaps").

### 5. After a restore

- **Accounts deleted since the backup come back.** `Accounts.delete_account/2` wipes the user row (`docs/design/accounts.md:15-29`), but an older snapshot still holds the email and other data of a person who has since been deleted. A restore returns that data to the live database. After a restore, delete again every account deleted after the snapshot. Before you drop `tavern_before_restore_*`, list them there (`select id from users where deleted_at is not null`) and compare with the restored database. Once that database is gone, nothing records which accounts to delete again, so this is a gap, filed below.
- **Cursors.** When the event log lands (`docs/design/event-log.md:193`), the restore calls `Events.new_generation!/0` before the app starts, so every reader resyncs. It does not exist in `lib/` yet.
- **Secrets.** See below.

### Secrets

`secret_key_base` is a `GeneratedSecret` in OpenBao (`cartridge.json:62-67`), and the bucket key's secret is stored only in OpenBao (`docs/design/object-store.md:43`). OpenBao is not backed up. A restored Garage keeps its key, but OpenBao must still hold the secret (`nixos/backup-operations.md:18`). If OpenBao is lost and rebuilt, a new `secret_key_base` signs out every member, because the session cookie is signed with it. No row is lost: session and email-link tokens are rows (stored hashed, `lib/tavern/accounts.ex:105-113`), so they survive.

## Drill record

2026-11-20, dev machine. Throwaway containers of `postgres:18-alpine` (the platform's major), not the shared dev cluster, no production or staging. Source `tavern-drill-src` held the app's schema from `mix ecto.migrate` (20 migrations), the seed data from `Tavern.Bootstrap.ensure_seed_data!/0`, four registered users, 20 messages sent through `Tavern.Chat.create_message/3`, and one `media_assets` row.

| Step | Command | Result |
| --- | --- | --- |
| Dump like the nightly job | `docker exec tavern-drill-src pg_dumpall -U postgres > cluster.sql` | 91 KB, ends with the `dump complete` marker |
| Restore into a fresh cluster | `docker exec -i tavern-drill-dst psql -q -U postgres -d postgres < cluster.sql` | No error other than the expected one. The visitor role holds `SELECT` on `messages` |
| Compare every table | A `count(*)` over all 35 tables of both databases | Identical. Non-empty: `channels` 3, `media_assets` 1, `memberships` 4, `messages` 21, `roles` 2, `schema_migrations` 20, `server_settings` 1, `users` 5 |
| Roll back one migration on the restored copy | `mix ecto.rollback --step 1` | `schema_migrations` fell from 20 to 19 (`20261120022303` reverted) |
| Restore the 19-migration dump into a new database | `pg_dump -Fc`, then `pg_restore --exit-on-error --single-transaction -d tavern_old` | Completed |
| Restore onto the newer schema | `mix ecto.migrate` against `tavern_old` | Applied `20261120022303`. All 35 table counts equal the source |

To repeat it, start two containers, load data with `mix run` and a scratch script, and compare counts with:

```sh
docker exec -i <container> psql -U postgres -d <db> -Atq <<'SQL'
select format('%I.%I', schemaname, tablename) || ' ' ||
  (xpath('/row/c/text()', query_to_xml(format('select count(*) as c from %I.%I', schemaname, tablename), false, true, '')))[1]::text
from pg_tables where schemaname not in ('pg_catalog','information_schema') order by 1;
SQL
```

Run the drill again after a migration that changes roles, grants, extensions or the table owner, because a dump carries those.

What the drill did not prove: `restore-database.sh` (it needs `ssh` to cynic and `sudo`), the Garage restore (the platform tested it on 2026-11-08), and a restore from R2. Run `sudo systemctl start restore-check-postgres restore-check-garage` on cynic and read the result to cover the last.

## Gaps

These are things the platform or Tavern lacks. Platform gaps are filed in the roamancer project, and this repository's own in its task store.

| Gap | Where it is filed |
| --- | --- |
| No point-in-time recovery: a restore loses up to a day | roamancer, task "Postgres point-in-time recovery or more frequent dumps" |
| No dump before a deploy that migrates, and `ops rollback` leaves the schema | roamancer, existing task "Dump an app's databases before a deploy that migrates, and let ops rollback restore the dump" |
| OpenBao is not backed up, so `secret_key_base` and the bucket key's secret have one copy | roamancer, task "Back up OpenBao" |
| A one-database restore from the nightly backup takes a hand-run scratch cluster first | roamancer, task "Restore one app's database straight from the nightly backup" |
| No `ops` path to dump or load a production database | roamancer, existing task "ops db: query, dump and load a production app database" |
| `Tavern.Release` has no rollback function | rfchat task "Release.rollback" |
| A restore returns deleted accounts' data, and nothing records which accounts to delete again | rfchat task "Re-apply account deletions after a restore" |
| No check for `media_assets` rows whose object is missing | rfchat task "Find media_assets rows with no object" |
