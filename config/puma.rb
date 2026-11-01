# Mapscript is not thread safe, so scale with worker processes, one thread each.
workers Integer(ENV.fetch('WEB_CONCURRENCY', 2))
threads 1, 1

port ENV.fetch('PORT', 3000)
environment ENV.fetch('RAILS_ENV', 'production')

# Warping and tiling large images can take a while.
worker_timeout 600

preload_app!

on_worker_boot do
  ActiveRecord::Base.establish_connection if defined?(ActiveRecord)
end
