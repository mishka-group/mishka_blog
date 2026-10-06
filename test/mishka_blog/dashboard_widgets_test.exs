defmodule MishkaBlog.Dashboard.WidgetsTest do
  @moduledoc """
  Each blog dashboard widget is its own `dashboard:widgets` plugin. These call each plugin's `call/1`
  (it appends its descriptor, admin link included) and run its real `load` + render through
  `Widget.card/1` against the test DB.

  The point of the file is the tenant contract, checked against three actors: a MASTER with roles
  (`site_id: nil`) must see every site's rows, a TENANT with roles only its own site's, and a user
  with no roles must not be offered the widget at all. A wrong cross-tenant read action, aggregate,
  field or filter fails here rather than in production.
  """
  use MishkaBlog.DataCase, async: false

  import Phoenix.LiveViewTest
  import MishkaBlog.Test.Factory

  alias MishkaCmsCore.Dashboard.Widget

  alias MishkaBlog.Dashboard.Widgets.{
    RecentPosts,
    DraftsScheduled,
    CommentsModeration,
    TopPosts,
    Bloggers
  }

  @widgets [
    {RecentPosts, "blog-recent-posts", "/admin/dashboard/blog/posts"},
    {DraftsScheduled, "blog-drafts-scheduled", "/admin/dashboard/blog/posts"},
    {CommentsModeration, "blog-comments-moderation", "/admin/dashboard/blog/comments"},
    {TopPosts, "blog-top-posts", "/admin/dashboard/blog/analytics"},
    {Bloggers, "blog-bloggers", "/admin/dashboard/blog/bloggers"}
  ]

  setup do
    site = create_site!()

    %{
      site: site,
      master: create_user_with_permissions!(["admin:dashboard:*"]),
      tenant: create_user_with_permissions!(["admin:dashboard:*"], site_id: site.id),
      roleless: create_user!(site_id: site.id)
    }
  end

  for {module, id, link} <- @widgets do
    test "#{id}: call/1 appends a valid descriptor with its admin link" do
      assert {:reply,
              %{
                widgets: [
                  %Widget{
                    id: unquote(id),
                    component: {unquote(module), :render},
                    link: unquote(link)
                  }
                ]
              }} = unquote(module).call(%{widgets: []})
    end

    test "#{id}: renders for a master without the failure placeholder", %{master: master} do
      refute render_widget(unquote(module), master) =~ "could not load"
    end

    test "#{id}: renders for a tenant without the failure placeholder", %{tenant: tenant} do
      refute render_widget(unquote(module), tenant) =~ "could not load"
    end

    test "#{id}: is not offered to a user without roles", %{roleless: roleless, master: master} do
      widget = unquote(module).widget()

      assert Widget.permitted?(widget, master)
      refute Widget.permitted?(widget, roleless)
    end
  end

  # EACH WIDGET IS ITS AREA'S, with the settings it declares: the comment queue a moderator's, every
  # other one an editor's.
  describe "who is offered each widget" do
    @areas %{
      "blog-recent-posts" => "admin:dashboard:blog:post",
      "blog-drafts-scheduled" => "admin:dashboard:blog:post",
      "blog-top-posts" => "admin:dashboard:blog:post",
      "blog-bloggers" => "admin:dashboard:blog:post",
      "blog-comments-moderation" => "admin:dashboard:blog:comment"
    }

    setup %{site: site} do
      holders =
        Map.new(
          [
            "admin:dashboard:blog:post",
            "admin:dashboard:blog:comment",
            "admin:dashboard:runtime:page"
          ],
          &{&1, create_user_with_permissions!([&1], site_id: site.id)}
        )

      %{holders: holders}
    end

    for {module, id, _link} <- @widgets do
      test "#{id}: its area's holder alone", %{holders: holders} do
        widget = unquote(module).widget()
        area = Map.fetch!(@areas, unquote(id))

        for {name, holder} <- holders do
          assert Widget.permitted?(widget, holder) == (name == area),
                 "#{unquote(id)} answered #{name} wrongly"
        end

        for definition <- Widget.settings_definitions(widget) do
          assert Enum.all?(holders, fn {name, holder} ->
                   MishkaCmsCore.Settings.permitted?(definition, holder) == (name == area)
                 end)
        end
      end
    end
  end

  describe "a master sees every site" do
    test "blog-recent-posts reads posts from all sites", %{master: master, site: site} do
      other = create_site!()
      create_blog_post!(site_id: site.id, title: "Site A Post")
      create_blog_post!(site_id: other.id, title: "Site B Post")

      titles = master |> RecentPosts.load() |> Map.fetch!(:posts) |> Enum.map(& &1.title)

      assert "Site A Post" in titles
      assert "Site B Post" in titles
    end

    test "blog-recent-posts names the author of any site's post", %{master: master} do
      site = create_site!()
      post = create_blog_post!(site_id: site.id, title: "Fleet Written Post")
      blogger = create_blogger!(site_id: site.id, display_name: "Fleet Author")
      create_post_blogger!(post_id: post.id, blogger_id: blogger.id)

      assert render_widget(RecentPosts, master) =~ "Fleet Author"
    end

    test "blog-recent-posts renders a status badge and the post title", %{master: master} do
      site = create_site!()
      create_blog_post!(site_id: site.id, title: "Recent Widget Post", status: :published)

      html = render_widget(RecentPosts, master)

      assert html =~ "Recent Widget Post"
      assert html =~ "published"
    end

    test "blog-comments-moderation counts pending comments across sites", %{master: master} do
      one = create_comment!()
      two = create_comment!()

      refute one.site_id == two.site_id

      assert %{counts: %{pending: pending}, latest: latest} = CommentsModeration.load(master)

      assert pending >= 2
      assert one.id in Enum.map(latest, & &1.id)
      assert two.id in Enum.map(latest, & &1.id)
    end

    test "blog-drafts-scheduled splits drafts from scheduled with their times", %{master: master} do
      publish_at = DateTime.utc_now() |> DateTime.add(3600, :second) |> DateTime.truncate(:second)
      site = create_site!()
      create_blog_post!(site_id: site.id, title: "Draft Widget Post", status: :draft)

      create_blog_post!(
        site_id: site.id,
        title: "Scheduled Widget Post",
        status: :scheduled,
        scheduled_publish_at: publish_at
      )

      html = render_widget(DraftsScheduled, master)

      assert html =~ "Draft Widget Post"
      assert html =~ "Scheduled Widget Post"
      assert html =~ Calendar.strftime(publish_at, "%b %d, %H:%M")
    end

    # The card is a top-N podium ranked by post count, so a brand-new profile will not appear on it
    # and WHICH bloggers rank depends on seeded data. The scope-independent fact: a fresh site has
    # exactly one blogger and a tenant sees only that, while the master's ranking is drawn from the
    # whole fleet and is therefore longer.
    test "blog-bloggers ranks across the fleet, not one site", %{master: master, site: site} do
      mine = create_blogger!(site_id: site.id)
      theirs = create_blogger!()
      tenant = create_user_with_permissions!(["admin:dashboard:*"], site_id: site.id)

      assert %{bloggers: [%{id: only}]} = Bloggers.load(tenant)
      assert only == mine.id

      assert %{bloggers: master_bloggers} = Bloggers.load(master)

      assert Enum.sort([mine.id, theirs.id]) ==
               master_bloggers |> Enum.map(& &1.id) |> Enum.sort()
    end
  end

  describe "a tenant sees only its own site" do
    test "blog-recent-posts drops the other site's posts", %{tenant: tenant, site: site} do
      other = create_site!()
      create_blog_post!(site_id: site.id, title: "Site A Post")
      create_blog_post!(site_id: other.id, title: "Site B Post")

      assert %{posts: posts} = RecentPosts.load(tenant)
      assert Enum.map(posts, & &1.title) == ["Site A Post"]
    end

    test "blog-recent-posts names its own post's author", %{tenant: tenant, site: site} do
      post = create_blog_post!(site_id: site.id, title: "Site Written Post")
      blogger = create_blogger!(site_id: site.id, display_name: "Site Author")
      create_post_blogger!(post_id: post.id, blogger_id: blogger.id)

      assert render_widget(RecentPosts, tenant) =~ "Site Author"
    end

    test "blog-top-posts ranks only published posts on its own site", %{
      tenant: tenant,
      site: site
    } do
      other = create_site!()
      create_blog_post!(site_id: site.id, title: "Tenant Top Post", status: :published)
      create_blog_post!(site_id: site.id, title: "Tenant Draft Post", status: :draft)
      create_blog_post!(site_id: other.id, title: "Neighbour Post", status: :published)

      html = render_widget(TopPosts, tenant)

      assert html =~ "Tenant Top Post"
      refute html =~ "Tenant Draft Post"
      refute html =~ "Neighbour Post"
    end

    test "blog-comments-moderation counts only its own site's comments", %{site: site} do
      mine = create_comment!(site_id: site.id)
      theirs = create_comment!()

      refute mine.site_id == theirs.site_id

      tenant = create_user_with_permissions!(["admin:dashboard:*"], site_id: mine.site_id)
      neighbour = create_user_with_permissions!(["admin:dashboard:*"], site_id: theirs.site_id)

      assert %{counts: %{pending: 1}, latest: [%{id: id}]} = CommentsModeration.load(tenant)
      assert id == mine.id

      assert %{counts: %{pending: 1}, latest: [%{id: other_id}]} =
               CommentsModeration.load(neighbour)

      assert other_id == theirs.id
    end

    test "blog-drafts-scheduled counts only its own site's posts", %{tenant: tenant, site: site} do
      other = create_site!()
      create_blog_post!(site_id: site.id, status: :draft)
      create_blog_post!(site_id: other.id, status: :draft)

      assert %{drafts: 1, scheduled: 0} = DraftsScheduled.load(tenant)
    end

    test "blog-bloggers lists only its own site's bloggers", %{site: site} do
      mine = create_blogger!(site_id: site.id)
      theirs = create_blogger!()

      refute mine.site_id == theirs.site_id

      tenant = create_user_with_permissions!(["admin:dashboard:*"], site_id: mine.site_id)

      assert %{bloggers: bloggers} = Bloggers.load(tenant)
      assert Enum.map(bloggers, & &1.id) == [mine.id]
    end
  end

  # A master who writes on a site — a post under its profile there, a comment — shows on that site's
  # dashboard as its profile does, and its account never does: not its email, not a part of it.
  describe "a master's work on a site's dashboard" do
    setup %{site: site} do
      master = create_user_with_permissions!(["*"], email: "the.master@example.com")

      profile =
        MishkaBlog.Blogger
        |> Ash.Changeset.for_create(
          :master_create,
          %{
            user_id: master.id,
            site_id: site.id,
            display_name: "Master Writer",
            slug: "master-writer"
          },
          actor: master
        )
        |> Ash.create!()

      post = create_blog_post!(site_id: site.id, title: "Master Post", status: :published)
      create_post_blogger!(post_id: post.id, blogger_id: profile.id)
      create_blogger!(site_id: site.id, display_name: "Another Writer")

      create_comment!(
        site_id: site.id,
        post_id: post.id,
        author_id: master.id,
        content: "A master's comment",
        status: :pending
      )

      {:ok, master_writer: master, post: post}
    end

    test "no blog widget shows the site's admin the master's email, or a part of it", %{
      tenant: tenant
    } do
      for {module, id, _link} <- @widgets do
        html = render_widget(module, tenant)

        refute html =~ "the.master", "#{id} showed a site's admin the master's email"
      end
    end

    test "blog-comments-moderation names the master by its profile on the site", %{
      tenant: tenant
    } do
      html = render_widget(CommentsModeration, tenant)

      assert html =~ "A master&#39;s comment"
      assert html =~ "Master Writer"
    end

    test "and as a master where it has no profile there", %{site: site, tenant: tenant} do
      other_master = create_user!(email: "profileless.master@example.com")
      post = create_blog_post!(site_id: site.id, status: :published)

      create_comment!(
        site_id: site.id,
        post_id: post.id,
        author_id: other_master.id,
        content: "Written without a profile",
        status: :pending
      )

      assert %{latest: latest} = CommentsModeration.load(tenant)
      html = render_widget(CommentsModeration, tenant)

      assert Enum.any?(latest, &(&1.author_id == other_master.id))
      refute html =~ "profileless.master"
      assert html =~ ">Master<"
    end

    test "a master reading the same widget sees the author's whole email", %{
      master_writer: master
    } do
      assert render_widget(CommentsModeration, master) =~ "the.master@example.com"
    end

    test "a site's admin sees its own site's writer by email", %{site: site, tenant: tenant} do
      writer = create_user!(email: "own.writer@site.test", site_id: site.id)
      post = create_blog_post!(site_id: site.id, status: :published)

      create_comment!(
        site_id: site.id,
        post_id: post.id,
        author_id: writer.id,
        content: "Written by the site's own writer",
        status: :pending
      )

      assert render_widget(CommentsModeration, tenant) =~ "own.writer@site.test"
    end
  end

  defp render_widget(module, user) do
    render_component(&Widget.card/1,
      widget: module.widget(),
      state: {:ok, module.load(user)},
      current_user: user
    )
  end
end
