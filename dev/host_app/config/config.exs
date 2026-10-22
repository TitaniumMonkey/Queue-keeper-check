import Config

config :host_app, ecto_repos: [HostApp.Repo]

config :host_app, HostApp.Repo,
  username: "postgres",
  password: "postgres",
  hostname: "localhost",
  database: "qk_host_app",
  pool_size: 10

config :host_app, Oban,
  repo: HostApp.Repo,
  queues: [default: 5],
  plugins: [{Oban.Plugins.Cron, crontab: [{"* * * * *", HostApp.Worker}]}, Oban.Plugins.Pruner]

config :logger, level: :info
