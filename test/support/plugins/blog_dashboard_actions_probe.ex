# SPDX-FileCopyrightText: 2026 Mishka Group contributors <https://github.com/mishka-group/mishka_blog/graphs/contributors>
#
# SPDX-License-Identifier: Apache-2.0

defmodule MishkaBlog.Test.Plugins.BlogDashboardActionsProbe do
  @moduledoc """
  Test plugin on `blog:dashboard:actions`: a link, a button that runs a `JS` command, an action whose
  id is taken, and one with nowhere to go. The first two are the only ones the header may draw.
  """
  use MishkaInstaller.Event.Hook, event: "blog:dashboard:actions"

  alias Phoenix.LiveView.JS

  @doc "The action that links to a path."
  def link_action,
    do: %{
      id: "probe-link",
      label: "Probe link",
      icon: "hero-arrow-down-tray",
      priority: 20,
      path: "/admin/dashboard/blog/tags"
    }

  @doc "The action that runs a command."
  def js_action,
    do: %{
      id: "probe-js",
      label: "Probe button",
      icon: "hero-bolt",
      priority: 10,
      js: JS.toggle(to: "#blog-calendar")
    }

  @impl true
  def call(%{actions: actions} = data) do
    extra = [
      link_action(),
      js_action(),
      %{link_action() | label: "Same id again"},
      %{id: "probe-bare", label: "Bare", icon: "hero-bolt", priority: 1},
      link_action() |> Map.put(:id, "probe-both") |> Map.put(:js, JS.toggle(to: "#x"))
    ]

    {:reply, %{data | actions: actions ++ extra}}
  end
end
