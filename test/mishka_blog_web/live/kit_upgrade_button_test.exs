# SPDX-FileCopyrightText: 2026 Mishka Group contributors <https://github.com/mishka-group/mishka_blog/graphs/contributors>
#
# SPDX-License-Identifier: Apache-2.0

defmodule MishkaBlogWeb.Test.KitUpgradeButtonTest do
  @moduledoc """
  The check-and-repair modal on the blog dashboard: what it reports before it writes anything, and
  what each of its three buttons writes.

  This is the only way an EXISTING site takes newer components. "Set up blog pages" installs what a
  site is missing and touches nothing it has — deliberately, so an admin's work is never lost to it
  — which left every site that was provisioned once on the components it was provisioned with.

  The site here is provisioned and then AGED: the version stamp on its rows is put back, which is
  exactly the state a site installed from an older bundle is in. Nothing here depends on the
  bundle's own version staying where it is.
  """
  use MishkaBlog.ConnCase
  use Oban.Testing, repo: MishkaBlog.Repo

  import Phoenix.LiveViewTest
  import MishkaBlog.Test.Factory

  alias MishkaBlog.Plugins.ShareCardTargets
  alias MishkaBlog.Provision
  alias MishkaBlog.Test.VersionHelpers
  alias MishkaCmsCore.Accounts.{Permission, User, UserPermission}
  alias MishkaCmsCore.Install.Extensions
  alias MishkaCmsCore.Runtime.{Component, ExtensionProvision}
  alias MishkaCmsCore.Runtime.Handlers.UiKitUpgrade
  alias MishkaCmsCore.Runtime.Page
  alias MishkaCmsCore.Runtime.PageDraft
  alias MishkaCmsCore.Runtime.ShareCard
  alias MishkaCmsCore.Runtime.States.SiteState
  alias MishkaCmsCore.Runtime.Workers.{ShareCardPlanWorker, ShareCardRefreshWorker}
  alias MishkaInstaller.Event.{Event, EventHandler}

  require Ash.Query

  @password "Password123!"
  @mine ~S(<div id={@id}>mine</div>)

  # HOW MANY THE BUNDLE SHIPS, read off the bundle rather than written here. The kit's components
  # are split and joined as the blog grows; a number typed into an assertion turns every one of
  # those into a test failure that says nothing.
  @components length(MishkaBlog.Provision.component_names())

  setup %{conn: conn} do
    SiteState.clear()
    :ok = Swoosh.TestAssertions.set_swoosh_global()

    site = create_site!(name: "localhost", host: "localhost", active: true, master: true)

    SiteState.save(%{
      id: site.id,
      name: site.name,
      host: site.host,
      priority: site.priority,
      active: site.active,
      master: site.master
    })

    :persistent_term.put(:mishka_installed, true)

    on_exit(fn ->
      :persistent_term.erase(:mishka_installed)
      SiteState.clear()
    end)

    conn =
      conn
      |> Map.put(:host, "localhost")
      |> Map.update!(:req_headers, &[{"host", "localhost"} | List.keydelete(&1, "host", 0)])

    {:ok, conn: conn, site: site}
  end

  # THE SITE AS THE INSTALLER LEAVES IT: what the blog ships, and the record core writes once the run
  # is over. That record is the whole answer to whether a site has the blog
  # (`Extensions.installed?/2`) — a site holding every component and page and no record opens on the
  # installer, and the modal this suite is about is not on that screen.
  defp set_up!(site) do
    report = Provision.ensure!(site)

    :ok = Extensions.mark_installed!(site.id, :mishka_blog, report.version)
  end

  defp components(site) do
    Component
    |> Ash.Query.for_read(:read_any, %{}, authorize?: false)
    |> Ash.Query.filter(site_id == ^site.id)
    |> Ash.read!(authorize?: false, page: [limit: 100])
    |> Map.fetch!(:results)
  end

  defp component!(site, name), do: Enum.find(components(site), &(&1.name == name))

  # THE STATE EVERY SITE PROVISIONED BEFORE THIS FEATURE IS IN, produced the only way a test can:
  # the rows are installed from the bundle in this checkout, put back to what an older bundle would
  # have written, and stamped as though that older bundle had written them.
  #
  # BOTH HALVES, because either alone is a different site. A row whose stamp is put back while its
  # content still matches the bundle byte for byte has nothing an update could give it, and one
  # whose content is put back without its fingerprint is a row somebody edited. What the check is
  # for is the site where the kit moved and nobody here touched it.
  defp age!(site) do
    for component <- components(site) do
      older = %{component | description: "as #{component.name} read at 0.0.1"}

      Ash.update!(
        component,
        %{
          description: older.description,
          extra:
            component.extra
            |> Map.put("ui_kit_version", "0.0.1")
            |> Map.put("ui_kit_digest", UiKitUpgrade.digest(older))
        },
        action: :master_update,
        authorize?: false,
        tenant: site.id
      )
    end
  end

  defp edit!(site, name) do
    site
    |> component!(name)
    |> Ash.update!(%{template: @mine}, action: :master_update, authorize?: false, tenant: site.id)
  end

  defp page!(site, path) do
    Page
    |> Ash.Query.for_read(:read_any, %{}, authorize?: false)
    |> Ash.Query.filter(site_id == ^site.id and path == ^path)
    |> Ash.read_one!(authorize?: false)
  end

  defp drafts(site, page) do
    PageDraft
    |> Ash.Query.for_read(:read_any, %{}, authorize?: false)
    |> Ash.Query.filter(site_id == ^site.id and source_page_id == ^page.id)
    |> Ash.read!(authorize?: false, page: [limit: 20])
    |> Map.fetch!(:results)
  end

  # THE STATE A SITE SET UP BEFORE THE INDEX PAGE WAS SPLIT IS IN: it answers at `/:lang/blog` with
  # the markup it was given then, which is neither what this checkout ships nor anything anybody
  # here typed — and nothing in the extension ever looked at it again.
  defp aged_page!(site) do
    site
    |> page!("/:lang/blog")
    |> Ash.update!(%{template: @mine}, action: :master_update, authorize?: false, tenant: site.id)
  end

  describe "a master who may edit the site's runtime" do
    setup %{conn: conn, site: site} do
      set_up!(site)

      {:ok, conn: log_in(conn, admin_with!("blogkit@example.com", "*"))}
    end

    test "is told there is nothing to do on a site the bundle has nothing newer for", %{
      conn: conn,
      site: site
    } do
      {:ok, view, _html} = live(conn, "/admin/dashboard/blog")

      assert has_element?(view, "#blog-kit-upgrade")
      refute has_element?(view, "#blog-kit-upgrade-report")

      view |> form("#blog-kit-upgrade-form", %{"site_id" => site.id}) |> render_submit()

      assert has_element?(view, "#blog-kit-upgrade-headline", "up to date")
      assert has_element?(view, "#blog-kit-upgrade-current")
      refute has_element?(view, "#blog-kit-upgrade-safe")
      refute has_element?(view, "#blog-kit-upgrade-all")

      close(view)
    end

    test "reports every outdated component before writing anything", %{conn: conn, site: site} do
      age!(site)

      {:ok, view, _html} = live(conn, "/admin/dashboard/blog")

      view |> form("#blog-kit-upgrade-form", %{"site_id" => site.id}) |> render_submit()

      assert has_element?(
               view,
               "#blog-kit-upgrade-headline",
               "#{@components} components behind the bundle"
             )

      assert has_element?(view, "#blog-kit-upgrade-ready-0", "installed from 0.0.1, untouched")
      assert has_element?(view, "#blog-kit-upgrade-safe", "Update #{@components} components")
      refute has_element?(view, "#blog-kit-upgrade-choice")

      assert component!(site, "blog-post-list").extra["ui_kit_version"] == "0.0.1",
             "reading what is outdated wrote to the site"

      close(view)
    end

    test "updates them when the admin presses it, and says everything is current after", %{
      conn: conn,
      site: site
    } do
      age!(site)

      {:ok, view, _html} = live(conn, "/admin/dashboard/blog")

      view |> form("#blog-kit-upgrade-form", %{"site_id" => site.id}) |> render_submit()
      html = view |> element("#blog-kit-upgrade-safe") |> render_click()

      assert html =~ "Updated #{@components} components"

      for component <- components(site) do
        assert UiKitUpgrade.digest(component) == component.extra["ui_kit_digest"],
               "#{component.name} was not written as the bundle has it"
      end

      refute has_element?(view, "#blog-kit-upgrade-safe"), "there is still something to update"

      html = view |> form("#blog-kit-upgrade-form", %{"site_id" => site.id}) |> render_submit()

      assert html =~ "up to date"

      close(view)
    end

    # THE HALF THE WHOLE CHECK EXISTS FOR. An edited row is reported, left where it is by the safe
    # button, and only written when the admin presses the second one — which says on screen that
    # what it replaces stays in the component's history.
    test "leaves a component the admin edited until they ask for it", %{conn: conn, site: site} do
      age!(site)
      edited = edit!(site, "blog-post-list")

      {:ok, view, _html} = live(conn, "/admin/dashboard/blog")

      view |> form("#blog-kit-upgrade-form", %{"site_id" => site.id}) |> render_submit()

      assert has_element?(view, "#blog-kit-upgrade-choice-0", "blog-post-list")
      assert has_element?(view, "#blog-kit-upgrade-choice-0", "edited here since")
      assert has_element?(view, "#blog-kit-upgrade-choice", "kept in the component's history")
      assert has_element?(view, "#blog-kit-upgrade-safe", "Update #{@components - 1} components")

      html = view |> element("#blog-kit-upgrade-safe") |> render_click()

      assert html =~ "1 component left for you to decide on"
      assert component!(site, "blog-post-list").template == @mine

      html = view |> element("#blog-kit-upgrade-all") |> render_click()

      assert html =~ "kept in its history"
      refute component!(site, "blog-post-list").template == @mine

      assert VersionHelpers.version_with_changes(
               Component.Version,
               edited.id,
               %{template: @mine},
               tenant: site.id
             ),
             "the admin cannot restore what the update replaced"

      close(view)
    end

    test "never offers a component the admin archived", %{conn: conn, site: site} do
      age!(site)
      archived = component!(site, "blog-tag-cloud")
      :ok = Ash.destroy!(archived, action: :master_destroy, authorize?: false, tenant: site.id)

      {:ok, view, _html} = live(conn, "/admin/dashboard/blog")

      view |> form("#blog-kit-upgrade-form", %{"site_id" => site.id}) |> render_submit()

      assert has_element?(view, "#blog-kit-upgrade-archived-0", "blog-tag-cloud")
      assert has_element?(view, "#blog-kit-upgrade-safe", "Update #{@components - 1} components")

      view |> element("#blog-kit-upgrade-safe") |> render_click()

      refute component!(site, "blog-tag-cloud"), "an archived component came back as a new row"

      close(view)
    end

    test "cannot be pointed at a site the page never offered", %{conn: conn, site: site} do
      age!(site)

      {:ok, view, _html} = live(conn, "/admin/dashboard/blog")

      html = render_submit(view, "kit_check", %{"site_id" => Ash.UUID.generate()})

      assert html =~ "That is not a site this page can update."
      refute has_element?(view, "#blog-kit-upgrade-report")

      close(view)
    end

    test "redraws the blog's own share cards on the site it is about", %{conn: conn, site: site} do
      MishkaCmsCore.PluginRegistrations.reconcile(false)
      {:ok, _} = ShareCardTargets.register()
      on_exit(fn -> Event.unregister(:name, ShareCardTargets, false) end)
      :ok = EventHandler.do_compile(ShareCard.targets_event(), :start, false)

      create_blog_post!(site_id: site.id, status: :published, slug: "shared", language: "en")

      {:ok, view, _html} = live(conn, "/admin/dashboard/blog")
      view |> form("#blog-kit-upgrade-form", %{"site_id" => site.id}) |> render_submit()

      assert has_element?(view, "#blog-kit-upgrade-share-cards")
      view |> element("#blog-kit-upgrade-share-cards-redraw-button") |> render_click()

      planner = %{site_id: site.id, force: true, producer: "mishka_blog"}
      assert_enqueued([worker: ShareCardPlanWorker, args: planner], 1_000)
      assert :ok = perform_job(ShareCardPlanWorker, planner)

      looks = Enum.filter(all_enqueued(worker: ShareCardRefreshWorker), & &1.args["force"])

      assert Enum.map(looks, & &1.args["target"]) == [
               %{"record" => "blog:post", "params" => %{"slug" => "shared", "lang" => "en"}}
             ]

      render_async(view, 5_000)

      assert has_element?(
               view,
               "#blog-kit-upgrade-share-cards-redraw-status",
               "Queued #{length(looks)} share card"
             )

      close(view)
    end

    test "refuses to write before anything has been checked", %{conn: conn, site: site} do
      age!(site)

      {:ok, view, _html} = live(conn, "/admin/dashboard/blog")

      html = render_click(view, "kit_upgrade", %{"mode" => "all"})

      assert html =~ "Check for updates first."
      assert component!(site, "blog-post-list").extra["ui_kit_version"] == "0.0.1"

      close(view)
    end
  end

  # THE OTHER HALF, and the one that must never write anything live: a page is what a
  # site's readers are looking at. The blog's featured strip became a component of its own and the
  # index page that places it was rewritten in the same commit — and every site already serving that
  # page kept the one it had, with nothing anywhere comparing the two.
  describe "the sample pages" do
    setup %{conn: conn, site: site} do
      set_up!(site)

      {:ok, conn: log_in(conn, admin_with!("blogpages@example.com", "*"))}
    end

    test "are all reported current on a site set up from this checkout", %{
      conn: conn,
      site: site
    } do
      {:ok, view, _html} = live(conn, "/admin/dashboard/blog")

      view |> form("#blog-kit-upgrade-form", %{"site_id" => site.id}) |> render_submit()

      assert has_element?(
               view,
               "#blog-kit-upgrade-pages-headline",
               "is the one this version ships"
             )

      assert has_element?(view, "#blog-kit-upgrade-pages-current-0", "/:lang/blog")
      refute has_element?(view, "#blog-kit-upgrade-pages-offer")

      close(view)
    end

    # A PAGE THIS VERSION ADDED is a page a site set up before it does not have, and neither are the
    # components it draws. The check names both, and Repair — the other half of the same modal —
    # writes both, as it writes anything a site is missing.
    test "names a page this version added as missing, and Repair writes it", %{
      conn: conn,
      site: site
    } do
      added = [Provision.item_paths().author, Provision.item_paths().team, "/:lang/blog/people"]
      drawn = ~w(blog-author-profile blog-team-profile blog-people blog-profile-card)

      for path <- added do
        site
        |> page!(path)
        |> Ash.destroy!(action: :master_permanent_destroy, authorize?: false, tenant: site.id)
      end

      for name <- drawn do
        site
        |> component!(name)
        |> Ash.destroy!(action: :master_permanent_destroy, authorize?: false, tenant: site.id)
      end

      {:ok, view, _html} = live(conn, "/admin/dashboard/blog")

      view |> form("#blog-kit-upgrade-form", %{"site_id" => site.id}) |> render_submit()

      for path <- added do
        assert has_element?(view, "#blog-kit-upgrade-pages-absent", path),
               "#{path} is not named as missing"
      end

      for name <- drawn do
        assert has_element?(view, "#blog-kit-upgrade-absent", name),
               "#{name} is not named as missing"
      end

      view |> form("#blog-provision-form", %{"site_id" => site.id}) |> render_submit()

      for path <- added, do: assert(page!(site, path), "Repair did not write #{path}")
      for name <- drawn, do: assert(component!(site, name), "Repair did not install #{name}")

      close(view)
    end

    test "are offered as drafts, and the live page is left exactly where it is", %{
      conn: conn,
      site: site
    } do
      aged = aged_page!(site)

      {:ok, view, _html} = live(conn, "/admin/dashboard/blog")

      view |> form("#blog-kit-upgrade-form", %{"site_id" => site.id}) |> render_submit()

      assert has_element?(view, "#blog-kit-upgrade-pages-headline", "create a draft?")
      assert has_element?(view, "#blog-kit-upgrade-pages-behind-0", "/:lang/blog")
      assert drafts(site, aged) == [], "reading what is behind wrote to the site"

      html = view |> element("#blog-kit-upgrade-pages-offer") |> render_click()

      assert html =~ "Created 1 draft"

      assert [draft] = drafts(site, aged)
      assert draft.label == "Blog sample page"
      assert draft.source_page_id == aged.id
      assert draft.template =~ "blog-featured-posts"
      assert is_nil(draft.applied_at)

      assert page!(site, "/:lang/blog").template == @mine,
             "the admin's live page was written over"

      close(view)
    end

    # THE STATE THE SITES THIS EXISTS FOR ARE ACTUALLY IN. `blog-featured-posts` is newer than
    # they are and no update installs a component a site does not have — the Set up button does —
    # so the page that draws it must not be offered until it is there. Published, that draft would
    # answer `/en/blog` with a red "Component failed to render!" line where the strip should be.
    test "are not offered while the component the index page draws is not in use", %{
      conn: conn,
      site: site
    } do
      aged = aged_page!(site)

      Ash.update!(component!(site, "blog-featured-posts"), %{active: false},
        action: :master_update,
        authorize?: false,
        tenant: site.id
      )

      {:ok, view, _html} = live(conn, "/admin/dashboard/blog")

      view |> form("#blog-kit-upgrade-form", %{"site_id" => site.id}) |> render_submit()

      refute has_element?(view, "#blog-kit-upgrade-pages-offer"),
             "a draft of a page this site cannot draw was offered"

      assert has_element?(view, "#blog-kit-upgrade-pages-blocked-0", "blog-featured-posts")
      assert drafts(site, aged) == []

      close(view)
    end

    test "are offered once, however often the button is pressed", %{conn: conn, site: site} do
      aged = aged_page!(site)

      {:ok, view, _html} = live(conn, "/admin/dashboard/blog")

      view |> form("#blog-kit-upgrade-form", %{"site_id" => site.id}) |> render_submit()
      view |> element("#blog-kit-upgrade-pages-offer") |> render_click()

      refute has_element?(view, "#blog-kit-upgrade-pages-offer"),
             "there is still a draft to create"

      assert has_element?(view, "#blog-kit-upgrade-pages-waiting-0", "waiting as a draft")

      view |> form("#blog-kit-upgrade-form", %{"site_id" => site.id}) |> render_submit()

      assert has_element?(view, "#blog-kit-upgrade-pages-headline", "waiting in the builder")
      assert [_one] = drafts(site, aged)

      close(view)
    end
  end

  # THE SAME NAMES THE SET-UP ASKS FOR open this modal, so each of its writes has to finish for
  # a holder of them alone: the components' update and the sample page's draft.
  describe "a holder of the names the set-up asks for" do
    setup %{site: site} do
      set_up!(site)
      age!(site)
      aged_page!(site)

      :ok
    end

    for {who, master?} <- [{"a master", true}, {"a site admin", false}] do
      @master? master?

      test "#{who} updates the components and drafts the sample page", %{conn: conn, site: site} do
        admin =
          create_user_with_permissions!(
            ["admin:dashboard:blog:post" | ExtensionProvision.required(Provision.manifest())],
            site_id: if(@master?, do: nil, else: site.id)
          )

        {:ok, view, _html} = live(log_in(conn, admin, @master?), "/admin/dashboard/blog")

        render_submit(view, "kit_check", %{"site_id" => site.id})

        assert view |> element("#blog-kit-upgrade-safe") |> render_click() =~
                 "Updated #{@components} components"

        for component <- components(site) do
          assert UiKitUpgrade.digest(component) == component.extra["ui_kit_digest"],
                 "#{component.name} was not written as the bundle has it"
        end

        render_submit(view, "kit_check", %{"site_id" => site.id})

        assert view |> element("#blog-kit-upgrade-pages-offer") |> render_click() =~
                 "Created 1 draft"

        assert [_draft] = drafts(site, page!(site, "/:lang/blog"))

        close(view)
      end
    end
  end

  describe "an editor who may not" do
    setup %{site: site} do
      set_up!(site)
      age!(site)

      :ok
    end

    test "is not offered the icon or the modal, and is refused both events anyway", %{
      conn: conn,
      site: site
    } do
      editor = create_user_with_permissions!(["admin:dashboard:blog:post"])
      {:ok, view, _html} = live(log_in(conn, editor), "/admin/dashboard/blog")

      refute has_element?(view, "#blog-kit-upgrade-open")
      refute has_element?(view, "#blog-kit-upgrade")

      assert render_submit(view, "kit_check", %{"site_id" => site.id}) =~ "not allowed"
      assert render_click(view, "kit_upgrade", %{"mode" => "all"}) =~ "not allowed"
      assert render_click(view, "page_drafts", %{}) =~ "not allowed"

      assert component!(site, "blog-post-list").extra["ui_kit_version"] == "0.0.1"

      close(view)
    end
  end

  # WHAT THE DASHBOARD NO LONGER CARRIES. Two cards sat under the tables of every site that was
  # already set up — one offering to install what was installed, one offering to compare — and a
  # dashboard is for the extension's own work. They are one modal now, behind one icon beside
  # Analytics, and a set-up site's dashboard says nothing about either until it is asked.
  describe "the header icon" do
    setup %{conn: conn, site: site} do
      set_up!(site)

      {:ok, conn: log_in(conn, admin_with!("blogicon@example.com", "*"))}
    end

    test "is the only way to either of them on a site that is set up", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/admin/dashboard/blog")

      assert has_element?(view, "#blog-kit-upgrade-open")

      refute has_element?(view, "#blog-provision-badge"),
             "a site that is set up was warned that it was not"

      # NEITHER FORM IS ON THE PAGE ON ITS OWN. Both are inside the modal, which is the change:
      # a descendant selector is the only thing that can tell the two apart.
      assert has_element?(view, "#blog-kit-upgrade-doctor #blog-kit-upgrade-form")
      assert has_element?(view, "#blog-kit-upgrade-doctor #blog-provision-form")
      assert has_element?(view, "#blog-provision-submit", "Repair")

      close(view)
    end

    # A TENANT ADMIN IS NOT OFFERED A CHOICE, and was shown nothing at all where the choice would
    # be — so the modal's buttons named no site. Their own is the only one this page will ever
    # write to, and now it says which one that is.
    test "shows a tenant admin their own site, and no picker", %{conn: conn, site: site} do
      tenant = create_user_with_permissions!(["admin:dashboard:*"], site_id: site.id)

      {:ok, view, _html} = live(log_in(conn, tenant, false), "/admin/dashboard/blog")

      assert has_element?(view, "#blog-kit-upgrade-site-fixed", site.name)

      refute has_element?(view, "#blog-kit-upgrade-site"),
             "a tenant admin was offered a choice of sites"

      close(view)
    end

    # ONE PICKER FOR BOTH HALVES. The Repair button has no select of its own, so a master who reads
    # one site's standings and presses Repair must write to that site and not to the one the
    # dashboard opened on.
    test "hands Repair the site whose standings are on screen", %{conn: conn} do
      other = create_site!(name: "blogsecond", host: "blogsecond.test", active: true)

      {:ok, view, _html} = live(conn, "/admin/dashboard/blog")

      view |> form("#blog-kit-upgrade-form", %{"site_id" => other.id}) |> render_change()

      assert has_element?(
               view,
               ~s(#blog-provision-form input[name="site_id"][value="#{other.id}"])
             )

      close(view)
    end
  end

  defp admin_with!(email, permission) do
    {:ok, user} =
      User
      |> Ash.Changeset.for_create(
        :register_with_password,
        %{email: email, password: @password, password_confirmation: @password},
        authorize?: false
      )
      |> Ash.create()

    UserPermission
    |> Ash.Changeset.for_create(:assign, %{}, authorize?: false)
    |> Ash.Changeset.force_change_attribute(:user_id, user.id)
    |> Ash.Changeset.force_change_attribute(:permission_id, permission!(permission).id)
    |> Ash.create!(authorize?: false)

    user
  end

  defp permission!(name) do
    case Permission |> Ash.Query.filter(name == ^name) |> Ash.read_one(authorize?: false) do
      {:ok, nil} ->
        Permission
        |> Ash.Changeset.for_create(:create, %{name: name}, authorize?: false)
        |> Ash.create!()

      {:ok, found} ->
        found
    end
  end

  # Signs `user` in with the token it was issued. Who is a master is read from that token alone —
  # issued with no site, on the master site's address — so `master_mode` only stands for the choice
  # the sign-in page would have kept, and changes nothing once someone is signed in.
  defp log_in(conn, user, master_mode \\ true) do
    conn
    |> Plug.Test.init_test_session(%{})
    |> Plug.Conn.put_session(:master_mode, master_mode)
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
