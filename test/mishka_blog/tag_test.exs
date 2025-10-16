defmodule MishkaBlog.Test.TagTest do
  @moduledoc """
  Comprehensive tests for MishkaBlog.Tag resource.
  """
  use MishkaBlog.DataCase, async: false

  if Code.ensure_loaded?(MishkaBlog) do
    alias MishkaBlog.Tag
    require Ash.Query

    describe "resource configuration" do
      test "uses correct table name" do
        assert AshPostgres.DataLayer.Info.table(Tag) == "mishka_blog_tags"
      end

      test "uses UUID v7 for primary keys" do
        tag = create_blog_tag!()
        assert is_binary(tag.id)
        assert String.length(tag.id) == 36
      end

      test "is always site-specific (not global)" do
        multitenancy_config = Ash.Resource.Info.multitenancy_strategy(Tag)
        assert multitenancy_config == :attribute
        assert Ash.Resource.Info.multitenancy_global?(Tag) == false
      end
    end

    describe "create action" do
      test "creates tag with valid attributes" do
        site = create_site!()

        tag =
          Tag
          |> Ash.Changeset.for_create(
            :create,
            %{
              name: "Programming",
              slug: "programming",
              language: "en"
            },
            tenant: site.id,
            authorize?: false
          )
          |> Ash.create!()

        assert tag.name == "Programming"
        assert tag.slug == "programming"
        assert tag.language == "en"
        assert tag.site_id == site.id
        assert tag.language_group_id != nil
      end

      test "auto-generates slug from input" do
        site = create_site!()

        tag =
          Tag
          |> Ash.Changeset.for_create(
            :create,
            %{
              name: "Elixir Programming",
              slug: "Elixir Programming",
              language: "en"
            },
            tenant: site.id,
            authorize?: false
          )
          |> Ash.create!()

        # Slugify transforms to lowercase and replaces spaces with dashes
        # but keeps certain punctuation based on ignore list
        assert tag.slug == "elixir-programming"
      end

      test "requires name, slug, and language" do
        site = create_site!()

        assert_raise Ash.Error.Invalid, fn ->
          Tag
          |> Ash.Changeset.for_create(:create, %{}, tenant: site.id, authorize?: false)
          |> Ash.create!()
        end
      end

      test "auto-assigns site_id from tenant context" do
        site = create_site!()

        tag =
          Tag
          |> Ash.Changeset.for_create(
            :create,
            %{name: "Test", slug: "test", language: "en"},
            tenant: site.id,
            authorize?: false
          )
          |> Ash.create!()

        assert tag.site_id == site.id
      end

      test "auto-assigns language_group_id" do
        site = create_site!()

        tag =
          Tag
          |> Ash.Changeset.for_create(
            :create,
            %{name: "Test", slug: "test", language: "en"},
            tenant: site.id,
            authorize?: false
          )
          |> Ash.create!()

        assert tag.language_group_id != nil
      end

      test "accepts optional description" do
        site = create_site!()

        tag =
          Tag
          |> Ash.Changeset.for_create(
            :create,
            %{
              name: "Tech",
              slug: "tech",
              language: "en",
              description: "Technology related topics"
            },
            tenant: site.id,
            authorize?: false
          )
          |> Ash.create!()

        assert tag.description == "Technology related topics"
      end

      test "accepts parent_tag_id for hierarchical tags" do
        site = create_site!()
        parent_tag = create_blog_tag!(name: "Programming", site_id: site.id)

        child_tag =
          Tag
          |> Ash.Changeset.for_create(
            :create,
            %{
              name: "Elixir",
              slug: "elixir",
              language: "en",
              parent_tag_id: parent_tag.id
            },
            tenant: site.id,
            authorize?: false
          )
          |> Ash.create!()

        assert child_tag.parent_tag_id == parent_tag.id
      end
    end

    describe "master_create action" do
      test "creates tag with explicit site_id" do
        site = create_site!()

        tag =
          Tag
          |> Ash.Changeset.for_create(
            :master_create,
            %{
              name: "Master Tag",
              slug: "master-tag",
              language: "en",
              site_id: site.id
            },
            authorize?: false
          )
          |> Ash.create!()

        assert tag.name == "Master Tag"
        assert tag.site_id == site.id
      end

      test "requires explicit site_id" do
        assert_raise Ash.Error.Invalid, fn ->
          Tag
          |> Ash.Changeset.for_create(
            :master_create,
            %{name: "Test", slug: "test", language: "en"},
            authorize?: false
          )
          |> Ash.create!()
        end
      end
    end

    describe "update action" do
      test "updates tag attributes" do
        site = create_site!()
        tag = create_blog_tag!(name: "Original", site_id: site.id)

        updated =
          tag
          |> Ash.Changeset.for_update(
            :update,
            %{name: "Updated", description: "New description"},
            tenant: site.id,
            authorize?: false
          )
          |> Ash.update!()

        assert updated.name == "Updated"
        assert updated.description == "New description"
      end

      test "prevents updating archived tag" do
        site = create_site!()
        tag = create_blog_tag!(site_id: site.id)

        # Archive the tag
        archived =
          tag
          |> Ash.Changeset.for_destroy(:destroy, %{}, tenant: site.id, authorize?: false)
          |> Ash.destroy!(return_destroyed?: true)

        # Try to update archived tag
        assert_raise Ash.Error.Invalid, fn ->
          archived
          |> Ash.Changeset.for_update(
            :update,
            %{name: "Should Fail"},
            tenant: site.id,
            authorize?: false
          )
          |> Ash.update!()
        end
      end

      test "prevents tag from being its own parent" do
        site = create_site!()
        tag = create_blog_tag!(site_id: site.id)

        assert_raise Ash.Error.Invalid, fn ->
          tag
          |> Ash.Changeset.for_update(
            :update,
            %{parent_tag_id: tag.id},
            tenant: site.id,
            authorize?: false
          )
          |> Ash.update!()
        end
      end

      test "prevents site_id changes" do
        site1 = create_site!()
        tag = create_blog_tag!(site_id: site1.id)

        # site_id is not in accepted fields for update
        updated =
          tag
          |> Ash.Changeset.for_update(
            :update,
            %{name: "Updated"},
            tenant: site1.id,
            authorize?: false
          )
          |> Ash.update!()

        # site_id should remain unchanged
        assert updated.site_id == site1.id
      end
    end

    describe "master_update action" do
      test "updates tag for master users" do
        site = create_site!()
        tag = create_blog_tag!(name: "Original", site_id: site.id)

        {:ok, updated} =
          tag
          |> Ash.Changeset.for_update(
            :master_update,
            %{name: "Master Updated"},
            authorize?: false
          )
          |> Ash.update()

        assert updated.name == "Master Updated"
      end
    end

    describe "read actions" do
      test "tenant read only shows tags for that tenant" do
        site1 = create_site!()
        site2 = create_site!()

        tag1 = create_blog_tag!(name: "Site 1 Tag", site_id: site1.id)
        _tag2 = create_blog_tag!(name: "Site 2 Tag", site_id: site2.id)

        # Query as site1 tenant
        tags =
          Tag
          |> Ash.Query.set_tenant(site1.id)
          |> Ash.read!(authorize?: false)

        assert length(tags) == 1
        assert Enum.at(tags, 0).id == tag1.id
      end

      test "master_read shows all tags system-wide" do
        site1 = create_site!()
        site2 = create_site!()

        _tag1 = create_blog_tag!(name: "Site 1", site_id: site1.id)
        _tag2 = create_blog_tag!(name: "Site 2", site_id: site2.id)

        result =
          Tag
          |> Ash.Query.for_read(:master_read, %{}, authorize?: false)
          |> Ash.read!(page: [limit: 100])

        tags = result.results
        assert length(tags) >= 2
      end

      test "master_get retrieves tag by ID bypassing tenant" do
        site = create_site!()
        tag = create_blog_tag!(site_id: site.id)

        fetched = Ash.get!(Tag, tag.id, action: :master_get, authorize?: false)

        assert fetched.id == tag.id
      end
    end

    describe "public_list action" do
      test "lists all tags with pagination" do
        site = create_site!()

        tag1 = create_blog_tag!(name: "Tag 1", site_id: site.id)
        tag2 = create_blog_tag!(name: "Tag 2", site_id: site.id)

        result =
          Tag
          |> Ash.Query.for_read(:public_list, %{}, tenant: site.id, authorize?: false)
          |> Ash.read!()

        tags = result.results
        tag_ids = Enum.map(tags, & &1.id) |> Enum.sort()

        assert length(tags) == 2
        assert Enum.sort([tag1.id, tag2.id]) == tag_ids
      end

      test "supports pagination" do
        site = create_site!()

        # Create 25 tags
        _tags =
          Enum.map(1..25, fn i ->
            create_blog_tag!(name: "Tag #{i}", site_id: site.id)
          end)

        result =
          Tag
          |> Ash.Query.for_read(:public_list, %{}, tenant: site.id, authorize?: false)
          |> Ash.read!()

        assert length(result.results) == 20

        # Query second page
        result_page2 =
          Tag
          |> Ash.Query.for_read(:public_list, %{}, tenant: site.id, authorize?: false)
          |> Ash.Query.page(offset: 20, limit: 10)
          |> Ash.read!()

        assert length(result_page2.results) == 5
      end

      test "respects tenant context" do
        site1 = create_site!()
        site2 = create_site!()

        site1_tag = create_blog_tag!(name: "Site 1", site_id: site1.id)
        _site2_tag = create_blog_tag!(name: "Site 2", site_id: site2.id)

        result =
          Tag
          |> Ash.Query.for_read(:public_list, %{}, tenant: site1.id, authorize?: false)
          |> Ash.read!()

        tags = result.results

        assert length(tags) == 1
        assert Enum.at(tags, 0).id == site1_tag.id
      end

      test "allows public access without authorization" do
        site = create_site!()
        _tag = create_blog_tag!(name: "Public", site_id: site.id)

        result =
          Tag
          |> Ash.Query.for_read(:public_list, %{}, tenant: site.id)
          |> Ash.read!()

        assert length(result.results) == 1
      end
    end

    describe "public_get action" do
      test "gets a single tag without authentication" do
        site = create_site!()
        tag = create_blog_tag!(name: "Public Tag", site_id: site.id)

        fetched =
          Ash.get!(
            Tag,
            tag.id,
            action: :public_get,
            tenant: site.id,
            authorize?: false
          )

        assert fetched.id == tag.id
        assert fetched.name == "Public Tag"
      end

      test "respects tenant context" do
        site1 = create_site!()
        site2 = create_site!()

        tag = create_blog_tag!(name: "Site 1", site_id: site1.id)

        # Should find in correct tenant
        fetched =
          Ash.get!(
            Tag,
            tag.id,
            action: :public_get,
            tenant: site1.id,
            authorize?: false
          )

        assert fetched.id == tag.id

        # Should not find in wrong tenant
        result =
          Ash.get(
            Tag,
            tag.id,
            action: :public_get,
            tenant: site2.id,
            authorize?: false
          )

        assert match?({:error, _}, result)
      end

      test "allows public access without authorization" do
        site = create_site!()
        tag = create_blog_tag!(name: "Public", site_id: site.id)

        fetched =
          Ash.get!(
            Tag,
            tag.id,
            action: :public_get,
            tenant: site.id
          )

        assert fetched.id == tag.id
      end
    end

    describe "language_variants action" do
      test "retrieves all language variants of a tag" do
        site = create_site!()

        # Create English tag
        en_tag = create_blog_tag!(name: "Technology", language: "en", site_id: site.id)
        language_group_id = en_tag.language_group_id

        # Create French variant
        fr_tag =
          Tag
          |> Ash.Changeset.for_create(
            :create,
            %{
              name: "Technologie",
              slug: "technologie",
              language: "fr",
              language_group_id: language_group_id
            },
            tenant: site.id,
            authorize?: false
          )
          |> Ash.create!()

        # Query language variants
        variants =
          Tag
          |> Ash.Query.for_read(
            :language_variants,
            %{language_group_id: language_group_id},
            tenant: site.id,
            authorize?: false
          )
          |> Ash.read!()

        variant_ids = Enum.map(variants, & &1.id) |> Enum.sort()
        assert length(variants) == 2
        assert Enum.sort([en_tag.id, fr_tag.id]) == variant_ids
      end
    end

    describe "archive/unarchive actions" do
      test "archived action lists only archived tags" do
        site = create_site!()
        active_tag = create_blog_tag!(name: "Active", site_id: site.id)

        archived_tag =
          create_blog_tag!(name: "To Archive", site_id: site.id)
          |> Ash.Changeset.for_destroy(:destroy, %{}, tenant: site.id, authorize?: false)
          |> Ash.destroy!(return_destroyed?: true)

        result =
          Tag
          |> Ash.Query.for_read(:archived, %{}, tenant: site.id, authorize?: false)
          |> Ash.read!()

        archived_list = result.results
        archived_ids = Enum.map(archived_list, & &1.id)
        assert archived_tag.id in archived_ids
        refute active_tag.id in archived_ids
      end

      test "get_archived retrieves single archived tag" do
        site = create_site!()

        tag =
          create_blog_tag!(site_id: site.id)
          |> Ash.Changeset.for_destroy(:destroy, %{}, tenant: site.id, authorize?: false)
          |> Ash.destroy!(return_destroyed?: true)

        fetched =
          Ash.get!(
            Tag,
            tag.id,
            action: :get_archived,
            tenant: site.id,
            authorize?: false
          )

        assert fetched.id == tag.id
        assert fetched.archived_at != nil
      end

      test "unarchive restores tag" do
        site = create_site!()

        tag =
          create_blog_tag!(site_id: site.id)
          |> Ash.Changeset.for_destroy(:destroy, %{}, tenant: site.id, authorize?: false)
          |> Ash.destroy!(return_destroyed?: true)

        unarchived =
          tag
          |> Ash.Changeset.for_update(:unarchive, %{}, tenant: site.id, authorize?: false)
          |> Ash.update!()

        assert unarchived.archived_at == nil
      end

      test "master_unarchive restores tag" do
        site = create_site!()

        tag =
          create_blog_tag!(site_id: site.id)
          |> Ash.Changeset.for_destroy(:destroy, %{}, tenant: site.id, authorize?: false)
          |> Ash.destroy!(return_destroyed?: true)

        {:ok, unarchived} =
          tag
          |> Ash.Changeset.for_update(:master_unarchive, %{}, authorize?: false)
          |> Ash.update()

        assert unarchived.archived_at == nil
      end

      test "prevents archiving already archived tag" do
        site = create_site!()

        tag =
          create_blog_tag!(site_id: site.id)
          |> Ash.Changeset.for_destroy(:destroy, %{}, tenant: site.id, authorize?: false)
          |> Ash.destroy!(return_destroyed?: true)

        assert_raise Ash.Error.Invalid, fn ->
          tag
          |> Ash.Changeset.for_destroy(:destroy, %{}, tenant: site.id, authorize?: false)
          |> Ash.destroy!()
        end
      end

      test "prevents unarchiving non-archived tag" do
        site = create_site!()
        tag = create_blog_tag!(site_id: site.id)

        {:error, error} =
          tag
          |> Ash.Changeset.for_update(:master_unarchive, %{}, authorize?: false)
          |> Ash.update()

        assert %Ash.Error.Invalid{} = error
      end
    end

    describe "permanent_destroy action" do
      test "permanently deletes tag and cannot be recovered" do
        site = create_site!()
        tag = create_blog_tag!(site_id: site.id)
        tag_id = tag.id

        tag
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
            Tag,
            tag_id,
            action: :master_get,
            authorize?: false
          )

        assert match?({:error, _}, result)
      end

      test "master_permanent_destroy permanently deletes tag" do
        site = create_site!()
        tag = create_blog_tag!(site_id: site.id)
        tag_id = tag.id

        :ok =
          tag
          |> Ash.Changeset.for_destroy(:master_permanent_destroy, %{}, authorize?: false)
          |> Ash.destroy()

        result =
          Ash.get(
            Tag,
            tag_id,
            action: :master_get,
            authorize?: false
          )

        assert match?({:error, _}, result)
      end
    end

    describe "hierarchical relationships" do
      test "parent-child relationship works" do
        site = create_site!()
        parent = create_blog_tag!(name: "Programming", site_id: site.id)

        child =
          Tag
          |> Ash.Changeset.for_create(
            :create,
            %{
              name: "Elixir",
              slug: "elixir",
              language: "en",
              parent_tag_id: parent.id
            },
            tenant: site.id,
            authorize?: false
          )
          |> Ash.create!()

        assert child.parent_tag_id == parent.id

        # Load child tags
        parent_with_children = Ash.load!(parent, :child_tags, authorize?: false, tenant: site.id)
        assert length(parent_with_children.child_tags) == 1
        assert Enum.at(parent_with_children.child_tags, 0).id == child.id
      end
    end

    describe "post relationship management" do
      test "assign_posts action exists and accepts post_ids" do
        site = create_site!()
        tag = create_blog_tag!(site_id: site.id)

        # Test that the action accepts the argument structure
        # Note: Actual post management would require valid post IDs in same tenant
        changeset =
          tag
          |> Ash.Changeset.for_update(
            :assign_posts,
            %{post_ids: []},
            tenant: site.id,
            authorize?: false
          )

        assert changeset.valid?
      end

      test "add_post action exists and accepts post_id" do
        site = create_site!()
        tag = create_blog_tag!(site_id: site.id)
        post = create_blog_post!(site_id: site.id, status: :published)

        # Note: This test verifies the action structure
        # Full integration requires matching tenant contexts
        changeset =
          tag
          |> Ash.Changeset.for_update(
            :add_post,
            %{post_id: post.id},
            tenant: site.id,
            authorize?: false
          )

        # Changeset should be valid and relationship should be configured
        assert changeset.valid?
        assert changeset.relationships[:tenant_posts] != nil
      end

      test "remove_post action exists and accepts post_id" do
        site = create_site!()
        tag = create_blog_tag!(site_id: site.id)
        post = create_blog_post!(site_id: site.id, status: :published)

        # Test that the action structure is correct
        changeset =
          tag
          |> Ash.Changeset.for_update(
            :remove_post,
            %{post_id: post.id},
            tenant: site.id,
            authorize?: false
          )

        # Verify action is properly configured
        assert changeset.action.name == :remove_post
      end
    end

    describe "database constraints" do
      test "enforces slug length constraints" do
        site = create_site!()

        # Empty slug should fail
        assert_raise Ash.Error.Invalid, fn ->
          create_blog_tag!(slug: "", site_id: site.id)
        end

        # Slug too long (> 255) should fail
        long_slug = String.duplicate("a", 256)

        assert_raise Ash.Error.Invalid, fn ->
          create_blog_tag!(slug: long_slug, site_id: site.id)
        end
      end

      test "enforces name length constraints" do
        site = create_site!()

        # Empty name should fail
        assert_raise Ash.Error.Invalid, fn ->
          Tag
          |> Ash.Changeset.for_create(
            :create,
            %{name: "", slug: "test", language: "en"},
            tenant: site.id,
            authorize?: false
          )
          |> Ash.create!()
        end
      end
    end

    describe "identities" do
      test "unique_slug_per_site prevents duplicate slugs within a site" do
        site = create_site!()
        _tag1 = create_blog_tag!(slug: "unique-slug", site_id: site.id)

        assert_raise Ash.Error.Invalid, fn ->
          create_blog_tag!(slug: "unique-slug", site_id: site.id)
        end
      end

      test "allows same slug across different sites" do
        site1 = create_site!()
        site2 = create_site!()

        tag1 = create_blog_tag!(slug: "same-slug", site_id: site1.id)
        tag2 = create_blog_tag!(slug: "same-slug", site_id: site2.id)

        assert tag1.slug == tag2.slug
        assert tag1.site_id != tag2.site_id
      end

      test "unique_language_per_group prevents duplicate languages in group" do
        site = create_site!()
        tag1 = create_blog_tag!(language: "en", site_id: site.id)
        language_group_id = tag1.language_group_id

        # Same language in same group should fail (raises Invalid, not Unknown)
        assert_raise Ash.Error.Invalid, fn ->
          Tag
          |> Ash.Changeset.for_create(
            :create,
            %{
              name: "Another",
              slug: "another",
              language: "en",
              language_group_id: language_group_id
            },
            tenant: site.id,
            authorize?: false
          )
          |> Ash.create!()
        end
      end
    end

    describe "relationships" do
      test "belongs_to site" do
        site = create_site!()
        tag = create_blog_tag!(site_id: site.id)

        tag_with_site = Ash.load!(tag, :site, authorize?: false, tenant: site.id)

        assert tag_with_site.site.id == site.id
        assert tag_with_site.site.host == site.host
      end
    end

    describe "JSON API configuration" do
      test "has correct JSON API type" do
        json_api_type = AshJsonApi.Resource.Info.type(Tag)
        assert json_api_type == "tag"
      end
    end

    describe "version management - get_with_versions" do
      test "gets tag with paginated versions (tenant)" do
        site = create_site!()

        tag =
          create_blog_tag!(name: "TAG1", site_id: site.id)

        # Update to create versions
        tag
        |> Ash.Changeset.for_update(:update, %{name: "TAG1V1"},
          tenant: site.id,
          authorize?: false
        )
        |> Ash.update!()

        tag
        |> Ash.Changeset.for_update(:update, %{name: "TAG1V2"},
          tenant: site.id,
          authorize?: false
        )
        |> Ash.update!()

        result =
          Tag
          |> Ash.Query.for_read(:get_with_versions, %{versions_limit: 10}, tenant: site.id)
          |> Ash.Query.filter(id == ^tag.id)
          |> Ash.read_one!(authorize?: false)

        assert result.id == tag.id
        assert is_list(result.sorted_versions)
        assert length(result.sorted_versions) > 0
      end

      test "respects versions_limit argument" do
        site = create_site!()

        tag =
          create_blog_tag!(name: "TAG2", site_id: site.id)

        # Create multiple versions
        for i <- 1..5 do
          tag
          |> Ash.Changeset.for_update(:update, %{name: "TAG2V#{i}"},
            tenant: site.id,
            authorize?: false
          )
          |> Ash.update!()
        end

        result =
          Tag
          |> Ash.Query.for_read(:get_with_versions, %{versions_limit: 2}, tenant: site.id)
          |> Ash.Query.filter(id == ^tag.id)
          |> Ash.read_one!(authorize?: false)

        assert length(result.sorted_versions) <= 2
      end
    end

    describe "version management - master_get_with_versions" do
      test "gets tag with versions bypassing tenant (master)" do
        site = create_site!()

        tag =
          create_blog_tag!(name: "TAG3", site_id: site.id)

        # Update to create a version
        tag
        |> Ash.Changeset.for_update(:update, %{name: "TAG3UPDATED"},
          tenant: site.id,
          authorize?: false
        )
        |> Ash.update!()

        result =
          Tag
          |> Ash.Query.for_read(:master_get_with_versions, %{versions_limit: 10},
            authorize?: false
          )
          |> Ash.Query.filter(id == ^tag.id)
          |> Ash.read_one!(authorize?: false)

        assert result.id == tag.id
        assert is_list(result.sorted_versions)
        assert length(result.sorted_versions) > 0
      end
    end

    describe "version management - list_versions" do
      test "lists all versions for a tag (tenant)" do
        site = create_site!()

        tag =
          create_blog_tag!(name: "TAG4", site_id: site.id)

        # Create versions
        tag
        |> Ash.Changeset.for_update(:update, %{name: "TAG4V1"},
          tenant: site.id,
          authorize?: false
        )
        |> Ash.update!()

        tag
        |> Ash.Changeset.for_update(:update, %{name: "TAG4V2"},
          tenant: site.id,
          authorize?: false
        )
        |> Ash.update!()

        result =
          Tag
          |> Ash.Query.for_read(:list_versions, %{tag_id: tag.id},
            tenant: site.id,
            authorize?: false
          )
          |> Ash.read!()

        tags = result.results
        assert length(tags) == 1

        first_tag = List.first(tags)
        assert first_tag.id == tag.id
        assert is_list(first_tag.sorted_versions)
        assert length(first_tag.sorted_versions) > 0
      end

      test "returns error for tag from different tenant" do
        site1 = create_site!()
        site2 = create_site!()

        tag = create_blog_tag!(site_id: site1.id)

        # Should return error when trying to access tag from different tenant
        result =
          Tag
          |> Ash.Query.for_read(:list_versions, %{tag_id: tag.id},
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

        tag =
          create_blog_tag!(name: "TAG5", site_id: site.id)

        # Create version
        tag
        |> Ash.Changeset.for_update(:update, %{name: "TAG5UPDATED"},
          tenant: site.id,
          authorize?: false
        )
        |> Ash.update!()

        result =
          Tag
          |> Ash.Query.for_read(:master_list_versions, %{tag_id: tag.id}, authorize?: false)
          |> Ash.read!(authorize?: false)

        tags = result.results
        assert length(tags) == 1

        first_tag = List.first(tags)
        assert first_tag.id == tag.id
        assert is_list(first_tag.sorted_versions)
      end
    end

    describe "version management - restore_version" do
      test "restores tag to a previous version (tenant)" do
        site = create_site!()

        tag =
          create_blog_tag!(
            name: "TAG6",
            description: "Original desc",
            site_id: site.id
          )

        # Update to create a version
        updated =
          tag
          |> Ash.Changeset.for_update(
            :update,
            %{name: "TAG6UPDATED", description: "Updated desc"},
            tenant: site.id,
            authorize?: false
          )
          |> Ash.update!()

        # Get the first version
        versions =
          Tag.Version
          |> Ash.Query.for_read(:read_any, %{}, authorize?: false)
          |> Ash.Query.filter(version_source_id == ^tag.id)
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

        assert restored.name == "TAG6"
        assert restored.description == "Original desc"
      end

      test "cannot restore version of archived tag" do
        site = create_site!()

        tag =
          create_blog_tag!(name: "TAG7", site_id: site.id)

        # Create a version
        tag
        |> Ash.Changeset.for_update(:update, %{name: "TAG7UPDATED"},
          tenant: site.id,
          authorize?: false
        )
        |> Ash.update!()

        # Archive the tag
        archived =
          tag
          |> Ash.Changeset.for_destroy(:destroy, %{}, tenant: site.id, authorize?: false)
          |> Ash.destroy!(return_destroyed?: true)

        # Get a version
        version =
          Tag.Version
          |> Ash.Query.for_read(:read_any, %{}, authorize?: false)
          |> Ash.Query.filter(version_source_id == ^tag.id)
          |> Ash.Query.limit(1)
          |> Ash.read_one!(authorize?: false)

        # Try to restore archived tag
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
      test "restores tag to a previous version (master)" do
        site = create_site!()

        tag =
          create_blog_tag!(name: "TAG8", site_id: site.id)

        # Update to create a version
        updated =
          tag
          |> Ash.Changeset.for_update(:update, %{name: "TAG8UPDATED"},
            tenant: site.id,
            authorize?: false
          )
          |> Ash.update!()

        # Get the first version
        version =
          Tag.Version
          |> Ash.Query.for_read(:read_any, %{}, authorize?: false)
          |> Ash.Query.filter(version_source_id == ^tag.id)
          |> Ash.Query.sort(version_inserted_at: :asc)
          |> Ash.Query.limit(1)
          |> Ash.read_one!(authorize?: false)

        # Restore using master action
        {:ok, restored} =
          updated
          |> Ash.Changeset.for_update(
            :master_restore_version,
            %{
              version_id: version.id
            },
            authorize?: false
          )
          |> Ash.update()

        assert restored.name == "TAG8"
      end

      test "returns error if version doesn't belong to tag" do
        site = create_site!()

        tag1 =
          create_blog_tag!(name: "TAG9", site_id: site.id)

        tag2 =
          create_blog_tag!(name: "TAG10", site_id: site.id)

        # Create a version for tag2
        tag2
        |> Ash.Changeset.for_update(:update, %{name: "TAG10UPDATED"},
          tenant: site.id,
          authorize?: false
        )
        |> Ash.update!()

        # Get version from tag2
        version =
          Tag.Version
          |> Ash.Query.for_read(:read_any, %{}, authorize?: false)
          |> Ash.Query.filter(version_source_id == ^tag2.id)
          |> Ash.Query.limit(1)
          |> Ash.read_one!(authorize?: false)

        # Try to restore tag1 with tag2's version
        result =
          tag1
          |> Ash.Changeset.for_update(
            :master_restore_version,
            %{
              version_id: version.id
            },
            authorize?: false
          )
          |> Ash.update()

        assert match?({:error, _}, result)
      end

      test "cannot restore archived tag" do
        site = create_site!()

        tag =
          create_blog_tag!(name: "TAG11", site_id: site.id)

        # Create a version
        tag
        |> Ash.Changeset.for_update(:update, %{name: "TAG11UPDATED"},
          tenant: site.id,
          authorize?: false
        )
        |> Ash.update!()

        # Archive the tag
        tag
        |> Ash.Changeset.for_destroy(:destroy, %{}, tenant: site.id, authorize?: false)
        |> Ash.destroy!()

        # Fetch the archived tag (with archived_at set)
        archived_tag =
          Ash.get!(Tag, tag.id, action: :master_get_archived, authorize?: false)

        # Get a version
        version =
          Tag.Version
          |> Ash.Query.for_read(:read_any, %{}, authorize?: false)
          |> Ash.Query.filter(version_source_id == ^tag.id)
          |> Ash.Query.limit(1)
          |> Ash.read_one!(authorize?: false)

        # Try to restore - should fail because tag is archived
        result =
          archived_tag
          |> Ash.Changeset.for_update(
            :master_restore_version,
            %{
              version_id: version.id
            },
            authorize?: false
          )
          |> Ash.update()

        assert match?({:error, _}, result)
      end
    end

    describe "version management - preview_version" do
      test "previews a version without restoring (tenant)" do
        site = create_site!()

        tag =
          create_blog_tag!(
            name: "TAG12",
            description: "Original desc",
            site_id: site.id
          )

        # Update to create a version
        tag
        |> Ash.Changeset.for_update(
          :update,
          %{name: "TAG12UPDATED", description: "Updated desc"},
          tenant: site.id,
          authorize?: false
        )
        |> Ash.update!()

        # Get the first version
        version =
          Tag.Version
          |> Ash.Query.for_read(:read_any, %{}, authorize?: false)
          |> Ash.Query.filter(version_source_id == ^tag.id)
          |> Ash.Query.sort(version_inserted_at: :asc)
          |> Ash.Query.limit(1)
          |> Ash.read_one!(authorize?: false)

        # Preview the version
        preview =
          Tag
          |> Ash.Query.for_read(
            :preview_version,
            %{tag_id: tag.id, version_id: version.id},
            tenant: site.id,
            authorize?: false
          )
          |> Ash.read_one!(authorize?: false)

        assert preview.name == "TAG12"
        assert preview.description == "Original desc"

        # Verify original is unchanged
        current = Ash.get!(Tag, tag.id, tenant: site.id, authorize?: false)
        assert current.name == "TAG12UPDATED"
      end

      test "raises error for version from wrong tag" do
        site = create_site!()
        tag1 = create_blog_tag!(site_id: site.id)
        tag2 = create_blog_tag!(site_id: site.id)

        # Create version for tag2
        tag2
        |> Ash.Changeset.for_update(:update, %{name: "TAG13UPDATED"},
          tenant: site.id,
          authorize?: false
        )
        |> Ash.update!()

        # Get version from tag2
        version =
          Tag.Version
          |> Ash.Query.for_read(:read_any, %{}, authorize?: false)
          |> Ash.Query.filter(version_source_id == ^tag2.id)
          |> Ash.Query.limit(1)
          |> Ash.read_one!(authorize?: false)

        # Try to preview with tag1 - should raise error
        assert_raise Ash.Error.Invalid, fn ->
          Tag
          |> Ash.Query.for_read(
            :preview_version,
            %{tag_id: tag1.id, version_id: version.id},
            tenant: site.id,
            authorize?: false
          )
          |> Ash.read_one!(authorize?: false)
        end
      end
    end

    describe "version management - master_preview_version" do
      test "previews a version without restoring (master)" do
        site = create_site!()

        tag =
          create_blog_tag!(name: "TAG14", site_id: site.id)

        # Update to create a version
        tag
        |> Ash.Changeset.for_update(:update, %{name: "TAG14UPDATED"},
          tenant: site.id,
          authorize?: false
        )
        |> Ash.update!()

        # Get the first version
        version =
          Tag.Version
          |> Ash.Query.for_read(:read_any, %{}, authorize?: false)
          |> Ash.Query.filter(version_source_id == ^tag.id)
          |> Ash.Query.sort(version_inserted_at: :asc)
          |> Ash.Query.limit(1)
          |> Ash.read_one!(authorize?: false)

        # Preview using master action
        preview =
          Tag
          |> Ash.Query.for_read(
            :master_preview_version,
            %{tag_id: tag.id, version_id: version.id},
            authorize?: false
          )
          |> Ash.read_one!(authorize?: false)

        assert preview.name == "TAG14"
      end
    end

    describe "version calculations" do
      test "version_count returns correct count" do
        site = create_site!()

        tag =
          create_blog_tag!(name: "TAG15", site_id: site.id)

        # Create some versions
        tag
        |> Ash.Changeset.for_update(:update, %{name: "TAG15V1"},
          tenant: site.id,
          authorize?: false
        )
        |> Ash.update!()

        tag
        |> Ash.Changeset.for_update(:update, %{name: "TAG15V2"},
          tenant: site.id,
          authorize?: false
        )
        |> Ash.update!()

        loaded =
          Tag
          |> Ash.get!(tag.id, tenant: site.id, authorize?: false)
          |> Ash.load!(:version_count, authorize?: false)

        assert loaded.version_count >= 2
      end

      test "latest_version returns most recent version" do
        site = create_site!()

        tag =
          create_blog_tag!(name: "TAG16", site_id: site.id)

        # Create versions
        tag
        |> Ash.Changeset.for_update(:update, %{name: "TAG16V1"},
          tenant: site.id,
          authorize?: false
        )
        |> Ash.update!()

        tag
        |> Ash.Changeset.for_update(:update, %{name: "TAG16V2"},
          tenant: site.id,
          authorize?: false
        )
        |> Ash.update!()

        loaded =
          Tag
          |> Ash.get!(tag.id, tenant: site.id, authorize?: false)
          |> Ash.load!(:latest_version, authorize?: false)

        assert not is_nil(loaded.latest_version)
        assert is_struct(loaded.latest_version, Tag.Version)
      end

      test "recent_versions returns up to 10 versions" do
        site = create_site!()

        tag =
          create_blog_tag!(name: "TAG17", site_id: site.id)

        # Create multiple versions
        for i <- 1..5 do
          tag
          |> Ash.Changeset.for_update(:update, %{name: "TAG17V#{i}"},
            tenant: site.id,
            authorize?: false
          )
          |> Ash.update!()
        end

        loaded =
          Tag
          |> Ash.get!(tag.id, tenant: site.id, authorize?: false)
          |> Ash.load!(:recent_versions, authorize?: false)

        assert is_list(loaded.recent_versions)
        assert length(loaded.recent_versions) <= 10
        assert length(loaded.recent_versions) >= 5
      end
    end

    describe "published_post_count" do
      # WHAT A VISITOR WOULD COUNT. `post_count` beside it counts every post carrying the tag,
      # drafts, scheduled and archived alike — so a public tag cloud ordered by it put a tag used
      # once in public above one used forty times, and offered tags whose only posts nobody can
      # open.
      test "counts the published posts and none of the rest" do
        site = create_site!()
        tag = create_blog_tag!(site_id: site.id)

        for status <- [:published, :published, :draft] do
          post = create_blog_post!(site_id: site.id, status: status)
          create_post_tag!(post_id: post.id, tag_id: tag.id)
        end

        archived = create_blog_post!(site_id: site.id, status: :published)
        create_post_tag!(post_id: archived.id, tag_id: tag.id)

        archived
        |> Ash.Changeset.for_destroy(:destroy, %{}, tenant: site.id)
        |> Ash.destroy!(authorize?: false)

        loaded =
          Tag
          |> Ash.get!(tag.id, tenant: site.id, authorize?: false)
          |> Ash.load!([:post_count, :published_post_count], authorize?: false)

        assert loaded.published_post_count == 2
        assert loaded.post_count == 3, "the archived post is out of both counts"
      end

      test "is zero for a tag nothing published carries" do
        site = create_site!()
        tag = create_blog_tag!(site_id: site.id)
        post = create_blog_post!(site_id: site.id, status: :draft)
        create_post_tag!(post_id: post.id, tag_id: tag.id)

        loaded =
          Tag
          |> Ash.get!(tag.id, tenant: site.id, authorize?: false)
          |> Ash.load!(:published_post_count, authorize?: false)

        assert loaded.published_post_count == 0
      end
    end
  end
end
