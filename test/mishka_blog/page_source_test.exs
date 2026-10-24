# SPDX-FileCopyrightText: 2026 Mishka Group contributors <https://github.com/mishka-group/mishka_blog/graphs/contributors>
#
# SPDX-License-Identifier: Apache-2.0

defmodule MishkaBlog.PageSourceTest do
  @moduledoc """
  `MishkaBlog.PageSource` and its `runtime:page:source` plugin: the rows a blog page shows, read once
  as the visitor and handed to the head and the frame, and what each of them makes of a record the
  visitor may not open.

  Every rule is asked twice, of a guest and of a reader holding the lock: a locked post, a post
  locked by the category it is filed under, a locked edition of an open post, and a draft. That a
  page then asks the database for each row once is the host's `BlogPageQueriesTest`.

  `async: false` — the settings cache is process-global.
  """
  use MishkaBlog.DataCase, async: false

  alias MishkaBlog.PageSource
  alias MishkaBlog.Plugins.{PageFrame, PageSeo}
  alias MishkaBlog.Plugins.PageSource, as: SourcePlugin
  alias MishkaBlog.Provision
  alias MishkaCmsCore.Runtime.PageSource, as: CorePageSource
  alias MishkaCmsCore.Runtime.{Seo, SiteLayout}
  alias MishkaCmsCore.Runtime.States.SettingsState
  alias MishkaCmsCore.Settings

  @lock ["members:read"]

  setup do
    site = create_site!(active: true)

    on_exit(fn ->
      SettingsState.delete(site.id, "site.languages")
      SettingsState.delete(site.id, "site.language_urls")
    end)

    {:ok, _} = Settings.put("site.languages", ["en", "fa"], site_id: site.id)

    member = create_user_with_permissions!(@lock, site_id: site.id)

    {:ok, site: site, member: member}
  end

  # THE PAGE AS `MishkaCmsWeb.RuntimeLive` HANDS IT TO THE THREE PLUGINS: the provisioned page of
  # `kind`, its `slug`, and the visitor.
  defp page(site, kind) do
    sample = Enum.find(Provision.sample_pages(site), &(&1.path == Provision.item_paths()[kind]))
    {sample, %{path: sample.path, section: sample.section, language: "en", title: sample.title}}
  end

  defp source(site, kind, slug, visitor) do
    {sample, page} = page(site, kind)

    given =
      CorePageSource.given(page,
        site_id: site.id,
        current_user: visitor,
        extra: sample.extra,
        params: %{"slug" => slug, "lang" => "en"}
      )

    case SourcePlugin.call(given) do
      {:reply, :halt, %{source: source}} -> source
      {:reply, _untouched} -> nil
    end
  end

  defp head(site, kind, slug, visitor) do
    {sample, page} = page(site, kind)
    source = source(site, kind, slug, visitor)

    given =
      Seo.given(Map.put(page, :seo, %{description: nil, schema: []}),
        site_id: site.id,
        params: %{"slug" => slug, "lang" => "en"},
        record: sample.extra["record"],
        source: source
      )

    {:reply, :halt, answered} = PageSeo.call(given)
    Seo.accept(answered, given)
  end

  defp frame(site, kind, slug, visitor) do
    {sample, page} = page(site, kind)

    given =
      SiteLayout.given(page,
        site_id: site.id,
        current_user: visitor,
        extra: sample.extra,
        params: %{"slug" => slug, "lang" => "en"},
        source: source(site, kind, slug, visitor)
      )

    {:reply, :halt, answered} = PageFrame.call(given)
    SiteLayout.accept(answered, given)
  end

  defp post!(site, slug, title, overrides \\ []) do
    create_blog_post!(
      [
        site_id: site.id,
        slug: slug,
        title: title,
        status: :published,
        language: "en",
        published_at: ~U[2026-09-01 08:30:00Z],
        permissions: []
      ] ++ overrides
    )
  end

  defp category!(site, slug, permissions) do
    create_collection!(
      site_id: site.id,
      slug: slug,
      name: String.capitalize(slug),
      status: :active,
      language: "en",
      permissions: permissions
    )
  end

  describe "a locked post" do
    setup %{site: site} do
      {:ok, post: post!(site, "the-locked-one", "The locked one", permissions: @lock)}
    end

    test "is no row for a guest, and the head names its lock and nothing else of it", %{
      site: site
    } do
      assert %PageSource{record: nil, visitor: nil} = source(site, :post, "the-locked-one", nil)

      head = head(site, :post, "the-locked-one", nil)

      assert head.permissions == @lock
      assert head.card == false
      refute head.title == "The locked one"
      refute inspect(head) =~ "The locked one"
    end

    test "is the row, with its head, for a reader holding the lock", %{
      site: site,
      member: member,
      post: post
    } do
      assert %PageSource{record: %{id: id}} = source(site, :post, "the-locked-one", member)
      assert id == post.id

      head = head(site, :post, "the-locked-one", member)
      assert head.title == "The locked one"
      assert head.permissions == @lock
    end
  end

  describe "a post filed under a locked category" do
    setup %{site: site} do
      post = post!(site, "filed-away", "Filed away")
      create_post_collection!(post_id: post.id, collection_id: category!(site, "staff", @lock).id)
      :ok
    end

    test "is no row for a guest, whose head carries the category's lock", %{site: site} do
      assert %PageSource{record: nil} = source(site, :post, "filed-away", nil)

      head = head(site, :post, "filed-away", nil)
      assert head.permissions == @lock
      refute inspect(head) =~ "Filed away"
    end

    test "is the row for a reader holding the category's lock, its category with it", %{
      site: site,
      member: member
    } do
      %PageSource{record: post} = source(site, :post, "filed-away", member)

      assert post.title == "Filed away"
      assert Enum.map(post.collections, & &1.slug) == ["staff"]
    end
  end

  describe "the editions of an open post" do
    setup %{site: site} do
      open = post!(site, "open-post", "Open")
      group = open.language_group_id || open.id

      post!(site, "ghofl", "قفل",
        language: "fa",
        language_group_id: group,
        permissions: @lock
      )

      {:ok, group: group}
    end

    test "leave a locked edition out for a guest, and offer it to a reader holding the lock", %{
      site: site,
      member: member
    } do
      guest = source(site, :post, "open-post", nil)
      assert guest.record.editions == []
      assert frame(site, :post, "open-post", nil).translations == []

      reader = source(site, :post, "open-post", member)

      assert Enum.map(reader.record.editions, &{&1.language, &1.slug, &1.title}) == [
               {"fa", "ghofl", "قفل"}
             ]

      assert Enum.map(frame(site, :post, "open-post", member).translations, & &1.language) ==
               ["en", "fa"]
    end

    # AN EDITION IS THE MINIMUM THE FRAME AND THE HEAD NAME: its language, its slug and its title.
    test "carry their language, their slug and their title, and no text", %{
      site: site,
      member: member
    } do
      [edition] = source(site, :post, "open-post", member).record.editions

      assert %Ash.NotLoaded{} = edition.content
      assert %Ash.NotLoaded{} = edition.seo_tags
    end

    test "never offer a draft, to anyone", %{site: site, member: member, group: group} do
      {:ok, _} = Settings.put("site.languages", ["en", "fa", "ar"], site_id: site.id)

      post!(site, "pish-nevis", "پیش‌نویس",
        language: "ar",
        language_group_id: group,
        status: :draft
      )

      for visitor <- [nil, member] do
        editions = source(site, :post, "open-post", visitor).record.editions
        refute Enum.any?(editions, &(&1.slug == "pish-nevis"))
        refute inspect(frame(site, :post, "open-post", visitor)) =~ "پیش‌نویس"
      end
    end
  end

  describe "a draft" do
    test "is no row and has no lock, for a guest and for a reader holding every lock", %{
      site: site,
      member: member
    } do
      post!(site, "not-yet", "Not yet", status: :draft)

      for visitor <- [nil, member] do
        assert %PageSource{record: nil} = source(site, :post, "not-yet", visitor)

        head = head(site, :post, "not-yet", visitor)
        refute inspect(head) =~ "Not yet"
        assert head.permissions == []
        assert frame(site, :post, "not-yet", visitor).translations == []
      end
    end
  end

  describe "a category's page" do
    test "carries how many of its posts its own list holds, for the reader it is read for", %{
      site: site,
      member: member
    } do
      news = category!(site, "news", [])

      for {slug, permissions} <- [{"one", []}, {"two", []}, {"three", @lock}] do
        post = post!(site, slug, slug, permissions: permissions)
        create_post_collection!(post_id: post.id, collection_id: news.id)
      end

      persian = post!(site, "farsi", "farsi", language: "fa")
      create_post_collection!(post_id: persian.id, collection_id: news.id)

      assert source(site, :category, "news", nil).record.listed_post_count == 2
      assert source(site, :category, "news", member).record.listed_post_count == 3
    end
  end

  describe "the blog's front page" do
    test "carries its newest featured posts and how many posts there are, as the reader may open them",
         %{site: site, member: member} do
      post!(site, "plain", "Plain")
      post!(site, "featured-open", "Featured open", featured: true)
      post!(site, "featured-locked", "Featured locked", featured: true, permissions: @lock)

      {sample, page} =
        Enum.find_value(Provision.sample_pages(site), fn sample ->
          sample.path == "/:lang/blog" &&
            {sample, %{path: sample.path, section: sample.section, language: "en", title: "Blog"}}
        end)

      read = fn visitor ->
        PageSource.read(
          CorePageSource.given(page,
            site_id: site.id,
            current_user: visitor,
            extra: sample.extra,
            params: %{"lang" => "en"}
          )
        )
      end

      guest = read.(nil)
      assert guest.kind == "blog:home"
      assert guest.total == 2
      assert Enum.map(guest.featured.rows, & &1.slug) == ["featured-open"]

      reader = read.(member)
      assert reader.total == 3

      assert Enum.sort(Enum.map(reader.featured.rows, & &1.slug)) == [
               "featured-locked",
               "featured-open"
             ]
    end
  end

  describe "another address of the same page" do
    test "takes the record from what the address before read, for the same visitor", %{
      site: site,
      member: member
    } do
      post = post!(site, "kept", "Kept")
      first = source(site, :post, "kept", member)

      Ash.Seed.update!(post, %{title: "Changed since"})
      {sample, page} = page(site, :post)

      again = fn visitor ->
        PageSource.read(
          CorePageSource.given(page,
            site_id: site.id,
            current_user: visitor,
            extra: sample.extra,
            params: %{"slug" => "kept", "lang" => "en", "page" => "2"},
            held: first
          )
        )
      end

      # the same visitor: nothing of the post is read again
      assert again.(member).record.title == "Kept"

      # another visitor is never handed what was read for somebody else
      assert again.(nil).record.title == "Changed since"
    end
  end

  test "the plugin answers for the blog's pages and hands every other back untouched", %{
    site: site
  } do
    given =
      CorePageSource.given(%{path: "/:lang/about", section: "starter", language: "en"},
        site_id: site.id,
        extra: %{},
        params: %{}
      )

    assert SourcePlugin.call(given) == {:reply, given}
  end
end
