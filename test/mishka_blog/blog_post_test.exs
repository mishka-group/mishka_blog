defmodule MishkaBlog.Test.BlogPostTest do
  @moduledoc """
  Tests for MishkaBlog.BlogPost resource.
  """
  use MishkaBlog.DataCase, async: false

  if Code.ensure_loaded?(MishkaBlog) do
    require Ash.Query
    alias MishkaBlog.BlogPost

    describe "resource configuration" do
      test "uses correct table name" do
        assert AshPostgres.DataLayer.Info.table(BlogPost) == "mishka_blog_posts"
      end

      test "uses UUID v7 for primary keys" do
        blog_post = create_blog_post!()
        assert is_binary(blog_post.id)
        assert String.length(blog_post.id) == 36
      end

      test "is always site-specific (not global)" do
        multitenancy_config = Ash.Resource.Info.multitenancy_strategy(BlogPost)
        assert multitenancy_config == :attribute
        assert Ash.Resource.Info.multitenancy_global?(BlogPost) == false
      end
    end

    describe "create action" do
      test "creates blog post with valid attributes" do
        site = create_site!()

        blog_post =
          create_blog_post!(
            title: "Test Blog Post",
            slug: "test-blog-post",
            content: "<p>Test content</p>",
            status: :draft,
            language: "en",
            site_id: site.id
          )

        assert blog_post.title == "Test Blog Post"
        assert blog_post.slug == "test-blog-post"
        assert blog_post.content == "<p>Test content</p>"
        assert blog_post.status == :draft
        assert blog_post.language == "en"
        assert blog_post.site_id == site.id
      end

      test "auto-generates slug from slug input" do
        site = create_site!()

        blog_post =
          create_blog_post!(
            title: "My Awesome Blog Post",
            slug: "My Awesome Blog Post",
            content: "<p>Content</p>",
            site_id: site.id
          )

        assert blog_post.slug == "my-awesome-blog-post"
      end

      test "requires title, slug, content, status, and language" do
        site = create_site!()

        assert_raise Ash.Error.Invalid, fn ->
          BlogPost
          |> Ash.Changeset.for_create(:create, %{}, tenant: site.id, authorize?: false)
          |> Ash.create!()
        end
      end

      test "auto-assigns site_id from tenant context" do
        site = create_site!()

        blog_post =
          BlogPost
          |> Ash.Changeset.for_create(
            :create,
            %{
              title: "Tenant Blog Post",
              slug: "tenant-blog-post",
              content: "<p>Content</p>",
              status: :draft,
              language: "en"
            },
            tenant: site.id,
            authorize?: false
          )
          |> Ash.create!()

        assert blog_post.site_id == site.id
      end

      test "auto-assigns language_group_id for new posts" do
        site = create_site!()
        blog_post = create_blog_post!(title: "Master Post", site_id: site.id)

        assert blog_post.language_group_id != nil
      end

      test "defaults status to draft" do
        site = create_site!()

        blog_post =
          BlogPost
          |> Ash.Changeset.for_create(
            :create,
            %{
              title: "Draft Post",
              slug: "draft-post",
              content: "<p>Content</p>",
              language: "en"
            },
            tenant: site.id,
            authorize?: false
          )
          |> Ash.create!()

        assert blog_post.status == :draft
      end

      test "defaults language to 'en'" do
        site = create_site!()

        blog_post =
          BlogPost
          |> Ash.Changeset.for_create(
            :create,
            %{
              title: "English Post",
              slug: "english-post",
              content: "<p>Content</p>",
              status: :draft
            },
            tenant: site.id,
            authorize?: false
          )
          |> Ash.create!()

        assert blog_post.language == "en"
      end

      test "defaults featured to false" do
        site = create_site!()
        blog_post = create_blog_post!(site_id: site.id)
        assert blog_post.featured == false
      end

      test "accepts optional excerpt" do
        site = create_site!()

        blog_post =
          create_blog_post!(
            title: "Post with Excerpt",
            excerpt: "This is an excerpt",
            site_id: site.id
          )

        assert blog_post.excerpt == "This is an excerpt"
      end

      test "accepts optional featured_image_url" do
        site = create_site!()

        blog_post =
          create_blog_post!(
            title: "Post with Image",
            featured_image_url: "https://example.com/image.jpg",
            site_id: site.id
          )

        assert blog_post.featured_image_url == "https://example.com/image.jpg"
      end

      test "accepts optional seo_tags" do
        site = create_site!()

        seo_tags = [
          %{tag: "meta", attrs: %{"name" => "description"}, content: "SEO description"},
          %{tag: "meta", attrs: %{"property" => "og:title"}, content: "Open Graph Title"}
        ]

        blog_post = create_blog_post!(seo_tags: seo_tags, site_id: site.id)

        assert blog_post.seo_tags == seo_tags
      end

      test "accepts optional schema" do
        site = create_site!()

        schema = [
          %{"@type" => "BlogPosting", "headline" => "Test Post"}
        ]

        blog_post = create_blog_post!(schema: schema, site_id: site.id)

        assert blog_post.schema == schema
      end
    end

    describe "master_create action" do
      test "creates blog post with explicit site_id" do
        site = create_site!()

        blog_post =
          BlogPost
          |> Ash.Changeset.for_create(
            :master_create,
            %{
              title: "Master Post",
              slug: "master-post",
              content: "<p>Content</p>",
              status: :draft,
              language: "en",
              site_id: site.id
            },
            authorize?: false
          )
          |> Ash.create!()

        assert blog_post.title == "Master Post"
        assert blog_post.site_id == site.id
      end

      test "requires explicit site_id" do
        assert_raise Ash.Error.Invalid, fn ->
          BlogPost
          |> Ash.Changeset.for_create(
            :master_create,
            %{
              title: "Missing Site",
              slug: "missing-site",
              content: "<p>Content</p>",
              status: :draft,
              language: "en"
            },
            authorize?: false
          )
          |> Ash.create!()
        end
      end
    end

    describe "update action" do
      test "updates blog post attributes" do
        site = create_site!()
        blog_post = create_blog_post!(title: "Original Title", site_id: site.id)

        updated =
          blog_post
          |> Ash.Changeset.for_update(
            :update,
            %{title: "Updated Title", excerpt: "New excerpt"},
            tenant: site.id,
            authorize?: false
          )
          |> Ash.update!()

        assert updated.title == "Updated Title"
        assert updated.excerpt == "New excerpt"
      end

      test "prevents updating archived blog post" do
        site = create_site!()
        blog_post = create_blog_post!(site_id: site.id)

        # Archive the blog post
        archived =
          blog_post
          |> Ash.Changeset.for_destroy(:destroy, %{}, tenant: site.id, authorize?: false)
          |> Ash.destroy!(return_destroyed?: true)

        # Try to update archived blog post
        assert_raise Ash.Error.Invalid, fn ->
          archived
          |> Ash.Changeset.for_update(
            :update,
            %{title: "Should Fail"},
            tenant: site.id,
            authorize?: false
          )
          |> Ash.update!()
        end
      end

      test "prevents site_id changes" do
        site1 = create_site!()
        site2 = create_site!()
        blog_post = create_blog_post!(site_id: site1.id)

        # site_id is not in the accepted fields for update
        updated =
          blog_post
          |> Ash.Changeset.for_update(
            :update,
            %{title: "Updated"},
            tenant: site1.id,
            authorize?: false
          )
          |> Ash.update!()

        # site_id should remain unchanged
        assert updated.site_id == site1.id
        assert updated.site_id != site2.id
      end
    end

    describe "master_update action" do
      test "updates blog post for master users" do
        site = create_site!()
        blog_post = create_blog_post!(title: "Original", site_id: site.id)

        {:ok, updated} =
          blog_post
          |> Ash.Changeset.for_update(:master_update, %{title: "Master Updated"},
            authorize?: false
          )
          |> Ash.update()

        assert updated.title == "Master Updated"
      end

      test "prevents site_id changes" do
        site1 = create_site!()
        blog_post = create_blog_post!(site_id: site1.id)

        {:ok, updated} =
          blog_post
          |> Ash.Changeset.for_update(:master_update, %{title: "Updated"}, authorize?: false)
          |> Ash.update()

        assert updated.site_id == site1.id
      end
    end

    describe "read actions with multitenancy" do
      test "tenant read only shows blog posts for that tenant" do
        site1 = create_site!()
        site2 = create_site!()

        blog_post1 = create_blog_post!(title: "Site 1 Post", site_id: site1.id)
        _blog_post2 = create_blog_post!(title: "Site 2 Post", site_id: site2.id)

        # Query as site1 tenant
        blog_posts =
          BlogPost
          |> Ash.Query.set_tenant(site1.id)
          |> Ash.read!(authorize?: false)

        assert length(blog_posts) == 1
        assert Enum.at(blog_posts, 0).id == blog_post1.id
      end

      test "master_read shows all blog posts system-wide" do
        site1 = create_site!()
        site2 = create_site!()

        _blog_post1 = create_blog_post!(title: "Site 1", site_id: site1.id)
        _blog_post2 = create_blog_post!(title: "Site 2", site_id: site2.id)

        result =
          BlogPost
          |> Ash.Query.for_read(:master_read, %{}, authorize?: false)
          |> Ash.read!()

        blog_posts = result.results
        assert length(blog_posts) >= 2
      end

      test "master_get retrieves blog post by ID bypassing tenant" do
        site = create_site!()
        blog_post = create_blog_post!(site_id: site.id)

        fetched = Ash.get!(BlogPost, blog_post.id, action: :master_get, authorize?: false)

        assert fetched.id == blog_post.id
      end

      test "published action lists only published posts" do
        site = create_site!()
        _draft = create_blog_post!(status: :draft, site_id: site.id)

        # Publish a draft post instead of creating a published post directly
        draft_post = create_blog_post!(status: :draft, site_id: site.id)

        published =
          draft_post
          |> Ash.Changeset.for_update(:publish, %{}, tenant: site.id, authorize?: false)
          |> Ash.update!()

        result =
          BlogPost
          |> Ash.Query.for_read(:published, %{}, tenant: site.id, authorize?: false)
          |> Ash.read!()

        posts = result.results
        assert length(posts) == 1
        assert Enum.at(posts, 0).id == published.id
      end

      test "drafts action lists only draft posts" do
        site = create_site!()
        draft = create_blog_post!(status: :draft, site_id: site.id)

        # Publish a draft post instead of creating a published post directly
        _published_post =
          create_blog_post!(status: :draft, site_id: site.id)
          |> Ash.Changeset.for_update(:publish, %{}, tenant: site.id, authorize?: false)
          |> Ash.update!()

        result =
          BlogPost
          |> Ash.Query.for_read(:drafts, %{}, tenant: site.id, authorize?: false)
          |> Ash.read!()

        posts = result.results
        assert length(posts) == 1
        assert Enum.at(posts, 0).id == draft.id
      end

      test "featured action lists only featured published posts" do
        site = create_site!()

        # Publish draft posts instead of creating published posts directly
        _not_featured =
          create_blog_post!(status: :draft, featured: false, site_id: site.id)
          |> Ash.Changeset.for_update(:publish, %{}, tenant: site.id, authorize?: false)
          |> Ash.update!()

        draft_featured = create_blog_post!(status: :draft, featured: true, site_id: site.id)

        featured =
          draft_featured
          |> Ash.Changeset.for_update(:publish, %{}, tenant: site.id, authorize?: false)
          |> Ash.update!()

        result =
          BlogPost
          |> Ash.Query.for_read(:featured, %{}, tenant: site.id, authorize?: false)
          |> Ash.read!()

        posts = result.results
        assert length(posts) == 1
        assert Enum.at(posts, 0).id == featured.id
      end
    end

    describe "publish/unpublish actions" do
      test "publish action publishes a draft post" do
        site = create_site!()
        blog_post = create_blog_post!(status: :draft, site_id: site.id)

        published =
          blog_post
          |> Ash.Changeset.for_update(:publish, %{}, tenant: site.id, authorize?: false)
          |> Ash.update!()

        assert published.status == :published
        assert published.published_at != nil
      end

      test "master_publish publishes a post" do
        site = create_site!()
        blog_post = create_blog_post!(status: :draft, site_id: site.id)

        {:ok, published} =
          blog_post
          |> Ash.Changeset.for_update(:master_publish, %{}, authorize?: false)
          |> Ash.update()

        assert published.status == :published
        assert published.published_at != nil
      end

      test "unpublish action reverts to draft" do
        site = create_site!()

        # First create as draft, then publish, then unpublish
        draft_post = create_blog_post!(status: :draft, site_id: site.id)

        blog_post =
          draft_post
          |> Ash.Changeset.for_update(:publish, %{}, tenant: site.id, authorize?: false)
          |> Ash.update!()

        unpublished =
          blog_post
          |> Ash.Changeset.for_update(:unpublish, %{}, tenant: site.id, authorize?: false)
          |> Ash.update!()

        assert unpublished.status == :draft
        assert unpublished.published_at == nil
      end

      test "master_unpublish reverts a post to draft" do
        site = create_site!()

        # First create as draft, then publish using master_publish, then unpublish
        draft_post = create_blog_post!(status: :draft, site_id: site.id)

        {:ok, published} =
          draft_post
          |> Ash.Changeset.for_update(:master_publish, %{}, authorize?: false)
          |> Ash.update()

        {:ok, unpublished} =
          published
          |> Ash.Changeset.for_update(:master_unpublish, %{}, authorize?: false)
          |> Ash.update()

        assert unpublished.status == :draft
        assert unpublished.published_at == nil
      end
    end

    describe "archive/unarchive actions" do
      test "destroy soft deletes blog post" do
        site = create_site!()
        blog_post = create_blog_post!(site_id: site.id)

        archived =
          blog_post
          |> Ash.Changeset.for_destroy(:destroy, %{}, tenant: site.id, authorize?: false)
          |> Ash.destroy!(return_destroyed?: true)

        assert archived.archived_at != nil
        assert archived.status == :archived

        # Should not appear in normal reads
        blog_posts =
          BlogPost
          |> Ash.Query.set_tenant(site.id)
          |> Ash.read!(authorize?: false)

        assert Enum.find(blog_posts, fn p -> p.id == blog_post.id end) == nil
      end

      test "unarchive restores archived blog post" do
        site = create_site!()
        blog_post = create_blog_post!(site_id: site.id)

        # Archive
        archived =
          blog_post
          |> Ash.Changeset.for_destroy(:destroy, %{}, tenant: site.id, authorize?: false)
          |> Ash.destroy!(return_destroyed?: true)

        # Unarchive
        unarchived =
          archived
          |> Ash.Changeset.for_update(:unarchive, %{}, tenant: site.id, authorize?: false)
          |> Ash.update!()

        assert unarchived.archived_at == nil
        assert unarchived.status == :draft
      end

      test "archived action lists only archived blog posts" do
        site = create_site!()
        active_post = create_blog_post!(title: "Active", site_id: site.id)

        archived_post =
          create_blog_post!(title: "To Archive", site_id: site.id)
          |> Ash.Changeset.for_destroy(:destroy, %{}, tenant: site.id, authorize?: false)
          |> Ash.destroy!(return_destroyed?: true)

        result =
          BlogPost
          |> Ash.Query.for_read(:archived, %{}, tenant: site.id, authorize?: false)
          |> Ash.read!()

        archived_list = result.results
        archived_ids = Enum.map(archived_list, & &1.id)
        assert archived_post.id in archived_ids
        refute active_post.id in archived_ids
      end

      test "get_archived retrieves single archived blog post" do
        site = create_site!()

        blog_post =
          create_blog_post!(site_id: site.id)
          |> Ash.Changeset.for_destroy(:destroy, %{}, tenant: site.id, authorize?: false)
          |> Ash.destroy!(return_destroyed?: true)

        fetched =
          Ash.get!(
            BlogPost,
            blog_post.id,
            action: :get_archived,
            tenant: site.id,
            authorize?: false
          )

        assert fetched.id == blog_post.id
        assert fetched.archived_at != nil
      end

      test "master_unarchive restores blog post" do
        site = create_site!()

        blog_post =
          create_blog_post!(site_id: site.id)
          |> Ash.Changeset.for_destroy(:destroy, %{}, tenant: site.id, authorize?: false)
          |> Ash.destroy!(return_destroyed?: true)

        {:ok, unarchived} =
          blog_post
          |> Ash.Changeset.for_update(:master_unarchive, %{}, authorize?: false)
          |> Ash.update()

        assert unarchived.archived_at == nil
        assert unarchived.status == :draft
      end

      test "prevents archiving already archived blog post" do
        site = create_site!()

        blog_post =
          create_blog_post!(site_id: site.id)
          |> Ash.Changeset.for_destroy(:destroy, %{}, tenant: site.id, authorize?: false)
          |> Ash.destroy!(return_destroyed?: true)

        assert_raise Ash.Error.Invalid, fn ->
          blog_post
          |> Ash.Changeset.for_destroy(:destroy, %{}, tenant: site.id, authorize?: false)
          |> Ash.destroy!()
        end
      end

      test "prevents unarchiving non-archived blog post" do
        site = create_site!()
        blog_post = create_blog_post!(site_id: site.id)

        # For update actions, we need to read the record with :master_get first
        # which will fail since it's not archived (base_filter_sql excludes archived)
        # but unarchive action has atomic_upgrade_with :master_archived which only reads archived
        {:error, error} =
          blog_post
          |> Ash.Changeset.for_update(:master_unarchive, %{}, authorize?: false)
          |> Ash.update()

        assert %Ash.Error.Invalid{} = error
      end
    end

    describe "permanent_destroy action" do
      test "permanently deletes blog post and cannot be recovered" do
        site = create_site!()
        blog_post = create_blog_post!(site_id: site.id)
        blog_post_id = blog_post.id

        blog_post
        |> Ash.Changeset.for_destroy(
          :permanent_destroy,
          %{},
          tenant: site.id,
          authorize?: false
        )
        |> Ash.destroy!()

        # Should not exist in any query
        result =
          Ash.get(
            BlogPost,
            blog_post_id,
            action: :master_get,
            authorize?: false
          )

        assert match?({:error, _}, result)
      end

      test "master_permanent_destroy permanently deletes blog post" do
        site = create_site!()
        blog_post = create_blog_post!(site_id: site.id)
        blog_post_id = blog_post.id

        :ok =
          blog_post
          |> Ash.Changeset.for_destroy(:master_permanent_destroy, %{}, authorize?: false)
          |> Ash.destroy()

        result =
          Ash.get(
            BlogPost,
            blog_post_id,
            action: :master_get,
            authorize?: false
          )

        assert match?({:error, _}, result)
      end
    end

    describe "database constraints" do
      test "enforces slug length constraints" do
        site = create_site!()

        # Empty slug should fail
        assert_raise Ash.Error.Invalid, fn ->
          create_blog_post!(slug: "", site_id: site.id)
        end

        # Slug too long (> 255) should fail
        long_slug = String.duplicate("a", 256)

        assert_raise Ash.Error.Invalid, fn ->
          create_blog_post!(slug: long_slug, site_id: site.id)
        end
      end
    end

    describe "attribute defaults" do
      test "defaults are applied correctly" do
        site = create_site!()

        blog_post =
          BlogPost
          |> Ash.Changeset.for_create(
            :create,
            %{
              title: "Test",
              slug: "test",
              content: "<p>Content</p>"
            },
            tenant: site.id,
            authorize?: false
          )
          |> Ash.create!()

        assert blog_post.status == :draft
        assert blog_post.language == "en"
        assert blog_post.featured == false
        assert blog_post.schema == []
        assert blog_post.seo_tags == []
      end
    end

    describe "complex scenarios" do
      test "language variants and grouping" do
        site = create_site!()

        # Create master blog post with language_group_id
        english =
          create_blog_post!(
            title: "English Post",
            slug: "english-post",
            content: "<p>English content</p>",
            language: "en",
            site_id: site.id
          )

        language_group_id = english.language_group_id

        # Create variant with same language_group_id
        persian =
          create_blog_post!(
            title: "Persian Post",
            slug: "persian-post",
            content: "<p>Persian content</p>",
            language: "fa",
            language_group_id: language_group_id,
            site_id: site.id
          )

        # Query language variants
        variants =
          BlogPost
          |> Ash.Query.for_read(
            :language_variants,
            %{language_group_id: language_group_id},
            tenant: site.id,
            authorize?: false
          )
          |> Ash.read!()

        variant_languages = Enum.map(variants, & &1.language) |> Enum.sort()
        assert variant_languages == ["en", "fa"]

        # Load relationship
        english_with_variants =
          Ash.load!(english, :language_variants, tenant: site.id, authorize?: false)

        assert length(english_with_variants.language_variants) == 2
        assert persian.id in Enum.map(english_with_variants.language_variants, & &1.id)
      end
    end

    describe "relationships" do
      test "belongs_to site" do
        site = create_site!()
        blog_post = create_blog_post!(site_id: site.id)

        blog_post_with_site = Ash.load!(blog_post, :site, authorize?: false)

        assert blog_post_with_site.site.id == site.id
        assert blog_post_with_site.site.host == site.host
      end

      test "language_variants relationship" do
        site = create_site!()

        english = create_blog_post!(language: "en", site_id: site.id)
        language_group_id = english.language_group_id

        _persian =
          create_blog_post!(
            language: "fa",
            language_group_id: language_group_id,
            site_id: site.id
          )

        _arabic =
          create_blog_post!(
            language: "ar",
            language_group_id: language_group_id,
            site_id: site.id
          )

        english_with_variants =
          Ash.load!(english, :language_variants, tenant: site.id, authorize?: false)

        languages =
          Enum.map(english_with_variants.language_variants, & &1.language) |> Enum.sort()

        assert languages == ["ar", "en", "fa"]
      end
    end

    describe "identities" do
      test "unique_slug_per_site prevents duplicate slugs within a site" do
        site = create_site!()
        _blog_post1 = create_blog_post!(slug: "unique-slug", site_id: site.id)

        # The unique constraint error comes as Ash.Error.Invalid with a constraint error
        assert_raise Ash.Error.Invalid, fn ->
          create_blog_post!(slug: "unique-slug", site_id: site.id)
        end
      end

      test "allows same slug across different sites" do
        site1 = create_site!()
        site2 = create_site!()

        blog_post1 = create_blog_post!(slug: "same-slug", site_id: site1.id)
        blog_post2 = create_blog_post!(slug: "same-slug", site_id: site2.id)

        assert blog_post1.slug == blog_post2.slug
        assert blog_post1.site_id != blog_post2.site_id
      end

      test "unique_language_per_group prevents duplicate languages in same group" do
        site = create_site!()

        english = create_blog_post!(language: "en", site_id: site.id)
        language_group_id = english.language_group_id

        # The unique identity constraint returns Ash.Error.Invalid
        assert_raise Ash.Error.Invalid, fn ->
          create_blog_post!(
            language: "en",
            language_group_id: language_group_id,
            site_id: site.id
          )
        end
      end

      test "allows same language in different groups" do
        site = create_site!()

        blog_post1 = create_blog_post!(language: "en", site_id: site.id)
        blog_post2 = create_blog_post!(language: "en", site_id: site.id)

        assert blog_post1.language == blog_post2.language
        assert blog_post1.language_group_id != blog_post2.language_group_id
      end
    end

    describe "collection relationships" do
      test "creates post and assigns it to multiple collections in same tenant" do
        site = create_site!()

        # Create 2 collections in the same tenant
        collection1 =
          create_collection!(
            name: "Collection 1",
            slug: "collection-1",
            status: :active,
            site_id: site.id
          )

        collection2 =
          create_collection!(
            name: "Collection 2",
            slug: "collection-2",
            status: :active,
            site_id: site.id
          )

        # Create a post and assign it to these collections
        blog_post =
          BlogPost
          |> Ash.Changeset.for_create(
            :create,
            %{
              title: "Post with Collections",
              slug: "post-with-collections",
              content: "<p>Content</p>",
              status: :draft,
              language: "en",
              collection_ids: [collection1.id, collection2.id]
            },
            tenant: site.id,
            authorize?: false
          )
          |> Ash.create!()

        # Load collections relationship
        blog_post_with_collections =
          Ash.load!(blog_post, :collections, tenant: site.id, authorize?: false)

        collection_ids =
          Enum.map(blog_post_with_collections.collections, & &1.id) |> Enum.sort()

        assert length(blog_post_with_collections.collections) == 2
        assert Enum.sort([collection1.id, collection2.id]) == collection_ids
      end

      test "master_create: creates post and assigns it to multiple collections in same tenant" do
        site = create_site!()

        # Create 2 collections in the same tenant
        collection1 =
          create_collection!(
            name: "Collection 1",
            slug: "collection-1",
            status: :active,
            site_id: site.id
          )

        collection2 =
          create_collection!(
            name: "Collection 2",
            slug: "collection-2",
            status: :active,
            site_id: site.id
          )

        # Create a post using master_create and assign it to these collections
        blog_post =
          BlogPost
          |> Ash.Changeset.for_create(
            :master_create,
            %{
              title: "Master Post with Collections",
              slug: "master-post-with-collections",
              content: "<p>Content</p>",
              status: :draft,
              language: "en",
              site_id: site.id,
              collection_ids: [collection1.id, collection2.id]
            },
            authorize?: false
          )
          |> Ash.create!()

        # Load collections relationship
        blog_post_with_collections =
          Ash.load!(blog_post, :collections, tenant: site.id, authorize?: false)

        collection_ids =
          Enum.map(blog_post_with_collections.collections, & &1.id) |> Enum.sort()

        assert length(blog_post_with_collections.collections) == 2
        assert Enum.sort([collection1.id, collection2.id]) == collection_ids
      end

      test "prevents assigning post to collection from different tenant" do
        site_a = create_site!()
        site_b = create_site!()

        # Create collection in tenant A
        collection_a =
          create_collection!(
            name: "Collection A",
            slug: "collection-a",
            status: :active,
            site_id: site_a.id
          )

        # Try to create a post in tenant B with a collection from tenant A
        # This should fail because the collection doesn't exist in tenant B
        assert_raise Ash.Error.Invalid, fn ->
          BlogPost
          |> Ash.Changeset.for_create(
            :create,
            %{
              title: "Post in Tenant B",
              slug: "post-tenant-b",
              content: "<p>Content</p>",
              status: :draft,
              language: "en",
              collection_ids: [collection_a.id]
            },
            tenant: site_b.id,
            authorize?: false
          )
          |> Ash.create!()
        end
      end

      test "master_create: prevents assigning post to collection from different tenant" do
        site_a = create_site!()
        site_b = create_site!()

        # Create collection in tenant A
        collection_a =
          create_collection!(
            name: "Collection A",
            slug: "collection-a",
            status: :active,
            site_id: site_a.id
          )

        # Try to create a post in tenant B with a collection from tenant A using master_create
        # This should fail because even though master_create sets the tenant to site_b.id,
        # the collection only exists in tenant A
        assert_raise Ash.Error.Invalid, fn ->
          BlogPost
          |> Ash.Changeset.for_create(
            :master_create,
            %{
              title: "Master Post in Tenant B",
              slug: "master-post-tenant-b",
              content: "<p>Content</p>",
              status: :draft,
              language: "en",
              site_id: site_b.id,
              collection_ids: [collection_a.id]
            },
            authorize?: false
          )
          |> Ash.create!()
        end
      end

      test "can add collections to existing post" do
        site = create_site!()

        collection1 = create_collection!(name: "Collection 1", status: :active, site_id: site.id)
        collection2 = create_collection!(name: "Collection 2", status: :active, site_id: site.id)

        # Create post without collections
        blog_post = create_blog_post!(title: "Post", site_id: site.id)

        # Add collection using add_collection action
        updated =
          blog_post
          |> Ash.Changeset.for_update(
            :add_collection,
            %{collection_id: collection1.id},
            tenant: site.id,
            authorize?: false
          )
          |> Ash.update!()

        # Add another collection
        updated2 =
          updated
          |> Ash.Changeset.for_update(
            :add_collection,
            %{collection_id: collection2.id},
            tenant: site.id,
            authorize?: false
          )
          |> Ash.update!()

        # Load and verify
        post_with_collections =
          Ash.load!(updated2, :collections, tenant: site.id, authorize?: false)

        collection_ids = Enum.map(post_with_collections.collections, & &1.id) |> Enum.sort()
        assert Enum.sort([collection1.id, collection2.id]) == collection_ids
      end

      test "can remove collection from post" do
        site = create_site!()

        collection1 = create_collection!(name: "Collection 1", status: :active, site_id: site.id)
        collection2 = create_collection!(name: "Collection 2", status: :active, site_id: site.id)

        # Create post with collections
        blog_post =
          BlogPost
          |> Ash.Changeset.for_create(
            :create,
            %{
              title: "Post",
              slug: "post",
              content: "<p>Content</p>",
              status: :draft,
              language: "en",
              collection_ids: [collection1.id, collection2.id]
            },
            tenant: site.id,
            authorize?: false
          )
          |> Ash.create!()

        # Remove one collection
        updated =
          blog_post
          |> Ash.Changeset.for_update(
            :remove_collection,
            %{collection_id: collection1.id},
            tenant: site.id,
            authorize?: false
          )
          |> Ash.update!()

        # Load and verify
        post_with_collections =
          Ash.load!(updated, :collections, tenant: site.id, authorize?: false)

        assert length(post_with_collections.collections) == 1
        assert Enum.at(post_with_collections.collections, 0).id == collection2.id
      end

      test "can replace all collections using assign_collections" do
        site = create_site!()

        collection1 = create_collection!(name: "Collection 1", status: :active, site_id: site.id)
        collection2 = create_collection!(name: "Collection 2", status: :active, site_id: site.id)
        collection3 = create_collection!(name: "Collection 3", status: :active, site_id: site.id)

        # Create post with collections 1 and 2
        blog_post =
          BlogPost
          |> Ash.Changeset.for_create(
            :create,
            %{
              title: "Post",
              slug: "post",
              content: "<p>Content</p>",
              status: :draft,
              language: "en",
              collection_ids: [collection1.id, collection2.id]
            },
            tenant: site.id,
            authorize?: false
          )
          |> Ash.create!()

        # Replace with collection 3
        updated =
          blog_post
          |> Ash.Changeset.for_update(
            :assign_collections,
            %{collection_ids: [collection3.id]},
            tenant: site.id,
            authorize?: false
          )
          |> Ash.update!()

        # Load and verify
        post_with_collections =
          Ash.load!(updated, :collections, tenant: site.id, authorize?: false)

        assert length(post_with_collections.collections) == 1
        assert Enum.at(post_with_collections.collections, 0).id == collection3.id
      end
    end

    describe "JSON API configuration" do
      test "has correct JSON API type" do
        json_api_type = AshJsonApi.Resource.Info.type(BlogPost)
        assert json_api_type == "blog_post"
      end
    end

    describe "calculation: view_count" do
      test "returns correct view count" do
        site = create_site!()
        post = create_blog_post!(site_id: site.id)

        # Create 10 views
        for _ <- 1..10 do
          user = create_user!()
          create_post_view!(post_id: post.id, user_id: user.id)
        end

        loaded_post = Ash.load!(post, [:view_count], tenant: site.id, authorize?: false)
        assert loaded_post.view_count == 10
      end

      test "returns zero when no views exist" do
        site = create_site!()
        post = create_blog_post!(site_id: site.id)

        loaded_post = Ash.load!(post, [:view_count], tenant: site.id, authorize?: false)
        assert loaded_post.view_count == 0
      end
    end

    describe "calculation: rating_average and rating_count" do
      test "returns correct rating average and count" do
        site = create_site!()
        post = create_blog_post!(site_id: site.id)

        # Create ratings: 5, 4, 5, 3, 5 = avg 4.4, count 5
        create_post_rating!(post_id: post.id, rating: 5)
        create_post_rating!(post_id: post.id, rating: 4)
        create_post_rating!(post_id: post.id, rating: 5)
        create_post_rating!(post_id: post.id, rating: 3)
        create_post_rating!(post_id: post.id, rating: 5)

        loaded_post =
          Ash.load!(post, [:rating_average, :rating_count], tenant: site.id, authorize?: false)

        assert loaded_post.rating_count == 5
        # Average should be 4.4
        assert_in_delta loaded_post.rating_average, 4.4, 0.01
      end

      test "returns zero when no ratings exist" do
        site = create_site!()
        post = create_blog_post!(site_id: site.id)

        loaded_post =
          Ash.load!(post, [:rating_average, :rating_count], tenant: site.id, authorize?: false)

        assert loaded_post.rating_count == 0
        assert is_nil(loaded_post.rating_average)
      end

      test "calculates correct average for high number of ratings" do
        site = create_site!()
        post = create_blog_post!(site_id: site.id)

        # Simulate 2000 ratings with average 4.7
        # Create 1400 5-star, 400 4-star, 200 5-star (avg = 4.7)
        for _ <- 1..14 do
          create_post_rating!(post_id: post.id, rating: 5)
        end

        for _ <- 1..4 do
          create_post_rating!(post_id: post.id, rating: 4)
        end

        for _ <- 1..2 do
          create_post_rating!(post_id: post.id, rating: 5)
        end

        loaded_post =
          Ash.load!(post, [:rating_average, :rating_count], tenant: site.id, authorize?: false)

        assert loaded_post.rating_count == 20
        # Average should be approximately 4.8
        assert loaded_post.rating_average >= 4.8 and loaded_post.rating_average <= 5.0
      end
    end

    describe "calculation: comment_count" do
      test "returns correct comment count" do
        site = create_site!()
        post = create_blog_post!(site_id: site.id)

        # Create 5 comments
        for i <- 1..5 do
          create_comment!(post_id: post.id, content: "Comment #{i}")
        end

        loaded_post = Ash.load!(post, [:comment_count], tenant: site.id, authorize?: false)
        assert loaded_post.comment_count == 5
      end

      test "does not count archived comments" do
        site = create_site!()
        post = create_blog_post!(site_id: site.id)

        # Create 3 active comments
        for i <- 1..3 do
          create_comment!(post_id: post.id, content: "Active comment #{i}")
        end

        # Create 2 archived comments
        for i <- 1..2 do
          comment = create_comment!(post_id: post.id, content: "Archived comment #{i}")

          comment
          |> Ash.Changeset.for_destroy(:destroy, %{}, authorize?: false)
          |> Ash.destroy!()
        end

        loaded_post = Ash.load!(post, [:comment_count], tenant: site.id, authorize?: false)
        # Should only count the 3 active comments
        assert loaded_post.comment_count == 3
      end

      test "returns zero when no comments exist" do
        site = create_site!()
        post = create_blog_post!(site_id: site.id)

        loaded_post = Ash.load!(post, [:comment_count], tenant: site.id, authorize?: false)
        assert loaded_post.comment_count == 0
      end
    end

    describe "public_list action" do
      test "returns only published posts" do
        site = create_site!()

        # Create posts with different statuses
        published1 =
          create_blog_post!(site_id: site.id, title: "Published 1", status: :published)

        published2 =
          create_blog_post!(site_id: site.id, title: "Published 2", status: :published)

        _draft = create_blog_post!(site_id: site.id, title: "Draft", status: :draft)

        # Add extra time to ensure it's definitely in the future even after truncation
        future_time =
          DateTime.utc_now() |> DateTime.add(3700, :second) |> DateTime.truncate(:second)

        _scheduled =
          create_blog_post!(
            site_id: site.id,
            title: "Scheduled",
            status: :scheduled,
            scheduled_publish_at: future_time
          )

        result =
          BlogPost
          |> Ash.Query.for_read(:public_list, %{}, authorize?: false, tenant: site.id)
          |> Ash.read!(authorize?: false)

        assert length(result.results) == 2
        assert Enum.all?(result.results, &(&1.status == :published))

        result_ids = Enum.map(result.results, & &1.id) |> Enum.sort()
        expected_ids = [published1.id, published2.id] |> Enum.sort()
        assert result_ids == expected_ids
      end

      test "pagination works on public_list" do
        site = create_site!()

        # Create 25 published posts
        for i <- 1..25 do
          create_blog_post!(
            site_id: site.id,
            title: "Published Post #{i}",
            status: :published
          )
        end

        result =
          BlogPost
          |> Ash.Query.for_read(:public_list, %{}, authorize?: false, tenant: site.id)
          |> Ash.Query.page(limit: 10, count: true)
          |> Ash.read!(authorize?: false)

        assert length(result.results) == 10
        assert result.count == 25
      end

      test "returns empty list when no published posts exist" do
        site = create_site!()

        # Create only draft posts
        create_blog_post!(site_id: site.id, title: "Draft", status: :draft)

        result =
          BlogPost
          |> Ash.Query.for_read(:public_list, %{}, authorize?: false, tenant: site.id)
          |> Ash.read!(authorize?: false)

        assert result.results == []
      end

      test "respects tenant isolation" do
        site1 = create_site!()
        site2 = create_site!()

        # Create published posts on site1
        _post1 =
          create_blog_post!(site_id: site1.id, title: "Site 1 Post", status: :published)

        # Create published posts on site2
        _post2 =
          create_blog_post!(site_id: site2.id, title: "Site 2 Post", status: :published)

        # Query site1's published posts
        result =
          BlogPost
          |> Ash.Query.for_read(:public_list, %{}, authorize?: false, tenant: site1.id)
          |> Ash.read!(authorize?: false)

        assert length(result.results) == 1
        assert hd(result.results).site_id == site1.id
      end

      test "allows public access without authorization" do
        site = create_site!()

        create_blog_post!(site_id: site.id, title: "Public Post", status: :published)

        # Should succeed without actor or authorization
        result =
          BlogPost
          |> Ash.Query.for_read(:public_list, %{}, authorize?: true, tenant: site.id)
          |> Ash.read!()

        assert length(result.results) == 1
      end
    end

    describe "public_get action" do
      test "returns a published post by ID" do
        site = create_site!()

        post =
          create_blog_post!(site_id: site.id, title: "Published Post", status: :published)

        fetched_post = Ash.get!(BlogPost, post.id, action: :public_get, tenant: site.id)

        assert fetched_post.id == post.id
        assert fetched_post.title == "Published Post"
        assert fetched_post.status == :published
      end

      test "does not return draft posts" do
        site = create_site!()

        draft_post = create_blog_post!(site_id: site.id, title: "Draft", status: :draft)

        # Should raise NotFound because draft posts are filtered out
        assert_raise Ash.Error.Invalid, fn ->
          Ash.get!(BlogPost, draft_post.id,
            action: :public_get,
            tenant: site.id,
            authorize?: false
          )
        end
      end

      test "does not return scheduled posts" do
        site = create_site!()

        # Add extra time to ensure it's definitely in the future even after truncation
        future_time =
          DateTime.utc_now() |> DateTime.add(7300, :second) |> DateTime.truncate(:second)

        scheduled_post =
          create_blog_post!(
            site_id: site.id,
            title: "Scheduled",
            status: :scheduled,
            scheduled_publish_at: future_time
          )

        # Should raise NotFound because scheduled posts are filtered out
        assert_raise Ash.Error.Invalid, fn ->
          Ash.get!(BlogPost, scheduled_post.id,
            action: :public_get,
            tenant: site.id,
            authorize?: false
          )
        end
      end

      test "respects tenant isolation" do
        site1 = create_site!()
        site2 = create_site!()

        post =
          create_blog_post!(site_id: site1.id, title: "Site 1 Post", status: :published)

        # Try to get site1's post using site2's tenant
        assert_raise Ash.Error.Invalid, fn ->
          Ash.get!(BlogPost, post.id,
            action: :public_get,
            tenant: site2.id,
            authorize?: false
          )
        end
      end

      test "allows public access without authorization" do
        site = create_site!()

        post =
          create_blog_post!(site_id: site.id, title: "Public Post", status: :published)

        # Should succeed without actor or authorization
        fetched_post =
          Ash.get!(BlogPost, post.id, action: :public_get, authorize?: true, tenant: site.id)

        assert fetched_post.id == post.id
      end
    end

    describe "version management - get_with_versions" do
      test "gets blog post with paginated versions (tenant)" do
        site = create_site!()

        post =
          create_blog_post!(title: "Post 1", site_id: site.id, status: :draft)

        # Update to create versions
        post
        |> Ash.Changeset.for_update(:update, %{title: "Post 1 V1"},
          tenant: site.id,
          authorize?: false
        )
        |> Ash.update!()

        post
        |> Ash.Changeset.for_update(:update, %{title: "Post 1 V2"},
          tenant: site.id,
          authorize?: false
        )
        |> Ash.update!()

        result =
          BlogPost
          |> Ash.Query.for_read(:get_with_versions, %{versions_limit: 10}, tenant: site.id)
          |> Ash.Query.filter(id == ^post.id)
          |> Ash.read_one!(authorize?: false)

        assert result.id == post.id
        assert is_list(result.sorted_versions)
        assert length(result.sorted_versions) > 0
      end

      test "respects versions_limit argument" do
        site = create_site!()

        post =
          create_blog_post!(title: "Post 2", site_id: site.id, status: :draft)

        # Create multiple versions
        for i <- 1..5 do
          post
          |> Ash.Changeset.for_update(:update, %{title: "Post 2 V#{i}"},
            tenant: site.id,
            authorize?: false
          )
          |> Ash.update!()
        end

        result =
          BlogPost
          |> Ash.Query.for_read(:get_with_versions, %{versions_limit: 2}, tenant: site.id)
          |> Ash.Query.filter(id == ^post.id)
          |> Ash.read_one!(authorize?: false)

        assert length(result.sorted_versions) <= 2
      end
    end

    describe "version management - master_get_with_versions" do
      test "gets blog post with versions bypassing tenant (master)" do
        site = create_site!()

        post =
          create_blog_post!(title: "Post 3", site_id: site.id, status: :draft)

        # Update to create a version
        post
        |> Ash.Changeset.for_update(:update, %{title: "Post 3 Updated"},
          tenant: site.id,
          authorize?: false
        )
        |> Ash.update!()

        result =
          BlogPost
          |> Ash.Query.for_read(:master_get_with_versions, %{versions_limit: 10},
            authorize?: false
          )
          |> Ash.Query.filter(id == ^post.id)
          |> Ash.read_one!(authorize?: false)

        assert result.id == post.id
        assert is_list(result.sorted_versions)
      end
    end

    describe "version management - list_versions" do
      test "lists all versions for a blog post (tenant)" do
        site = create_site!()

        post =
          create_blog_post!(title: "Post 4", site_id: site.id, status: :draft)

        # Create versions
        post
        |> Ash.Changeset.for_update(:update, %{title: "Post 4 V1"},
          tenant: site.id,
          authorize?: false
        )
        |> Ash.update!()

        post
        |> Ash.Changeset.for_update(:update, %{title: "Post 4 V2"},
          tenant: site.id,
          authorize?: false
        )
        |> Ash.update!()

        result =
          BlogPost
          |> Ash.Query.for_read(:list_versions, %{post_id: post.id},
            tenant: site.id,
            authorize?: false
          )
          |> Ash.read!()

        posts = result.results
        assert length(posts) == 1

        first_post = List.first(posts)
        assert first_post.id == post.id
        assert is_list(first_post.sorted_versions)
        assert length(first_post.sorted_versions) > 0
      end

      test "returns error for post from different tenant" do
        site1 = create_site!()
        site2 = create_site!()

        post = create_blog_post!(site_id: site1.id, title: "Post 5", status: :draft)

        result =
          BlogPost
          |> Ash.Query.for_read(:list_versions, %{post_id: post.id},
            tenant: site2.id,
            authorize?: false
          )
          |> Ash.read()

        assert {:error, %Ash.Error.Invalid{}} = result
      end
    end

    describe "version management - master_list_versions" do
      test "lists all versions bypassing tenant (master)" do
        site = create_site!()

        post =
          create_blog_post!(title: "Post 6", site_id: site.id, status: :draft)

        # Create version
        post
        |> Ash.Changeset.for_update(:update, %{title: "Post 6 Updated"},
          tenant: site.id,
          authorize?: false
        )
        |> Ash.update!()

        result =
          BlogPost
          |> Ash.Query.for_read(:master_list_versions, %{post_id: post.id}, authorize?: false)
          |> Ash.read!(authorize?: false)

        posts = result.results
        assert length(posts) == 1

        first_post = List.first(posts)
        assert first_post.id == post.id
        assert is_list(first_post.sorted_versions)
      end
    end

    describe "version management - restore_version" do
      test "restores blog post to a previous version (tenant)" do
        site = create_site!()

        post =
          create_blog_post!(
            title: "Post 7",
            content: "Original content",
            site_id: site.id,
            status: :draft
          )

        # Update to create a version
        updated =
          post
          |> Ash.Changeset.for_update(
            :update,
            %{title: "Post 7 Updated", content: "Updated content"},
            tenant: site.id,
            authorize?: false
          )
          |> Ash.update!()

        # Get the first version
        versions =
          BlogPost.Version
          |> Ash.Query.for_read(:read_any)
          |> Ash.Query.filter(version_source_id: post.id)
          |> Ash.Query.sort(version_inserted_at: :asc)
          |> Ash.read!(authorize?: false)

        first_version = List.first(versions)
        assert not is_nil(first_version)

        # Restore to first version
        restored =
          updated
          |> Ash.Changeset.for_update(:restore_version, %{version_id: first_version.id},
            tenant: site.id,
            authorize?: false
          )
          |> Ash.update!()

        assert restored.title == "Post 7"
        assert restored.content == "Original content"
      end

      test "cannot restore version of archived post" do
        site = create_site!()

        post =
          create_blog_post!(title: "Post 8", site_id: site.id, status: :draft)

        # Create a version
        post
        |> Ash.Changeset.for_update(:update, %{title: "Post 8 Updated"},
          tenant: site.id,
          authorize?: false
        )
        |> Ash.update!()

        # Archive the post
        archived =
          post
          |> Ash.Changeset.for_destroy(:destroy, %{}, tenant: site.id, authorize?: false)
          |> Ash.destroy!(return_destroyed?: true)

        # Get a version
        version =
          BlogPost.Version
          |> Ash.Query.for_read(:read_any)
          |> Ash.Query.filter(version_source_id: post.id)
          |> Ash.Query.limit(1)
          |> Ash.read_one!(authorize?: false)

        # Try to restore archived post
        assert_raise Ash.Error.Invalid, fn ->
          archived
          |> Ash.Changeset.for_update(:restore_version, %{version_id: version.id},
            tenant: site.id,
            authorize?: false
          )
          |> Ash.update!()
        end
      end
    end

    describe "version management - master_restore_version" do
      test "restores blog post to a previous version (master)" do
        site = create_site!()

        post =
          create_blog_post!(title: "Post 9", site_id: site.id, status: :draft)

        # Update to create a version
        updated =
          post
          |> Ash.Changeset.for_update(:update, %{title: "Post 9 Updated"},
            tenant: site.id,
            authorize?: false
          )
          |> Ash.update!()

        # Get the first version
        version =
          BlogPost.Version
          |> Ash.Query.for_read(:read_any)
          |> Ash.Query.filter(version_source_id: post.id)
          |> Ash.Query.sort(version_inserted_at: :asc)
          |> Ash.Query.limit(1)
          |> Ash.read_one!(authorize?: false)

        # Restore using master action
        {:ok, restored} =
          updated
          |> Ash.Changeset.for_update(:master_restore_version, %{version_id: version.id},
            authorize?: false
          )
          |> Ash.update()

        assert restored.title == "Post 9"
      end

      test "returns error if version doesn't belong to post" do
        site = create_site!()

        post1 =
          create_blog_post!(title: "Post 10", site_id: site.id, status: :draft)

        post2 =
          create_blog_post!(title: "Post 11", site_id: site.id, status: :draft)

        # Create a version for post2
        post2
        |> Ash.Changeset.for_update(:update, %{title: "Post 11 Updated"},
          tenant: site.id,
          authorize?: false
        )
        |> Ash.update!()

        # Get version from post2
        version =
          BlogPost.Version
          |> Ash.Query.for_read(:read_any)
          |> Ash.Query.filter(version_source_id: post2.id)
          |> Ash.Query.limit(1)
          |> Ash.read_one!(authorize?: false)

        # Try to restore post1 with post2's version
        result =
          post1
          |> Ash.Changeset.for_update(:master_restore_version, %{version_id: version.id},
            authorize?: false
          )
          |> Ash.update()

        assert match?({:error, _}, result)
      end

      test "cannot restore archived post" do
        site = create_site!()

        post =
          create_blog_post!(title: "Post 12", site_id: site.id, status: :draft)

        # Create a version
        post
        |> Ash.Changeset.for_update(:update, %{title: "Post 12 Updated"},
          tenant: site.id,
          authorize?: false
        )
        |> Ash.update!()

        # Archive the post
        post
        |> Ash.Changeset.for_destroy(:destroy, %{}, tenant: site.id, authorize?: false)
        |> Ash.destroy!()

        # Get a version
        version =
          BlogPost.Version
          |> Ash.Query.for_read(:read_any)
          |> Ash.Query.filter(version_source_id: post.id)
          |> Ash.Query.limit(1)
          |> Ash.read_one!(authorize?: false)

        # Try to restore - need to fetch the archived post first
        {:ok, archived_post} =
          Ash.get(BlogPost, post.id, action: :master_get_archived, authorize?: false)

        result =
          archived_post
          |> Ash.Changeset.for_update(:master_restore_version, %{version_id: version.id},
            authorize?: false
          )
          |> Ash.update()

        assert match?({:error, _}, result)
      end
    end

    describe "version management - preview_version" do
      test "previews a version without restoring (tenant)" do
        site = create_site!()

        post =
          create_blog_post!(
            title: "Post 13",
            content: "Original content",
            site_id: site.id,
            status: :draft
          )

        # Update to create a version
        post
        |> Ash.Changeset.for_update(
          :update,
          %{title: "Post 13 Updated", content: "Updated content"},
          tenant: site.id,
          authorize?: false
        )
        |> Ash.update!()

        # Get the first version
        version =
          BlogPost.Version
          |> Ash.Query.for_read(:read_any)
          |> Ash.Query.filter(version_source_id: post.id)
          |> Ash.Query.sort(version_inserted_at: :asc)
          |> Ash.Query.limit(1)
          |> Ash.read_one!(authorize?: false)

        # Preview the version
        {:ok, preview} =
          BlogPost
          |> Ash.ActionInput.for_action(
            :preview_version,
            %{post_id: post.id, version_id: version.id},
            tenant: site.id
          )
          |> Ash.run_action(authorize?: false)

        assert preview.title == "Post 13"
        assert preview.content == "Original content"

        # Verify original is unchanged
        current = Ash.get!(BlogPost, post.id, tenant: site.id, authorize?: false)
        assert current.title == "Post 13 Updated"
      end

      test "returns error for version from wrong post" do
        site = create_site!()
        post1 = create_blog_post!(site_id: site.id, title: "Post 14", status: :draft)
        post2 = create_blog_post!(site_id: site.id, title: "Post 15", status: :draft)

        # Create version for post2
        post2
        |> Ash.Changeset.for_update(:update, %{title: "Post 15 Updated"},
          tenant: site.id,
          authorize?: false
        )
        |> Ash.update!()

        # Get version from post2
        version =
          BlogPost.Version
          |> Ash.Query.for_read(:read_any)
          |> Ash.Query.filter(version_source_id: post2.id)
          |> Ash.Query.limit(1)
          |> Ash.read_one!(authorize?: false)

        # Try to preview with post1
        result =
          BlogPost
          |> Ash.ActionInput.for_action(
            :preview_version,
            %{post_id: post1.id, version_id: version.id},
            tenant: site.id
          )
          |> Ash.run_action(authorize?: false)

        assert match?({:error, _}, result)
      end
    end

    describe "version management - master_preview_version" do
      test "previews a version without restoring (master)" do
        site = create_site!()

        post =
          create_blog_post!(title: "Post 16", site_id: site.id, status: :draft)

        # Update to create a version
        post
        |> Ash.Changeset.for_update(:update, %{title: "Post 16 Updated"},
          tenant: site.id,
          authorize?: false
        )
        |> Ash.update!()

        # Get the first version
        version =
          BlogPost.Version
          |> Ash.Query.for_read(:read_any)
          |> Ash.Query.filter(version_source_id: post.id)
          |> Ash.Query.sort(version_inserted_at: :asc)
          |> Ash.Query.limit(1)
          |> Ash.read_one!(authorize?: false)

        # Preview using master action
        {:ok, preview} =
          BlogPost
          |> Ash.ActionInput.for_action(
            :master_preview_version,
            %{
              post_id: post.id,
              version_id: version.id
            },
            authorize?: false
          )
          |> Ash.run_action(authorize?: false)

        assert preview.title == "Post 16"
      end
    end

    describe "version calculations" do
      test "version_count returns correct count" do
        site = create_site!()

        post =
          create_blog_post!(title: "Post 17", site_id: site.id, status: :draft)

        # Create some versions
        post
        |> Ash.Changeset.for_update(:update, %{title: "Post 17 V1"},
          tenant: site.id,
          authorize?: false
        )
        |> Ash.update!()

        post
        |> Ash.Changeset.for_update(:update, %{title: "Post 17 V2"},
          tenant: site.id,
          authorize?: false
        )
        |> Ash.update!()

        loaded =
          BlogPost
          |> Ash.get!(post.id, tenant: site.id, authorize?: false)
          |> Ash.load!(:version_count, authorize?: false)

        assert loaded.version_count >= 2
      end

      test "latest_version returns most recent version" do
        site = create_site!()

        post =
          create_blog_post!(title: "Post 18", site_id: site.id, status: :draft)

        # Create versions
        post
        |> Ash.Changeset.for_update(:update, %{title: "Post 18 V1"},
          tenant: site.id,
          authorize?: false
        )
        |> Ash.update!()

        post
        |> Ash.Changeset.for_update(:update, %{title: "Post 18 V2"},
          tenant: site.id,
          authorize?: false
        )
        |> Ash.update!()

        loaded =
          BlogPost
          |> Ash.get!(post.id, tenant: site.id, authorize?: false)
          |> Ash.load!(:latest_version, authorize?: false)

        assert not is_nil(loaded.latest_version)
        assert is_struct(loaded.latest_version, BlogPost.Version)
      end

      test "recent_versions returns up to 10 versions" do
        site = create_site!()

        post =
          create_blog_post!(title: "Post 19", site_id: site.id, status: :draft)

        # Create multiple versions
        for i <- 1..5 do
          post
          |> Ash.Changeset.for_update(:update, %{title: "Post 19 V#{i}"},
            tenant: site.id,
            authorize?: false
          )
          |> Ash.update!()
        end

        loaded =
          BlogPost
          |> Ash.get!(post.id, tenant: site.id, authorize?: false)
          |> Ash.load!(:recent_versions, authorize?: false)

        assert is_list(loaded.recent_versions)
        assert length(loaded.recent_versions) <= 10
        assert length(loaded.recent_versions) >= 5
      end
    end
  end
end
