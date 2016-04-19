defmodule Croma.Mixfile do
  use Mix.Project

  @github_url "https://github.com/skirino/croma"

  def project do
    [
      app:             :croma,
      version:         "0.4.2",
      elixir:          "~> 1.2",
      build_embedded:  Mix.env == :prod,
      start_permanent: Mix.env == :prod,
      compilers:       compilers,
      deps:            deps,
      description:     description,
      package:         package,
      source_url:      @github_url,
      homepage_url:    @github_url,
      test_coverage:   [tool: Coverex.Task, coveralls: true],
    ]
  end

  def application do
    []
  end

  defp compilers do
    additional = if Mix.env == :prod, do: [], else: [:exref]
    Mix.compilers ++ additional
  end

  defp deps do
    [
      {:exref, "~> 0.1", only: [:dev, :test]},
      {:excheck, "~> 0.3", only: :test},
      {:triq, github: "krestenkrab/triq", only: :test},
      {:coverex, "~> 1.4", only: :test},
      {:dialyze, "~> 0.2", only: :dev},
      {:earmark, "~> 0.2", only: :dev},
      {:ex_doc, "~> 0.11", only: :dev},
      {:inch_ex, "~> 0.5", only: :docs},
    ]
  end

  defp description do
    """
    Elixir macro utilities
    """
  end

  defp package do
    [
      files:       ["lib", "mix.exs", "README.md", "LICENSE"],
      maintainers: ["Shunsuke Kirino"],
      licenses:    ["MIT"],
      links:       %{"GitHub repository" => @github_url, "Doc" => "http://hexdocs.pm/croma/"},
    ]
  end
end
