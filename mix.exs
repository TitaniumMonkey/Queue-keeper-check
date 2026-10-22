defmodule QueueKeeperCheck.MixProject do
  use Mix.Project

  @version "0.2.1"
  @source_url "https://github.com/TitaniumMonkey/Queue-keeper-check"

  def project do
    [
      app: :queue_keeper_check,
      version: @version,
      elixir: "~> 1.15",
      elixirc_paths: elixirc_paths(Mix.env()),
      start_permanent: Mix.env() == :prod,
      deps: deps(),
      description:
        "Read-only health check for Oban queues: orphaned, hanging, backed-up and stalled queues, " <>
          "retry storms, discard/cancel spikes and missing cron jobs. Postgres, SQLite and MySQL.",
      package: package(),
      docs: docs(),
      source_url: @source_url,
      homepage_url: "https://queuekeeper.dev"
    ]
  end

  def application, do: [extra_applications: [:logger]]

  defp elixirc_paths(:test), do: ["lib", "test/support"]
  defp elixirc_paths(_), do: ["lib"]

  defp package do
    [
      licenses: ["MIT"],
      links: %{
        "GitHub" => @source_url,
        "Website" => "https://queuekeeper.dev",
        "Changelog" => "#{@source_url}/blob/main/CHANGELOG.md"
      },
      files: ~w(lib mix.exs README.md LICENSE CHANGELOG.md SECURITY.md)
    ]
  end

  defp docs do
    [
      main: "readme",
      extras: [
        "README.md",
        "CHANGELOG.md",
        "SECURITY.md",
        "docs/SECURITY_REVIEW.md",
        "docs/OBAN_PRO_COMPATIBILITY.md",
        "LICENSE"
      ],
      source_ref: "v#{@version}",
      source_url: @source_url
    ]
  end

  defp deps do
    [
      {:oban, "~> 2.18"},
      {:ecto_sql, "~> 3.10"},
      {:jason, "~> 1.4"},
      {:postgrex, "~> 0.17", only: :test},
      {:ecto_sqlite3, "~> 0.17", only: :test},
      {:myxql, "~> 0.7", only: :test},
      {:ex_doc, "~> 0.34", only: :dev, runtime: false}
    ]
  end
end
