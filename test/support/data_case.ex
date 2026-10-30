# SPDX-FileCopyrightText: 2026 Mishka Group contributors <https://github.com/mishka-group/mishka_blog/graphs/contributors>
#
# SPDX-License-Identifier: Apache-2.0

defmodule MishkaBlog.DataCase do
  @moduledoc """
  Test case for anything that touches the database but not the web layer — the resources, their
  actions and policies, the version trail, the dashboard queries.

  The core's `MishkaCmsCore.DataCase` with this extension's fixtures on top. The sandbox is the
  core's (`MishkaCmsCore.DataCase.setup_sandbox/1`): each test gets its own sandboxed connection and
  everything it writes is rolled back at the end; `async: false` (the default here) shares that
  connection with any process the test spawns, which the async data loaders behind the dashboard
  widgets rely on, and puts the site cache and the runtime modules back as the test found them.

  The helpers come from the core too — `errors_on/1` and the rest of `MishkaCmsCore.DataCase`, the
  sites, users and runtime records of `MishkaCmsCore.Test.Factory`, `MishkaCmsCore.Test.VersionHelpers`
  — and this case adds the blog's own: its records (`MishkaBlog.Test.Factory`), a plugin for the
  length of a block (`with_plugin/3`) and the SQL a block ran (`queries_while/1`).

  See `MishkaBlog.ConnCase` for tests that go through the JSON API instead.
  """

  use ExUnit.CaseTemplate

  using do
    quote do
      alias MishkaBlog.Repo

      import Ecto
      import Ecto.Changeset
      import Ecto.Query
      import MishkaCmsCore.DataCase
      import MishkaCmsCore.Test.Factory
      import MishkaCmsCore.Test.VersionHelpers
      import MishkaBlog.DataCase
      import MishkaBlog.Test.Factory
    end
  end

  setup tags do
    MishkaCmsCore.DataCase.setup_sandbox(tags)
    :ok
  end

  @doc """
  Runs `fun` with `module` registered and started as the plugin for `event`, and unregisters it
  afterwards.

      with_plugin(MyPlugin, "blog:comment:before_create_public", fn -> ... end)
  """
  def with_plugin(module, event, fun) do
    {:ok, _registered} =
      MishkaInstaller.Event.Event.write(%{
        name: module,
        event: event,
        extension: :mishka_installer,
        status: :started
      })

    :ok = MishkaInstaller.Event.EventHandler.do_compile(event, :start, false)

    try do
      fun.()
    after
      MishkaInstaller.Event.Event.unregister(:name, module, false)
    end
  end

  @doc """
  Runs `fun` and returns the SQL of every query the repo ran meanwhile, off the repo's own
  telemetry — the only mark a read whose answer nothing shows leaves.

      assert queries_while(fn -> render(view) end) == []
  """
  def queries_while(fun) do
    handler = "queries-#{System.unique_integer([:positive])}"
    listener = self()

    :telemetry.attach(
      handler,
      [:mishka_blog, :repo, :query],
      fn _event, _measurements, metadata, _config ->
        send(listener, {handler, metadata.query})
      end,
      nil
    )

    try do
      fun.()
      drain(handler, [])
    after
      :telemetry.detach(handler)
    end
  end

  defp drain(handler, gathered) do
    receive do
      {^handler, query} -> drain(handler, [query | gathered])
    after
      0 -> gathered
    end
  end
end
