#!/bin/sh
# Runs once, when the Postgres volume is empty. It makes the two roles Tavern's migrations and
# server expect (priv/repo/migrations/20261108031103_grant_visitor_role.exs):
#   tavern_visitor  holds the table grants; it cannot log in.
#   tavern_api      the server's login; it holds nothing itself and switches to tavern_visitor.
# The owner login, `tavern`, runs the migrations and owns the tables.
set -eu

psql -v ON_ERROR_STOP=1 -v api_password="$TAVERN_DB_API_PASSWORD" \
  --username "$POSTGRES_USER" --dbname "$POSTGRES_DB" <<'SQL'
CREATE ROLE tavern_visitor NOLOGIN;
CREATE ROLE tavern_api LOGIN NOINHERIT PASSWORD :'api_password';
GRANT tavern_visitor TO tavern_api;
SQL
