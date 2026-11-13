# SPDX-FileCopyrightText: 2026 Mishka Group contributors <https://github.com/mishka-group/mishka_blog/graphs/contributors>
#
# SPDX-License-Identifier: Apache-2.0

defmodule MishkaBlog.Test.Plugins.BlogAnalyticsPanelsProbe do
  @moduledoc """
  Test plugin on `blog:analytics:panels`: adds a "Referrers (Probe)" card read off the render,
  takes Quiet Posts out, and adds a tab to the Top card.
  """
  use MishkaInstaller.Event.Hook, event: "blog:analytics:panels"
  use Phoenix.Component

  @impl true
  def call(%{panels: panels} = state) do
    referrers = %{
      id: "referrers",
      title: "Referrers (Probe)",
      icon: "hero-globe-alt",
      size: :half,
      tabs: [
        %{
          id: "referrers",
          data: :referrers,
          load: {__MODULE__, :referrers, []},
          component: &__MODULE__.referrers_card/1
        }
      ]
    }

    probe_tab = %{
      id: "probe",
      label: "Probe tab",
      data: :referrers,
      load: {__MODULE__, :referrers, []},
      component: &__MODULE__.referrers_card/1
    }

    panels =
      panels
      |> Enum.reject(&(&1.id == "quiet"))
      |> Enum.map(fn
        %{id: "top"} = top -> %{top | tabs: top.tabs ++ [probe_tab]}
        panel -> panel
      end)

    {:reply, %{state | panels: panels ++ [referrers]}}
  end

  @doc "The referrers, as another source would answer them, by the period's `source` filter."
  def referrers(_user, period, _comments?),
    do: [%{host: "example.org", visits: 7, source: period.filters["source"] || "all"}]

  @doc "Draws the referrers."
  def referrers_card(assigns) do
    ~H"""
    <ul>
      <li :for={row <- @data} data-role="probe-referrer">{row.host} {row.visits} {row.source}</li>
    </ul>
    """
  end
end

defmodule MishkaBlog.Test.Plugins.BlogAnalyticsPanelProbe do
  @moduledoc """
  Test plugin on `blog:analytics:panel`: puts another source's total in the overview's place.
  """
  use MishkaInstaller.Event.Hook, event: "blog:analytics:panel"

  @impl true
  def call(%{panel: :overview, data: data} = state),
    do: {:reply, %{state | data: %{data | views_total: 4242}}}

  def call(state), do: {:reply, state}
end

defmodule MishkaBlog.Test.Plugins.BlogAnalyticsFiltersProbe do
  @moduledoc """
  Test plugin on `blog:analytics:filters`: adds a Source filter and takes the Team filter out.
  """
  use MishkaInstaller.Event.Hook, event: "blog:analytics:filters"

  @impl true
  def call(%{filters: filters} = state) do
    source = %{id: "source", label: "Source", choices: {__MODULE__, :sources, []}}

    {:reply, %{state | filters: Enum.reject(filters, &(&1.id == "team")) ++ [source]}}
  end

  @doc "The sources a period can be narrowed to."
  def sources(_user, _opts), do: {[{"Plausible", "plausible"}], false}
end
