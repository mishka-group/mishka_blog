# SPDX-FileCopyrightText: 2026 Mishka Group contributors <https://github.com/mishka-group/mishka_blog/graphs/contributors>
#
# SPDX-License-Identifier: Apache-2.0

defmodule MishkaBlog.LiveComponentsRenderTest do
  @moduledoc """
  The blog's live components, compiled by the real runtime and driven on a real page.

  This is the acceptance case for the CMS's whole stateful-component feature, written in the one
  application that has both halves: the blog's rows and the CMS's runtime. The component goes
  through `MishkaCmsCore.Runtime.Compilers.ComponentCompiler`, is reached the way a page reaches it
  — `LiveViewHelpers.component/1`, off the stored `<.component component_name="…"/>` rather than a
  `<.live_component>` a test wrote — and is then clicked the way a visitor would.

  ## What only a live component can do, asserted rather than described

  Paging is per-instance server state. Two lists on one page hold two different pages; a click on
  one moves only that one; and neither is reset when the page around them re-renders. A function
  component keeping the number in the HOSTING page's assigns has none of those three properties.
  """
  use MishkaBlog.ConnCase, async: false

  import Phoenix.LiveViewTest
  import MishkaBlog.Test.Factory
  import MishkaBlog.DataCase, only: [with_plugin: 3, queries_while: 1]
  import Phoenix.Component, only: [sigil_H: 2]

  alias MishkaCmsCore.Runtime.Compilers.Helpers, as: CompilerHelpers
  alias MishkaCmsCore.Runtime.Handlers.ModuleCompilerHandler
  alias MishkaCmsCore.Runtime.LiveViewHelpers
  alias MishkaCmsCore.Runtime.States.{SettingsState, SiteState}
  alias MishkaCmsCore.Runtime.Translations

  require Ash.Query

  @moduletag :integration

  # A UNIQUE SITE NAME PER TEST, and it is not tidiness. A component's runtime module is named from
  # a hash of (component name, SITE NAME) and is cached in the VM's code table for the rest of the
  # run — while the module carries the site's ID, read from the row it was compiled against. Reuse
  # one name across tests and the second test renders the FIRST test's module, which points at a
  # site id that test rolled back: every list comes back empty with nothing to say why.
  #
  # Production never meets this — a site's name is stable and its id does not change under it — but
  # a suite that rolls back between tests does.
  setup do
    SiteState.clear()
    name = "blogtown#{System.unique_integer([:positive])}"
    site = create_site!(name: name, host: "#{name}.test", active: true)

    SiteState.save(%{
      id: site.id,
      name: site.name,
      host: site.host,
      priority: site.priority,
      active: site.active,
      master: site.master
    })

    on_exit(fn -> SiteState.clear() end)

    {:ok, _installed} = MishkaBlog.Kit.install!(site.id)

    # The test process renders for this site, as a page on it would — `cold/2` draws in it. A site's
    # component is drawn only where that site is the one being rendered: see
    # `LiveViewHelpers.component/1`.
    :ok = Translations.put_site(site.id)

    {:ok, site: site}
  end

  defp publish!(site, titles) do
    for {title, index} <- Enum.with_index(titles) do
      create_blog_post!(
        site_id: site.id,
        title: title,
        status: :published,
        published_at: DateTime.add(~U[2026-01-01 00:00:00Z], index * 86_400, :second)
      )
    end
  end

  # THE WAY A PAGE REACHES IT. A page's stored template says `<.component component_name="…"/>` and
  # `LiveViewHelpers.component/1` is what forks on the compiled shape and builds the
  # `%Phoenix.LiveView.Component{}`. Calling `<.live_component>` here would skip that fork, which is
  # the half of the feature most likely to break and the half this test exists for.
  defmodule Host do
    use Phoenix.LiveView

    # IT RENDERS FOR THE SITE, as `MishkaCmsWeb.RuntimeLive` does, once for the dead render and again
    # in the socket's own process.
    def mount(_params, session, socket) do
      :ok = Translations.put_site(session["site_id"])

      {:ok,
       Phoenix.Component.assign(socket,
         name: session["name"],
         site: session["site"],
         attrs: session["attrs"] || %{},
         second: session["second"] == true,
         ticks: 0
       )}
    end

    # WITHOUT THIS THE RE-RENDER TEST BELOW ASSERTS NOTHING. A `send/2` to a LiveView that exports no
    # matching `handle_info/2` is answered with the socket untouched, nothing is marked changed, and
    # the next `render/1` returns the tree the proxy already held. The host has to take the message
    # and change an assign its own template reads.
    def handle_info(:anything, socket),
      do: {:noreply, Phoenix.Component.update(socket, :ticks, &(&1 + 1))}

    def render(assigns) do
      ~H"""
      <div id="host">
        <span data-role="ticks">{@ticks}</span>
        {LiveViewHelpers.component(Map.merge(@attrs, %{component_name: @name, site: @site, id: "one"}))}
        <div :if={@second}>
          {LiveViewHelpers.component(
            Map.merge(@attrs, %{component_name: @name, site: @site, id: "two"})
          )}
        </div>
      </div>
      """
    end
  end

  # SEVERAL DIFFERENT BLOCKS ON ONE PAGE, which is what a real blog page is: the featured strip, the
  # paged list and the sidebar, each with its own read. `Host` above draws one component twice; this
  # draws whichever ones a test names, so what one of them does to another can be asserted.
  defmodule Several do
    use Phoenix.LiveView

    def mount(_params, session, socket) do
      :ok = Translations.put_site(session["site_id"])

      {:ok,
       Phoenix.Component.assign(socket,
         blocks: session["blocks"],
         site: session["site"],
         missing: false
       )}
    end

    # WHAT `MishkaCmsWeb.RuntimeLive` IS TOLD when a block finds nothing at the address it was
    # handed, once the socket is connected; it answers with the site's 404.
    def handle_info(:mishka_runtime_not_found, socket),
      do: {:noreply, Phoenix.Component.assign(socket, :missing, true)}

    # THE PAGE CHANGING WHAT IT HANDS ONE BLOCK, which is what an author does in the builder and
    # what a patch to another URL does to `params`. It is the only re-render that reaches a
    # component at all: LiveView's change tracking skips a component whose assigns are the same.
    def handle_info({:attrs, id, attrs}, socket) do
      with_attrs = fn block ->
        (block["id"] == id && Map.put(block, "attrs", attrs)) || block
      end

      # The host LiveView of this test reads its own assigns.
      # credo:disable-for-next-line Jump.CredoChecks.AvoidSocketAssignsInTest
      blocks = Enum.map(socket.assigns.blocks, with_attrs)

      {:noreply, Phoenix.Component.assign(socket, :blocks, blocks)}
    end

    def render(assigns) do
      ~H"""
      <div id="host">
        <span :if={@missing} data-role="not-found"></span>
        <div :for={block <- @blocks} id={"holder-#{block["id"]}"}>
          {LiveViewHelpers.component(
            Map.merge(block["attrs"], %{
              component_name: block["name"],
              site: @site,
              id: block["id"]
            })
          )}
        </div>
      </div>
      """
    end
  end

  # EVERY READ OF A MOUNTED PAGE WAITS FOR THE BLOCKS ON IT, because most of them now read in the
  # background: a connected socket takes the `start_async/3` branch, so the first render is the
  # skeleton and the rows arrive in the message after it. `render_async/2` waits on the tasks
  # themselves — it is not a sleep, and a block that never starts one is answered immediately.
  @async 5_000

  defp mount_page(site, name, attrs \\ %{}, second \\ false) do
    {:ok, view, _first_paint} =
      live_isolated(Phoenix.ConnTest.build_conn(), Host,
        session: %{
          "name" => name,
          "site" => site.name,
          "site_id" => site.id,
          "attrs" => attrs,
          "second" => second
        }
      )

    {:ok, view, render_async(view, @async)}
  end

  defp text_of(view, selector) do
    view
    |> render_async(@async)
    |> LazyHTML.from_fragment()
    |> LazyHTML.query(selector)
    |> Enum.map(&(&1 |> LazyHTML.text() |> String.trim()))
  end

  defp titles(view), do: text_of(view, ~s([data-role="blog-list-title"]))

  defp mount_blocks(site, blocks) do
    {:ok, view, first_paint} =
      live_isolated(Phoenix.ConnTest.build_conn(), Several,
        session: %{"blocks" => blocks, "site" => site.name, "site_id" => site.id}
      )

    {view, first_paint}
  end

  defp roles(html, role),
    do:
      html
      |> LazyHTML.from_fragment()
      |> LazyHTML.query(~s([data-role="#{role}"]))
      |> Enum.count()

  # A COMPONENT'S OWN ROW, EDITED THE WAY AN ADMIN EDITS ONE — which is also the only way to make a
  # read fail on purpose. `fetch/1` is the one helper that runs inside the task, so a `raise` there
  # is exactly what a read that dies looks like from the outside. What was there is handed back, so
  # a test can put it right again and watch the block recover.
  defp break!(site, name) do
    kept = site |> component_row(name) |> Map.fetch!(:helpers) |> Enum.map(&helper_map/1)

    broken =
      Enum.map(kept, fn helper ->
        case helper.name do
          "fetch" -> %{helper | args: "_asked", code: ~s|raise "the read failed"|}
          _left_alone -> helper
        end
      end)

    refute broken == kept, "#{name} has no fetch/1, so nothing was broken"

    write_helpers!(site, name, broken)

    kept
  end

  # A READ THAT ANSWERS WITH AN ERROR, which is what a read the database refuses looks like: Ash
  # hands back `{:error, _}` rather than raising. A block's FIRST read is in step with the page, so
  # this is how a first read fails; `break!/2`'s raise is a read in the background dying.
  defp refuse!(site, name) do
    kept = site |> component_row(name) |> Map.fetch!(:helpers) |> Enum.map(&helper_map/1)

    refused =
      Enum.map(kept, fn helper ->
        case helper.name do
          "fetch" -> %{helper | args: "_asked", code: "{:error, :refused}"}
          _left_alone -> helper
        end
      end)

    refute refused == kept, "#{name} has no fetch/1, so nothing was refused"

    write_helpers!(site, name, refused)

    kept
  end

  # THE CLOUD TWICE ON ONE PAGE, because it has TWO row containers and draws whichever one the page
  # gave it a base for — a guard put on one of them is a guard missing from the other, and one
  # stalled read reaches both.
  defp both_tag_clouds,
    do: [
      %{"name" => "blog-tag-cloud", "id" => "linked", "attrs" => %{tag_base: "/en/blog/tag"}},
      %{"name" => "blog-tag-cloud", "id" => "plain", "attrs" => %{}}
    ]

  defp one_category_list,
    do: [%{"name" => "blog-category-list", "id" => "one", "attrs" => %{}}]

  defp mount_reloading(site, blocks) do
    {view, _first_paint} = mount_blocks(site, blocks)
    settled = render_async(view, @async)

    for block <- blocks do
      assert has_element?(view, ~s(##{block["id"]})), "#{block["name"]} was not drawn"
    end

    refute roles(settled, "blog-tag") + roles(settled, "blog-category") == 0,
           "nothing was read, so there is nothing for the re-load to replace"

    view
  end

  # THE PAGE HANDING EVERY BLOCK ON IT SOMETHING NEW, which is what puts each of them back into
  # `load/1` with a signature it has not read for.
  defp reload!(view, blocks) do
    for block <- blocks do
      send(view.pid, {:attrs, block["id"], Map.put(block["attrs"], :limit, 5)})
    end

    :ok
  end

  # A READ THAT NEVER COMES BACK, which is the only honest way to look at a block WHILE it is
  # reading. Nothing here waits on a clock and nothing races: the task sits in `receive` until the
  # LiveView that started it goes away, so every render taken after this one is the loading render.
  # Unlike `break!/2` this lands on a component that is already compiled, so it rebuilds it too.
  defp stall!(site, name) do
    kept = site |> component_row(name) |> Map.fetch!(:helpers) |> Enum.map(&helper_map/1)

    stalled =
      Enum.map(kept, fn helper ->
        case helper.name do
          "fetch" -> %{helper | args: "_asked", code: "receive do\n  :never -> :ok\nend"}
          _left_alone -> helper
        end
      end)

    refute stalled == kept, "#{name} has no fetch/1, so nothing was stalled"

    write_helpers!(site, name, stalled)
    recompile!(site, name)

    kept
  end

  defp helper_map(helper),
    do: Map.take(helper, [:name, :args, :code, :attrs, :slots, :discriminators])

  defp component_row(site, name) do
    MishkaCmsCore.Runtime.Component
    |> Ash.Query.for_read(:read_any, %{}, authorize?: false)
    |> Ash.Query.filter(name == ^name and site_id == ^site.id)
    |> Ash.read_one!()
  end

  # `page_code: :package` FOR THE REASON `Validations.CodeChange` GIVES: helpers are author-written
  # Elixir, and writing them needs `admin:dashboard:runtime:component` or `admin:dashboard:code` —
  # unless what is writing is a package, which is how `UiKitHandler.install_kit!/2` puts these very
  # helpers there in the first place. This writes the kit's own code back in the kit's own shape, so
  # it announces itself the same way.
  defp write_helpers!(site, name, helpers) do
    site
    |> component_row(name)
    |> Ash.update!(%{helpers: helpers},
      action: :master_update,
      authorize?: false,
      tenant: site.id,
      context: %{page_code: :package}
    )
  end

  # THE ROW IS NOT THE MODULE. A component is compiled once per (name, site) and kept in the VM's
  # code table, so editing the row changes nothing until something rebuilds it — which is what the
  # admin's own save does through `MishkaCmsCore.Runtime.Workers.RuntimeCompilerWorker`.
  defp cold(site, name) do
    %{component_name: name, site: site.name, id: "cold"}
    |> LiveViewHelpers.static_component()
    |> Phoenix.HTML.Safe.to_iodata()
    |> IO.iodata_to_binary()
  end

  defp recompile!(site, name) do
    {:ok, _module} =
      ModuleCompilerHandler.compile_or_return_module(
        CompilerHelpers.module_name(name, site.name, "Component"),
        name,
        site.name,
        site.id,
        :update
      )

    :ok
  end

  defp positions(view),
    do:
      view
      |> text_of(~s([data-role="blog-list-position"]))
      |> Enum.map(&String.replace(&1, ~r/\s+/, ""))

  describe "they compile" do
    # WHICH KIND EACH ONE IS COMES OUT OF THE BUNDLE, not out of a list here. The kit holds both
    # now — blocks that run a query and hold state, and the function components they draw their
    # rows with — and the two get different module shapes from
    # `MishkaCmsCore.Runtime.Compilers.ComponentCompiler`. A function component given the live shape
    # would be handed a socket it cannot use, and a live one given the stateless shape loses
    # `update_many/1` and with it every assign its parent sends.
    test "and each takes the shape its own row asks for", %{site: site} do
      for component <- bundle_components() do
        name = component["name"]

        assert LiveViewHelpers.ensure_component_loaded(name, site.name),
               "#{name} did not compile"

        module = CompilerHelpers.module_name(name, site.name, "Component")
        assert module.__component_information__([:private, :stateful]) == component["stateful"]

        assert function_exported?(module, :update_many, 1) == component["stateful"],
               "#{name} got the other shape"
      end
    end

    # WHICH ONES ANSWER IS READ OUT OF THE BUNDLE. Two of the six draw themselves from the URL alone
    # and declare no handler, so demanding one of all six would only have kept the list short: the
    # three that used to be named here were the three that happened to have one.
    test "and every declared handler reaches the compiled module", %{site: site} do
      answering =
        for component <- bundle_components(),
            Enum.any?(component["helpers"], &(&1["name"] == "handle_event")),
            do: component["name"]

      refute answering == [], "no component declares a handler, so this asserts nothing"

      for name <- answering do
        assert LiveViewHelpers.ensure_component_loaded(name, site.name),
               "#{name} did not compile"

        module = CompilerHelpers.module_name(name, site.name, "Component")
        assert function_exported?(module, :handle_event, 3), "#{name} answers nothing"
      end
    end
  end

  # A RECORD LOCKED TO PERMISSIONS IS LEFT OUT OF EVERY LIST ITS VISITOR MAY NOT OPEN IT FROM — out of
  # the rows, the count and the pages — and shown to one who may. The page hands the block its
  # visitor as `current_user`; a block handed none reads for a visitor who is not signed in.
  describe "a locked record in a list" do
    setup %{site: site} do
      members = category!(site, name: "Members", slug: "members", permissions: ["members:read"])
      open = category!(site, name: "Open", slug: "open")
      [locked, public] = publish!(site, ["Locked", "Public"])
      categorize!(locked, members)
      categorize!(public, open)

      tag_post!(public, tag!(site, name: "Staff", slug: "staff", permissions: ["members:read"]))
      tag_post!(public, tag!(site, name: "Elixir", slug: "elixir"))

      %{
        member: create_user_with_permissions!(["members:read"], site_id: site.id),
        locked: locked,
        open: open
      }
    end

    test "is left out of the posts, and their count, for a visitor who may not open it",
         %{site: site, member: member} do
      {:ok, guest, _html} = mount_page(site, "blog-post-list", %{per_page: 10, show_total: true})
      assert titles(guest) == ["Public"]
      assert [<<"1 ", _posts::binary>>] = text_of(guest, ~s([data-role="blog-list-total"]))

      {:ok, shown, _html} =
        mount_page(site, "blog-post-list", %{per_page: 10, show_total: true, current_user: member})

      assert titles(shown) == ["Public", "Locked"]
      assert [<<"2 ", _posts::binary>>] = text_of(shown, ~s([data-role="blog-list-total"]))
    end

    test "is left out of the categories and the tags", %{site: site, member: member} do
      {:ok, guest, _html} = mount_page(site, "blog-category-list", %{hide_empty: false})
      assert text_of(guest, ~s([data-role="blog-category-name"])) == ["Open"]

      {:ok, shown, _html} =
        mount_page(site, "blog-category-list", %{hide_empty: false, current_user: member})

      assert Enum.sort(text_of(shown, ~s([data-role="blog-category-name"]))) == [
               "Members",
               "Open"
             ]

      {:ok, guest, _html} = mount_page(site, "blog-tag-cloud", %{hide_empty: false})
      assert text_of(guest, ~s([data-role="blog-tag"])) == ["Elixir"]
    end

    test "is not counted beside a category or a tag, and a row leading only to it is left out",
         %{site: site, member: member, locked: locked, open: open} do
      categorize!(locked, open)
      tag_post!(locked, tag!(site, name: "Secrets", slug: "secrets"))
      [elixir] = Ash.read!(MishkaBlog.Tag, tenant: site.id, authorize?: false) |> named("Elixir")
      tag_post!(locked, elixir)

      cloud = %{show_count: true}
      {:ok, guest, _html} = mount_page(site, "blog-tag-cloud", cloud)
      assert labels(guest, ~s([data-role="blog-tag"])) == ["Elixir 1"]

      {:ok, shown, _html} =
        mount_page(site, "blog-tag-cloud", Map.put(cloud, :current_user, member))

      assert labels(shown, ~s([data-role="blog-tag"])) == ["Elixir 2", "Secrets 1", "Staff 1"]

      menu = %{show_count: true, parent: "all"}
      {:ok, guest, _html} = mount_page(site, "blog-category-list", menu)
      assert text_of(guest, ~s([data-role="blog-category-name"])) == ["Open"]
      assert text_of(guest, ~s([data-role="blog-category-count"])) == ["1"]

      {:ok, shown, _html} =
        mount_page(site, "blog-category-list", Map.put(menu, :current_user, member))

      assert text_of(shown, ~s([data-role="blog-category-name"])) == ["Members", "Open"]
      assert text_of(shown, ~s([data-role="blog-category-count"])) == ["1", "2"]
    end

    test "draws no conversation under it for a visitor who may not open it",
         %{site: site, member: member, locked: locked} do
      comment!(site, locked, content: "Inside")

      {:ok, guest, _html} = mount_page(site, "blog-post-comments", %{slug: locked.slug})
      assert text_of(guest, ~s([data-role="blog-comment-body"])) == []

      {:ok, shown, _html} =
        mount_page(site, "blog-post-comments", %{slug: locked.slug, current_user: member})

      assert text_of(shown, ~s([data-role="blog-comment-body"])) == ["Inside"]
    end
  end

  # THE BLOG'S LOCK SCENARIOS, one table: what each of a guest, a user without the permission and a
  # user with it sees, in the list, among the categories, asking for the post by itself and under it.
  # The permission of a page that serves the blog is the runtime's, asked before any block draws, and
  # is held to its own test in the application that serves one.
  describe "the lock scenarios" do
    setup %{site: site} do
      %{
        readers: [
          guest: nil,
          user: create_user_with_permissions!([], site_id: site.id),
          member: create_user_with_permissions!(["members:read"], site_id: site.id)
        ]
      }
    end

    # What `reader` sees of the site: the titles listed, the categories, and for each post whether it
    # is drawn when asked for by itself and whether its comment is.
    defp seen(site, reader, posts) do
      as = if reader, do: %{current_user: reader}, else: %{}
      {:ok, list, _html} = mount_page(site, "blog-post-list", Map.merge(%{per_page: 10}, as))

      {:ok, categories, _html} =
        mount_page(site, "blog-category-list", Map.merge(%{hide_empty: false}, as))

      %{
        listed: list |> titles() |> Enum.sort(),
        categories: categories |> text_of(~s([data-role="blog-category-name"])) |> Enum.sort(),
        asked_for:
          for post <- posts, into: %{} do
            {:ok, detail, _html} =
              mount_page(site, "blog-post-detail", Map.merge(%{slug: post.slug}, as))

            {post.title, text_of(detail, ~s([data-role="blog-detail-title"])) != []}
          end,
        commented:
          for post <- posts, into: %{} do
            {:ok, comments, _html} =
              mount_page(site, "blog-post-comments", Map.merge(%{slug: post.slug}, as))

            {post.title, text_of(comments, ~s([data-role="blog-comment-body"])) != []}
          end
      }
    end

    test "a locked post: seen by a user who holds the permission, and by nobody else",
         %{site: site, readers: readers} do
      [open, locked] = publish!(site, ["Open", "Locked"])
      shelf = category!(site, name: "Shelf", slug: "shelf")
      categorize!(open, shelf)
      categorize!(locked, shelf)

      locked
      |> Ash.Changeset.for_update(:master_update, %{permissions: ["members:read"]},
        authorize?: false
      )
      |> Ash.update!()

      for post <- [open, locked], do: comment!(site, post, content: "On #{post.title}")
      posts = [open, locked]

      assert seen(site, readers[:guest], posts) == %{
               listed: ["Open"],
               categories: ["Shelf"],
               asked_for: %{"Open" => true, "Locked" => false},
               commented: %{"Open" => true, "Locked" => false}
             }

      assert seen(site, readers[:user], posts) == seen(site, readers[:guest], posts)

      assert seen(site, readers[:member], posts) == %{
               listed: ["Locked", "Open"],
               categories: ["Shelf"],
               asked_for: %{"Open" => true, "Locked" => true},
               commented: %{"Open" => true, "Locked" => true}
             }
    end

    test "a locked category: its posts are seen by a user who holds the permission, and by nobody else",
         %{site: site, readers: readers} do
      [open, behind] = publish!(site, ["Open", "Behind"])
      members = category!(site, name: "Members", slug: "members", permissions: ["members:read"])
      shelf = category!(site, name: "Shelf", slug: "shelf")
      categorize!(open, shelf)
      categorize!(behind, members)

      for post <- [open, behind], do: comment!(site, post, content: "On #{post.title}")
      posts = [open, behind]

      assert seen(site, readers[:guest], posts) == %{
               listed: ["Open"],
               categories: ["Shelf"],
               asked_for: %{"Open" => true, "Behind" => false},
               commented: %{"Open" => true, "Behind" => false}
             }

      assert seen(site, readers[:user], posts) == seen(site, readers[:guest], posts)

      assert seen(site, readers[:member], posts) == %{
               listed: ["Behind", "Open"],
               categories: ["Members", "Shelf"],
               asked_for: %{"Open" => true, "Behind" => true},
               commented: %{"Open" => true, "Behind" => true}
             }
    end

    test "nothing locked: seen by everybody", %{site: site, readers: readers} do
      [first, second] = publish!(site, ["First", "Second"])
      shelf = category!(site, name: "Shelf", slug: "shelf")
      categorize!(first, shelf)
      categorize!(second, shelf)

      for post <- [first, second], do: comment!(site, post, content: "On #{post.title}")
      posts = [first, second]

      everything = %{
        listed: ["First", "Second"],
        categories: ["Shelf"],
        asked_for: %{"First" => true, "Second" => true},
        commented: %{"First" => true, "Second" => true}
      }

      for {_name, reader} <- readers, do: assert(seen(site, reader, posts) == everything)
    end
  end

  describe "blog-post-list" do
    test "shows the site's published posts, newest first", %{site: site} do
      publish!(site, ["First", "Second", "Third"])

      {:ok, view, _html} = mount_page(site, "blog-post-list", %{per_page: 10})

      assert titles(view) == ["Third", "Second", "First"]
    end

    test "says so when there is nothing published", %{site: site} do
      {:ok, _view, html} = mount_page(site, "blog-post-list")

      assert html =~ "Nothing published yet."
    end

    # THE POINT OF THE WHOLE FEATURE. The page number lives on the component, a click reaches the
    # component's own handler through `@myself`, and the list moves.
    test "pages forward and back", %{site: site} do
      publish!(site, ["A", "B", "C", "D", "E"])

      {:ok, view, _html} = mount_page(site, "blog-post-list", %{per_page: 2})

      assert titles(view) == ["E", "D"]
      assert positions(view) == ["1/3"]

      view |> element(~s(#one [data-role="blog-list-next"])) |> render_click()
      assert titles(view) == ["C", "B"]
      assert positions(view) == ["2/3"]

      view |> element(~s(#one [data-role="blog-list-next"])) |> render_click()
      assert titles(view) == ["A"]
      assert positions(view) == ["3/3"]

      view |> element(~s(#one [data-role="blog-list-prev"])) |> render_click()
      assert titles(view) == ["C", "B"]
    end

    # TWO ON ONE PAGE, EACH WITH ITS OWN. The property a function component cannot have at any
    # price: a page assign holding the number would be shared by both.
    test "two lists on one page keep separate pages", %{site: site} do
      publish!(site, ["A", "B", "C", "D"])

      {:ok, view, _html} = mount_page(site, "blog-post-list", %{per_page: 2}, true)

      assert positions(view) == ["1/2", "1/2"]

      view |> element(~s(#one [data-role="blog-list-next"])) |> render_click()

      assert positions(view) == ["2/2", "1/2"], "moving one list moved the other"
    end

    # AND THE PAGE SURVIVES THE PAGE AROUND IT REDRAWING, which is the other half of "stateful".
    test "the page it is on survives a re-render of the page holding it", %{site: site} do
      publish!(site, ["A", "B", "C", "D"])

      {:ok, view, _html} = mount_page(site, "blog-post-list", %{per_page: 2})

      view |> element(~s(#one [data-role="blog-list-next"])) |> render_click()
      assert positions(view) == ["2/2"]

      # AND THE PAGE AROUND IT REDRAWING READS NOTHING. `update_many/1` runs on every render of the
      # page holding this block, so a block that read again on each of them would restart its own
      # load — and drop back to its skeleton — whenever anything else on the page moved. Counted off
      # the repo's telemetry rather than off the markup, because the markup settles either way; the
      # wait is inside the counting, so a read that WAS started is counted rather than missed.
      asked =
        queries_while(fn ->
          send(view.pid, :anything)
          render_async(view, @async)
        end)

      refute Enum.any?(asked, &String.contains?(&1, "mishka_blog_posts")),
             "the page around it redrawing sent the block back to the database"

      assert render(view) =~ ~s(<span data-role="ticks">1</span>),
             "the hosting page never re-rendered, so this proves nothing about surviving one"

      assert positions(view) == ["2/2"], "the page was rebuilt from the hosting page's assigns"
    end

    # THE LINK HAS TO GO WHERE THE ROUTER ACTUALLY SERVES A POST. The route is
    # `live "/mish-blog/post/:slug"` — there is no `/mish-blog/:slug`, so every title in this list
    # was a 404 until this was pinned. Checked against the router rather than against the string, so
    # moving the route moves the test.
    # THE LIST'S OWN TITLES PATCH, they do not navigate: clicking one opens `blog-post-detail`
    # beside the list on the same page, through `?post=<slug>`. `blog-post-search` still writes a
    # real href, and that is the one that has to resolve — see the test below it.
    test "a post title patches to the same page carrying the post's slug", %{site: site} do
      publish!(site, ["A"])

      {:ok, view, _html} = mount_page(site, "blog-post-list", %{base: "/here"})

      [href] =
        view
        |> render_async(@async)
        |> LazyHTML.from_fragment()
        |> LazyHTML.query(~s([data-role="blog-list-title"]))
        |> Enum.map(&LazyHTML.attribute(&1, "href"))
        |> List.flatten()

      assert href =~ "/here?"
      assert href =~ "post="
    end

    test "a search result links where the page said posts live", %{site: site} do
      [post | _rest] = publish!(site, ["A"])

      {:ok, view, _html} = mount_page(site, "blog-post-search", %{post_base: "/somewhere"})

      view |> form(~s(#one form), %{"q" => "A"}) |> render_change()

      href =
        view
        |> render_async(@async)
        |> LazyHTML.from_fragment()
        |> LazyHTML.query(~s([data-role="blog-search-results"] a))
        |> Enum.map(&LazyHTML.attribute(&1, "href"))
        |> List.flatten()
        |> List.first()

      # NO COMPONENT INVENTS A ROUTE. This extension does not own the router, so a link only exists
      # where the PAGE said posts live — and a page that said nothing gets a title with no link
      # rather than one pointing at a URL nobody serves.
      assert href == "/somewhere/#{post.slug}"
    end

    test "and renders the title unlinked when the page said nothing", %{site: site} do
      publish!(site, ["A"])

      {:ok, view, _html} = mount_page(site, "blog-post-search")

      view |> form(~s(#one form), %{"q" => "A"}) |> render_change()

      assert text_of(view, ~s([data-role="blog-search-result"])) == ["A"]

      links =
        view
        |> render_async(@async)
        |> LazyHTML.from_fragment()
        |> LazyHTML.query(~s([data-role="blog-search-results"] a))
        |> Enum.to_list()

      assert links == [], "it linked somewhere nobody told it about"
    end

    # FIRST AND LAST, not only one step at a time. A reader on page one of thirty-five who wants the
    # oldest post should not have to click Next thirty-four times.
    test "First and Last jump to the ends", %{site: site} do
      publish!(site, ["A", "B", "C", "D", "E", "F"])

      {:ok, view, _html} = mount_page(site, "blog-post-list", %{per_page: 2})

      assert positions(view) == ["1/3"]

      view |> element(~s(#one [data-role="blog-list-last"])) |> render_click()
      assert positions(view) == ["3/3"]

      view |> element(~s(#one [data-role="blog-list-first"])) |> render_click()
      assert positions(view) == ["1/3"]
    end

    # THE READER'S OWN ORDER. `sort` is an author default AND an event, so a page can ship
    # oldest-first and a reader can still flip it — and flipping returns to page one, because page
    # three of newest-first is not page three of oldest-first.
    test "the sort button flips the order and returns to page one", %{site: site} do
      publish!(site, ["A", "B", "C", "D"])

      {:ok, view, _html} =
        mount_page(site, "blog-post-list", %{per_page: 2, show_sort: true})

      assert titles(view) == ["D", "C"], "newest first by default"

      view |> element(~s(#one [data-role="blog-list-next"])) |> render_click()
      assert positions(view) == ["2/2"]

      view |> element(~s(#one [data-role="blog-list-sort"])) |> render_click()

      assert titles(view) == ["A", "B"], "the order did not flip"
      assert positions(view) == ["1/2"], "flipping the order left the reader on page two"
    end

    test "the author can ship it oldest-first without the reader touching anything", %{site: site} do
      publish!(site, ["A", "B", "C"])

      {:ok, view, _html} = mount_page(site, "blog-post-list", %{sort: "oldest"})

      assert titles(view) == ["A", "B", "C"]
    end

    # EVERY SWITCH THE AUTHOR HAS, including the three that default to showing nothing. These are
    # the declarations whose default is `false` or `nil`, which is the shape that used to be dropped
    # before it reached the socket.
    test "the show_ switches each turn their own part on and off", %{site: site} do
      publish!(site, ["A", "B", "C"])

      {:ok, shown, _html} =
        mount_page(site, "blog-post-list", %{per_page: 2, show_total: true})

      assert text_of(shown, ~s([data-role="blog-list-date"])) != []
      assert text_of(shown, ~s([data-role="blog-list-total"])) == ["3 posts"]
      assert text_of(shown, ~s([data-role="blog-list-pager"])) != []

      {:ok, hidden, _html} =
        mount_page(site, "blog-post-list", %{
          per_page: 2,
          show_date: false,
          show_excerpt: false,
          show_pager: false
        })

      assert text_of(hidden, ~s([data-role="blog-list-date"])) == []
      assert text_of(hidden, ~s([data-role="blog-list-excerpt"])) == []
      assert text_of(hidden, ~s([data-role="blog-list-pager"])) == []
      assert titles(hidden) == ["C", "B"], "the list itself is still there"
    end

    # THE AUTHOR'S OWN SETTINGS REACH IT, which is what makes it a component rather than a page.
    test "the per-page and heading the author set are what it uses", %{site: site} do
      publish!(site, ["A", "B", "C"])

      {:ok, view, html} = mount_page(site, "blog-post-list", %{per_page: 1, heading: "From us"})

      assert html =~ "From us"
      assert titles(view) == ["C"]
      assert positions(view) == ["1/3"]
    end

    # ANOTHER SITE'S POSTS ARE NOT THIS SITE'S. The tenant comes from the component's own compiled
    # metadata, so it is not something a stored template could be edited into changing.
    test "reads only its own site's posts", %{site: site} do
      elsewhere = "elsewhere#{System.unique_integer([:positive])}"
      other = create_site!(name: elsewhere, host: "#{elsewhere}.test", active: true)
      publish!(site, ["Ours"])
      publish!(other, ["Theirs"])

      {:ok, view, _html} = mount_page(site, "blog-post-list", %{per_page: 10})

      assert titles(view) == ["Ours"]
    end
  end

  # THE URL IS THE BUS. Given `base` and `params` a list reads its page from the query string and
  # writes the next one into a `<.link patch>`, so Back, reload and a shared link all land on the
  # same page — none of which server-held state can do. Given neither, it keeps the `phx-click`
  # pager and the state stays on the socket, which is what a component dropped on a page with no
  # wiring should still do.
  # LIKE ANY OTHER COMPONENT. `precompile: false` means nothing builds this module at boot: the
  # first call finds no module, compiles the row, and renders. That is the ordinary path for a
  # function component and being stateful must not change it — a live component that only worked
  # when something had compiled it in advance would be a different kind of component.
  describe "compiling on first use" do
    test "a stateful row with no module yet compiles when it is first called", %{site: site} do
      publish!(site, ["A"])

      module = CompilerHelpers.module_name("blog-post-list", site.name, "Component")

      refute Code.ensure_loaded?(module),
             "the module was already built, so this proves nothing about lazy compilation"

      {:ok, view, _html} = mount_page(site, "blog-post-list")

      assert Code.ensure_loaded?(module), "the first call did not compile it"
      assert titles(view) == ["A"], "it compiled but did not render"

      assert module.__component_information__([:private, :stateful]) == true,
             "it compiled as a function component"
    end
  end

  describe "blog-post-list in URL mode" do
    test "reads its page from the params it was handed", %{site: site} do
      publish!(site, ["A", "B", "C", "D", "E", "F"])

      {:ok, view, _html} =
        mount_page(site, "blog-post-list", %{
          per_page: 2,
          base: "/here",
          params: %{"page" => "3"}
        })

      assert positions(view) == ["3/3"]
      assert titles(view) == ["B", "A"], "page three of six newest-first"
    end

    # A PAGE THE ADDRESS NAMES PAST THE LAST ONE IS NOT THERE: the response is the site's 404, as for
    # an address nothing is stored at, never the last page under a title and a canonical of its own.
    test "answers a page nobody has with the site's 404", %{site: site} do
      publish!(site, ["A", "B"])

      for page <- ["3", "999"] do
        assert_raise MishkaCmsCore.ErrorsExceptions.NotFoundError, fn ->
          mount_page(site, "blog-post-list", %{
            per_page: 1,
            base: "/here",
            params: %{"page" => page}
          })
        end
      end
    end

    test "and so does a second page of a list that holds nothing", %{site: site} do
      assert_raise MishkaCmsCore.ErrorsExceptions.NotFoundError, fn ->
        mount_page(site, "blog-post-list", %{base: "/here", params: %{"page" => "2"}})
      end
    end

    test "and serves the first and the last page there is", %{site: site} do
      publish!(site, ["A", "B"])

      for {page, position, title} <- [{"1", "1/2", "B"}, {"2", "2/2", "A"}] do
        {:ok, view, _html} =
          mount_page(site, "blog-post-list", %{
            per_page: 1,
            base: "/here",
            params: %{"page" => page}
          })

        assert positions(view) == [position]
        assert titles(view) == [title]
      end
    end

    # ONCE CONNECTED, a patch to a page nobody has asks the page to answer it: a LiveComponent has
    # no response of its own to make a 404 of.
    test "and a patch to a page nobody has asks the page for its 404", %{site: site} do
      publish!(site, ["A", "B"])
      attrs = %{per_page: 1, base: "/here", params: %{"page" => "2"}}

      {view, _first_paint} =
        mount_blocks(site, [%{"name" => "blog-post-list", "id" => "one", "attrs" => attrs}])

      refute has_element?(view, ~s([data-role="not-found"]))

      send(view.pid, {:attrs, "one", %{attrs | params: %{"page" => "9"}}})
      render_async(view, @async)

      assert has_element?(view, ~s([data-role="not-found"]))
    end

    test "and clamps a page nobody has when the click pager asked for it", %{site: site} do
      publish!(site, ["A", "B", "C"])

      {:ok, view, _html} = mount_page(site, "blog-post-list", %{per_page: 1})

      view
      |> element(~s(#one button[data-role="blog-list-next"]))
      |> render_click(%{"to" => "999"})

      assert positions(view) == ["3/3"], "999 / 3 would be a lie with an empty list under it"
      assert titles(view) == ["A"], "and the last page's post is what it should show"
    end

    # TWO LISTS, TWO KEYS, ONE QUERY STRING. Each writes only the key it owns, so moving one leaves
    # the other's page and the open post exactly where the reader left them.
    test "writes its own key and preserves the rest", %{site: site} do
      publish!(site, ["A", "B", "C", "D"])

      {:ok, view, _html} =
        mount_page(site, "blog-post-list", %{
          per_page: 2,
          base: "/here",
          page_param: "left",
          params: %{"left" => "1", "right" => "2", "post" => "keepme"}
        })

      [next] =
        view
        |> render_async(@async)
        |> LazyHTML.from_fragment()
        |> LazyHTML.query(~s([data-role="blog-list-next"]))
        |> Enum.map(&LazyHTML.attribute(&1, "href"))
        |> List.flatten()

      assert next =~ "left=2", "it did not advance its own key"
      assert next =~ "right=2", "it dropped the other list's page"
      assert next =~ "post=keepme", "it closed the open post"
    end

    test "and keeps the click pager when it was given no base", %{site: site} do
      publish!(site, ["A", "B", "C", "D"])

      {:ok, view, _html} = mount_page(site, "blog-post-list", %{per_page: 2})

      assert has_element?(view, ~s(button[data-role="blog-list-next"]))
      refute has_element?(view, ~s(a[data-role="blog-list-next"]))
    end
  end

  # TWO PAGES, NOT ONE. `post_base` turns the list's titles from "open it beside me" into "open it on
  # its own page": a `<.link navigate>` to `<post_base>/<slug>`, which a page stored at
  # `<post_base>/:slug` answers. The detail component then reads the slug the same way either way,
  # because a captured path segment arrives under the same name a query key would.
  describe "blog-post-list linking to a detail page" do
    test "titles navigate to the detail path when one is set", %{site: site} do
      [post | _rest] = publish!(site, ["A"])

      {:ok, view, _html} =
        mount_page(site, "blog-post-list", %{post_base: "/test-blog-post"})

      [href] =
        view
        |> render_async(@async)
        |> LazyHTML.from_fragment()
        |> LazyHTML.query(~s([data-role="blog-list-title"]))
        |> Enum.map(&LazyHTML.attribute(&1, "href"))
        |> List.flatten()

      assert href == "/test-blog-post/#{post.slug}"
    end

    # A TITLE IS A LINK AND DOES NOT LOOK LIKE ONE. It underlines on hover and nowhere else, so a
    # card full of image and excerpt reads as though nothing on it is clickable. The footer carries
    # a labelled action as well, pointing at whichever destination the page chose.
    test "every card carries a visible read link", %{site: site} do
      [post | _rest] = publish!(site, ["A"])

      {:ok, view, _html} =
        mount_page(site, "blog-post-list", %{post_base: "/test-blog-posts/post"})

      [href] =
        view
        |> render_async(@async)
        |> LazyHTML.from_fragment()
        |> LazyHTML.query(~s([data-role="blog-list-read"]))
        |> Enum.map(&LazyHTML.attribute(&1, "href"))
        |> List.flatten()

      assert href == "/test-blog-posts/post/#{post.slug}"
      assert text_of(view, ~s([data-role="blog-list-read"])) == ["Read →"]
    end

    test "and the read link follows the inline mode when that is what the page chose", %{
      site: site
    } do
      publish!(site, ["A"])

      {:ok, view, _html} = mount_page(site, "blog-post-list", %{base: "/here"})

      [href] =
        view
        |> render_async(@async)
        |> LazyHTML.from_fragment()
        |> LazyHTML.query(~s([data-role="blog-list-read"]))
        |> Enum.map(&LazyHTML.attribute(&1, "href"))
        |> List.flatten()

      assert href =~ "/here?"
      assert href =~ "post="
    end

    test "and keep opening beside the list when none is", %{site: site} do
      publish!(site, ["A"])

      {:ok, view, _html} = mount_page(site, "blog-post-list", %{base: "/here"})

      [href] =
        view
        |> render_async(@async)
        |> LazyHTML.from_fragment()
        |> LazyHTML.query(~s([data-role="blog-list-title"]))
        |> Enum.map(&LazyHTML.attribute(&1, "href"))
        |> List.flatten()

      assert href =~ "/here?"
      assert href =~ "post="
    end
  end

  # THE HALF THAT LEFT THE LIST. `blog-post-list` drew the featured strip through a `featured_only`
  # switch, which meant an author who wanted only the strip carried a pager, a sort button and a
  # page size to turn off one at a time — and on the blog's home page the two blocks were one
  # component reading twice anyway.
  describe "blog-featured-posts" do
    test "draws the posts an editor flagged and nothing else", %{site: site} do
      publish!(site, ["Plain"])
      create_blog_post!(site_id: site.id, title: "Starred", status: :published, featured: true)

      {:ok, view, _html} = mount_page(site, "blog-featured-posts")

      assert titles(view) == ["Starred"]
    end

    test "says so when nothing is featured", %{site: site} do
      publish!(site, ["Plain"])

      {:ok, _view, html} = mount_page(site, "blog-featured-posts")

      assert html =~ "Nothing is featured yet."
    end

    test "draws at most what the author asked for", %{site: site} do
      for {title, day} <- [{"A", 1}, {"B", 2}, {"C", 3}] do
        create_blog_post!(
          site_id: site.id,
          title: title,
          status: :published,
          featured: true,
          published_at: DateTime.add(~U[2026-01-01 00:00:00Z], day * 86_400, :second)
        )
      end

      {:ok, view, _html} = mount_page(site, "blog-featured-posts", %{limit: 2})

      assert titles(view) == ["C", "B"]
    end

    # THE SAME EDITION RULE THE REST OF THE KIT FOLLOWS. The report this split came out of was that
    # clicking `fa` brought every language back "even the Featured"; the strip is its own read now,
    # so it is its own answer to that question.
    test "shows one language when the page names one", %{site: site} do
      english =
        create_blog_post!(
          site_id: site.id,
          title: "English",
          status: :published,
          featured: true,
          published_at: ~U[2026-01-01 00:00:00Z]
        )

      persian =
        create_blog_post!(
          site_id: site.id,
          title: "Persian",
          language: "fa",
          language_group_id: english.id,
          status: :published,
          featured: true,
          published_at: ~U[2026-02-01 00:00:00Z]
        )

      {:ok, persian_view, _html} = mount_page(site, "blog-featured-posts", %{language: "fa"})
      assert titles(persian_view) == [persian.title]

      {:ok, english_view, _html} = mount_page(site, "blog-featured-posts", %{language: "en"})
      assert titles(english_view) == ["English"]

      {:ok, master_view, _html} = mount_page(site, "blog-featured-posts")
      assert titles(master_view) == ["English"]

      {:ok, every_view, _html} = mount_page(site, "blog-featured-posts", %{language: "all"})
      assert Enum.sort(titles(every_view)) == Enum.sort(["English", persian.title])
    end

    test "sends a title to the post's own page when the page says where posts live", %{site: site} do
      post =
        create_blog_post!(site_id: site.id, title: "Starred", status: :published, featured: true)

      {:ok, view, _html} =
        mount_page(site, "blog-featured-posts", %{post_base: "/mish-blog/post"})

      assert hrefs(view, ~s([data-role="blog-list-title"])) == ["/mish-blog/post/#{post.slug}"]
    end

    test "reads only its own site's posts", %{site: site} do
      other = create_site!(name: "elsewhere#{System.unique_integer([:positive])}")

      create_blog_post!(
        site_id: other.id,
        title: "Somebody else's",
        status: :published,
        featured: true
      )

      {:ok, view, _html} = mount_page(site, "blog-featured-posts")

      assert titles(view) == []
    end
  end

  # WHAT A READER SEES WHILE A BLOCK IS READING, AND IF IT CANNOT. Three states, each drawn by
  # `blog-notice` and each asserted on a real page rather than on a rendered string.
  describe "a block that reads" do
    # ITS FIRST PAINT HOLDS ITS ROWS, because what a crawler and a reader without JavaScript are
    # served is the first paint: a skeleton there was a listing with no posts in it, and no link to
    # any of them.
    test "draws its rows in its first paint, with no skeleton", %{site: site} do
      publish!(site, ["A", "B"])

      {view, first_paint} =
        mount_blocks(site, [%{"name" => "blog-post-list", "id" => "one", "attrs" => %{}}])

      assert roles(first_paint, "blog-list-loading") == 0,
             "the first paint held a skeleton, so a crawler was served no posts"

      assert roles(first_paint, "blog-list-item") == 2
      assert roles(render_async(view, @async), "blog-list-item") == 2
    end

    # ONE READ PER RENDER OF THE VISIT, AND NONE IN A TASK. A visit renders the page twice — the GET
    # and the connected mount — and each reads its first page in step: the GET so its HTML holds the
    # rows, the connected mount so they are drawn at once rather than behind a skeleton. Counted off
    # the repo's telemetry: `live_isolated/3` is the whole visit, its dead render and its mount.
    test "and one visit reads once per render, and starts no background read", %{site: site} do
      publish!(site, ["A", "B"])

      asked =
        queries_while(fn ->
          {view, _first_paint} =
            mount_blocks(site, [%{"name" => "blog-post-list", "id" => "one", "attrs" => %{}}])

          render_async(view, @async)
        end)

      # One load reads the page of rows and its count, nothing being locked on the site: two per
      # render, two renders.
      assert Enum.count(asked, &String.contains?(&1, "mishka_blog_posts")) == 4,
             "a load is the page of rows and its count, once for each render"
    end

    # EVERY BLOCK ON THE PAGE ANSWERS IN THE SAME FIRST PAINT.
    test "beside other blocks, each with its rows in the first paint", %{site: site} do
      create_blog_post!(site_id: site.id, title: "A", status: :published, featured: true)

      {_view, first_paint} =
        mount_blocks(site, [
          %{"name" => "blog-featured-posts", "id" => "featured", "attrs" => %{}},
          %{"name" => "blog-post-list", "id" => "list", "attrs" => %{}},
          %{"name" => "blog-category-list", "id" => "categories", "attrs" => %{}}
        ])

      for role <- ~w(blog-featured-loading blog-list-loading blog-category-loading) do
        assert roles(first_paint, role) == 0, "#{role} was drawn in the first paint"
      end

      assert roles(first_paint, "blog-featured-items") == 1
      assert roles(first_paint, "blog-list-items") == 1
      assert roles(first_paint, "blog-category-empty") == 1
    end

    # AND A CHANGE THAT IS NOT THE READ'S DOES NOT REACH THE DATABASE. `update_many/1` runs whenever
    # the page hands this block anything new, so a block that read again on each of those would put
    # itself back into its skeleton — and read the whole page of posts again — because somebody
    # renamed its heading. Counted off the repo's own telemetry, with the wait inside the counting
    # so a read that WAS started is counted rather than missed.
    test "and a change to its words is not a change to its read", %{site: site} do
      publish!(site, ["A", "B"])

      {view, _first_paint} =
        mount_blocks(site, [
          %{"name" => "blog-post-list", "id" => "one", "attrs" => %{heading: "First"}}
        ])

      assert render_async(view, @async) =~ "First"

      asked =
        queries_while(fn ->
          send(view.pid, {:attrs, "one", %{heading: "Second"}})
          render_async(view, @async)
        end)

      assert render(view) =~ "Second",
             "the page never handed the block anything new, so this proves nothing"

      refute Enum.any?(asked, &String.contains?(&1, "mishka_blog_posts")),
             "renaming a heading sent the block back to the database"

      assert roles(render(view), "blog-list-item") == 2
    end

    # BUT A CHANGE TO WHAT THE ROWS ARE DRAWN FROM IS. A streamed row is rendered once and never
    # again — LiveView prunes `stream.inserts` after each render, so `@streams.posts` is empty on
    # every render that is not a fresh load — so the layout, the words inside a card and the bases
    # its links are built from cannot reach the cards already on the page by re-rendering. Switching
    # the layout swapped one container for the other and drew the new one over an empty stream: a
    # list of nothing where two cards had been.
    test "but a change to what the rows are drawn from re-streams them", %{site: site} do
      publish!(site, ["A", "B"])

      {view, _first_paint} =
        mount_blocks(site, [%{"name" => "blog-post-list", "id" => "one", "attrs" => %{}}])

      assert roles(render_async(view, @async), "blog-list-item") == 2
      assert has_element?(view, ~s(div[data-role="blog-list-items"]))

      send(view.pid, {:attrs, "one", %{variant: "compact"}})
      drawn = render_async(view, @async)

      assert roles(drawn, "blog-list-item") == 2,
             "the layout changed and the rows were never drawn again for it"

      assert has_element?(view, ~s(ul[data-role="blog-list-items"]))
    end

    # ONE BLOCK FAILING IS ONE BLOCK'S PROBLEM. The read answers with an error, so the block draws
    # its own error and the page around it, blocks and all, is still standing.
    test "and a block whose read fails takes nothing else down with it", %{site: site} do
      publish!(site, ["A", "B"])
      refuse!(site, "blog-tag-cloud")

      {view, _first_paint} =
        mount_blocks(site, [
          %{"name" => "blog-tag-cloud", "id" => "tags", "attrs" => %{}},
          %{"name" => "blog-post-list", "id" => "list", "attrs" => %{}}
        ])

      arrived = render_async(view, @async)

      assert roles(arrived, "blog-tag-error") == 1, "the block that failed drew no error"
      assert roles(arrived, "blog-list-item") == 2, "the block beside it lost its rows"
      assert roles(arrived, "blog-notice-retry") == 1, "the error offers no way to ask again"

      assert render(view) =~ "blog-list-item",
             "the page holding both blocks came down with the read"
    end

    # AND THE WAY OUT WORKS. The signature that stops a re-render from re-reading is the one thing
    # that has to be cleared for this, which is what the button's own handler does.
    test "and asking again reads again", %{site: site} do
      publish!(site, ["A"])
      kept = refuse!(site, "blog-post-list")

      {view, _first_paint} =
        mount_blocks(site, [%{"name" => "blog-post-list", "id" => "list", "attrs" => %{}}])

      assert roles(render_async(view, @async), "blog-list-error") == 1

      write_helpers!(site, "blog-post-list", kept)
      recompile!(site, "blog-post-list")

      view |> element(~s(#list [data-role="blog-notice-retry"])) |> render_click()

      assert roles(render_async(view, @async), "blog-list-item") == 1,
             "asking again did not read again"
    end

    # AND A BLOCK THAT IS READING AGAIN DRAWS ITS SKELETON INSTEAD OF WHAT IT HELD, NOT BOTH.
    # `load/1` sets `loading: true` and leaves the previous answer where it is — it has nothing
    # better to put there — so a row container guarded on emptiness alone drew the old rows
    # underneath the skeleton for the whole length of the read. Every container that holds rows,
    # which for the tag cloud is two: it draws links where the page named a base and words where it
    # did not, and only one of them was ever looked at.
    test "and a re-load draws its skeleton in place of the rows it held", %{site: site} do
      tagged!(site, "Elixir", "elixir")
      filed!(site, "OTP Patterns", "otp-patterns")

      tags = mount_reloading(site, both_tag_clouds())

      stall!(site, "blog-tag-cloud")
      reload!(tags, both_tag_clouds())
      reading = render(tags)

      assert roles(reading, "blog-tag-loading") == 2, "neither tag cloud was reading again"
      assert roles(reading, "blog-tag") == 0, "a tag cloud drew its tags under its own skeleton"

      categories = mount_reloading(site, one_category_list())

      stall!(site, "blog-category-list")
      reload!(categories, one_category_list())
      reading = render(categories)

      assert roles(reading, "blog-category-loading") == 1, "the list was not reading again"
      assert roles(reading, "blog-category") == 0, "the list drew its rows under its own skeleton"
    end

    # AND A RE-LOAD THAT DIES TAKES THEM WITH IT. `handle_async/3`'s `{:exit, _}` clause says
    # `failed: true` and nothing else — the rows it holds are the ones it can no longer vouch for —
    # so the same container has to answer to `@failed` as well as to `@loading`.
    test "and a re-load that dies does not leave the rows it held", %{site: site} do
      tagged!(site, "Elixir", "elixir")
      filed!(site, "OTP Patterns", "otp-patterns")

      tags = mount_reloading(site, both_tag_clouds())

      break!(site, "blog-tag-cloud")
      recompile!(site, "blog-tag-cloud")
      reload!(tags, both_tag_clouds())
      died = render_async(tags, @async)

      assert roles(died, "blog-tag-error") == 2, "a tag cloud drew no error"
      assert roles(died, "blog-tag") == 0, "a tag cloud kept tags its read cannot vouch for"

      categories = mount_reloading(site, one_category_list())

      break!(site, "blog-category-list")
      recompile!(site, "blog-category-list")
      reload!(categories, one_category_list())
      died = render_async(categories, @async)

      assert roles(died, "blog-category-error") == 1, "the list drew no error"
      assert roles(died, "blog-category") == 0, "the list kept rows its read cannot vouch for"
    end
  end

  # THE BUILDER'S PREVIEW AND ITS CANVAS RENDER A COMPONENT WITH NO PROCESS AT ALL —
  # `MishkaCmsCore.Runtime.LiveViewHelpers.cold/2` — where `Phoenix.LiveView.Async` starts no task
  # at all, so a block that only ever read in one would draw an author its skeleton and never
  # anything else. Every block is rendered that way here.
  describe "with no socket at all" do
    test "every block still draws what it holds", %{site: site} do
      publish!(site, ["Cold one"])

      for component <- bundle_components(), component["stateful"] do
        html = cold(site, component["name"])

        refute html =~ ~s(data-tone="loading"),
               "#{component["name"]} drew its skeleton where nothing will ever finish loading"

        refute html =~ "failed to render", "#{component["name"]} did not render at all"
      end
    end

    test "and the list draws its rows", %{site: site} do
      publish!(site, ["Cold one"])

      html = cold(site, "blog-post-list")

      assert roles(html, "blog-list-item") == 1
      assert html =~ "Cold one"
    end

    test "and the featured strip draws its own", %{site: site} do
      create_blog_post!(site_id: site.id, title: "Starred", status: :published, featured: true)

      html = cold(site, "blog-featured-posts")

      assert roles(html, "blog-list-item") == 1
      assert html =~ "Starred"
    end
  end

  describe "blog-post-detail" do
    test "says nothing is chosen when the URL names no post", %{site: site} do
      publish!(site, ["A"])

      {:ok, view, _html} = mount_page(site, "blog-post-detail")

      assert text_of(view, ~s([data-role="blog-detail-idle"])) != []
      assert text_of(view, ~s([data-role="blog-detail-article"])) == []
    end

    test "draws the post the URL names", %{site: site} do
      [post | _rest] = publish!(site, ["Gardening notes"])

      {:ok, view, _html} = mount_page(site, "blog-post-detail", %{slug: post.slug})

      assert text_of(view, ~s([data-role="blog-detail-title"])) == ["Gardening notes"]
      assert text_of(view, ~s([data-role="blog-detail-body"])) != []
      assert text_of(view, ~s([data-role="blog-detail-subtitle"])) == []
    end

    test "draws the post's subtitle under its title", %{site: site} do
      [post | _rest] = publish!(site, ["Gardening notes"])

      post =
        post
        |> Ash.Changeset.for_update(:master_update, %{subtitle: "What grows in a dry summer"},
          authorize?: false
        )
        |> Ash.update!()

      {:ok, view, _html} = mount_page(site, "blog-post-detail", %{slug: post.slug})

      assert text_of(view, ~s([data-role="blog-detail-subtitle"])) == [
               "What grows in a dry summer"
             ]
    end

    # A SLUG THAT NAMES NOTHING IS A DIFFERENT SENTENCE from no slug at all — one is "pick a post",
    # the other is "that post is gone", and a reader who followed a stale link deserves the second.
    test "and says so when the slug names nothing published", %{site: site} do
      publish!(site, ["A"])

      {:ok, view, _html} = mount_page(site, "blog-post-detail", %{slug: "no-such-post"})

      assert text_of(view, ~s([data-role="blog-detail-missing"])) != []
      assert text_of(view, ~s([data-role="blog-detail-idle"])) == []
    end

    # THE PAGE HANDS IT THE QUERY STRING AND NOTHING ELSE. A page that already passes `params` for
    # the list should not have to name the post a second time, so the key this reads is its own
    # `post_param` — the same shape the list uses for `page_param`.
    test "takes the slug out of the params it was handed", %{site: site} do
      [post | _rest] = publish!(site, ["From the URL"])

      {:ok, view, _html} =
        mount_page(site, "blog-post-detail", %{params: %{"post" => post.slug}})

      assert text_of(view, ~s([data-role="blog-detail-title"])) == ["From the URL"]
    end

    test "and under whatever key the author named", %{site: site} do
      [post | _rest] = publish!(site, ["Renamed key"])

      {:ok, view, _html} =
        mount_page(site, "blog-post-detail", %{
          post_param: "story",
          params: %{"story" => post.slug, "post" => "ignored"}
        })

      assert text_of(view, ~s([data-role="blog-detail-title"])) == ["Renamed key"]
    end

    # THE BODY IS MARKUP, AND IT IS SCRUBBED. It has to render as HTML or the reader sees `&lt;p&gt;`
    # down the page; it is stored data rather than reviewed code, so `raw/1` is applied to the
    # sanitizer's output and to nothing else.
    test "renders the body as markup with the executable parts removed", %{site: site} do
      [post | _rest] = publish!(site, ["Scripted"])

      post
      |> Ash.Changeset.for_update(
        :update,
        %{
          content:
            "<h2>Heading</h2><p>Body</p><script>steal()</script><img src=\"x\" onerror=\"boom()\">"
        },
        tenant: site.id,
        context: %{page_code: :package}
      )
      |> Ash.update!(authorize?: false)

      {:ok, view, _html} = mount_page(site, "blog-post-detail", %{slug: post.slug})

      body =
        view
        |> render_async(@async)
        |> LazyHTML.from_fragment()
        |> LazyHTML.query(~s([data-role="blog-detail-body"]))
        |> Enum.map(&LazyHTML.to_html/1)
        |> List.first()

      assert body =~ "<h2>Heading</h2>", "the author's markup was escaped instead of rendered"
      assert body =~ "<p>Body</p>"

      refute body =~ "<script", "a script tag survived into the page"
      refute body =~ "onerror", "an event handler attribute survived into the page"
    end

    # A POST'S CODE IS STORED HIGHLIGHTED, and the body is scrubbed again on its way to the page.
    # The token classes have to come through that, or the kit's stylesheet has nothing to colour.
    test "draws a highlighted code block with every token class it was stored with", %{site: site} do
      editor = create_user_with_permissions!(["admin:dashboard:blog:post"], site_id: site.id)

      post =
        MishkaBlog.BlogPost
        |> Ash.Changeset.for_create(
          :create,
          %{
            title: "Code",
            slug: "code",
            status: :published,
            language: "en",
            content:
              ~S|<pre><code class="language-elixir">def hello(name), do: "Hi #{name}"</code></pre>|
          },
          actor: editor,
          tenant: site.id
        )
        |> Ash.create!()

      {:ok, view, _html} = mount_page(site, "blog-post-detail", %{slug: post.slug})

      token_classes = fn html, scope ->
        html
        |> LazyHTML.from_fragment()
        |> LazyHTML.query(scope <> " pre.highlight > code.language-elixir > span")
        |> LazyHTML.attribute("class")
      end

      stored = token_classes.(post.content, "")
      drawn = token_classes.(render_async(view, @async), ~s([data-role="blog-detail-body"]))

      assert "kd" in stored and "nf" in stored and "s" in stored
      assert drawn == stored
    end

    test "reads only its own site's posts", %{site: site} do
      other = create_site!(name: "elsewhere#{System.unique_integer([:positive])}")
      [theirs | _rest] = publish!(other, ["Theirs"])

      {:ok, view, _html} = mount_page(site, "blog-post-detail", %{slug: theirs.slug})

      assert text_of(view, ~s([data-role="blog-detail-missing"])) != []
    end
  end

  # A POST NAMES COMPONENTS BY MARKER and its page draws them — see
  # `MishkaCmsCore.Runtime.ContentComponents`. The body goes through `rich_content`, so a marker is
  # the site's real component, cast to what it declares, and the HTML around it is the post's own.
  describe "blog-post-detail drawing the components a post names" do
    # WHAT THE COMPILE WORKER DOES FOR AN ACTIVE COMPONENT, which `testing: :manual` never runs: its
    # name goes into `SiteState`, the names a marker is checked against before anything is built.
    defp known!(site, name) do
      :ok = SiteState.put_component(site.id, name)
      on_exit(fn -> SiteState.delete_component(site.id, name) end)
    end

    defp callout!(site) do
      name = "post-callout-#{System.unique_integer([:positive])}"
      known!(site, name)

      create_component!(
        name: name,
        site_id: site.id,
        active: true,
        template:
          ~S|<aside data-role="post-callout" data-title={@title} data-tone={@tone}>{render_slot(@inner_block)}</aside>|,
        attrs: [
          %{"name" => "title", "type" => "string", "opts" => %{"default" => nil}},
          %{
            "name" => "tone",
            "type" => "string",
            "opts" => %{"default" => "info", "values" => ["info", "warn"]}
          }
        ],
        slots: [%{"name" => "inner_block", "opts" => %{}}]
      )
    end

    defp written!(site, title, content) do
      create_blog_post!(
        site_id: site.id,
        title: title,
        status: :published,
        published_at: ~U[2026-01-01 00:00:00Z],
        content: content
      )
    end

    defp body(view) do
      view
      |> render_async(@async)
      |> LazyHTML.from_fragment()
      |> LazyHTML.query(~s([data-role="blog-detail-body"]))
    end

    test "draws the component a marker names, where the marker stands", %{site: site} do
      callout = callout!(site)

      post =
        written!(
          site,
          "With a callout",
          ~s(<p>Intro</p>[[component #{callout.name} title="Heads up" tone="warn" phx-click="boom"]]Read <b>this</b>[[/component]]<p>Outro</p>)
        )

      {:ok, view, _html} = mount_page(site, "blog-post-detail", %{slug: post.slug})

      body = body(view)
      [aside] = body |> LazyHTML.query(~s([data-role="post-callout"])) |> Enum.to_list()

      assert LazyHTML.attribute(aside, "data-title") == ["Heads up"]
      assert LazyHTML.attribute(aside, "data-tone") == ["warn"]
      assert aside |> LazyHTML.query("b") |> LazyHTML.text() == "this"

      html = LazyHTML.to_html(body)

      assert html =~ "<p>Intro</p>"
      assert html =~ "<p>Outro</p>"
      refute html =~ "[[component"
      refute html =~ "phx-click"
    end

    # AN EDITOR WRAPS EVERY LINE IN A `<p>`, and a block inside one is HTML a browser takes apart.
    test "a marker alone in its paragraph is drawn without the paragraph", %{site: site} do
      callout = callout!(site)
      post = written!(site, "Wrapped", "<p>Intro</p><p>[[component #{callout.name} /]]</p>")

      {:ok, view, _html} = mount_page(site, "blog-post-detail", %{slug: post.slug})

      assert body(view) |> LazyHTML.query(~s(p [data-role="post-callout"])) |> Enum.to_list() ==
               []

      assert [_aside] =
               body(view) |> LazyHTML.query(~s([data-role="post-callout"])) |> Enum.to_list()

      assert body(view) |> LazyHTML.query("p") |> Enum.count() == 1
    end

    # A COMPONENT'S MARKUP AS CHELEKOM WRITES IT: every element carries classes of its own. Each is
    # marked `data-part="component"` too, so a test can tell it from the post's own HTML.
    defp marked!(site, template) do
      name = "post-marked-#{System.unique_integer([:positive])}"
      known!(site, name)
      create_component!(name: name, site_id: site.id, active: true, template: template)
    end

    defp crumbs!(site),
      do:
        marked!(
          site,
          ~S|<nav data-role="post-crumbs" data-part="component" class="text-sm"><ol data-part="component" class="flex items-center gap-2"><li data-part="component" class="flex items-center"><a data-part="component" href="https://example.com/home" class="text-[#5b57d6]">Home</a></li><li data-part="component" class="flex items-center">Here</li></ol></nav>|
        )

    defp heading!(site),
      do:
        marked!(
          site,
          ~S|<h2 data-role="post-heading" data-part="component" class="text-3xl font-black">Drawn heading</h2>|
        )

    # WHAT EACH CONTENT STYLE ON THE BODY REACHES: every `[selector]:utility` class of
    # `blog-detail-body`, read as the rule Tailwind writes for it — `&` the body, `_` a space — and
    # run over the drawn page. One `{utility, elements}` per class.
    defp styled(view) do
      page = view |> render_async(@async) |> LazyHTML.from_fragment()
      body = ~s([data-role="blog-detail-body"])
      [classes] = page |> LazyHTML.query(body) |> LazyHTML.attribute("class")

      for class <- String.split(classes),
          [_class, selector, utility] <- [Regex.run(~r/\A\[(.+)\]:([^\]]+)\z/, class)] do
        rule = selector |> String.replace("_", " ") |> String.replace("&", body)
        {utility, page |> LazyHTML.query(rule) |> Enum.to_list()}
      end
    end

    defp reached(styled, utility),
      do: for({^utility, elements} <- styled, element <- elements, do: element)

    defp reached_component(styled),
      do:
        for(
          {_utility, elements} <- styled,
          element <- elements,
          LazyHTML.attribute(element, "data-part") == ["component"],
          do: element
        )

    test "the post's own list and link take its styles, and a component's list and link do not",
         %{site: site} do
      crumbs = crumbs!(site)

      post =
        written!(
          site,
          "Styled",
          ~s(<p>Read <a href="https://example.com/guide">the guide</a> first.</p><ul><li><p>Own item</p></li></ul><ol><li><p>First step</p></li></ol><p>[[component #{crumbs.name} /]]</p>)
        )

      {:ok, view, _html} = mount_page(site, "blog-post-detail", %{slug: post.slug})

      assert [_nav] =
               body(view) |> LazyHTML.query(~s([data-role="post-crumbs"])) |> Enum.to_list()

      styles = styled(view)

      assert styles |> reached("list-disc") |> Enum.map(&LazyHTML.text/1) == ["Own item"]
      assert styles |> reached("list-decimal") |> Enum.map(&LazyHTML.text/1) == ["First step"]

      assert styles |> reached("ml-5") |> Enum.map(&LazyHTML.text/1) == [
               "Own item",
               "First step"
             ]

      assert styles |> reached("underline") |> Enum.flat_map(&LazyHTML.attribute(&1, "href")) ==
               ["https://example.com/guide"]

      assert reached_component(styles) == []
    end

    # A COMPONENT IS NOT TEXT WHEREVER IT IS DRAWN: one whose own root is a heading, and one placed
    # inside a list item, keep the classes they were drawn with.
    test "a component drawn as a heading, or inside a list item, is left to its own classes",
         %{site: site} do
      heading = heading!(site)
      crumbs = crumbs!(site)

      post =
        written!(
          site,
          "Nested",
          ~s(<h2>Own heading</h2><p>[[component #{heading.name} /]]</p><ul><li><p>Own item</p><p>[[component #{crumbs.name} /]]</p></li></ul><blockquote><p>Quoted <a href="https://example.com/source">source</a></p></blockquote>)
        )

      {:ok, view, _html} = mount_page(site, "blog-post-detail", %{slug: post.slug})

      assert [_heading] =
               body(view) |> LazyHTML.query(~s([data-role="post-heading"])) |> Enum.to_list()

      assert [_crumbs] =
               body(view) |> LazyHTML.query(~s(li > [data-role="post-crumbs"])) |> Enum.to_list()

      styles = styled(view)

      assert styles |> reached("text-lg") |> Enum.map(&LazyHTML.text/1) == ["Own heading"]
      assert styles |> reached("list-disc") |> Enum.count() == 1

      assert styles |> reached("underline") |> Enum.flat_map(&LazyHTML.attribute(&1, "href")) ==
               ["https://example.com/source"]

      assert reached_component(styles) == []
    end

    test "a stateful block in a post is a live component of its own", %{site: site} do
      known!(site, "blog-featured-posts")
      create_blog_post!(site_id: site.id, title: "Starred", status: :published, featured: true)
      post = written!(site, "Holder", "<p>See also</p>[[component blog-featured-posts /]]")

      {:ok, view, _html} = mount_page(site, "blog-post-detail", %{slug: post.slug})
      render_async(view, @async)

      assert has_element?(view, ~s(#one-body-0[data-role="blog-featured-posts"]))
      assert "Starred" in titles(view)
    end

    test "a marker for a block that draws posts itself is drawn as nothing", %{site: site} do
      known!(site, "blog-post-detail")

      post =
        written!(site, "Itself", ~s(<p>Kept</p>[[component blog-post-detail slug="itself" /]]))

      {:ok, view, _html} = mount_page(site, "blog-post-detail", %{slug: post.slug})

      assert body(view) |> LazyHTML.query(~s([data-role="blog-post-detail"])) |> Enum.to_list() ==
               []

      assert body(view) |> LazyHTML.text() =~ "Kept"
    end

    # STORED CONTENT IS SANITIZED WHEN IT IS WRITTEN, and a code-heavy post scrubbed again on every
    # view cost ~150 ms. The row is written here past the write path, with markup the scrubber would
    # take out, so a second pass on read is something this test can see.
    test "draws the stored content as it was stored, without scrubbing it again", %{site: site} do
      post = written!(site, "Stored", "<p>placeholder</p>")
      stored = ~s(<p><font data-probe="kept">Stored as written</font></p>)

      Ecto.Adapters.SQL.query!(
        Application.fetch_env!(:mishka_cms_core, :repo),
        "UPDATE mishka_blog_posts SET content = $1 WHERE id = $2",
        [stored, Ecto.UUID.dump!(post.id)]
      )

      {:ok, view, _html} = mount_page(site, "blog-post-detail", %{slug: post.slug})

      assert [_kept] =
               body(view) |> LazyHTML.query(~s(font[data-probe="kept"])) |> Enum.to_list()
    end

    # A PLUGIN'S OUTPUT WAS NEVER SCRUBBED, so it alone is sanitized on the way to the page.
    test "scrubs what a render_content plugin changed", %{site: site} do
      with_plugin(
        MishkaBlog.Test.Plugins.BlogPostRenderContentScript,
        "blog:blog_post:render_content",
        fn ->
          post = written!(site, "Plugged", "<p>Stored</p>")

          {:ok, view, _html} = mount_page(site, "blog-post-detail", %{slug: post.slug})

          html = view |> body() |> LazyHTML.to_html()

          assert html =~ "<p>Stored</p>"
          assert html =~ ~s(data-probe="plugin")
          refute html =~ "<script"
        end
      )
    end

    test "a marker inside code is shown as written", %{site: site} do
      callout = callout!(site)
      post = written!(site, "Docs", "<pre><code>[[component #{callout.name} /]]</code></pre>")

      {:ok, view, _html} = mount_page(site, "blog-post-detail", %{slug: post.slug})

      assert body(view) |> LazyHTML.query(~s([data-role="post-callout"])) |> Enum.to_list() == []
      assert body(view) |> LazyHTML.text() =~ "[[component #{callout.name} /]]"
    end
  end

  describe "blog-post-search" do
    test "narrows the list as the visitor types", %{site: site} do
      publish!(site, ["Elixir at work", "Gardening notes", "Elixir releases"])

      {:ok, view, _html} = mount_page(site, "blog-post-search")

      view |> form(~s(#one form), %{"q" => "Elixir"}) |> render_change()

      found = text_of(view, ~s([data-role="blog-search-result"]))

      assert Enum.sort(found) == ["Elixir at work", "Elixir releases"]
    end

    test "and says when nothing matches", %{site: site} do
      publish!(site, ["Gardening notes"])

      {:ok, view, _html} = mount_page(site, "blog-post-search")

      html = view |> form(~s(#one form), %{"q" => "Elixir"}) |> render_change()

      assert html =~ "Nothing matches"
    end

    # A VISITOR TYPES THE WAY THEY TYPE. `contains/2` with a plain string is SQL `LIKE`, so
    # "elixir" found nothing titled "Elixir" — the lower-case query a search box mostly receives.
    test "is case-insensitive", %{site: site} do
      publish!(site, ["Elixir at work", "Gardening notes", "ELIXIR releases"])

      {:ok, view, _html} = mount_page(site, "blog-post-search")

      view |> form(~s(#one form), %{"q" => "elixir"}) |> render_change()

      found = text_of(view, ~s([data-role="blog-search-result"]))

      assert Enum.sort(found) == ["ELIXIR releases", "Elixir at work"]
    end

    # AN EMPTY BOX IS NOT A SEARCH FOR EVERYTHING. Clearing it sends `q=""`, which used to reload
    # with no filter at all and list the newest posts under a box that says nothing. A query of
    # only spaces is the same empty box, and nothing was searched, so nothing "matches" either.
    test "clearing the query clears the results", %{site: site} do
      publish!(site, ["Elixir at work", "Gardening notes"])

      {:ok, view, _html} = mount_page(site, "blog-post-search")

      for cleared <- ["", "   "] do
        view |> form(~s(#one form), %{"q" => "Elixir"}) |> render_change()
        assert text_of(view, ~s([data-role="blog-search-result"])) == ["Elixir at work"]

        view |> form(~s(#one form), %{"q" => cleared}) |> render_change()

        refute has_element?(view, ~s(#one [data-role="blog-search-result"])),
               "#{inspect(cleared)} listed posts nobody searched for"

        refute has_element?(view, ~s(#one [data-role="blog-search-none"])),
               "#{inspect(cleared)} said nothing matches a search nobody ran"
      end
    end

    # A QUERY THAT IS NOT TEXT IS NOT A SEARCH. The event's params are decoded from whatever the
    # client sent, so `q[]=Elixir` arrives as a list; carried into the socket it reached
    # `String.trim/1` in the template and took the visitor's whole page down with it.
    test "ignores a query that is not text", %{site: site} do
      publish!(site, ["Elixir at work", "Gardening notes"])

      {:ok, view, _html} = mount_page(site, "blog-post-search")

      view |> element(~s(#one form)) |> render_change(%{"q" => ["Elixir"]})

      refute has_element?(view, ~s(#one [data-role="blog-search-result"]))
      refute has_element?(view, ~s(#one [data-role="blog-search-none"]))

      view |> form(~s(#one form), %{"q" => "Elixir"}) |> render_change()
      assert text_of(view, ~s([data-role="blog-search-result"])) == ["Elixir at work"]
    end
  end

  # A LIST THAT HOLDS ONE SUBJECT, which is what a category page and a sidebar block both are. The
  # narrowing is done in the query rather than by a template that renders everything and hides most
  # of it: page two of a category has to be page two of that category.
  describe "blog-post-list narrowed" do
    test "a collection narrows it to that category's published posts", %{site: site} do
      [ours, theirs] = publish!(site, ["Ours", "Theirs"])
      category = category!(site, name: "OTP Patterns", slug: "otp-patterns")

      categorize!(ours, category)

      {:ok, view, _html} =
        mount_page(site, "blog-post-list", %{per_page: 10, collection: "otp-patterns"})

      assert titles(view) == ["Ours"]
      refute theirs.title in titles(view)
    end

    test "and heads the list with that category's own name and description", %{site: site} do
      [post] = publish!(site, ["Ours"])

      category =
        category!(site, name: "OTP Patterns", slug: "otp-patterns", description: "Processes.")

      categorize!(post, category)

      {:ok, view, _html} =
        mount_page(site, "blog-post-list", %{
          collection: "otp-patterns",
          heading: "Latest posts"
        })

      assert text_of(view, ~s([data-role="blog-list-filter-title"])) == ["OTP Patterns"]
      assert text_of(view, ~s([data-role="blog-list-filter-description"])) == ["Processes."]

      assert text_of(view, ~s([data-role="blog-list-heading"])) == [],
             "the page's own heading was drawn as well as the category's"
    end

    # A DRAFT CATEGORY IS NOT A CATEGORY. Its slug still resolves in the URL, and a list that read
    # it would publish, through the back door, a grouping its author has not finished.
    test "and an unpublished or unknown collection holds nothing", %{site: site} do
      [post] = publish!(site, ["Ours"])
      draft = category!(site, name: "Unfinished", slug: "unfinished", status: :draft)

      categorize!(post, draft)

      for slug <- ["unfinished", "no-such-category"] do
        {:ok, view, _html} = mount_page(site, "blog-post-list", %{collection: slug})

        assert titles(view) == [], "#{slug} listed posts"
        assert text_of(view, ~s([data-role="blog-list-empty"])) != []
      end
    end

    test "a tag narrows it to the posts carrying that tag", %{site: site} do
      [ours, _theirs] = publish!(site, ["Ours", "Theirs"])
      tag = tag!(site, name: "Elixir", slug: "elixir")

      tag_post!(ours, tag)

      {:ok, view, _html} = mount_page(site, "blog-post-list", %{per_page: 10, tag: "elixir"})

      assert titles(view) == ["Ours"]
      assert text_of(view, ~s([data-role="blog-list-filter-title"])) == ["Elixir"]
    end

    # BOTH AT ONCE IS AN INTERSECTION, not a union: an author who sets a category and a tag on one
    # block is asking for the posts in both.
    test "a collection and a tag together keep only the posts in both", %{site: site} do
      [both, tagged_only, filed_only] = publish!(site, ["Both", "Tagged", "Filed"])
      category = category!(site, name: "OTP", slug: "otp")
      tag = tag!(site, name: "Elixir", slug: "elixir")

      categorize!(both, category)
      tag_post!(both, tag)
      tag_post!(tagged_only, tag)
      categorize!(filed_only, category)

      {:ok, view, _html} =
        mount_page(site, "blog-post-list", %{
          per_page: 10,
          collection: "otp",
          tag: "elixir",
          show_filter_title: false
        })

      assert titles(view) == ["Both"]
    end

    test "featured_only keeps the posts an editor flagged", %{site: site} do
      publish!(site, ["Ordinary"])

      create_blog_post!(
        site_id: site.id,
        title: "Picked",
        status: :published,
        featured: true,
        published_at: ~U[2026-02-01 00:00:00Z]
      )

      {:ok, view, _html} =
        mount_page(site, "blog-post-list", %{per_page: 10, featured_only: true})

      assert titles(view) == ["Picked"]
    end

    # THE POST THE READER IS ALREADY ON. A "more from us" block under an article that offers the
    # article itself is the one link on it that cannot be useful.
    test "exclude_slug leaves that one post out", %{site: site} do
      [open_one | _rest] = publish!(site, ["Open", "Another"])

      {:ok, view, _html} =
        mount_page(site, "blog-post-list", %{per_page: 10, exclude_slug: open_one.slug})

      assert titles(view) == ["Another"]
    end

    test "the compact variant draws a list and not a grid", %{site: site} do
      publish!(site, ["A", "B"])

      {:ok, view, _html} = mount_page(site, "blog-post-list", %{variant: "compact"})

      assert has_element?(view, ~s(ul[data-role="blog-list-items"]))
      refute has_element?(view, ~s(div[data-role="blog-list-items"]))
      assert titles(view) == ["B", "A"]
    end

    # EVERY WORD ON IT IS THE AUTHOR'S. A site written in Persian cannot have "Next" and "Featured"
    # in the middle of it, and this component does not own the site's language.
    test "the label attributes replace every English word it ships with", %{site: site} do
      publish!(site, ["A", "B", "C"])

      {:ok, view, _html} =
        mount_page(site, "blog-post-list", %{
          per_page: 2,
          show_total: true,
          show_sort: true,
          first_text: "Aval",
          previous_text: "Ghabli",
          next_text: "Badi",
          last_text: "Akhar",
          total_text: "neveshte",
          newest_text: "Tazetarin",
          read_text: "Bekhan",
          base: "/here"
        })

      assert text_of(view, ~s([data-role="blog-list-first"])) == ["Aval"]
      assert text_of(view, ~s([data-role="blog-list-prev"])) == ["Ghabli"]
      assert text_of(view, ~s([data-role="blog-list-next"])) == ["Badi"]
      assert text_of(view, ~s([data-role="blog-list-last"])) == ["Akhar"]
      assert text_of(view, ~s([data-role="blog-list-total"])) == ["3 neveshte"]
      assert text_of(view, ~s([data-role="blog-list-sort"])) == ["Tazetarin"]
      assert text_of(view, ~s([data-role="blog-list-read"])) == ["Bekhan →", "Bekhan →"]
    end
  end

  # ONE ARTICLE, ONCE. A post written in five languages is five rows sharing a group, and a listing
  # that showed all five showed the same article five times over. The default is the master edition
  # — the row whose group points at itself — and a page asks for a language by naming it.
  describe "blog-post-list in one language" do
    test "shows one edition of each post by default", %{site: site} do
      master = publish!(site, ["Master"]) |> List.first()
      translate!(site, master, "fa", "Tarjome")

      {:ok, view, _html} = mount_page(site, "blog-post-list", %{per_page: 10})

      assert titles(view) == ["Master"]
    end

    test "shows one language when the page names one", %{site: site} do
      master = publish!(site, ["Master"]) |> List.first()
      translate!(site, master, "fa", "Tarjome")

      {:ok, view, _html} =
        mount_page(site, "blog-post-list", %{per_page: 10, language: "fa"})

      assert titles(view) == ["Tarjome"]
    end

    test "and every edition when the page asks for all of them", %{site: site} do
      master = publish!(site, ["Master"]) |> List.first()
      translate!(site, master, "fa", "Tarjome")

      {:ok, view, _html} =
        mount_page(site, "blog-post-list", %{per_page: 10, language: "all"})

      assert Enum.sort(titles(view)) == ["Master", "Tarjome"]
    end

    # THE LINKS IT WRITES STAY IN THE PAGE'S MODE. A site addressed as /blog?lang=fa has to carry
    # that key onto the next page, and a site addressed as /fa/blog already has it in the base and
    # must not be given it twice.
    test "carries the language on its links when the page addresses languages by query", %{
      site: site
    } do
      persian!(site, "Neveshte")

      {:ok, view, _html} =
        mount_page(site, "blog-post-list", %{
          post_base: "/mish-blog/post",
          language: "fa",
          lang_param: "lang"
        })

      assert [href] = hrefs(view, ~s([data-role="blog-list-title"]))
      assert href =~ "/mish-blog/post/"
      assert href =~ "lang=fa"
    end

    test "and leaves them alone when the language is already in the path", %{site: site} do
      persian!(site, "Neveshte")

      {:ok, view, _html} =
        mount_page(site, "blog-post-list", %{post_base: "/fa/blog/post", language: "fa"})

      assert [href] = hrefs(view, ~s([data-role="blog-list-title"]))
      refute href =~ "lang=", "the language was appended to a path that already carries it"
    end

    # THE HEADING IS READ IN THE PAGE'S LANGUAGE TOO. A slug names one row per site whatever
    # language it is written in, so `/fa/blog/category/<english slug>` — a link somebody kept, or a
    # URL somebody typed — headed a Persian page with the English category's name and listed the
    # nothing that category holds in Persian underneath it.
    test "does not head itself with a category written in another one", %{site: site} do
      [post] = publish!(site, ["Ours"])
      categorize!(post, category!(site, name: "OTP Patterns", slug: "otp-patterns"))

      {:ok, asked_in_persian, _html} =
        mount_page(site, "blog-post-list", %{
          collection: "otp-patterns",
          language: "fa",
          heading: "Latest posts"
        })

      assert text_of(asked_in_persian, ~s([data-role="blog-list-filter-title"])) == []

      assert text_of(asked_in_persian, ~s([data-role="blog-list-heading"])) == ["Latest posts"]

      {:ok, asked_in_english, _html} =
        mount_page(site, "blog-post-list", %{collection: "otp-patterns", language: "en"})

      assert text_of(asked_in_english, ~s([data-role="blog-list-filter-title"])) ==
               ["OTP Patterns"]
    end

    test "nor with a tag written in another one", %{site: site} do
      [post] = publish!(site, ["Ours"])
      tag_post!(post, tag!(site, name: "Elixir", slug: "elixir"))

      {:ok, asked_in_persian, _html} =
        mount_page(site, "blog-post-list", %{tag: "elixir", language: "fa"})

      assert text_of(asked_in_persian, ~s([data-role="blog-list-filter-title"])) == []

      {:ok, asked_in_english, _html} =
        mount_page(site, "blog-post-list", %{tag: "elixir", language: "en"})

      assert text_of(asked_in_english, ~s([data-role="blog-list-filter-title"])) == ["Elixir"]
    end

    # A page that does not address languages at all still heads itself with the row it was given,
    # whichever language that row is written in.
    test "and heads itself by the slug alone when the page names no language", %{site: site} do
      persian = persian!(site, "نوشته")
      categorize!(persian, category!(site, name: "الگوها", slug: "olgooha", language: "fa"))

      {:ok, view, _html} = mount_page(site, "blog-post-list", %{collection: "olgooha"})

      assert text_of(view, ~s([data-role="blog-list-filter-title"])) == ["الگوها"]
    end

    # AND THE LIST AGREES WITH THE HEADING ABOUT WHETHER THAT ROW IS HERE. Posts are filed under a
    # category whatever language either of them is written in, so a category read in one language
    # and posts read by its slug alone put a Persian article under a heading the component had just
    # refused to draw, and the page said "Category" over a list of real posts.
    test "and lists nothing under a category that is not written in that language", %{site: site} do
      persian = persian!(site, "به فارسی")
      categorize!(persian, category!(site, name: "OTP Patterns", slug: "otp-patterns"))

      {:ok, asked_in_persian, _html} =
        mount_page(site, "blog-post-list", %{collection: "otp-patterns", language: "fa"})

      assert titles(asked_in_persian) == []
      assert text_of(asked_in_persian, ~s([data-role="blog-list-empty"])) != []

      {:ok, asked_in_every, _html} =
        mount_page(site, "blog-post-list", %{collection: "otp-patterns", language: "all"})

      assert titles(asked_in_every) == ["به فارسی"]
    end

    test "nor under a tag that is not", %{site: site} do
      persian = persian!(site, "به فارسی")
      tag_post!(persian, tag!(site, name: "Elixir", slug: "elixir"))

      {:ok, asked_in_persian, _html} =
        mount_page(site, "blog-post-list", %{tag: "elixir", language: "fa"})

      assert titles(asked_in_persian) == []

      {:ok, asked_in_every, _html} =
        mount_page(site, "blog-post-list", %{tag: "elixir", language: "all"})

      assert titles(asked_in_every) == ["به فارسی"]
    end
  end

  describe "blog-tag-cloud" do
    test "says so when the site has no tags", %{site: site} do
      {:ok, _view, html} = mount_page(site, "blog-tag-cloud")

      assert html =~ "No tags yet."
    end

    # A TAG USED TO BE A BUTTON THAT DID NOTHING. `phx-click="pick"` flipped a `data-selected` on the
    # tag itself and narrowed no list anywhere, so the one thing a reader expects of a tag cloud —
    # pressing a tag and reading that tag's posts — was the one thing it could not do.
    test "links each tag to where the page said that tag's posts live", %{site: site} do
      tagged!(site, "Elixir", "elixir")

      {:ok, view, _html} = mount_page(site, "blog-tag-cloud", %{tag_base: "/blog/tag"})

      assert hrefs(view, ~s([data-role="blog-tag"])) == ["/blog/tag/elixir"]
      assert text_of(view, ~s([data-role="blog-tag"])) == ["Elixir"]
    end

    test "and draws them as plain words when the page said nothing", %{site: site} do
      tagged!(site, "Elixir", "elixir")

      {:ok, view, _html} = mount_page(site, "blog-tag-cloud")

      assert text_of(view, ~s([data-role="blog-tag"])) == ["Elixir"]
      assert hrefs(view, ~s([data-role="blog-tag"])) == []
    end

    # POPULAR MEANS POPULAR IN PUBLIC. `post_count` counts drafts, so a tag carried by one published
    # post and nine drafts outranked a tag carried by five published ones.
    test "orders by published posts, and a draft is not one", %{site: site} do
      much = tag!(site, name: "Much", slug: "much")
      little = tag!(site, name: "Little", slug: "little")

      for post <- publish!(site, ["A", "B"]), do: tag_post!(post, much)

      [one] = publish!(site, ["C"])
      tag_post!(one, little)

      drafted = create_blog_post!(site_id: site.id, title: "Draft", status: :draft)
      tag_post!(drafted, little)

      {:ok, view, _html} = mount_page(site, "blog-tag-cloud", %{show_count: true})

      assert squished(view, ~s([data-role="blog-tag"])) == ["Much 2", "Little 1"]
    end

    test "and alphabetically when the author asked for that instead", %{site: site} do
      tagged!(site, "Zebra", "zebra")
      tagged!(site, "Apple", "apple")

      {:ok, view, _html} = mount_page(site, "blog-tag-cloud", %{sort: "name"})

      assert text_of(view, ~s([data-role="blog-tag"])) == ["Apple", "Zebra"]
    end

    # A TAG NOBODY CAN FOLLOW. Every tag ever typed in the admin was offered, including the ones
    # whose only posts are drafts, and each of them led to an empty page.
    test "leaves out the tags no published post carries", %{site: site} do
      used = tagged!(site, "Used", "used")
      _unused = tag!(site, name: "Unused", slug: "unused")

      {:ok, view, _html} = mount_page(site, "blog-tag-cloud")

      assert text_of(view, ~s([data-role="blog-tag"])) == [used.name]

      {:ok, showing_all, _html} = mount_page(site, "blog-tag-cloud", %{hide_empty: false})

      assert Enum.sort(text_of(showing_all, ~s([data-role="blog-tag"]))) == ["Unused", "Used"]
    end

    test "shows one language's tags when the page names one", %{site: site} do
      english = tagged!(site, "Elixir", "elixir")
      persian = tag!(site, name: "اکسیر", slug: "eksir", language: "fa")
      tag_post!(persian!(site, "A"), persian)

      {:ok, view, _html} = mount_page(site, "blog-tag-cloud", %{language: "fa"})

      assert text_of(view, ~s([data-role="blog-tag"])) == [persian.name]

      {:ok, master, _html} = mount_page(site, "blog-tag-cloud")

      assert Enum.sort(text_of(master, ~s([data-role="blog-tag"]))) ==
               Enum.sort([english.name, persian.name]),
             "both are masters of their own group, so both belong in the default"
    end

    # EMPTY IN THIS LANGUAGE IS EMPTY. The count beside a tag is of every post filed under it, so
    # hiding by that number offered a Persian reader a tag whose only public post is English — and
    # the page it opens, listing Persian posts, has nothing on it.
    test "and leaves out a tag with nothing published in that language", %{site: site} do
      carrying = tag!(site, name: "اکسیر", slug: "eksir", language: "fa")
      tag_post!(persian!(site, "به فارسی"), carrying)

      english_only = tag!(site, name: "فونیکس", slug: "phoenix-fa", language: "fa")
      [english] = publish!(site, ["In English"])
      tag_post!(english, english_only)

      {:ok, view, _html} = mount_page(site, "blog-tag-cloud", %{language: "fa"})

      assert text_of(view, ~s([data-role="blog-tag"])) == [carrying.name]

      {:ok, showing_all, _html} =
        mount_page(site, "blog-tag-cloud", %{language: "fa", hide_empty: false})

      assert Enum.sort(text_of(showing_all, ~s([data-role="blog-tag"]))) ==
               Enum.sort([carrying.name, english_only.name])
    end

    test "marks the tag the reader is already reading", %{site: site} do
      tagged!(site, "Elixir", "elixir")
      tagged!(site, "Erlang", "erlang")

      {:ok, view, _html} =
        mount_page(site, "blog-tag-cloud", %{
          tag_base: "/en/blog/tag",
          params: %{"slug" => "elixir"}
        })

      marked =
        view
        |> render_async(@async)
        |> LazyHTML.from_fragment()
        |> LazyHTML.query(~s([data-role="blog-tag"][data-selected="true"]))
        |> Enum.map(&(&1 |> LazyHTML.text() |> String.trim()))

      assert marked == ["Elixir"]
    end
  end

  describe "blog-category-list" do
    test "says so when the site has no categories", %{site: site} do
      {:ok, view, _html} = mount_page(site, "blog-category-list")

      assert text_of(view, ~s([data-role="blog-category-empty"])) == ["No categories yet."]
    end

    test "lists the active categories and links them where the page said", %{site: site} do
      filed!(site, "OTP Patterns", "otp-patterns")

      {:ok, view, _html} =
        mount_page(site, "blog-category-list", %{category_base: "/blog/category"})

      assert text_of(view, ~s([data-role="blog-category-name"])) == ["OTP Patterns"]
      assert hrefs(view, ~s([data-role="blog-category-name"])) == ["/blog/category/otp-patterns"]
    end

    # A DRAFT CATEGORY IS THE AUTHOR'S BUSINESS. `:public_list` is what decides that, and this reads
    # through it rather than filtering afterwards.
    test "and never a draft or archived one", %{site: site} do
      [post] = publish!(site, ["A"])

      for status <- [:draft, :archived] do
        category = category!(site, name: "#{status}", slug: "#{status}", status: status)
        categorize!(post, category)
      end

      {:ok, view, _html} = mount_page(site, "blog-category-list")

      assert text_of(view, ~s([data-role="blog-category-name"])) == []
    end

    test "counts the published posts and nothing else", %{site: site} do
      category = category!(site, name: "OTP", slug: "otp")

      for post <- publish!(site, ["A", "B"]), do: categorize!(post, category)

      drafted = create_blog_post!(site_id: site.id, title: "Draft", status: :draft)
      categorize!(drafted, category)

      {:ok, view, _html} = mount_page(site, "blog-category-list", %{show_count: true})

      assert text_of(view, ~s([data-role="blog-category-count"])) == ["2"]
    end

    test "leaves out the categories holding nothing published", %{site: site} do
      filed!(site, "Full", "full")
      _empty = category!(site, name: "Empty", slug: "empty")

      {:ok, view, _html} = mount_page(site, "blog-category-list")

      assert text_of(view, ~s([data-role="blog-category-name"])) == ["Full"]

      {:ok, showing_all, _html} = mount_page(site, "blog-category-list", %{hide_empty: false})

      assert Enum.sort(text_of(showing_all, ~s([data-role="blog-category-name"]))) ==
               ["Empty", "Full"]
    end

    # THE SIDEBAR THE TODO ASKS FOR: categories, each with what it most recently holds. It is the
    # block that makes a category list something a reader uses rather than a table of contents.
    test "carries each category's own latest posts when the author asks for them", %{site: site} do
      category = category!(site, name: "OTP", slug: "otp")
      [first, second, third] = publish!(site, ["First", "Second", "Third"])

      for post <- [first, second, third], do: categorize!(post, category)

      {:ok, view, _html} =
        mount_page(site, "blog-category-list", %{
          posts_per_category: 2,
          post_base: "/blog/post"
        })

      assert text_of(view, ~s([data-role="blog-category-post"])) == ["Third", "Second"]
      assert hrefs(view, ~s([data-role="blog-category-post"])) |> List.first() =~ "/blog/post/"
    end

    test "and none of them by default", %{site: site} do
      filed!(site, "OTP", "otp")

      {:ok, view, _html} = mount_page(site, "blog-category-list")

      assert text_of(view, ~s([data-role="blog-category-post"])) == []
    end

    # THE ARTICLE THE READER ALREADY HAS OPEN. On a post page this block sits beside it, and the
    # category that article is filed under spent one of its three lines offering it back.
    test "and leaves out the one post the page is already showing", %{site: site} do
      category = category!(site, name: "OTP", slug: "otp")
      [open_one, other] = publish!(site, ["Open", "Another"])

      for post <- [open_one, other], do: categorize!(post, category)

      {:ok, view, _html} =
        mount_page(site, "blog-category-list", %{
          posts_per_category: 5,
          exclude_slug: open_one.slug
        })

      assert text_of(view, ~s([data-role="blog-category-post"])) == ["Another"]
    end

    test "shows one language's categories when the page names one", %{site: site} do
      filed!(site, "OTP", "otp")
      persian = category!(site, name: "الگوها", slug: "olgooha", language: "fa")
      categorize!(persian!(site, "A"), persian)

      {:ok, view, _html} = mount_page(site, "blog-category-list", %{language: "fa"})

      assert text_of(view, ~s([data-role="blog-category-name"])) == [persian.name]
    end

    # A PERSIAN SIDEBAR IS PERSIAN ALL THE WAY DOWN. The titles under a category were read without
    # the language the categories themselves were chosen by, so a Persian menu listed English
    # articles under Persian headings.
    test "and only that language's posts underneath them", %{site: site} do
      persian = category!(site, name: "الگوها", slug: "olgooha", language: "fa")
      categorize!(persian!(site, "به فارسی"), persian)
      [english] = publish!(site, ["In English"])
      categorize!(english, persian)

      {:ok, view, _html} =
        mount_page(site, "blog-category-list", %{language: "fa", posts_per_category: 5})

      assert text_of(view, ~s([data-role="blog-category-post"])) == ["به فارسی"]
    end

    # EMPTY IN THIS LANGUAGE IS EMPTY, and `hide_empty` is on unless an author turns it off: the
    # count it used to hide by is of every post filed under the category, so a Persian reader was
    # offered a category whose only public post is English and whose page opens with nothing on it.
    test "and leaves out a category with nothing published in that language", %{site: site} do
      holding = category!(site, name: "الگوها", slug: "olgooha", language: "fa")
      categorize!(persian!(site, "به فارسی"), holding)

      english_only = category!(site, name: "فونیکس", slug: "phoenix-fa", language: "fa")
      [english] = publish!(site, ["In English"])
      categorize!(english, english_only)

      {:ok, view, _html} = mount_page(site, "blog-category-list", %{language: "fa"})

      assert text_of(view, ~s([data-role="blog-category-name"])) == [holding.name]

      {:ok, showing_all, _html} =
        mount_page(site, "blog-category-list", %{language: "fa", hide_empty: false})

      assert Enum.sort(text_of(showing_all, ~s([data-role="blog-category-name"]))) ==
               Enum.sort([holding.name, english_only.name])
    end

    # ROOTS BY DEFAULT. A flat list of forty categories with their children mixed in among them is
    # not a menu; a parent's children are asked for by naming the parent.
    test "lists the top level, a named parent's children, or everything flat", %{site: site} do
      parent = category!(site, name: "Parent", slug: "parent")
      [one, two] = publish!(site, ["One", "Two"])
      categorize!(one, parent)

      child =
        category!(site, name: "Child", slug: "child", parent_collection_id: parent.id)

      categorize!(two, child)

      {:ok, roots, _html} = mount_page(site, "blog-category-list")
      assert text_of(roots, ~s([data-role="blog-category-name"])) == ["Parent"]

      {:ok, children, _html} = mount_page(site, "blog-category-list", %{parent: "parent"})
      assert text_of(children, ~s([data-role="blog-category-name"])) == ["Child"]

      {:ok, flat, _html} = mount_page(site, "blog-category-list", %{parent: "all"})

      assert Enum.sort(text_of(flat, ~s([data-role="blog-category-name"]))) == ["Child", "Parent"]
    end

    # FAIL SAFE. A parent slug nobody has published is a mistake in the page, and answering it with
    # every category on the site would put a tree in a sidebar sized for five names.
    test "and nothing at all when the named parent is not a category", %{site: site} do
      filed!(site, "Parent", "parent")

      {:ok, view, _html} = mount_page(site, "blog-category-list", %{parent: "no-such-category"})

      assert text_of(view, ~s([data-role="blog-category-name"])) == []
      assert text_of(view, ~s([data-role="blog-category-empty"])) != []
    end

    # AND THE PARENT IS A SLUG LIKE ANY OTHER, read in the language the rest of this menu is read in.
    # A slug is unique per SITE and not per language, so a Persian menu given the English parent's
    # slug answered with whatever happens to hang under the English row.
    test "and takes the named parent in the page's own language", %{site: site} do
      english = category!(site, name: "Parent", slug: "parent")

      child =
        category!(site,
          name: "فرزند",
          slug: "farzand",
          language: "fa",
          parent_collection_id: english.id
        )

      categorize!(persian!(site, "به فارسی"), child)

      {:ok, view, _html} =
        mount_page(site, "blog-category-list", %{parent: "parent", language: "fa"})

      assert text_of(view, ~s([data-role="blog-category-name"])) == []
      assert text_of(view, ~s([data-role="blog-category-empty"])) != []
    end

    test "marks the category the reader is already reading", %{site: site} do
      filed!(site, "OTP", "otp")
      filed!(site, "Ecto", "ecto")

      {:ok, view, _html} =
        mount_page(site, "blog-category-list", %{params: %{"slug" => "otp"}})

      marked =
        view
        |> render_async(@async)
        |> LazyHTML.from_fragment()
        |> LazyHTML.query(~s([data-role="blog-category"][data-selected="true"]))
        |> Enum.map(&(&1 |> LazyHTML.attribute("id")))
        |> List.flatten()

      assert length(marked) == 1
    end
  end

  # ONE ARTICLE IN FULL, which is more than a title and a body: who wrote it, what it is filed
  # under, what it is tagged, and which other languages it exists in.
  describe "blog-post-detail in full" do
    test "draws the post's tags and categories as links under the bases it was given", %{
      site: site
    } do
      [post] = publish!(site, ["Ours"])
      categorize!(post, category!(site, name: "OTP", slug: "otp"))
      tag_post!(post, tag!(site, name: "Elixir", slug: "elixir"))

      {:ok, view, _html} =
        mount_page(site, "blog-post-detail", %{
          slug: post.slug,
          tag_base: "/blog/tag",
          category_base: "/blog/category"
        })

      assert text_of(view, ~s([data-role="blog-detail-tag"])) == ["Elixir"]
      assert hrefs(view, ~s([data-role="blog-detail-tag"])) == ["/blog/tag/elixir"]
      assert text_of(view, ~s([data-role="blog-detail-category"])) == ["OTP"]
      assert hrefs(view, ~s([data-role="blog-detail-category"])) == ["/blog/category/otp"]
    end

    test "and names the bloggers credited with it", %{site: site} do
      [post] = publish!(site, ["Ours"])
      blogger = create_blogger!(site_id: site.id, display_name: "Ada Lovelace")
      create_post_blogger!(post_id: post.id, blogger_id: blogger.id)

      {:ok, view, _html} = mount_page(site, "blog-post-detail", %{slug: post.slug})

      assert text_of(view, ~s([data-role="blog-detail-author"])) == ["Ada Lovelace"]
    end

    # ONLY THE TRANSLATIONS A READER CAN OPEN. `language_variants` is every row sharing the group,
    # drafts included, so a link per variant would have published the unfinished ones.
    test "lists the published translations and not the unfinished ones", %{site: site} do
      [master] = publish!(site, ["Master"])
      translate!(site, master, "fa", "Tarjome")
      translate!(site, master, "ru", "Perevod", :draft)

      {:ok, view, _html} =
        mount_page(site, "blog-post-detail", %{slug: master.slug, post_base: "/mish-blog/post"})

      assert text_of(view, ~s([data-role="blog-detail-translation"])) == ["fa"]
    end

    # A PERSIAN POST READ LEFT TO RIGHT is not a styling detail — punctuation lands on the wrong
    # side of every sentence in it.
    test "reads right to left when the post is written that way", %{site: site} do
      persian =
        create_blog_post!(
          site_id: site.id,
          title: "نوشته",
          status: :published,
          language: "fa",
          published_at: ~U[2026-01-01 00:00:00Z]
        )

      {:ok, view, _html} = mount_page(site, "blog-post-detail", %{slug: persian.slug})

      assert has_element?(
               view,
               ~s(article[data-role="blog-detail-article"][dir="rtl"][lang="fa"])
             )

      [english] = publish!(site, ["English"])
      {:ok, ltr, _html} = mount_page(site, "blog-post-detail", %{slug: english.slug})

      assert has_element?(ltr, ~s(article[data-role="blog-detail-article"][dir="auto"]))
    end

    # A PART THE PAGE TURNED OFF COSTS NOTHING. The four extra reads ran whatever the switches said
    # and only the markup consulted them, and `update/2` runs again on every re-render of the page
    # around it — so a page drawing the body alone paid five queries for one, every single time.
    test "and reads nothing for the parts the page turned off", %{site: site} do
      [post] = publish!(site, ["Ours"])
      tag_post!(post, tag!(site, name: "Elixir", slug: "elixir"))
      categorize!(post, category!(site, name: "OTP", slug: "otp"))

      off =
        queries_while(fn ->
          {:ok, view, _html} =
            mount_page(site, "blog-post-detail", %{
              slug: post.slug,
              show_tags: false,
              show_categories: false,
              show_authors: false,
              show_translations: false
            })

          render(view)
        end)

      # The post itself is read for its visitor, which reads the categories' locks whatever the page
      # draws, so a part is told by what it would draw: a category's name.
      for {table, drawn} <- [
            {"mishka_blog_tags", ""},
            {"mishka_blog_collections", ~s("name")},
            {"mishka_blog_bloggers", ""}
          ] do
        refute Enum.any?(off, &(String.contains?(&1, table) and String.contains?(&1, drawn))),
               "#{table} was read for a part the page does not draw"
      end

      on =
        queries_while(fn ->
          {:ok, view, _html} = mount_page(site, "blog-post-detail", %{slug: post.slug})
          render(view)
        end)

      assert Enum.any?(on, &String.contains?(&1, "mishka_blog_tags")),
             "the switches being on has to be the difference, or this asserts nothing"
    end

    # WHOLE DAYS, NOT INSTANTS. A row's `updated_at` is later than its `published_at` by the width
    # of the write that published it, so comparing the timestamps marked every article as edited
    # the moment it appeared — which is the opposite of what the line is for.
    test "says it was edited when the row was last written after the day it claims", %{site: site} do
      same_day =
        create_blog_post!(
          site_id: site.id,
          title: "Fresh",
          status: :published,
          published_at: DateTime.utc_now()
        )

      {:ok, fresh, _html} = mount_page(site, "blog-post-detail", %{slug: same_day.slug})

      assert text_of(fresh, ~s([data-role="blog-detail-updated"])) == [],
             "an article published today was marked edited by the write that published it"

      [backdated] = publish!(site, ["Older"])

      {:ok, edited, _html} = mount_page(site, "blog-post-detail", %{slug: backdated.slug})

      assert text_of(edited, ~s([data-role="blog-detail-updated"])) != []
    end

    # THE BODY A READER SEES IS THE ONE THE SITE'S PLUGINS PRODUCED. `rendered_content` is the
    # `blog:blog_post:render_content` seam — shortcodes, embeds, a table of contents — and the
    # public view read the raw `content` instead, so every such plugin was dead on the one page it
    # exists for. The sanitizer still runs, and it runs AFTER the plugin.
    test "renders the body a render_content plugin produced", %{site: site} do
      with_plugin(
        MishkaBlog.Test.Plugins.BlogPostRenderContent,
        "blog:blog_post:render_content",
        fn ->
          [post] = publish!(site, ["Ours"])

          {:ok, view, _html} = mount_page(site, "blog-post-detail", %{slug: post.slug})

          assert view
                 |> text_of(~s([data-role="blog-detail-body"]))
                 |> List.first() =~ "[rendered by plugin]"
        end
      )
    end
  end

  # A SLUG BELONGS TO ONE EDITION, and a page in one language answers for that edition alone.
  describe "blog-post-detail in one language" do
    # Without this the English article also answers at /fa/blog/<its slug> — the same piece writing
    # itself out inside a Persian page, right to left, with a Persian sidebar beside it, and nothing
    # anywhere saying the URL was wrong.
    test "does not serve a post written in another one", %{site: site} do
      [english] = publish!(site, ["English post"])

      {:ok, asked_in_persian, _html} =
        mount_page(site, "blog-post-detail", %{slug: english.slug, language: "fa"})

      assert has_element?(asked_in_persian, ~s([data-role="blog-detail-missing"]))

      {:ok, asked_in_english, _html} =
        mount_page(site, "blog-post-detail", %{slug: english.slug, language: "en"})

      assert text_of(asked_in_english, ~s([data-role="blog-detail-title"])) == ["English post"]
    end

    # A page that does not address languages at all still has to open every post it is given.
    test "and takes the post by slug alone when the page names no language", %{site: site} do
      persian = persian!(site, "نوشته")

      {:ok, view, _html} = mount_page(site, "blog-post-detail", %{slug: persian.slug})

      assert text_of(view, ~s([data-role="blog-detail-title"])) == ["نوشته"]
    end

    # THE ONE LINK THAT LEAVES THE PAGE'S OWN LANGUAGE. A base with the language written into it
    # gets everything else right and this wrong: the Persian edition offered as /en/blog/<fa slug>,
    # a path under English carrying hreflang="fa", answered by the English page, which does not have
    # that post. Written as /:lang/blog, each link is filled with the language of the row it leads
    # to.
    #
    # The site has to PUBLISH Persian for that link to lead anywhere: `:lang` only answers
    # `site.languages`, so the link is offered on a site that lists `fa` and drawn as a word on one
    # that does not — see the test below.
    test "offers each translation under the path of its own language", %{site: site} do
      {:ok, _} = MishkaCmsCore.Settings.put("site.languages", ["en", "fa"], site_id: site.id)
      [master] = publish!(site, ["Master"])
      persian = translate!(site, master, "fa", "Tarjome")

      {:ok, view, _html} =
        mount_page(site, "blog-post-detail", %{
          slug: master.slug,
          language: "en",
          post_base: "/:lang/blog"
        })

      assert hrefs(view, ~s([data-role="blog-detail-translation"])) == [
               "/fa/blog/#{persian.slug}"
             ]
    end

    test "and draws a translation the site does not publish as a word, not a link", %{site: site} do
      {:ok, _} = MishkaCmsCore.Settings.put("site.languages", ["en"], site_id: site.id)
      [master] = publish!(site, ["Master"])
      persian = translate!(site, master, "fa", "Tarjome")

      {:ok, view, _html} =
        mount_page(site, "blog-post-detail", %{
          slug: master.slug,
          language: "en",
          post_base: "/:lang/blog"
        })

      assert hrefs(view, ~s([data-role="blog-detail-translation"])) == []
      assert text_of(view, ~s([data-role="blog-detail-translation"])) == ["fa"]
      refute render(view) =~ persian.slug
    end

    test "and fills the same capture on a tag and a category from the row it links to", %{
      site: site
    } do
      {:ok, _} = MishkaCmsCore.Settings.put("site.languages", ["en", "fa"], site_id: site.id)
      persian = persian!(site, "نوشته")
      tag_post!(persian, tag!(site, name: "اکسیر", slug: "eksir", language: "fa"))
      categorize!(persian, category!(site, name: "الگوها", slug: "olgooha", language: "fa"))

      {:ok, view, _html} =
        mount_page(site, "blog-post-detail", %{
          slug: persian.slug,
          language: "fa",
          tag_base: "/:lang/blog/tag",
          category_base: "/:lang/blog/category"
        })

      assert hrefs(view, ~s([data-role="blog-detail-tag"])) == ["/fa/blog/tag/eksir"]
      assert hrefs(view, ~s([data-role="blog-detail-category"])) == ["/fa/blog/category/olgooha"]
    end

    # AN EDITION OPENED BESIDE THIS ONE IS A PATCH, AND THAT IS NOT COSMETIC. `patch` keeps the page
    # holding this block mounted — its list, its sidebar and everything each of them has read stay
    # where they are — while `navigate` throws all of it away and mounts the page again. Both write
    # the same `href`, so nothing but this attribute can tell them apart, which is exactly how the
    # distinction was lost when the row became a component.
    test "opens an edition beside this one with a patch, and its own page with a navigation", %{
      site: site
    } do
      [master] = publish!(site, ["Master"])
      translate!(site, master, "fa", "Tarjome")

      {:ok, beside, _html} =
        mount_page(site, "blog-post-detail", %{slug: master.slug, base: "/en/blog"})

      assert attrs_of(beside, ~s([data-role="blog-detail-translation"]), "data-phx-link") ==
               ["patch"]

      {:ok, its_own_page, _html} =
        mount_page(site, "blog-post-detail", %{slug: master.slug, post_base: "/en/blog"})

      assert attrs_of(its_own_page, ~s([data-role="blog-detail-translation"]), "data-phx-link") ==
               ["redirect"]
    end

    # AND EACH ROW STILL ANSWERS TO ITS OWN NAME. The three rows under an article are one component
    # drawn three times now, and a component that named only its words left nothing for a stylesheet
    # or a test to address the row by — while the categories row, which sits directly under the
    # body, also lost the wider gap that separated it from the text.
    test "names each row under the article, and spaces the first of them", %{site: site} do
      [post] = publish!(site, ["Ours"])
      tag_post!(post, tag!(site, name: "Elixir", slug: "elixir"))
      categorize!(post, category!(site, name: "OTP", slug: "otp"))
      translate!(site, post, "fa", "Tarjome")

      {:ok, view, _html} =
        mount_page(site, "blog-post-detail", %{slug: post.slug, post_base: "/en/blog"})

      for role <- ~w(blog-detail-categories blog-detail-tags blog-detail-translations) do
        assert has_element?(view, ~s([data-role="#{role}"])), "#{role} was not drawn"
      end

      assert [categories] = attrs_of(view, ~s([data-role="blog-detail-categories"]), "class")
      assert [tags] = attrs_of(view, ~s([data-role="blog-detail-tags"]), "class")

      assert categories =~ "mt-6", "the row under the article lost the gap above it"
      assert tags =~ "mt-3"
    end
  end

  # THE TWO SHAPES OF AN EMPTY STATE, WHICH `blog-notice` HAS TO KEEP APART. A dashed box is right
  # where the rows would have been and wrong beside an article: the idle line under a post, the tag
  # cloud's and the conversation's were all plain words, and routing them through the notice turned
  # all three into boxes. Asserted on the class the notice chose, because that IS the difference —
  # its twin `doc-notice` keeps the same two and is answered by the same `quiet`.
  describe "the notice a block draws in place of its rows" do
    test "draws a line where the block asked for one and a box where it did not", %{site: site} do
      [post] = publish!(site, ["Ours"])

      quiet = [
        {"blog-post-detail", %{}, "blog-detail-idle"},
        {"blog-tag-cloud", %{}, "blog-tag-empty"},
        {"blog-post-comments", %{slug: post.slug}, "blog-comments-empty"}
      ]

      boxed = [
        {"blog-post-list", %{exclude_slug: post.slug}, "blog-list-empty"},
        {"blog-category-list", %{}, "blog-category-empty"},
        {"blog-post-detail", %{slug: "nothing-like-this"}, "blog-detail-missing"}
      ]

      for {name, attrs, role} <- quiet do
        {:ok, view, _html} = mount_page(site, name, attrs)

        assert [class] = attrs_of(view, ~s([data-role="#{role}"]), "class"),
               "#{role} is not drawn"

        refute class =~ "border-dashed", "#{role} was drawn as a box where it was words"
      end

      for {name, attrs, role} <- boxed do
        {:ok, view, _html} = mount_page(site, name, attrs)

        assert [class] = attrs_of(view, ~s([data-role="#{role}"]), "class"),
               "#{role} is not drawn"

        assert class =~ "border-dashed", "#{role} was drawn as words where it was a box"
      end
    end
  end

  # THE LANGUAGE IN A LINK IS THE LANGUAGE OF THE ROW IT LEADS TO. A listing that is not narrowed to
  # one language holds rows of several, and one prefix over all of them sends half of them to a URL
  # their own edition's page will not answer. Each link is the address the site's URL mode gives its
  # language: English, the first, unprefixed while the site leaves it so.
  describe "a base written with the lang capture" do
    for mode <- ~w(prefix_others prefix_all) do
      test "sends each post to its own language, in #{mode}", %{site: site} do
        publishes_persian!(site, unquote(mode))
        [english] = publish!(site, ["English"])
        persian = persian!(site, "نوشته")

        {:ok, view, _html} =
          mount_page(site, "blog-post-list", %{
            per_page: 10,
            language: "all",
            post_base: "/:lang/blog"
          })

        assert Enum.sort(hrefs(view, ~s([data-role="blog-list-title"]))) ==
                 Enum.sort([
                   english(unquote(mode), "/blog/#{english.slug}"),
                   "/fa/blog/#{persian.slug}"
                 ])
      end

      test "and each tag and category to theirs, in #{mode}", %{site: site} do
        publishes_persian!(site, unquote(mode))
        tagged!(site, "Elixir", "elixir")
        persian_tag = tag!(site, name: "اکسیر", slug: "eksir", language: "fa")
        tag_post!(persian!(site, "نوشته"), persian_tag)

        {:ok, tags, _html} =
          mount_page(site, "blog-tag-cloud", %{language: "all", tag_base: "/:lang/blog/tag"})

        assert Enum.sort(hrefs(tags, ~s([data-role="blog-tag"]))) ==
                 Enum.sort([english(unquote(mode), "/blog/tag/elixir"), "/fa/blog/tag/eksir"])

        filed!(site, "OTP", "otp")
        persian_category = category!(site, name: "الگوها", slug: "olgooha", language: "fa")
        categorize!(persian!(site, "دیگر"), persian_category)

        {:ok, categories, _html} =
          mount_page(site, "blog-category-list", %{
            language: "all",
            category_base: "/:lang/blog/category"
          })

        assert Enum.sort(hrefs(categories, ~s([data-role="blog-category-name"]))) ==
                 Enum.sort([
                   english(unquote(mode), "/blog/category/otp"),
                   "/fa/blog/category/olgooha"
                 ])
      end

      # A BASE WRITTEN UNDER THE FIRST LANGUAGE is the same address as the one with the capture:
      # `/en/blog` is `/blog` while English goes unprefixed, and a link to the form the site
      # redirects away from would cost every reader a hop.
      test "and a base written under the first language is that language's address, in #{mode}",
           %{site: site} do
        publishes_persian!(site, unquote(mode))
        tagged!(site, "Elixir", "elixir")

        {:ok, view, _html} = mount_page(site, "blog-tag-cloud", %{tag_base: "/en/blog/tag"})

        assert hrefs(view, ~s([data-role="blog-tag"])) == [
                 english(unquote(mode), "/blog/tag/elixir")
               ]
      end
    end

    # AND SO IS EVERY OTHER ROW WITH NO ADDRESS, NEVER A LINK TO NOTHING. `<.link navigate={nil}>`
    # draws `href="#"` — a link that scrolls the reader to the top of the page they are on. A title,
    # a tag, a category and a post under one are drawn as the word they name instead; a control
    # that only leads somewhere — a card's read link, the permalink — is not drawn at all.
    test "draws every row with no address as a word, and no link to nothing", %{site: site} do
      {:ok, _} = MishkaCmsCore.Settings.put("site.languages", ["en"], site_id: site.id)
      persian = persian!(site, "نوشته")
      tag_post!(persian, tag!(site, name: "اکسیر", slug: "eksir", language: "fa"))
      categorize!(persian, category!(site, name: "الگوها", slug: "olgooha", language: "fa"))
      listed = %{per_page: 10, language: "all", post_base: "/:lang/blog"}

      for {name, given, roles} <- [
            {"blog-post-list", listed, ["blog-list-title"]},
            {"blog-post-list", Map.put(listed, :variant, "compact"), ["blog-list-title"]},
            {"blog-tag-cloud", %{language: "all", tag_base: "/:lang/blog/tag"}, ["blog-tag"]},
            {"blog-category-list",
             %{
               language: "all",
               category_base: "/:lang/blog/category",
               post_base: "/:lang/blog",
               posts_per_category: 1
             }, ["blog-category-name", "blog-category-post"]},
            {"blog-post-detail", %{slug: persian.slug, base: "/blog", post_base: "/:lang/blog"},
             ["blog-detail-title"]}
          ] do
        {:ok, view, _html} = mount_page(site, name, given)

        for role <- roles do
          assert text_of(view, ~s([data-role="#{role}"])) != [], "#{name} drew no #{role}"

          assert hrefs(view, ~s([data-role="#{role}"])) == [],
                 "#{name} linked a #{role} to nothing"
        end

        assert attrs_of(view, "a", "href") |> Enum.filter(&(&1 == "#")) == [],
               "#{name} drew a link to nothing"

        assert text_of(view, "a:not([href])") == [], "#{name} drew a link with no address"
        assert text_of(view, ~s([data-role="blog-list-read"])) == []
        assert text_of(view, ~s([data-role="blog-detail-permalink"])) == []
      end

      {:ok, search, _html} = mount_page(site, "blog-post-search", %{post_base: "/:lang/blog"})
      search |> form(~s(#one form), %{"q" => "نوشته"}) |> render_change()

      assert text_of(search, ~s([data-role="blog-search-result"])) == ["نوشته"]
      assert text_of(search, ~s([data-role="blog-search-result"] a)) == []
    end

    # A ROW IN A LANGUAGE THE SITE DOES NOT PUBLISH HAS NO ADDRESS — the `:lang` capture answers
    # `site.languages` alone — so it is drawn as a word rather than linked to a 404.
    test "and draws a row in a language the site does not publish as a word", %{site: site} do
      {:ok, _} = MishkaCmsCore.Settings.put("site.languages", ["en"], site_id: site.id)
      persian = persian!(site, "نوشته")
      tag_post!(persian, tag!(site, name: "اکسیر", slug: "eksir", language: "fa"))

      {:ok, view, _html} =
        mount_page(site, "blog-post-detail", %{
          slug: persian.slug,
          language: "fa",
          tag_base: "/:lang/blog/tag"
        })

      assert text_of(view, ~s([data-role="blog-detail-tag"])) == ["اکسیر"]
      assert hrefs(view, ~s([data-role="blog-detail-tag"])) == []
    end
  end

  describe "blog-post-comments" do
    test "shows the approved conversation and none of the rest", %{site: site} do
      [post] = publish!(site, ["Ours"])

      comment!(site, post, content: "Approved")
      comment!(site, post, content: "Waiting", status: :pending)
      comment!(site, post, content: "Junk", status: :spam)

      {:ok, view, _html} = mount_page(site, "blog-post-comments", %{slug: post.slug})

      assert text_of(view, ~s([data-role="blog-comment-body"])) == ["Approved"]
    end

    # A REPLY HAS NO READ ACTION OF ITS OWN, so `has_many :replies` hands back the pending and the
    # spam with the rest. Moderation that holds at the top level and not one level down is not
    # moderation.
    test "including under a reply, where the relationship itself filters nothing", %{site: site} do
      [post] = publish!(site, ["Ours"])
      parent = comment!(site, post, content: "Approved")

      comment!(site, post, content: "Approved reply", parent_comment_id: parent.id)
      comment!(site, post, content: "Spam reply", parent_comment_id: parent.id, status: :spam)

      {:ok, view, _html} = mount_page(site, "blog-post-comments", %{slug: post.slug})

      assert text_of(view, ~s([data-role="blog-comment-replies"] [data-role="blog-comment-body"])) ==
               ["Approved reply"]
    end

    # PLAIN TEXT, WHATEVER IS STORED. A comment written before tags were stripped on save, or one a
    # render_content plugin reshaped, may still hold markup: it is drawn as the characters it is.
    test "draws a comment's markup as text, never as HTML", %{site: site} do
      [post] = publish!(site, ["Ours"])
      markup = ~s(<b>bold</b> <a href="https://evil.example">link</a>)

      Ash.Seed.seed!(MishkaBlog.Comment, %{
        site_id: site.id,
        post_id: post.id,
        status: :approved,
        content: markup
      })

      {:ok, view, _html} = mount_page(site, "blog-post-comments", %{slug: post.slug})

      assert text_of(view, ~s([data-role="blog-comment-body"])) == [markup]

      assert text_of(
               view,
               ~s([data-role="blog-comment-body"] b, [data-role="blog-comment-body"] a)
             ) == []
    end

    # THE BOX TO WRITE IN COMES FIRST, under the heading, and the conversation follows it, so a
    # long thread never pushes it out of reach.
    test "puts the box to write in above the conversation", %{site: site} do
      [post] = publish!(site, ["Ours"])
      comment!(site, post, content: "First")

      {:ok, view, _html} =
        mount_page(site, "blog-post-comments", %{slug: post.slug, current_user: create_user!()})

      html = render(view)
      {form_at, _} = :binary.match(html, ~s(data-role="blog-comments-form"))
      {list_at, _} = :binary.match(html, ~s(data-role="blog-comments-list"))

      assert form_at < list_at
    end

    # `whitespace-pre-line` KEEPS EVERY LINE BREAK, the template's own too: text on a line of its own
    # drew a blank line above and below every comment.
    test "draws a comment's text with no blank line around it", %{site: site} do
      [post] = publish!(site, ["Ours"])
      comment!(site, post, content: "Just this")

      {:ok, view, _html} = mount_page(site, "blog-post-comments", %{slug: post.slug})

      assert view
             |> render()
             |> LazyHTML.from_fragment()
             |> LazyHTML.query(~s([data-role="blog-comment-body"]))
             |> Enum.map(&LazyHTML.text/1) == ["Just this"]
    end

    test "puts the pinned ones first", %{site: site} do
      [post] = publish!(site, ["Ours"])

      comment!(site, post, content: "Ordinary")
      comment!(site, post, content: "Pinned", is_pinned: true)

      {:ok, view, _html} = mount_page(site, "blog-post-comments", %{slug: post.slug})

      assert text_of(view, ~s([data-role="blog-comment-body"])) == ["Pinned", "Ordinary"]
    end

    # NEVER AN EMAIL ADDRESS. A `User` carries one and a display name is not among its fields, so
    # the name is the blogger profile this site knows the commenter by, and everyone else is the
    # same anonymous word.
    test "names a commenter by their blogger profile, and everybody else the same way", %{
      site: site
    } do
      [post] = publish!(site, ["Ours"])
      known = create_user!()
      create_blogger!(site_id: site.id, user_id: known.id, display_name: "Ada Lovelace")
      stranger = create_user!()

      comment!(site, post, content: "From Ada", author_id: known.id)
      comment!(site, post, content: "From a stranger", author_id: stranger.id)
      comment!(site, post, content: "From nobody")

      {:ok, view, _html} = mount_page(site, "blog-post-comments", %{slug: post.slug})

      names = text_of(view, ~s([data-role="blog-comment-author"]))

      assert "Ada Lovelace" in names
      assert Enum.count(names, &(&1 == "Reader")) == 2
      refute Enum.any?(names, &String.contains?(&1, "@"))
    end

    test "offers a signed-out reader a way in, and no box to type in", %{site: site} do
      [post] = publish!(site, ["Ours"])

      {:ok, view, _html} = mount_page(site, "blog-post-comments", %{slug: post.slug})

      refute has_element?(view, ~s([data-role="blog-comments-form"]))
      assert has_element?(view, ~s([data-role="blog-comments-login"]))
    end

    # THE SIGN-IN PAGE IS KEPT OUT OF AN INDEX, so a crawler is not sent there from every post.
    test "and the way in is a link a crawler does not follow", %{site: site} do
      [post] = publish!(site, ["Ours"])

      {:ok, view, _html} = mount_page(site, "blog-post-comments", %{slug: post.slug})

      assert has_element?(view, ~s([data-role="blog-comments-login"] a[rel="nofollow"]))
    end

    # THE WAY IN IS THE SIGN-IN PAGE IN THE POST'S LANGUAGE, at the address the site's URL mode
    # gives it: English, the first, unprefixed while the site leaves it so.
    for mode <- ~w(prefix_others prefix_all) do
      test "and sends them to the sign-in page in the post's language, in #{mode}", %{site: site} do
        publishes_persian!(site, unquote(mode))
        [english] = publish!(site, ["Ours"])
        persian = persian!(site, "نوشته")

        for {post, address} <- [
              {english, english(unquote(mode), "/auth")},
              {persian, "/fa/auth"}
            ] do
          {:ok, view, _html} = mount_page(site, "blog-post-comments", %{slug: post.slug})

          assert hrefs(view, ~s([data-role="blog-comments-login"] a)) == [address]
        end
      end
    end

    test "and a signed-in one a box, whose comment arrives waiting for a moderator", %{site: site} do
      [post] = publish!(site, ["Ours"])
      user = create_user!()

      {:ok, view, _html} =
        mount_page(site, "blog-post-comments", %{slug: post.slug, current_user: user})

      assert has_element?(view, ~s([data-role="blog-comments-form"]))

      view |> form(~s(#one form), %{"content" => "Well put."}) |> render_submit()

      assert has_element?(view, ~s([data-role="blog-comments-pending"]))

      written =
        MishkaBlog.Comment
        |> Ash.Query.for_read(:read, %{}, authorize?: false)
        |> Ash.Query.filter(content == "Well put.")
        |> Ash.read!(tenant: site.id)

      assert [%{status: :pending, author_id: author_id, site_id: site_id}] = written
      assert author_id == user.id
      assert site_id == site.id

      refute text_of(view, ~s([data-role="blog-comment-body"])) == ["Well put."],
             "a comment nobody has approved was published"
    end

    # NOTHING TO SAY ABOUT A POST THAT IS NOT THERE. The detail component sitting above this one on
    # the same page already tells the reader the post is gone; this one went on to say there were no
    # comments yet and to invite them to sign in and add one.
    test "and says nothing at all when the URL names no post anybody can read", %{site: site} do
      {:ok, view, _html} = mount_page(site, "blog-post-comments", %{slug: "no-such-post"})

      refute has_element?(view, ~s([data-role="blog-comments-empty"]))
      refute has_element?(view, ~s([data-role="blog-comments-login"]))

      [post] = publish!(site, ["Ours"])
      {:ok, real, _html} = mount_page(site, "blog-post-comments", %{slug: post.slug})

      assert has_element?(real, ~s([data-role="blog-comments-empty"])),
             "a post with no comments still has that much to say"

      assert has_element?(real, ~s([data-role="blog-comments-login"]))
    end

    test "lengthens the conversation rather than paging it", %{site: site} do
      [post] = publish!(site, ["Ours"])

      for n <- 1..3, do: comment!(site, post, content: "Number #{n}")

      {:ok, view, _html} =
        mount_page(site, "blog-post-comments", %{slug: post.slug, per_page: 2})

      assert length(text_of(view, ~s([data-role="blog-comment-body"]))) == 2
      assert has_element?(view, ~s([data-role="blog-comments-more"]))

      view |> element(~s(#one [data-role="blog-comments-more"])) |> render_click()

      assert length(text_of(view, ~s([data-role="blog-comment-body"]))) == 3
      refute has_element?(view, ~s([data-role="blog-comments-more"]))
    end

    # PAST THE READ'S OWN PAGE SIZE. `:approved_by_post` hands back a hundred rows at a time and Ash
    # shrinks a bigger ask down to that cap instead of refusing it, so asking for the whole
    # conversation at once stopped dead at a hundred — with the button to lengthen it still on the
    # page, because the total said there was more, and four comments nobody could ever reach.
    test "and reaches the comments past the read's own page size", %{site: site} do
      [post] = publish!(site, ["Ours"])

      for number <- 1..105, do: comment!(site, post, content: "Number #{number}")

      {:ok, view, _html} =
        mount_page(site, "blog-post-comments", %{slug: post.slug, per_page: 50})

      assert length(text_of(view, ~s([data-role="blog-comment-body"]))) == 50

      view |> element(~s(#one [data-role="blog-comments-more"])) |> render_click()
      assert length(text_of(view, ~s([data-role="blog-comment-body"]))) == 100

      view |> element(~s(#one [data-role="blog-comments-more"])) |> render_click()
      assert length(text_of(view, ~s([data-role="blog-comment-body"]))) == 105
      refute has_element?(view, ~s([data-role="blog-comments-more"]))
    end

    # A NOTICE BELONGS TO THE ACTION THAT RAISED IT. Nothing ever cleared it, so a reader who posted
    # once was told their comment was waiting for a moderator above everything they did afterwards.
    test "and the thank-you does not follow the reader around the page", %{site: site} do
      [post] = publish!(site, ["Ours"])
      user = create_user!()

      for number <- 1..3, do: comment!(site, post, content: "Number #{number}")

      {:ok, view, _html} =
        mount_page(site, "blog-post-comments", %{
          slug: post.slug,
          current_user: user,
          per_page: 2
        })

      view |> form(~s(#one form), %{"content" => "Well put."}) |> render_submit()
      assert has_element?(view, ~s([data-role="blog-comments-pending"]))

      view |> element(~s(#one [data-role="blog-comments-more"])) |> render_click()
      refute has_element?(view, ~s([data-role="blog-comments-pending"]))
    end

    test "reads the post out of the params the page handed it", %{site: site} do
      [post] = publish!(site, ["Ours"])
      comment!(site, post, content: "Approved")

      {:ok, view, _html} =
        mount_page(site, "blog-post-comments", %{params: %{"slug" => post.slug}})

      assert text_of(view, ~s([data-role="blog-comment-body"])) == ["Approved"]
    end

    test "reads only its own site's comments", %{site: site} do
      other = create_site!(name: "elsewhere#{System.unique_integer([:positive])}")
      [theirs] = publish!(other, ["Theirs"])
      comment!(other, theirs, content: "Theirs")

      {:ok, view, _html} = mount_page(site, "blog-post-comments", %{slug: theirs.slug})

      assert text_of(view, ~s([data-role="blog-comment-body"])) == []
    end

    # THE SAME RULE THE ARTICLE ABOVE IT FOLLOWS. These two sit on one page, `/:lang/blog/:slug`,
    # and the detail block serves the edition the URL's language names — so at /fa/blog/<english
    # slug> it says the post is not there while this one, resolving the slug alone, went on to
    # publish that article's conversation underneath it and to offer a signed-in Persian reader a
    # box that writes onto the English post.
    test "does not open the conversation of an edition in another language", %{site: site} do
      [english] = publish!(site, ["English post"])
      comment!(site, english, content: "Well put.")
      user = create_user!()

      {:ok, asked_in_persian, _html} =
        mount_page(site, "blog-post-comments", %{
          slug: english.slug,
          language: "fa",
          current_user: user
        })

      assert text_of(asked_in_persian, ~s([data-role="blog-comment-body"])) == []
      refute has_element?(asked_in_persian, ~s([data-role="blog-comments-form"]))

      {:ok, asked_in_english, _html} =
        mount_page(site, "blog-post-comments", %{
          slug: english.slug,
          language: "en",
          current_user: user
        })

      assert text_of(asked_in_english, ~s([data-role="blog-comment-body"])) == ["Well put."]
    end

    # A page that does not address languages at all still has to open every post it is given.
    test "and takes the post by slug alone when the page names no language", %{site: site} do
      persian = persian!(site, "نوشته")
      comment!(site, persian, content: "خوب بود")

      {:ok, view, _html} = mount_page(site, "blog-post-comments", %{slug: persian.slug})

      assert text_of(view, ~s([data-role="blog-comment-body"])) == ["خوب بود"]
    end

    # AN EMPTY CARD RATHER THAN A LABELLED ONE. Every other block here is drawn only where there is
    # a post to draw it for, and the heading was not — so a URL naming a post that is not in this
    # language left the word "Comments" alone inside the page's card, under a detail block saying
    # that post is not here.
    test "does not head a conversation that is not there", %{site: site} do
      [english] = publish!(site, ["English post"])

      {:ok, asked_in_persian, _html} =
        mount_page(site, "blog-post-comments", %{
          slug: english.slug,
          language: "fa",
          heading: "Comments"
        })

      assert text_of(asked_in_persian, ~s([data-role="blog-comments-heading"])) == []

      {:ok, asked_in_english, _html} =
        mount_page(site, "blog-post-comments", %{
          slug: english.slug,
          language: "en",
          heading: "Comments"
        })

      assert text_of(asked_in_english, ~s([data-role="blog-comments-heading"])) == ["Comments"]
    end
  end

  # A BLOGGER'S PAGE: who they are, the teams a reader can open, and the posts they are credited with
  # that the reader may open — each a read of the public action, as the visitor the page hands down.
  describe "blog-author-profile" do
    setup %{site: site} do
      writer =
        blogger!(site,
          display_name: "Mona Writer",
          slug: "mona",
          bio: "Writes about <strong>OTP</strong>.",
          social_links: [
            %{platform: "GitHub", url: "https://github.com/mona"},
            %{platform: "Trap", url: "javascript:alert(1)"}
          ]
        )

      core = team!(site, name: "Core", slug: "core")
      member!(core, writer)
      member!(team!(site, name: "Hidden", slug: "hidden", status: :draft), writer)

      [older, newer] = publish!(site, ["Older post", "Newer post"])
      credit!(older, writer)
      credit!(newer, writer)
      credit!(create_blog_post!(site_id: site.id, title: "A draft", status: :draft), writer)
      publish!(site, ["Somebody else's"])

      %{writer: writer, core: core}
    end

    test "draws the blogger the slug names, their teams and their published posts", %{site: site} do
      {:ok, view, _html} =
        mount_page(site, "blog-author-profile", %{
          slug: "mona",
          team_base: "/:lang/blog/team",
          post_base: "/:lang/blog"
        })

      assert text_of(view, ~s([data-role="blog-author-name"])) == ["Mona Writer"]
      assert text_of(view, ~s([data-role="blog-author-handle"])) == ["@mona"]
      assert has_element?(view, ~s([data-role="blog-author-bio"] strong), "OTP")

      assert text_of(view, ~s([data-role="blog-author-team"] [data-role="blog-profile-name"])) ==
               ["Core"]

      assert hrefs(view, ~s([data-role="blog-author-team"] a)) == ["/blog/team/core"]

      assert titles(view) == ["Newer post", "Older post"]
      assert has_element?(view, ~s([data-role="blog-author-pager"])) == false
    end

    # A LINK ON A PROFILE IS AN ADDRESS SOMEBODY TYPED. Only one a browser should follow is put in
    # an `href`; the rest is drawn as the words it was saved as.
    test "links only the addresses a browser should follow", %{site: site} do
      {:ok, view, _html} = mount_page(site, "blog-author-profile", %{slug: "mona"})

      assert text_of(view, ~s([data-role="blog-author-link"])) == ["GitHub", "Trap"]
      assert hrefs(view, ~s([data-role="blog-author-link"])) == ["https://github.com/mona"]
      refute render(view) =~ "javascript:"
    end

    test "draws a team as a word, not a link, where the page gave it no base", %{site: site} do
      {:ok, view, _html} = mount_page(site, "blog-author-profile", %{slug: "mona"})

      assert text_of(view, ~s([data-role="blog-author-team"] [data-role="blog-profile-name"])) ==
               ["Core"]

      assert hrefs(view, ~s([data-role="blog-author-team"] a)) == []
    end

    test "says nothing is chosen, and that nobody is here, by which it was asked", %{site: site} do
      {:ok, idle, _html} = mount_page(site, "blog-author-profile")
      assert has_element?(idle, ~s([data-role="blog-author-idle"]))
      refute has_element?(idle, ~s([data-role="blog-author-card"]))

      {:ok, missing, _html} = mount_page(site, "blog-author-profile", %{slug: "nobody"})
      assert has_element?(missing, ~s([data-role="blog-author-missing"]))
      refute has_element?(missing, ~s([data-role="blog-author-posts"]))
    end

    test "and an archived blogger is nobody", %{site: site, writer: writer} do
      Ash.destroy!(writer, action: :destroy, tenant: site.id, authorize?: false)

      {:ok, view, _html} = mount_page(site, "blog-author-profile", %{slug: "mona"})

      assert has_element?(view, ~s([data-role="blog-author-missing"]))
      refute has_element?(view, ~s([data-role="blog-author-card"]))
    end

    test "leaves a locked post out for a visitor who may not open it", %{
      site: site,
      writer: writer
    } do
      locked =
        create_blog_post!(
          site_id: site.id,
          title: "Members only",
          status: :published,
          permissions: ["members:read"],
          published_at: ~U[2026-03-01 00:00:00Z]
        )

      credit!(locked, writer)
      member = create_user_with_permissions!(["members:read"], site_id: site.id)

      {:ok, guest, _html} = mount_page(site, "blog-author-profile", %{slug: "mona"})
      assert titles(guest) == ["Newer post", "Older post"]

      {:ok, shown, _html} =
        mount_page(site, "blog-author-profile", %{slug: "mona", current_user: member})

      assert titles(shown) == ["Members only", "Newer post", "Older post"]
    end

    test "says so when they have published nothing", %{site: site} do
      blogger!(site, display_name: "Quiet", slug: "quiet")

      {:ok, view, _html} = mount_page(site, "blog-author-profile", %{slug: "quiet"})

      assert text_of(view, ~s([data-role="blog-author-name"])) == ["Quiet"]
      assert has_element?(view, ~s([data-role="blog-author-posts-empty"]))
      refute has_element?(view, ~s([data-role="blog-author-teams"]))
    end

    # TURNING A PAGE READS THE POSTS AND NOTHING ELSE. The profile above them is its own load, so
    # it stays where it is while the next page arrives.
    test "pages their posts, and a page turned leaves the profile where it is", %{site: site} do
      {:ok, view, _html} = mount_page(site, "blog-author-profile", %{slug: "mona", per_page: 1})

      assert titles(view) == ["Newer post"]

      asked =
        queries_while(fn ->
          view
          |> element(~s([data-role="blog-author-pager"] [data-role="blog-list-next"]))
          |> render_click()

          render_async(view, @async)
        end)

      assert titles(view) == ["Older post"]
      assert text_of(view, ~s([data-role="blog-author-name"])) == ["Mona Writer"]
      # The profile is the one read that asks for a blogger's links.
      assert Enum.any?(asked, &String.contains?(&1, "mishka_blog_posts")),
             "turning a page read no posts, so nothing is asserted of it"

      refute Enum.any?(asked, &String.contains?(&1, "social_links")),
             "turning a page read the profile again"
    end

    test "answers a page of their posts nobody has with the site's 404", %{site: site} do
      for {page, position} <- [{"1", "1/2"}, {"2", "2/2"}] do
        {:ok, view, _html} =
          mount_page(site, "blog-author-profile", %{
            slug: "mona",
            per_page: 1,
            base: "/blog/author/mona",
            params: %{"page" => page}
          })

        assert positions(view) == [position]
      end

      assert_raise MishkaCmsCore.ErrorsExceptions.NotFoundError, fn ->
        mount_page(site, "blog-author-profile", %{
          slug: "mona",
          per_page: 1,
          base: "/blog/author/mona",
          params: %{"page" => "3"}
        })
      end
    end

    test "draws the blogger in its first paint, with no skeleton", %{site: site} do
      {_view, first_paint} =
        mount_blocks(site, [
          %{"name" => "blog-author-profile", "id" => "one", "attrs" => %{slug: "mona"}}
        ])

      assert roles(first_paint, "blog-author-loading") == 0
      assert roles(first_paint, "blog-author-card") == 1
    end
  end

  describe "blog-team-profile" do
    setup %{site: site} do
      team =
        team!(site, name: "Core", slug: "core", description: "The people behind the runtime.")

      [ada, gone] =
        for {name, slug} <- [{"Ada", "ada"}, {"Gone", "gone"}] do
          writer = blogger!(site, display_name: name, slug: slug)
          member!(team, writer)
          writer
        end

      [post] = publish!(site, ["By the team"])
      credit!(post, ada)
      publish!(site, ["By nobody in it"])

      Ash.destroy!(gone, action: :destroy, tenant: site.id, authorize?: false)

      %{team: team, ada: ada}
    end

    test "draws the team, the members a reader can see, and their posts", %{site: site} do
      {:ok, view, _html} =
        mount_page(site, "blog-team-profile", %{
          slug: "core",
          author_base: "/:lang/blog/author",
          post_base: "/:lang/blog"
        })

      assert text_of(view, ~s([data-role="blog-team-name"])) == ["Core"]

      assert text_of(view, ~s([data-role="blog-team-description"])) == [
               "The people behind the runtime."
             ]

      assert text_of(view, ~s([data-role="blog-team-member"] [data-role="blog-profile-name"])) ==
               ["Ada"]

      assert hrefs(view, ~s([data-role="blog-team-member"] a)) == ["/blog/author/ada"]
      assert titles(view) == ["By the team"]
    end

    test "leaves a locked post out for a visitor who may not open it", %{site: site, ada: ada} do
      locked =
        create_blog_post!(
          site_id: site.id,
          title: "Members only",
          status: :published,
          permissions: ["members:read"],
          published_at: ~U[2026-03-01 00:00:00Z]
        )

      credit!(locked, ada)
      member = create_user_with_permissions!(["members:read"], site_id: site.id)

      {:ok, guest, _html} = mount_page(site, "blog-team-profile", %{slug: "core"})
      assert titles(guest) == ["By the team"]

      {:ok, shown, _html} =
        mount_page(site, "blog-team-profile", %{slug: "core", current_user: member})

      assert titles(shown) == ["Members only", "By the team"]
    end

    test "says nobody is here for a team that is not active, or is archived", %{
      site: site,
      team: team
    } do
      team!(site, name: "Drafted", slug: "drafted", status: :draft)

      {:ok, drafted, _html} = mount_page(site, "blog-team-profile", %{slug: "drafted"})
      assert has_element?(drafted, ~s([data-role="blog-team-missing"]))

      Ash.destroy!(team, action: :destroy, tenant: site.id, authorize?: false)

      {:ok, archived, _html} = mount_page(site, "blog-team-profile", %{slug: "core"})
      assert has_element?(archived, ~s([data-role="blog-team-missing"]))
      refute has_element?(archived, ~s([data-role="blog-team-card"]))

      {:ok, idle, _html} = mount_page(site, "blog-team-profile")
      assert has_element?(idle, ~s([data-role="blog-team-idle"]))
    end

    test "answers a page of its posts nobody has with the site's 404", %{site: site} do
      attrs = %{slug: "core", per_page: 1, base: "/blog/team/core"}

      {:ok, view, _html} =
        mount_page(site, "blog-team-profile", Map.put(attrs, :params, %{"page" => "1"}))

      assert titles(view) == ["By the team"]

      assert_raise MishkaCmsCore.ErrorsExceptions.NotFoundError, fn ->
        mount_page(site, "blog-team-profile", Map.put(attrs, :params, %{"page" => "2"}))
      end
    end

    test "says so when nobody is in it and nothing is published", %{site: site} do
      team!(site, name: "Empty", slug: "empty")

      {:ok, view, _html} = mount_page(site, "blog-team-profile", %{slug: "empty"})

      assert has_element?(view, ~s([data-role="blog-team-members-empty"]))
      assert has_element?(view, ~s([data-role="blog-team-posts-empty"]))
    end
  end

  # EVERYBODY WHO WRITES HERE: each active team with the members a reader can see, then the
  # bloggers in no team a reader can open — which takes in the members of a team that is not active.
  describe "blog-people" do
    setup %{site: site} do
      core = team!(site, name: "Core", slug: "core")
      member!(core, blogger!(site, display_name: "Ada", slug: "ada"))
      gone = blogger!(site, display_name: "Gone", slug: "gone")
      member!(core, gone)
      Ash.destroy!(gone, action: :destroy, tenant: site.id, authorize?: false)

      member!(
        team!(site, name: "Drafted", slug: "drafted", status: :draft),
        blogger!(site, display_name: "Bea", slug: "bea")
      )

      blogger!(site, display_name: "Cyrus", slug: "cyrus")
      team!(site, name: "Empty", slug: "empty")

      :ok
    end

    test "draws every active team with its members, then the bloggers in none", %{site: site} do
      {:ok, view, _html} =
        mount_page(site, "blog-people", %{
          author_base: "/:lang/blog/author",
          team_base: "/:lang/blog/team"
        })

      assert text_of(view, ~s([data-role="blog-people-team-name"])) == ["Core", "Empty"]

      assert text_of(view, ~s([data-role="blog-people-member"] [data-role="blog-profile-name"])) ==
               ["Ada"]

      assert has_element?(view, ~s([data-role="blog-people-team-empty"]))

      assert text_of(view, ~s([data-role="blog-people-person"] [data-role="blog-profile-name"])) ==
               ["Bea", "Cyrus"]

      assert hrefs(view, ~s([data-role="blog-people-team-name"])) == [
               "/blog/team/core",
               "/blog/team/empty"
             ]

      assert hrefs(view, ~s([data-role="blog-people-person"] a)) == [
               "/blog/author/bea",
               "/blog/author/cyrus"
             ]
    end

    # A BLOGGER AND A TEAM ARE ONE ROW IN EVERY LANGUAGE, so their addresses are the page's own.
    test "builds every address in the page's language, at the place the site's mode puts it", %{
      site: site
    } do
      publishes_persian!(site, "prefix_others")

      {:ok, view, _html} =
        mount_page(site, "blog-people", %{
          language: "fa",
          author_base: "/:lang/blog/author",
          team_base: "/:lang/blog/team"
        })

      assert hrefs(view, ~s([data-role="blog-people-team-name"])) == [
               "/fa/blog/team/core",
               "/fa/blog/team/empty"
             ]

      assert hrefs(view, ~s([data-role="blog-people-member"] a)) == ["/fa/blog/author/ada"]
    end

    test "draws every name as a word where the page gave it no base", %{site: site} do
      {:ok, view, _html} = mount_page(site, "blog-people")

      assert text_of(view, ~s([data-role="blog-people-team-name"])) == ["Core", "Empty"]
      assert hrefs(view, ~s([data-role="blog-people-team-name"])) == []
      assert hrefs(view, ~s([data-role="blog-profile-name"])) == []
    end

    test "leaves out the teams, or the bloggers in none, when the author says so", %{site: site} do
      {:ok, view, _html} = mount_page(site, "blog-people", %{show_teams: false})

      assert text_of(view, ~s([data-role="blog-people-team-name"])) == []

      assert text_of(view, ~s([data-role="blog-people-person"] [data-role="blog-profile-name"])) ==
               ["Bea", "Cyrus"]

      {:ok, view, _html} = mount_page(site, "blog-people", %{show_unteamed: false})

      assert text_of(view, ~s([data-role="blog-people-team-name"])) == ["Core", "Empty"]
      refute has_element?(view, ~s([data-role="blog-people-unteamed"]))
    end

    test "draws its people in its first paint, and an error with a way out when the read fails",
         %{
           site: site
         } do
      {_view, first_paint} =
        mount_blocks(site, [%{"name" => "blog-people", "id" => "people", "attrs" => %{}}])

      assert roles(first_paint, "blog-people-loading") == 0
      assert roles(first_paint, "blog-people-team") == 2

      kept = refuse!(site, "blog-people")
      recompile!(site, "blog-people")

      {view, _first_paint} =
        mount_blocks(site, [%{"name" => "blog-people", "id" => "people", "attrs" => %{}}])

      assert roles(render_async(view, @async), "blog-people-error") == 1

      write_helpers!(site, "blog-people", kept)
      recompile!(site, "blog-people")

      view |> element(~s(#people [data-role="blog-notice-retry"])) |> render_click()

      assert roles(render_async(view, @async), "blog-people-team") == 2,
             "asking again did not read again"
    end
  end

  describe "blog-people with nobody to show" do
    test "says so", %{site: site} do
      {:ok, view, _html} = mount_page(site, "blog-people")

      assert has_element?(view, ~s([data-role="blog-people-empty"]))
    end
  end

  # THE COMPONENTS AS THE BUNDLE LISTS THEM, so a seventh is covered the day it is added rather than
  # the day somebody remembers to lengthen a list written here.
  defp bundle_components do
    MishkaBlog.Kit.bundle_path() |> File.read!() |> Jason.decode!() |> Map.fetch!("components")
  end

  defp squished(view, selector),
    do: view |> text_of(selector) |> Enum.map(&String.replace(&1, ~r/\s+/, " "))

  defp hrefs(view, selector), do: attrs_of(view, selector, "href")

  defp attrs_of(view, selector, name) do
    view
    |> render_async(@async)
    |> LazyHTML.from_fragment()
    |> LazyHTML.query(selector)
    |> Enum.map(&LazyHTML.attribute(&1, name))
    |> List.flatten()
  end

  defp tag!(site, opts),
    do: create_blog_tag!(Keyword.merge([site_id: site.id, language: "en"], opts))

  defp category!(site, opts),
    do:
      create_collection!(Keyword.merge([site_id: site.id, language: "en", status: :active], opts))

  defp comment!(site, post, opts),
    do:
      create_comment!(
        Keyword.merge([site_id: site.id, post_id: post.id, status: :approved], opts)
      )

  defp tag_post!(post, tag), do: create_post_tag!(post_id: post.id, tag_id: tag.id)

  defp blogger!(site, opts), do: create_blogger!(Keyword.merge([site_id: site.id], opts))

  defp team!(site, opts),
    do: create_team!(Keyword.merge([site_id: site.id, status: :active], opts))

  defp member!(team, blogger), do: create_team_member!(team_id: team.id, blogger_id: blogger.id)

  defp credit!(post, blogger), do: create_post_blogger!(post_id: post.id, blogger_id: blogger.id)

  defp named(records, name), do: Enum.filter(records, &(&1.name == name))

  defp labels(view, selector),
    do: view |> text_of(selector) |> Enum.map(&(&1 |> String.split() |> Enum.join(" ")))

  defp persian!(site, title) do
    create_blog_post!(
      site_id: site.id,
      title: title,
      status: :published,
      language: "fa",
      published_at: ~U[2026-01-01 00:00:00Z]
    )
  end

  # English and Persian on `site`, its addresses named in `mode`.
  defp publishes_persian!(site, mode) do
    on_exit(fn ->
      SettingsState.delete(site.id, "site.languages")
      SettingsState.delete(site.id, "site.language_urls")
    end)

    {:ok, _} = MishkaCmsCore.Settings.put("site.languages", ["en", "fa"], site_id: site.id)
    {:ok, _} = MishkaCmsCore.Settings.put("site.language_urls", mode, site_id: site.id)
  end

  # Where English, the site's first language, puts `path` in `mode`.
  defp english("prefix_others", path), do: path
  defp english("prefix_all", path), do: "/en" <> path

  defp categorize!(post, category),
    do: create_post_collection!(post_id: post.id, collection_id: category.id)

  # A tag with something published behind it, which is the only kind the cloud shows.
  defp tagged!(site, name, slug) do
    tag = tag!(site, name: name, slug: slug)
    [post] = publish!(site, ["For #{slug}"])
    tag_post!(post, tag)
    tag
  end

  # The same for a category.
  defp filed!(site, name, slug) do
    category = category!(site, name: name, slug: slug)
    [post] = publish!(site, ["For #{slug}"])
    categorize!(post, category)
    category
  end

  defp translate!(site, master, language, title, status \\ :published) do
    create_blog_post!(
      site_id: site.id,
      title: title,
      status: status,
      language: language,
      language_group_id: master.language_group_id,
      published_at: (status == :published && ~U[2026-01-01 00:00:00Z]) || nil
    )
  end
end
