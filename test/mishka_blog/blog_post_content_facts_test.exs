defmodule MishkaBlog.Test.BlogPostContentFactsTest do
  @moduledoc """
  What a post's content says about it, stored when the content is written —
  `MishkaBlog.Resources.Changes.ContentFacts`: how long it takes to read, and the components its
  markers name, which `MishkaBlog.Plugins.ContentComponents` hands a site's stylesheet. Reading a
  post works out neither.
  """
  use MishkaBlog.DataCase, async: false

  alias MishkaBlog.BlogPost
  alias MishkaBlog.Plugins.ContentComponents
  alias MishkaBlog.Resources.Changes.ContentFacts

  require Ash.Query
  require Ecto.Query

  @moduletag :unit

  setup do
    site = create_site!()
    admin = create_user_with_permissions!(["*"], site_id: site.id)

    {:ok, site: site, admin: admin}
  end

  defp words(count), do: "<p>" <> String.duplicate("word ", count) <> "</p>"

  defp write!(post, action, params, %{site: site, admin: admin}) do
    post
    |> Ash.Changeset.for_update(action, params, actor: admin, tenant: site.id)
    |> Ash.update!()
  end

  defp stored(post), do: Ash.get!(BlogPost, post.id, action: :read_any, authorize?: false)

  describe "reading_time_minutes" do
    test "is set when the post is created", %{site: site} do
      post = create_blog_post!(site_id: site.id, content: words(450))

      assert post.reading_time_minutes == 3
      assert stored(post).reading_time_minutes == 3
    end

    test "is never under a minute", %{site: site} do
      assert create_blog_post!(site_id: site.id, content: "<p>Hi</p>").reading_time_minutes == 1
    end

    test "counts the words a reader reads, not the markup around them", %{site: site} do
      html = ~s(<h2 class="lead">One two</h2><pre><code><span class="k">three</span></code></pre>)

      assert ContentFacts.reading_time(html) == 1
      assert ContentFacts.reading_time(words(201)) == 2
      assert create_blog_post!(site_id: site.id, content: html).reading_time_minutes == 1
    end

    test "changes when the content does", %{site: site} = context do
      post = create_blog_post!(site_id: site.id, content: words(10))

      assert write!(post, :update, %{content: words(650)}, context).reading_time_minutes == 4
    end

    test "is left alone by a write that leaves the content alone", %{site: site} = context do
      post = create_blog_post!(site_id: site.id, content: words(450))

      updated = write!(post, :update, %{title: "Another title"}, context)

      assert updated.reading_time_minutes == 3
      assert stored(updated).reading_time_minutes == 3
    end

    test "is filled by any save when the post has none yet", %{site: site} = context do
      post = create_blog_post!(site_id: site.id, content: words(450))

      {1, _} =
        AshPostgres.DataLayer.Info.repo(BlogPost, :mutate).update_all(
          Ecto.Query.from(p in "mishka_blog_posts", where: p.id == type(^post.id, Ecto.UUID)),
          set: [reading_time_minutes: nil]
        )

      updated = write!(stored(post), :update, %{title: "Another title"}, context)

      assert updated.reading_time_minutes == 3
      assert stored(updated).reading_time_minutes == 3
    end

    test "comes back with the content a version restores", %{site: site} = context do
      post = create_blog_post!(site_id: site.id, content: words(450))
      write!(post, :update, %{content: words(10)}, context)

      [first | _later] =
        BlogPost.Version
        |> Ash.Query.for_read(:read_any)
        |> Ash.Query.filter(version_source_id == ^post.id)
        |> Ash.Query.sort(version_inserted_at: :asc)
        |> Ash.read!(authorize?: false)

      restored = write!(stored(post), :restore_version, %{version_id: first.id}, context)

      assert restored.reading_time_minutes == 3
    end
  end

  describe "content_components" do
    test "are the names the content's markers name, each once", %{site: site} do
      post =
        create_blog_post!(
          site_id: site.id,
          content:
            ~s(<p>[[component callout title="a"]]x[[/component]]</p>[[component badge /]][[component callout /]]<code>[[component shown /]]</code>)
        )

      assert stored(post).content_components == ["callout", "badge"]
    end

    test "are nothing for content that names none", %{site: site} = context do
      post = create_blog_post!(site_id: site.id, content: "[[component callout /]]")

      assert stored(write!(post, :update, %{content: "<p>plain</p>"}, context)).content_components ==
               nil
    end

    test "are left alone by a write that leaves the content alone", %{site: site} = context do
      post = create_blog_post!(site_id: site.id, content: "[[component callout /]]")

      assert stored(write!(post, :update, %{title: "Renamed"}, context)).content_components ==
               ["callout"]
    end
  end

  # A SITE'S STYLESHEET IS BUILT FROM WHAT IT REACHES, and a post's components are in no template.
  describe "the names a site's stylesheet hears" do
    test "are those its published posts name, each once", %{site: site} do
      create_blog_post!(
        site_id: site.id,
        status: :published,
        content: "[[component callout /]][[component badge /]]"
      )

      create_blog_post!(site_id: site.id, status: :published, content: "[[component callout /]]")
      create_blog_post!(site_id: site.id, status: :draft, content: "[[component draft-only /]]")

      create_blog_post!(
        site_id: create_site!().id,
        status: :published,
        content: "[[component theirs /]]"
      )

      assert {:reply, %{components: names}} =
               ContentComponents.call(%{site: site.name, site_id: site.id, components: ["kept"]})

      assert Enum.sort(names) == ["badge", "callout", "kept"]
    end
  end

  # WHEN A WRITE ASKS FOR THE STYLESHEET AGAIN: a name a published post makes live.
  describe "newly_live/2" do
    test "is what a published post names now and did not before" do
      was = %{status: :published, content_components: ["a"]}

      assert ContentFacts.newly_live(was, %{was | content_components: ["a", "b"]}) == ["b"]
      assert ContentFacts.newly_live(was, %{was | content_components: ["a"]}) == []
      assert ContentFacts.newly_live(was, %{was | content_components: nil}) == []
    end

    test "is everything a post names once it is published, and nothing while it is not" do
      draft = %{status: :draft, content_components: ["a"]}

      assert ContentFacts.newly_live(draft, %{draft | status: :published}) == ["a"]
      assert ContentFacts.newly_live(%{draft | status: :published}, draft) == []
      assert ContentFacts.newly_live(%BlogPost{}, draft) == []
    end
  end
end
