# SPDX-FileCopyrightText: 2026 Mishka Group contributors <https://github.com/mishka-group/mishka_blog/graphs/contributors>
#
# SPDX-License-Identifier: Apache-2.0

defmodule MishkaBlog.Test.PluginReadiness do
  @moduledoc """
  Holds the test run until the plugins it names are live: each `:started` in `mishka_installer`,
  and every event they joined rebuilt with them in it.

  A plugin registers from its own `handle_continue` once `mishka_installer` is ready, and on a slow
  boot tries again a second later — after the first tests have asked its event. Without this wait
  the first tests of a run find no `MishkaBlogWeb.SidebarMenu` on `"sidebar:menus"`, so every blog
  admin page declares no permission and refuses its admin ("You don't have permission to access
  this page"). The same wait the CMS's core suite starts with, which a dependency's `test/support`
  cannot reach.

      MishkaBlog.Test.PluginReadiness.await(plugins)
  """

  alias MishkaInstaller.Event.{Event, EventHandler}
  alias MishkaInstaller.QueueAssistant

  @spec await([module()], timeout()) :: :ok
  def await(plugins, timeout \\ :timer.seconds(30)) do
    MishkaInstaller.subscribe("event")

    plugins
    |> Enum.reject(&started?/1)
    |> wait(timeout)

    MishkaInstaller.unsubscribe("event")
    flush()
    drain()
  end

  defp started?(plugin), do: match?(%{status: :started}, Event.get(:name, plugin))

  defp wait([], _timeout), do: :ok

  defp wait(waiting, timeout) do
    receive do
      %{channel: "event", status: :start, data: %{name: name}} ->
        waiting |> List.delete(name) |> Enum.reject(&started?/1) |> wait(timeout)
    after
      timeout -> raise "these plugins never started: #{inspect(waiting)}"
    end
  end

  defp flush do
    receive do
      %{channel: "event"} -> flush()
    after
      0 -> :ok
    end
  end

  defp drain do
    state = EventHandler.get()

    if Keyword.get(state, :running, []) == [] and
         QueueAssistant.empty?(Keyword.get(state, :queues)),
       do: :ok,
       else: drain()
  end
end
