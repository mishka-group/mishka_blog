# SPDX-FileCopyrightText: 2026 Mishka Group contributors <https://github.com/mishka-group/mishka_blog/graphs/contributors>
#
# SPDX-License-Identifier: Apache-2.0

defmodule MishkaBlogWeb.Test.DoctorChecksTest do
  @moduledoc """
  The checks installed extensions add to the blog's check and repair window on `doctor:checks`
  (`MishkaCmsCore.Install.DoctorChecks`): the dashboard hands the window its signed-in admin, so an
  admin holding a check's area is shown it when the window opens, and one without it is not.

  The plugin is `MishkaBlog.Test.Plugins.BlogDoctorChecksProbe`; no real extension's check is
  tested here. The plugin registry is process-global, so the suite is not async.
  """
  use MishkaBlog.ConnCase

  import Phoenix.LiveViewTest

  alias MishkaBlog.Provision
  alias MishkaBlog.Test.Plugins.BlogDoctorChecksProbe
  alias MishkaCmsCore.Install.{DoctorChecks, Extensions}
  alias MishkaCmsCore.Runtime.ExtensionProvision
  alias MishkaCmsCore.Runtime.States.SiteState
  alias MishkaCmsCore.Test.Installer, as: TestInstaller

  setup %{conn: conn} do
    SiteState.clear()

    site = create_site!(name: "localhost", host: "localhost", active: true, master: true)
    SiteState.save(Map.take(site, [:id, :name, :host, :priority, :active, :master]))

    :persistent_term.put(:mishka_installed, true)

    on_exit(fn ->
      :persistent_term.erase(:mishka_installed)
      SiteState.clear()
    end)

    :ok = Extensions.mark_installed!(site.id, :mishka_blog, "test")
    TestInstaller.register!(BlogDoctorChecksProbe, DoctorChecks.event())

    conn =
      conn
      |> Map.put(:host, "localhost")
      |> Map.update!(:req_headers, &[{"host", "localhost"} | List.keydelete(&1, "host", 0)])

    {:ok, conn: conn, site: site}
  end

  test "an admin holding the check's area is shown it in the window", %{conn: conn, site: site} do
    view = open(conn, admin!(site, [BlogDoctorChecksProbe.permission()]))

    assert has_element?(view, "[data-check='probe:probe'][data-outcome=ok]", "Probe check")

    close(view)
  end

  test "an admin without the check's area is not shown it", %{conn: conn, site: site} do
    view = open(conn, admin!(site, []))

    assert has_element?(view, "#blog-kit-upgrade-doctor")
    refute has_element?(view, "[data-check='probe:probe']")
    refute render(view) =~ "Probe check"

    close(view)
  end

  # A site admin who may open the window — the names the set-up asks for — and `areas` besides.
  defp admin!(site, areas) do
    create_user_with_permissions!(
      ["admin:dashboard:blog:post" | ExtensionProvision.required(Provision.manifest())] ++ areas,
      site_id: site.id
    )
  end

  # Opens the window the way the dashboard's wrench does, and waits for its checks to answer.
  defp open(conn, admin) do
    {:ok, view, _html} = conn |> log_in(admin) |> live("/admin/dashboard/blog")

    view |> element("#blog-kit-upgrade-open") |> render_click()
    render_async(view, 5_000)
    view
  end

  defp log_in(conn, user) do
    conn
    |> Plug.Test.init_test_session(%{})
    |> Plug.Conn.put_session(:master_mode, false)
    |> AshAuthentication.Plug.Helpers.store_in_session(user)
  end

  # The dashboard's figures load in a `start_async/3`; a view stopped while one is in flight raises
  # on the way down once the test's sandbox owner is gone.
  defp close(view) do
    render_async(view, 5_000)
    ref = Process.monitor(view.pid)
    GenServer.stop(view.pid, :normal)
    assert_receive {:DOWN, ^ref, :process, _pid, _reason}
  end
end
