defmodule MishkaBlogWeb.Test.ProvisionButtonTest do
  @moduledoc """
  The "Set up …" card, driven as an admin drives it.

  The card itself is `MishkaCmsCoreWeb.Live.Admin.Components.ExtensionInstallerPanel`, shared by
  every extension — so this is the only copy of these assertions. The document dashboard draws the
  same component with another noun, and a second file would test the same module twice and leave
  the two free to drift in their wording instead.

  The blog is the one driven because it is the extension with the most to install: six pages, a
  snippet, and a name (`Blog`) a site may well hold already, which is what makes the rename path
  reachable at all.
  """
  use MishkaBlog.ConnCase

  import ExUnit.CaptureLog, only: [with_log: 1]
  import Phoenix.LiveViewTest
  import MishkaBlog.Test.Factory

  alias MishkaBlog.Provision
  alias MishkaCmsCore.Accounts.{Permission, User, UserPermission}
  alias MishkaCmsCore.Runtime.{ExtensionProvision, Page}
  alias MishkaCmsCore.Runtime.States.{SettingsState, SiteState}
  alias MishkaCmsCore.Settings

  require Ash.Query

  @password "Password123!"

  # HOW MANY THE BUNDLE SHIPS, read off the bundle rather than written here. The kit's components
  # are split and joined as the blog grows; a number typed into an assertion turns every one of
  # those into a test failure that says nothing.
  @components length(MishkaBlog.Provision.component_names())
  @permissions length(MishkaBlog.Provision.manifest().permissions)

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

  defp paths(site) do
    Page
    |> Ash.Query.for_read(:read_any, %{}, authorize?: false)
    |> Ash.Query.filter(site_id == ^site.id)
    |> Ash.Query.select([:path])
    |> Ash.read!(page: [limit: 100])
    |> then(&Enum.map(&1.results, fn page -> page.path end))
  end

  defp page!(site, path) do
    Page
    |> Ash.Query.for_read(:read_any, %{}, authorize?: false)
    |> Ash.Query.filter(site_id == ^site.id and path == ^path)
    |> Ash.read_one!(authorize?: false)
  end

  # THE SCREEN AN EXTENSION OPENS ON. A dashboard for an extension a site has never installed is a
  # page of zeroes over pages that do not exist, and nothing on it says why.
  describe "the first visit" do
    setup %{conn: conn} do
      {:ok, conn: log_in(conn, admin_with!("blogfirst@example.com", "*"))}
    end

    test "opens the installer instead of the dashboard", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/admin/dashboard/blog")

      assert has_element?(view, "#blog-provision-first-run")
      refute has_element?(view, "[data-role=blog-head]"), "the dashboard was drawn as well"

      close(view)
    end

    # NOT NOW IS A REAL ANSWER, and it writes nothing: the site stays as it is and the dashboard
    # opens, empty.
    test "and lets the admin past it without installing anything", %{conn: conn, site: site} do
      {:ok, view, _html} = live(conn, "/admin/dashboard/blog")

      view |> element("#blog-provision-skip") |> render_click()

      assert has_element?(view, "[data-role=blog-head]")
      refute has_element?(view, "#blog-provision-first-run")
      assert paths(site) == [], "skipping wrote pages"

      close(view)
    end

    # AND THE WAY BACK. The badge is the only thing on an empty dashboard that says why it is empty.
    test "leaves a badge that opens it again", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/admin/dashboard/blog")

      view |> element("#blog-provision-skip") |> render_click()

      assert has_element?(view, "#blog-provision-badge")

      view |> element("#blog-provision-badge") |> render_click()

      assert has_element?(view, "#blog-provision-first-run")

      close(view)
    end

    test "is not the screen a site that has been set up opens on", %{conn: conn, site: site} do
      {:ok, view, _html} = live(conn, "/admin/dashboard/blog")

      view |> form("#blog-provision-form", %{"site_id" => site.id}) |> render_submit()

      refute has_element?(view, "#blog-provision-first-run"),
             "the installer stayed up after it had run"

      assert has_element?(view, "[data-role=blog-head]")
      refute has_element?(view, "#blog-provision-badge"), "a set-up site still says it is not"

      close(view)
    end
  end

  describe "a master who may edit the site's runtime" do
    setup %{conn: conn} do
      {:ok, conn: log_in(conn, admin_with!("blogsetup@example.com", "*"))}
    end

    test "sets the site up from the dashboard, and says what it added", %{conn: conn, site: site} do
      {:ok, view, _html} = live(conn, "/admin/dashboard/blog")

      assert has_element?(view, "#blog-provision")
      assert has_element?(view, "#blog-provision-site option[value='#{site.id}']")

      html =
        view
        |> form("#blog-provision-form", %{"site_id" => site.id})
        |> render_submit()

      assert html =~
               "Added #{@permissions} permissions, #{@components} components, 6 pages, 1 snippet."

      assert Enum.sort(paths(site)) == Enum.sort(Provision.page_paths())

      close(view)
    end

    # A SITE HOLDING THE FIRST SAMPLE PAGE'S NAME at an address of its own — first the button
    # answered "The blog could not be set up. The logs say why.", having created no page at all,
    # and then it created five of the six and skipped the one that matters: `/:lang/blog` is the
    # only page carrying `blog-featured-posts`. The name is now answered with the next free one, and
    # the card says which page that happened to.
    test "names the page itself on a site that already has a page called Blog", %{
      conn: conn,
      site: site
    } do
      mine =
        create_page!(
          site_id: site.id,
          name: "Blog",
          path: "/our-blog",
          template: "<div>mine</div>"
        )

      {:ok, view, _html} = live(conn, "/admin/dashboard/blog")

      html =
        view
        |> form("#blog-provision-form", %{"site_id" => site.id})
        |> render_submit()

      assert html =~
               "Added #{@permissions} permissions, #{@components} components, 6 pages, 1 snippet. 1 page created under another name."

      assert has_element?(view, "#blog-provision-report")
      assert has_element?(view, "#blog-provision-renamed-0", "/:lang/blog")
      assert has_element?(view, "#blog-provision-renamed-0", ~s(created as "blog-2"))
      refute has_element?(view, "#blog-provision-renamed-1")
      refute has_element?(view, "#blog-provision-skipped-0")

      assert Enum.sort(paths(site)) == Enum.sort(["/our-blog" | Provision.page_paths()])

      html =
        view
        |> form("#blog-provision-form", %{"site_id" => site.id})
        |> render_submit()

      # AND THE SECOND PRESS ADDS NOTHING AND RENAMES NOTHING. The page is at its own address now,
      # so what holds it is its PATH — this is a site that has the blog's pages, and saying anything
      # else would send the admin looking for a page that is there.
      assert has_element?(view, "#blog-provision-added", "already has everything the blog ships")
      assert has_element?(view, "#blog-provision-added", "Nothing to add.")
      refute has_element?(view, "#blog-provision-renamed-0")
      refute html =~ "created under another name"

      assert length(paths(site)) == length(Provision.page_paths()) + 1
      assert page!(site, "/our-blog").id == mine.id

      close(view)
    end

    # ONE ADDRESS, ONE PAGE. A page of the site's own at `/blog` answers the address the blog's home
    # has in the site's first language while that language goes unprefixed, so the home is left out
    # and the card names the page in its way — in either URL mode, because a site that switches to
    # the other one later must not find one of the two hidden behind the other.
    for mode <- ~w(prefix_others prefix_all) do
      test "leaves the blog's home out where a page of the site answers its address, in #{mode}",
           %{conn: conn, site: site} do
        on_exit(fn -> SettingsState.delete(site.id, "site.language_urls") end)
        {:ok, _} = Settings.put("site.language_urls", unquote(mode), site_id: site.id)
        create_page!(site_id: site.id, name: "Mine", path: "/blog", template: "<div>mine</div>")

        {:ok, view, _html} = live(conn, "/admin/dashboard/blog")

        html =
          view
          |> form("#blog-provision-form", %{"site_id" => site.id})
          |> render_submit()

        assert html =~ "#{@components} components, 5 pages, 1 snippet."
        assert has_element?(view, "#blog-provision-skipped-0", "/:lang/blog")
        assert has_element?(view, "#blog-provision-skipped-0", ~s("/blog"))
        refute "/:lang/blog" in paths(site)

        close(view)
      end
    end

    # A PATH IS THE ONE CLASH A RUN CANNOT ANSWER ON ITS OWN. A name it can take another of; an
    # address belongs to whoever is at it, and only the admin knows whether to move ours or theirs.
    test "asks where to put a page whose address is taken, and puts it there", %{
      conn: conn,
      site: site
    } do
      taken =
        create_page!(
          site_id: site.id,
          name: "Mine",
          path: "/:lang/blog",
          template: "<div>mine</div>"
        )

      {:ok, view, _html} = live(conn, "/admin/dashboard/blog")

      view |> form("#blog-provision-form", %{"site_id" => site.id}) |> render_submit()

      assert has_element?(view, "#blog-provision-clashes"),
             "a held address was reported and not asked about"

      assert has_element?(view, "#blog-provision-skipped-0", "/:lang/blog")

      view
      |> form("#blog-provision-clashes", %{
        "site_id" => site.id,
        "paths" => %{"/:lang/blog" => "/:lang/journal"}
      })
      |> render_submit()

      assert "/:lang/journal" in paths(site), "the address the admin chose was not written"
      assert page!(site, "/:lang/blog").id == taken.id, "the admin's own page was touched"

      refute has_element?(view, "#blog-provision-clashes"),
             "it went on asking after it was answered"

      close(view)
    end

    # AND THE OTHER ANSWER: move the lot rather than place one. The site keeps every page it has and
    # the extension's arrive beside them under a segment of their own.
    test "or moves every page of the extension under one segment", %{conn: conn, site: site} do
      create_page!(site_id: site.id, name: "Mine", path: "/:lang/blog", template: "<div>m</div>")

      {:ok, view, _html} = live(conn, "/admin/dashboard/blog")

      view |> form("#blog-provision-form", %{"site_id" => site.id}) |> render_submit()

      view
      |> form("#blog-provision-clashes", %{"site_id" => site.id, "prefix" => "/mish"})
      |> render_submit()

      assert "/:lang/mish/blog" in paths(site)
      assert page!(site, "/:lang/blog").name == "mine"

      close(view)
    end

    # WHAT A RUN THAT RAISES LEAVES ON THE SCREEN. Everything but a page being taken is re-raised —
    # a template that does not compile, a site that has gone — and by then the components are
    # written, so clearing the card answers the admin's "what happened?" with less than they had
    # before they pressed it: the logs, which is what this card exists to stop.
    test "keeps the report of what the site got when a later run fails", %{conn: conn, site: site} do
      gone = create_site!(name: "gonesite", host: "gone.test", active: true)

      {:ok, view, _html} = live(conn, "/admin/dashboard/blog")

      view |> form("#blog-provision-form", %{"site_id" => site.id}) |> render_submit()

      assert has_element?(
               view,
               "#blog-provision-added",
               "Added #{@permissions} permissions, #{@components} components, 6 pages, 1 snippet."
             )

      Ash.destroy!(gone, action: :permanent_destroy, authorize?: false)

      # THROUGH THE EVENT, because the first run put the dashboard up and the form moved with it
      # into the doctor modal, where Repair is bound to the one site whose standings are on screen.
      # A run against another site is the picker's job and a run against a site that has GONE is
      # nobody's — which is the state this test is about.
      {html, _logged} =
        with_log(fn ->
          render_submit(view, "extension_install", %{"site_id" => gone.id})
        end)

      assert html =~ "The blog could not be set up."

      assert has_element?(
               view,
               "#blog-provision-added",
               "Added #{@permissions} permissions, #{@components} components, 6 pages, 1 snippet."
             )

      close(view)
    end

    test "presses it twice and is told nothing needed doing", %{conn: conn, site: site} do
      {:ok, view, _html} = live(conn, "/admin/dashboard/blog")

      view |> form("#blog-provision-form", %{"site_id" => site.id}) |> render_submit()

      html = view |> form("#blog-provision-form", %{"site_id" => site.id}) |> render_submit()

      assert html =~ "already has everything the blog ships"
      assert has_element?(view, "#blog-provision-added", "Nothing to add")
      assert length(paths(site)) == length(Provision.page_paths())

      close(view)
    end

    # A SITE ID IS NOT AN AUTHORIZATION. The picker offers the sites this deployment has, and a value
    # that was not offered is refused rather than written to — and told so as a refusal, because
    # somebody who did choose a site and is answered "choose one" reads that as the page being broken.
    test "cannot set up a site the page never offered", %{conn: conn, site: site} do
      {:ok, view, _html} = live(conn, "/admin/dashboard/blog")

      html = render_submit(view, "extension_install", %{"site_id" => Ash.UUID.generate()})

      assert html =~ "That is not a site this page can set up."
      assert paths(site) == []

      close(view)
    end

    test "is asked for a site when the event carries none", %{conn: conn, site: site} do
      {:ok, view, _html} = live(conn, "/admin/dashboard/blog")

      html = render_submit(view, "extension_install", %{})

      assert html =~ "Choose the site to set up first."
      assert paths(site) == []

      close(view)
    end
  end

  describe "an editor who may not" do
    test "is not offered the control, and is refused the event anyway", %{conn: conn, site: site} do
      editor = create_user_with_permissions!(["admin:dashboard:blog:post"])
      {:ok, view, _html} = live(log_in(conn, editor), "/admin/dashboard/blog")

      refute has_element?(view, "#blog-provision")

      html = render_submit(view, "extension_install", %{"site_id" => site.id})

      assert html =~ "not allowed"
      assert paths(site) == []

      close(view)
    end
  end

  # EVERY NAME OF WHAT THE BUTTON WRITES: pages and the page builder's snippet, components, the
  # bundle's stylesheet, and the site read — read off the bundle, as the button reads them. Holding
  # all of them offers it; missing any one does not.
  describe "who is offered the control" do
    # OFFERED IS NOT ENOUGH: the button has to finish for whoever it is offered to, so the holder
    # presses it, as a master and as an admin of the site alone.
    for {who, master?} <- [{"a master", true}, {"a site admin", false}] do
      @master? master?

      test "#{who} holding every name, who sets the site up", %{conn: conn, site: site} do
        admin =
          create_user_with_permissions!(["admin:dashboard:blog:post" | provision_names()],
            site_id: if(@master?, do: nil, else: site.id)
          )

        {:ok, view, _html} = live(log_in(conn, admin, @master?), "/admin/dashboard/blog")

        assert has_element?(view, "#blog-provision")

        html = render_submit(view, "extension_install", %{"site_id" => site.id})

        assert html =~ "Added", "the set-up was offered and then refused"
        assert length(paths(site)) == length(Provision.page_paths())

        close(view)
      end
    end

    test "missing any one of them, and refused the event too", %{conn: conn, site: site} do
      for missing <- provision_names() do
        admin =
          create_user_with_permissions!([
            "admin:dashboard:blog:post" | provision_names() -- [missing]
          ])

        {:ok, view, _html} = live(log_in(conn, admin), "/admin/dashboard/blog")

        refute has_element?(view, "#blog-provision-form"), "offered without #{missing}"
        assert render_submit(view, "extension_install", %{"site_id" => site.id}) =~ "not allowed"
        assert paths(site) == []

        close(view)
      end
    end
  end

  defp provision_names, do: ExtensionProvision.required(Provision.manifest())

  describe "a tenant admin" do
    test "sets up their own site, whatever the event asks for", %{conn: conn, site: site} do
      other = create_site!(name: "othertown", host: "othertown.test", active: true)

      admin = create_user_with_permissions!(["*"], site_id: site.id)

      {:ok, view, _html} = live(log_in(conn, admin, false), "/admin/dashboard/blog")

      assert has_element?(view, "#blog-provision")

      refute has_element?(view, "#blog-provision-site"),
             "a tenant admin was offered a choice of sites"

      html = render_submit(view, "extension_install", %{"site_id" => other.id})

      assert html =~ "Added"
      assert length(paths(site)) == length(Provision.page_paths())
      assert paths(other) == []

      close(view)
    end
  end

  # WHO THE WRITE IS AUTHORIZED AS. Every one of these rows used to be written with
  # `authorize?: false` through a master action, whoever pressed the button: the page resource's
  # own policy never ran, `TenantContext` is bypassed outright when authorization is off, and the
  # version history — `belongs_to_actor(:user, …)` — recorded nobody for every page on every site.
  describe "the actor behind the button" do
    setup %{conn: conn} do
      {:ok, conn: conn, admin: admin_with!("blogactor@example.com", "*")}
    end

    test "is on every version of every page it writes", %{conn: conn, site: site, admin: admin} do
      {:ok, view, _html} = live(log_in(conn, admin), "/admin/dashboard/blog")

      view |> form("#blog-provision-form", %{"site_id" => site.id}) |> render_submit()

      versions = page_versions(site)

      refute versions == [], "the run wrote no pages at all"

      assert Enum.all?(versions, &(&1.user_id == admin.id)),
             "a page this admin created is attributed to nobody in its own history"

      close(view)
    end

    # THE SECOND GATE, behind the button: a blog editor holds none of what `Page` and `Component`
    # ask for, so the run is refused by the provision's own check of the names it needs, before
    # its first write, and leaves nothing behind.
    test "is refused when they hold none of what it writes", %{site: site} do
      weak = create_user_with_permissions!(["admin:dashboard:blog:post"])

      assert_raise ArgumentError, ~r/setting up an extension needs/, fn ->
        MishkaBlog.Provision.ensure!(site.id, %{}, actor: weak)
      end

      assert paths(site) == [], "a refused run left pages behind"
    end

    # THE TENANT HALF OF THE SPLIT, which is the half that can raise: a site admin writes through
    # `Page.:create` under their own tenant rather than `:master_create`, and `TenantContext`
    # refuses each of those to the other.
    test "is a site admin writing their own site's action", %{conn: conn, site: site} do
      tenant = create_user_with_permissions!(["*"], site_id: site.id)

      {:ok, view, _html} = live(log_in(conn, tenant, false), "/admin/dashboard/blog")

      render_submit(view, "extension_install", %{"site_id" => site.id})

      versions = page_versions(site)

      refute versions == [], "the run wrote no pages at all"

      assert Enum.all?(versions, &(&1.user_id == tenant.id)),
             "a page this site admin created is attributed to somebody else"

      assert Enum.all?(versions, &(&1.version_action_name == "create")),
             "a site admin's page went through the master action"

      close(view)
    end

    # AND NOT SOMEBODY ELSE'S SITE. The dashboard never offers them one, so this is about the door
    # behind the dashboard: the tenant read is scoped to their own site and the tenant write takes
    # the site it is given, and a caller that went around `chosen_site/2` would set those two
    # against each other.
    test "is refused another site outright", %{site: site} do
      other = create_site!(name: "elsewhere", host: "elsewhere.test", active: true)

      tenant = create_user_with_permissions!(["admin:dashboard:*"], site_id: site.id)

      assert_raise ArgumentError, ~r/own site/, fn ->
        MishkaBlog.Provision.ensure!(other.id, %{}, actor: tenant)
      end

      assert paths(other) == []
    end

    # NOBODY IS STILL A REAL ANSWER. The wizard runs before there is a user and the seeds have no
    # session; both keep the system path, and nothing about this change asks them to invent one.
    test "is absent for a run with no session behind it", %{site: site} do
      report = MishkaBlog.Provision.ensure!(site.id)

      refute report.pages == []
      assert Enum.all?(page_versions(site), &is_nil(&1.user_id))
    end
  end

  # JOINED THROUGH THE PAGE, not filtered on the version's own `site_id`: a master action is
  # required to carry no tenant, and the version row takes its site from the tenant, so a master's
  # version has none. Which page it is about is never in doubt.
  defp page_versions(site) do
    %{rows: rows} =
      MishkaBlog.Repo.query!(
        """
        SELECT v.user_id::text, v.version_action_name
        FROM page_versions v
        JOIN pages p ON p.id = v.version_source_id
        WHERE p.site_id = $1
        """,
        [Ecto.UUID.dump!(site.id)]
      )

    Enum.map(rows, fn [user_id, action] -> %{user_id: user_id, version_action_name: action} end)
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
  # on the way down once the test's sandbox owner is gone. Drained rather than guessed at a timeout.
  defp close(view) do
    render_async(view, 5_000)
    ref = Process.monitor(view.pid)
    GenServer.stop(view.pid, :normal)
    assert_receive {:DOWN, ^ref, :process, _pid, _reason}
  end
end
