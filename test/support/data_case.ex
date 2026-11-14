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
  length of a block (`with_plugin/3`), a shipped plugin for the length of a test
  (`register_plugin!/1`) and the SQL a block ran (`queries_while/1`).

  See `MishkaBlog.ConnCase` for tests that go through the JSON API instead.
  """

  use ExUnit.CaseTemplate

  require Ash.Query

  alias MishkaCmsCore.Runtime.Handlers.BootHandler
  alias MishkaCmsCore.Runtime.States.{SiteState, WebRunTimeMetaDataState}

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
  Registers and starts one of this extension's plugins the way the CMS boot does, and unregisters
  it when the test ends. The application's own plugins also register themselves at boot once the
  installer is ready, so one a test did not register may still be answering, but only until a test
  that registered it exits: the registry is shared by the whole run. A test whose result depends on
  a shipped plugin therefore calls this in its setup rather than relying on boot.

      setup do
        register_plugin!(MishkaBlog.Plugins.PostShareCard)
      end
  """
  def register_plugin!(plugin) do
    MishkaCmsCore.PluginRegistrations.reconcile(false)
    {:ok, _registered} = plugin.register()
    {:ok, _started} = plugin.start()

    ExUnit.Callbacks.on_exit(fn ->
      MishkaInstaller.Event.Event.unregister(:name, plugin, false)
    end)

    :ok = MishkaInstaller.Event.EventHandler.do_compile(plugin.config(:__event__), :start, false)
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

  @doc """
  Puts the pages of `site`, and the site itself, into the routing tables as the compile jobs put
  them in a running site — what a link to a row's page is found in (`MishkaBlog.Address`) — and
  takes them out when the test ends. A test that writes pages with no job running calls it once they are written.

      Provision.ensure!(site)
      route_pages!(site)
  """
  def route_pages!(site) do
    with {:error, :not_found} <- SiteState.get(site.id) do
      :ok =
        SiteState.save(%{
          id: site.id,
          name: site.name,
          host: site.host,
          priority: site.priority,
          active: site.active,
          master: site.master
        })

      ExUnit.Callbacks.on_exit(fn -> SiteState.delete(site.id) end)
    end

    MishkaCmsCore.Runtime.Page
    |> Ash.Query.for_read(:read_any, %{}, authorize?: false)
    |> Ash.Query.filter(site_id == ^site.id and active == true)
    |> Ash.Query.load(:site)
    |> Ash.read!(authorize?: false)
    |> Enum.each(&(:ok = WebRunTimeMetaDataState.save(BootHandler.web_metadata_row(&1, "Page"))))

    ExUnit.Callbacks.on_exit(fn -> WebRunTimeMetaDataState.delete_by_site(site.name) end)
    site
  end
end
