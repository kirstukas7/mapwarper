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

Tile and WMS image responses are sent with no session cookie and

```
Cache-Control: max-age=<TILE_CACHE_MAX_AGE>, public
```

Responses also carry `Last-Modified`: the time the map was last warped (for a
mosaic, the latest re-warp of a member map or change to its map list).

Browsers and Cloudflare keep an image for `TILE_CACHE_MAX_AGE` (default 5
minutes). After that they ask again with `If-Modified-Since`. If the image hasn't changed, the app answers
`304 Not Modified` after one database lookup, without rendering, and the cached
copy is kept. Only a re-warp makes the app render new tiles. Errors, and WMS
`GetCapabilities`, are sent as `no-cache` and are never cached.

Tiles cache far better than WMS. Every client asks for the same XYZ tile URLs
(`/maps/tile/<id>/{z}/{x}/{y}.png`), while WMS requests carry a `BBOX` that
depends on the client's grid or current view, so they rarely repeat. The map
preview and mosaic pages therefore use tiles. Point outside users (QGIS, JOSM,
iD) to the tile URL on the Export tab rather than WMS where they can.

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

Check it works: request the same tile twice and look for `cf-cache-status: HIT`
and a `last-modified` header.

```bash
curl -sI https://maps.example.com/maps/tile/1/10/570/335.png | grep -iE "cf-cache-status|cache-control|last-modified"
```

Once a cached tile is older than `TILE_CACHE_MAX_AGE`, the next request shows
`cf-cache-status: REVALIDATED`, and the app log shows `304 Not Modified` for it.

**After re-warping a map**, the site's own pages (map preview, warp and mosaic
pages) show the new images at once: their tile and WMS URLs carry a `?v=`
version that changes on every re-warp. Outside tile URLs, such as ones pasted
into QGIS, get the new tiles at the next recheck: within `TILE_CACHE_MAX_AGE`,
or up to twice that if a browser fetched Cloudflare's copy just before it
expired (10 minutes at most by default). To update them at once, purge in
Cloudflare (Caching → Configuration → Purge Cache).

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
