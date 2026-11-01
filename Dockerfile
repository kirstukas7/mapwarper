# Mapwarper needs the Mapserver Ruby bindings (ruby-mapscript), which Ubuntu
# ships built against the system Ruby. Ubuntu 18.04 gives Ruby 2.5 + GDAL 2.2,
# the combination documented in ubuntu18_installnotes.
FROM ubuntu:18.04

ENV DEBIAN_FRONTEND=noninteractive \
    LANG=C.UTF-8 \
    LC_ALL=C.UTF-8 \
    RAILS_ENV=production \
    BUNDLE_PATH=/usr/local/bundle \
    BUNDLE_WITHOUT=development:test \
    RAILS_SERVE_STATIC_FILES=1 \
    RAILS_LOG_TO_STDOUT=1

RUN apt-get update \
 && apt-get install -y --no-install-recommends \
      ruby ruby-dev build-essential pkg-config git ca-certificates curl tzdata \
      libpq-dev postgresql-client libxml2-dev libxslt1-dev zlib1g-dev shared-mime-info \
      imagemagick gdal-bin proj-bin ruby-mapscript nodejs file \
 && rm -rf /var/lib/apt/lists/* \
 && gem install bundler -v 1.17.3 --no-document

WORKDIR /app

COPY Gemfile Gemfile.lock ./
RUN bundle config build.nokogiri --use-system-libraries \
 && bundle _1.17.3_ install --jobs 4 --retry 3

COPY . .

# Config files the app expects. database.yml reads from the environment;
# application.yml is replaced at runtime by the mounted docker/application.yml.
RUN cp docker/database.yml config/database.yml \
 && cp config/secrets.yml.example config/secrets.yml \
 && cp docker/application.yml.example config/application.yml \
 && SECRET_KEY_BASE=precompile DB_HOST=none bundle exec rake assets:precompile \
 && useradd --create-home --uid 1000 app \
 && mkdir -p public/uploads public/system public/mapimages/src public/mapimages/dst \
             db/maptileindex db/imports log tmp/pids tmp/cache \
 && chown -R app:app public/uploads public/system public/mapimages db/maptileindex db/imports log tmp \
 && chmod +x docker/entrypoint.sh

USER app
EXPOSE 3000

ENTRYPOINT ["docker/entrypoint.sh"]
CMD ["bundle", "exec", "puma", "-C", "config/puma.rb"]
