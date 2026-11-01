# Running Mapwarper with Docker Compose

The stack has four services:

| Service | What it does |
|---------|--------------|
| `app`   | Rails app (Puma) with GDAL, ImageMagick and Mapserver mapscript |
| `db`    | PostgreSQL 11 + PostGIS |
| `redis` | WMS/tile cache |
| `caddy` | Reverse proxy on ports 80/443 with automatic Let's Encrypt HTTPS |

## Image builds

Every push to `master` triggers `.github/workflows/docker-image.yml`, which builds
the app image and pushes it to GitHub Container Registry as
`ghcr.io/kirstukas7/mapwarper` with these tags:

- `latest`: the newest build from `master`
- `sha-<commit>`: one tag per commit, so you can pin or roll back
- `<version>`: for git tags like `v1.2.0`

You can also start a build by hand from the repository's Actions tab ("Run workflow").

New GHCR packages are private. Either make the package public (GitHub → your
profile → Packages → mapwarper → Package settings → Change visibility), or log in
on the VPS once with a personal access token that has the `read:packages` scope:

```bash
docker login ghcr.io -u kirstukas7
```

## Deploying to a VPS

The VPS does not need the source code, only these files:

```
docker-compose.yml
.env                      (from .env.example)
docker/Caddyfile
docker/application.yml    (from docker/application.yml.example)
```

1. Install Docker Engine with the compose plugin on the VPS
   (https://docs.docker.com/engine/install/).
2. Point your domain's DNS A/AAAA record at the VPS and open ports 80 and 443.
3. Copy the files above to a folder on the VPS (or clone the repo there).
4. Edit `.env`: set `DOMAIN`, `DB_PASSWORD`, and `SECRET_KEY_BASE`
   (`openssl rand -hex 64`). Add SMTP settings if you want signup emails.
5. Edit `docker/application.yml`: set `host` to your domain, the email addresses,
   and the OAuth / hCaptcha / MapTiler keys you use.
6. Pull and start:

   ```bash
   docker compose pull
   docker compose up -d
   ```

   The first start loads the schema into the empty database. Follow progress
   with `docker compose logs -f app`.

## Creating an admin user

```bash
docker compose exec app bundle exec rails runner '
  u = User.new(login: "super", email: "you@example.com", password: "change-me", password_confirmation: "change-me")
  u.confirmed_at = Time.now
  u.save!
  ["super user", "administrator"].each { |r| Permission.create!(role: Role.find_by_name(r), user: u) }
'
```

## Updating

Push to `master`, wait for the workflow to finish, then on the VPS:

```bash
docker compose pull app
docker compose up -d
```

Migrations run automatically when the app container starts. To roll back, set
`MAPWARPER_IMAGE` in `.env` to an earlier `sha-…` tag and run `docker compose up -d`.

## Data and backups

Uploaded and warped maps live in named Docker volumes (`uploads`, `mapimages`,
`maptileindex`, `imports`, `system`), the database in `db_data`. Back up the
database with:

```bash
docker compose exec db pg_dump -U mapwarper mapwarper_production | gzip > mapwarper.sql.gz
```

## Notes

- Puma runs `WEB_CONCURRENCY` worker processes with one thread each, because
  Mapserver mapscript is not thread safe. Raise it if you have spare RAM/CPU.
- Warping large images is memory hungry; give the VPS at least 4 GB of RAM.
- The image is based on Ubuntu 18.04 because the app needs Ruby 2.x with the
  distro's `ruby-mapscript` bindings. That base no longer receives free security
  updates, so keep the app behind Caddy and don't expose port 3000 directly.
