# Running Mapwarper with Docker Compose

The stack has three services and plugs into an existing Traefik reverse proxy:

| Service | What it does |
|---------|--------------|
| `app`   | Rails app (Puma) with GDAL, ImageMagick and Mapserver mapscript |
| `db`    | PostgreSQL 11 + PostGIS 3.3 (`imresamu/postgis`, multi-arch) |
| `redis` | WMS/tile cache |

## Image builds

Every push to `master` triggers `.github/workflows/docker-image.yml`, which builds
the app image and pushes it to GitHub Container Registry as
`ghcr.io/<owner>/<repo>` (the GitHub repository it runs in, lowercased) with
these tags:

- `latest`: the newest build from `master`
- `sha-<commit>`: one tag per commit, so you can pin or roll back
- `<version>`: for git tags like `v1.2.0`

Images are built for both x86 (`linux/amd64`) and ARM (`linux/arm64`) servers;
Docker pulls the right one automatically.

You can also start a build by hand from the repository's Actions tab ("Run workflow").

New GHCR packages are private. Either make the package public (GitHub → your
profile → Packages → <repo> → Package settings → Change visibility), or log in
on the server once with a personal access token that has the `read:packages` scope:

```bash
docker login ghcr.io -u <github-username>
```

## Deploying to a server

The server does not need the source code, only these files:

```
docker-compose.yml
.env                      (from .env.example)
docker/application.yml    (from docker/application.yml.example)
```

1. Have Docker Engine with the compose plugin and a running Traefik v2/v3 on
   the server. Traefik needs the Docker provider enabled.
2. Point your domain's DNS A/AAAA record at the server.
3. Copy the files above to a folder on the server (or clone the repo there).
   In `.env`, set `MAPWARPER_IMAGE` to your published image.
4. Edit `.env`: set `DOMAIN`, `DB_PASSWORD`, and `SECRET_KEY_BASE`
   (`openssl rand -hex 64`). Add SMTP settings if you want signup emails.
   Set the three `TRAEFIK_*` values to match your Traefik setup (see below).
5. Edit `docker/application.yml`: set `host` to your domain, the email addresses,
   and the OAuth / hCaptcha / MapTiler keys you use.
6. Pull and start:

   ```bash
   docker compose pull
   docker compose up -d
   ```

   The first start loads the schema into the empty database. Follow progress
   with `docker compose logs -f app`.

## Traefik settings

The `app` container gets Traefik labels and joins Traefik's network. Three
values in `.env` must match your Traefik configuration:

| Variable | What it is | How to find it |
|----------|------------|----------------|
| `TRAEFIK_NETWORK` | Docker network Traefik is attached to | `docker network ls`, or the `networks:` of your Traefik compose file |
| `TRAEFIK_ENTRYPOINT` | Traefik's HTTPS entrypoint | `--entrypoints.<name>.address=:443` in Traefik's config |
| `TRAEFIK_CERTRESOLVER` | Traefik's certificate resolver | `--certificatesresolvers.<name>.acme...` in Traefik's config |

If Traefik already redirects HTTP to HTTPS globally, nothing else is needed.
The router is named `mapwarper`; rename it in the labels if that clashes with
another service.

## Cloudflare caching for tiles and WMS

Tile and WMS image responses are sent with
`Cache-Control: public, max-age=<TILE_CACHE_MAX_AGE>` (default one day) and no
session cookie, so Cloudflare and browsers can cache them. Errors, and WMS
`GetCapabilities`, are sent as `no-cache` and are never cached.

Cloudflare only caches URLs with a file extension by default, and WMS URLs have
none, so add a Cache Rule (Caching → Cache Rules → Create rule) with this
expression:

```
(starts_with(http.request.uri.path, "/maps/tile/") or starts_with(http.request.uri.path, "/maps/wms/") or starts_with(http.request.uri.path, "/mosaics/tile/") or starts_with(http.request.uri.path, "/mosaics/wms") or starts_with(http.request.uri.path, "/layers/tile/") or starts_with(http.request.uri.path, "/layers/wms"))
```

- Cache eligibility: **Eligible for cache**
- Edge TTL: **Use cache-control header if present**, bypass cache if not
- Browser TTL: **Respect origin**
- Cache key: turn on **Sort query string**, never **Ignore query string**. The
  default key already includes the full query string, which WMS requests need
  because they differ only by it. Sorting makes clients that order parameters
  differently share cache entries.

Check it works: request the same tile twice and look for `cf-cache-status: HIT`.

```bash
curl -sI https://maps.example.com/maps/tile/1/10/570/335.png | grep -iE "cf-cache-status|cache-control"
```

**After re-warping a map**, the editor pages fetch fresh images, but other users
and outside tile URLs can see the old version until the cache expires. To
update it sooner, purge in Cloudflare (Caching → Configuration → Purge Cache),
or lower `TILE_CACHE_MAX_AGE` in `.env`.

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

Push to `master`, wait for the workflow to finish, then on the server:

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
- Warping large images is memory hungry; give the server at least 4 GB of RAM.
- The image is based on Ubuntu 18.04 because the app needs Ruby 2.x with the
  distro's `ruby-mapscript` bindings. That base no longer receives free security
  updates, so keep the app behind Traefik and don't expose port 3000 directly.
