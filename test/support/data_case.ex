defmodule MishkaBlog.DataCase do
  @moduledoc """
  Test case for anything that touches the database but not the web layer — the resources, their
  actions and policies, the version trail, the dashboard queries.

  Stands in for the CMS's `MishkaCms.DataCase` so this suite runs without the CMS around it. Each
  test gets its own sandboxed connection and everything it writes is rolled back at the end;
  `async: false` (the default here) shares that connection with any process the test spawns, which
  the async data loaders behind the dashboard widgets rely on.

  See `MishkaBlog.ConnCase` for tests that go through the JSON API instead.
  """

  use ExUnit.CaseTemplate

  @repo Application.compile_env!(:mishka_cms_core, :repo)

  using do
    quote do
      alias MishkaBlog.Repo

      import Ecto
      import Ecto.Changeset
      import Ecto.Query
      import MishkaBlog.DataCase
      import MishkaBlog.Test.Factory
      import MishkaBlog.Test.VersionHelpers
    end
  end

  setup tags do
    setup_sandbox(tags)
    :ok
  end

  @doc "Checks out a sandboxed connection for the test, shared with its spawned processes unless async."
  def setup_sandbox(tags) do
    pid = Ecto.Adapters.SQL.Sandbox.start_owner!(@repo, shared: not tags[:async])
    on_exit(fn -> Ecto.Adapters.SQL.Sandbox.stop_owner(pid) end)
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

  @doc """
  Turns changeset errors into a map of field to messages.

      assert %{password: ["password is too short"]} = errors_on(changeset)
  """
  def errors_on(changeset) do
    Ecto.Changeset.traverse_errors(changeset, fn {message, opts} ->
      Regex.replace(~r"%{(\w+)}", message, fn _, key ->
        opts |> Keyword.get(String.to_existing_atom(key), key) |> to_string()
      end)
    end)
  end
end
