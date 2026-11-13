# SPDX-FileCopyrightText: 2026 Mishka Group contributors <https://github.com/mishka-group/mishka_blog/graphs/contributors>
#
# SPDX-License-Identifier: Apache-2.0

defmodule MishkaBlogWeb.Test.AgentReceiptLiveTest do
  @moduledoc """
  The UI layer of a publish's receipt: with the posts page open, the page itself reports that it
  received this publish's broadcast (`MishkaCmsCore.Agent.UiObserver`), and the receipt says which
  page, never what it holds. With the page closed the same stage stays unverified.
  """
  use MishkaBlog.ConnCase

  import Phoenix.LiveViewTest
  import MishkaBlog.Test.Factory

  alias MishkaCmsCore.Agent.Receipts
  alias MishkaCmsCore.Runtime.States.SiteState

  @posts "/admin/dashboard/blog/posts"
  @await 5_000

  setup %{conn: conn} do
    Receipts.switch(true)
    SiteState.clear()
    :persistent_term.put(:mishka_installed, true)

    on_exit(fn ->
      Receipts.switch(false)
      :persistent_term.erase(:mishka_installed)
    end)

    n = System.unique_integer([:positive])
    home = create_site!(name: "localhost", host: "localhost", active: true, master: true)
    site = create_site!(name: "Receipt #{n}", host: "receipt-#{n}.localhost", active: true)
    Enum.each([home, site], &remember/1)

    admin =
      create_user_with_permissions!(["*"], email: "receipt-#{n}@example.com", site_id: site.id)

    post = create_blog_post!(site_id: site.id, status: :draft)

    {:ok, conn: conn, site: site, admin: admin, post: post}
  end

  defp remember(site) do
    SiteState.save(%{
      id: site.id,
      name: site.name,
      host: site.host,
      priority: site.priority,
      active: site.active,
      master: site.master
    })
  end

  defp publish(post, site, admin) do
    post
    |> Ash.Changeset.for_update(:publish, %{}, actor: admin, tenant: site.id)
    |> then(&Receipts.run("blog:blog_post:publish", &1, source: :agent))
  end

  defp ui(receipt, admin) do
    {:ok, read} = Receipts.get(receipt.id, admin)
    Enum.find(read.stages, &(&1.name == :ui_observed))
  end

  test "the open posts page verifies :ui_observed for the publish it received", ctx do
    {:ok, view, _html} =
      ctx.conn
      |> Map.put(:host, ctx.site.host)
      |> Map.update!(:req_headers, &[{"host", ctx.site.host} | List.keydelete(&1, "host", 0)])
      |> Plug.Test.init_test_session(%{})
      |> AshAuthentication.Plug.Helpers.store_in_session(ctx.admin)
      |> live(@posts)

    render_async(view, @await)

    {:ok, _post, receipt} = publish(ctx.post, ctx.site, ctx.admin)
    # A call to the page returns after it handled every message sent to it before.
    render(view)

    assert %{status: :verified, layer: :ui, observed: observed} = ui(receipt, ctx.admin)
    assert observed.view == MishkaBlogWeb.Live.Admin.Dashboard.Post.Index
    assert observed.event == "publish"
    assert Enum.sort(Map.keys(observed)) == [:event, :topic, :view]
  end

  test "with no page open nobody observed it, and the receipt says so", ctx do
    {:ok, _post, receipt} = publish(ctx.post, ctx.site, ctx.admin)

    assert %{status: :unverified, reason: :no_observer} = ui(receipt, ctx.admin)
    assert receipt.status == :verified
  end
end
