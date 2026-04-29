defmodule Adam.MixProject do
  use Mix.Project

  def project do
    [
      app: :adam,
      version: "0.1.0",
      elixir: "~> 1.17",
      start_permanent: Mix.env() == :prod,
      deps: deps()
    ]
  end

  def application do
    [
      extra_applications: [:logger, :ssl, :crypto],
      mod: {Adam, []}
    ]
  end

  defp deps do
    [
      {:req, github: "wojtekmach/req", tag: "v0.5.10"},
      {:jason, github: "michalmuskala/jason", tag: "v1.4.4", override: true},
      {:gen_smtp, github: "gen-smtp/gen_smtp", tag: "1.3.0"},
      {:floki, github: "philss/floki", tag: "v0.37.0"},
      {:finch, github: "sneako/finch", tag: "v0.19.0", override: true},
      {:mime, github: "elixir-plug/mime", tag: "v2.0.6", override: true},
      {:mint, github: "elixir-mint/mint", tag: "v1.6.2", override: true},
      {:nimble_pool, github: "dashbitco/nimble_pool", tag: "v1.1.0", override: true},
      {:nimble_options, github: "dashbitco/nimble_options", tag: "v1.1.1", override: true},
      {:castore, github: "elixir-mint/castore", tag: "v1.0.10", override: true},
      {:hpax, github: "elixir-mint/hpax", tag: "v1.0.1", override: true},
      {:telemetry, github: "beam-telemetry/telemetry", tag: "v1.3.0", override: true},
      {:ranch, github: "ninenines/ranch", branch: "master", override: true},
      {:html_entities, github: "martinsvalin/html_entities", branch: "master", override: true}
    ]
  end
end
