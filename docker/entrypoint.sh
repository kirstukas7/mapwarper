#!/bin/sh
set -e

# Map image directories live on a volume; make sure the subfolders exist.
mkdir -p public/mapimages/src public/mapimages/dst tmp/pids
rm -f tmp/pids/server.pid

if [ "$1" = "bundle" ] && [ "$2" = "exec" ] && [ "$3" = "puma" ]; then
  export PGPASSWORD="$DB_PASSWORD"
  echo "Waiting for PostgreSQL at $DB_HOST..."
  until pg_isready -q -h "$DB_HOST" -p "${DB_PORT:-5432}" -U "$DB_USER"; do
    sleep 2
  done

  has_schema=$(psql -h "$DB_HOST" -p "${DB_PORT:-5432}" -U "$DB_USER" -d "$DB_NAME" -tAc \
    "select to_regclass('public.schema_migrations') is not null")
  if [ "$has_schema" = "t" ]; then
    echo "Running migrations..."
    bundle exec rake db:migrate
  else
    echo "Empty database: loading schema and seeds..."
    bundle exec rake db:schema:load db:seed
  fi
fi

exec "$@"
