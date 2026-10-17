# SPDX-FileCopyrightText: 2026 Mishka Group contributors <https://github.com/mishka-group/mishka_blog/graphs/contributors>
#
# SPDX-License-Identifier: Apache-2.0

defmodule MishkaBlog.Test.CollectionTest do
  @moduledoc """
  Tests for MishkaBlog.Collection resource.
  """
  use MishkaBlog.DataCase, async: false
  import MishkaBlog.Test.VersionHelpers

  if Code.ensure_loaded?(MishkaBlog) do
    require Ash.Query
    alias MishkaBlog.Collection
    alias MishkaCmsCore.Runtime.Resources.Validations.PreventMasterLanguageDeletion

    describe "resource configuration" do
      test "uses correct table name" do
        assert AshPostgres.DataLayer.Info.table(Collection) == "mishka_blog_collections"
      end

      test "uses UUID v7 for primary keys" do
        collection = create_collection!()
        assert is_binary(collection.id)
        assert String.length(collection.id) == 36
      end

      test "is always site-specific (not global)" do
        multitenancy_config = Ash.Resource.Info.multitenancy_strategy(Collection)
        assert multitenancy_config == :attribute
        assert Ash.Resource.Info.multitenancy_global?(Collection) == false
      end
    end

    describe "create action" do
      test "creates collection with valid attributes" do
        site = create_site!()

        collection =
          create_collection!(
            name: "Test Collection",
            slug: "test-collection",
            status: :active,
            language: "en",
            site_id: site.id
          )

        assert collection.name == "Test Collection"
        assert collection.slug == "test-collection"
        assert collection.status == :active
        assert collection.language == "en"
        assert collection.site_id == site.id
      end

      test "auto-generates slug from slug" do
        site = create_site!()

        collection =
          create_collection!(
            name: "My Awesome Collection",
            slug: "My Awesome Collection",
            site_id: site.id
          )

        assert collection.slug == "my-awesome-collection"
      end

      test "requires name, slug, status, and language" do
        site = create_site!()

        assert_raise Ash.Error.Invalid, fn ->
          Collection
          |> Ash.Changeset.for_create(:create, %{}, tenant: site.id, authorize?: false)
          |> Ash.create!()
        end
      end

      test "auto-assigns site_id from tenant context" do
        site = create_site!()

        collection =
          Collection
          |> Ash.Changeset.for_create(
            :create,
            %{
              name: "Tenant Collection",
              slug: "tenant-collection",
              status: :active,
              language: "en"
            },
            tenant: site.id,
            authorize?: false
          )
          |> Ash.create!()

        assert collection.site_id == site.id
      end

      test "auto-assigns language_group_id for master collections" do
        site = create_site!()

        collection = create_collection!(name: "Master Collection", site_id: site.id)

        assert collection.language_group_id != nil
      end

      test "defaults status to draft" do
        site = create_site!()

        collection =
          Collection
          |> Ash.Changeset.for_create(
            :create,
            %{
              name: "Draft Collection",
              slug: "draft-collection",
              language: "en"
            },
            tenant: site.id,
            authorize?: false
          )
          |> Ash.create!()

        assert collection.status == :draft
      end

      test "defaults language to 'en'" do
        site = create_site!()

        collection =
          Collection
          |> Ash.Changeset.for_create(
            :create,
            %{
              name: "English Collection",
              slug: "english-collection",
              status: :active
            },
            tenant: site.id,
            authorize?: false
          )
          |> Ash.create!()

        assert collection.language == "en"
      end

      test "defaults featured to false" do
        site = create_site!()
        collection = create_collection!(site_id: site.id)
        assert collection.featured == false
      end

      test "defaults display_order to 0" do
        site = create_site!()
        collection = create_collection!(site_id: site.id)
        assert collection.display_order == 0
      end

      test "accepts optional description" do
        site = create_site!()

        collection =
          create_collection!(
            name: "Collection with Description",
            description: "This is a test description",
            site_id: site.id
          )

        assert collection.description == "This is a test description"
      end

      test "accepts optional seo_tags" do
        site = create_site!()

        seo_tags = [
          %{tag: "meta", attrs: %{"name" => "description"}, content: "SEO description"},
          %{tag: "meta", attrs: %{"property" => "og:title"}, content: "Open Graph Title"}
        ]

        collection = create_collection!(seo_tags: seo_tags, site_id: site.id)

        assert collection.seo_tags == seo_tags
      end

      test "accepts permissions, each trimmed and downcased, repeats dropped" do
        site = create_site!()

        collection =
          create_collection!(
            permissions: ["  Members:Read  ", "members:read", "EDITORS:READ"],
            site_id: site.id
          )

        assert collection.permissions == ["members:read", "editors:read"]
      end

      test "accepts optional schema" do
        site = create_site!()

        schema = [
          %{"@type" => "CollectionPage", "name" => "Test Collection"}
        ]

        collection = create_collection!(schema: schema, site_id: site.id)

        assert collection.schema == schema
      end
    end

    describe "master_create action" do
      test "creates collection with explicit site_id" do
        site = create_site!()

        collection =
          Collection
          |> Ash.Changeset.for_create(
            :master_create,
            %{
              name: "Master Collection",
              slug: "master-collection",
              status: :active,
              language: "en",
              site_id: site.id
            },
            authorize?: false
          )
          |> Ash.create!()

        assert collection.name == "Master Collection"
        assert collection.site_id == site.id
      end

      test "requires explicit site_id" do
        assert_raise Ash.Error.Invalid, fn ->
          Collection
          |> Ash.Changeset.for_create(
            :master_create,
            %{
              name: "Missing Site",
              slug: "missing-site",
              status: :active,
              language: "en"
            },
            authorize?: false
          )
          |> Ash.create!()
        end
      end
    end

    describe "update action" do
      test "updates collection attributes" do
        site = create_site!()
        collection = create_collection!(name: "Original Name", site_id: site.id)

        updated =
          collection
          |> Ash.Changeset.for_update(
            :update,
            %{name: "Updated Name", description: "New description"},
            tenant: site.id,
            authorize?: false
          )
          |> Ash.update!()

        assert updated.name == "Updated Name"
        assert updated.description == "New description"
      end

      test "prevents updating archived collection" do
        site = create_site!()
        collection = create_collection!(site_id: site.id)

        # Archive the collection
        archived =
          collection
          |> Ash.Changeset.for_destroy(:destroy, %{}, tenant: site.id, authorize?: false)
          |> Ash.destroy!(return_destroyed?: true)

        # Try to update archived collection
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

      test "prevents collection from being its own parent" do
        site = create_site!()
        collection = create_collection!(site_id: site.id)

        assert_raise Ash.Error.Invalid, fn ->
          collection
          |> Ash.Changeset.for_update(
            :update,
            %{parent_collection_id: collection.id},
            tenant: site.id,
            authorize?: false
          )
          |> Ash.update!()
        end
      end

      test "prevents site_id changes" do
        site1 = create_site!()
        site2 = create_site!()
        collection = create_collection!(site_id: site1.id)

        # site_id is not in the accepted fields for update, so we just verify it can't be changed
        # by updating with only allowed fields
        updated =
          collection
          |> Ash.Changeset.for_update(
            :update,
            %{name: "Updated"},
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
      test "updates collection for master users" do
        site = create_site!()
        collection = create_collection!(name: "Original", site_id: site.id)

        {:ok, updated} =
          collection
          |> Ash.Changeset.for_update(
            :master_update,
            %{name: "Master Updated"},
            authorize?: false
          )
          |> Ash.update()

        assert updated.name == "Master Updated"
      end

      test "prevents site_id changes" do
        site1 = create_site!()
        collection = create_collection!(site_id: site1.id)

        # site_id is not an accepted argument, so passing it would error
        # Just verify that updating without site_id keeps the original value
        {:ok, updated} =
          collection
          |> Ash.Changeset.for_update(
            :master_update,
            %{name: "Updated"},
            authorize?: false
          )
          |> Ash.update()

        # site_id should remain unchanged
        assert updated.site_id == site1.id
      end
    end

    describe "read actions with multitenancy" do
      test "tenant read only shows collections for that tenant" do
        site1 = create_site!()
        site2 = create_site!()

        collection1 = create_collection!(name: "Site 1 Collection", site_id: site1.id)
        _collection2 = create_collection!(name: "Site 2 Collection", site_id: site2.id)

        # Query as site1 tenant
        collections =
          Collection
          |> Ash.Query.set_tenant(site1.id)
          |> Ash.read!(authorize?: false)

        assert length(collections) == 1
        assert Enum.at(collections, 0).id == collection1.id
      end

      test "master_read shows all collections system-wide" do
        site1 = create_site!()
        site2 = create_site!()

        _collection1 = create_collection!(name: "Site 1", site_id: site1.id)
        _collection2 = create_collection!(name: "Site 2", site_id: site2.id)

        result =
          Collection
          |> Ash.Query.for_read(:master_read, %{}, authorize?: false)
          |> Ash.read!(page: [limit: 100])

        collections = result.results
        assert length(collections) >= 2
      end

      test "master_get retrieves collection by ID bypassing tenant" do
        site = create_site!()
        collection = create_collection!(site_id: site.id)

        fetched = Ash.get!(Collection, collection.id, action: :master_get, authorize?: false)

        assert fetched.id == collection.id
      end
    end

    describe "archive/unarchive actions" do
      test "destroy soft deletes collection" do
        site = create_site!()
        collection = create_collection!(site_id: site.id)

        archived =
          collection
          |> Ash.Changeset.for_destroy(:destroy, %{}, tenant: site.id, authorize?: false)
          |> Ash.destroy!(return_destroyed?: true)

        assert archived.archived_at != nil
        assert archived.status == :archived

        # Should not appear in normal reads
        collections =
          Collection
          |> Ash.Query.set_tenant(site.id)
          |> Ash.read!(authorize?: false)

        assert Enum.find(collections, fn c -> c.id == collection.id end) == nil
      end

      test "unarchive restores archived collection" do
        site = create_site!()
        collection = create_collection!(site_id: site.id)

        # Archive
        archived =
          collection
          |> Ash.Changeset.for_destroy(:destroy, %{}, tenant: site.id, authorize?: false)
          |> Ash.destroy!(return_destroyed?: true)

        # Unarchive
        unarchived =
          archived
          |> Ash.Changeset.for_update(:unarchive, %{}, tenant: site.id, authorize?: false)
          |> Ash.update!()

        assert unarchived.archived_at == nil
        assert unarchived.status == :active
      end

      test "archived action lists only archived collections" do
        site = create_site!()
        active_collection = create_collection!(name: "Active", site_id: site.id)

        archived_collection =
          create_collection!(name: "To Archive", site_id: site.id)
          |> Ash.Changeset.for_destroy(:destroy, %{}, tenant: site.id, authorize?: false)
          |> Ash.destroy!(return_destroyed?: true)

        result =
          Collection
          |> Ash.Query.for_read(:archived, %{}, tenant: site.id, authorize?: false)
          |> Ash.read!()

        archived_list = result.results
        archived_ids = Enum.map(archived_list, & &1.id)
        assert archived_collection.id in archived_ids
        refute active_collection.id in archived_ids
      end

      test "get_archived retrieves single archived collection" do
        site = create_site!()

        collection =
          create_collection!(site_id: site.id)
          |> Ash.Changeset.for_destroy(:destroy, %{}, tenant: site.id, authorize?: false)
          |> Ash.destroy!(return_destroyed?: true)

        fetched =
          Ash.get!(
            Collection,
            collection.id,
            action: :get_archived,
            tenant: site.id,
            authorize?: false
          )

        assert fetched.id == collection.id
        assert fetched.archived_at != nil
      end

      test "master_unarchive restores collection" do
        site = create_site!()

        collection =
          create_collection!(site_id: site.id)
          |> Ash.Changeset.for_destroy(:destroy, %{}, tenant: site.id, authorize?: false)
          |> Ash.destroy!(return_destroyed?: true)

        {:ok, unarchived} =
          collection
          |> Ash.Changeset.for_update(:master_unarchive, %{}, authorize?: false)
          |> Ash.update()

        assert unarchived.archived_at == nil
        assert unarchived.status == :active
      end

      test "prevents archiving already archived collection" do
        site = create_site!()

        collection =
          create_collection!(site_id: site.id)
          |> Ash.Changeset.for_destroy(:destroy, %{}, tenant: site.id, authorize?: false)
          |> Ash.destroy!(return_destroyed?: true)

        assert_raise Ash.Error.Invalid, fn ->
          collection
          |> Ash.Changeset.for_destroy(:destroy, %{}, tenant: site.id, authorize?: false)
          |> Ash.destroy!()
        end
      end

      test "prevents unarchiving non-archived collection" do
        site = create_site!()
        collection = create_collection!(site_id: site.id)

        {:error, error} =
          collection
          |> Ash.Changeset.for_update(:master_unarchive, %{}, authorize?: false)
          |> Ash.update()

        assert %Ash.Error.Invalid{} = error
      end
    end

    describe "permanent_destroy action" do
      test "permanently deletes collection and cannot be recovered" do
        site = create_site!()
        collection = create_collection!(site_id: site.id)
        collection_id = collection.id

        collection
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
            Collection,
            collection_id,
            action: :master_get,
            authorize?: false
          )

        assert match?({:error, _}, result)
      end

      test "master_permanent_destroy permanently deletes collection" do
        site = create_site!()
        collection = create_collection!(site_id: site.id)
        collection_id = collection.id

        :ok =
          collection
          |> Ash.Changeset.for_destroy(:master_permanent_destroy, %{}, authorize?: false)
          |> Ash.destroy()

        result =
          Ash.get(
            Collection,
            collection_id,
            action: :master_get,
            authorize?: false
          )

        assert match?({:error, _}, result)
      end
    end

    # A TRANSLATION POINTS AT ITS MASTER BY ID, so the master goes last and comes back first. The
    # admin tables destroy with the record and no `authorize?`, which an archive hands its validations
    # as `authorize?: false`.
    describe "deleting a master that has translations" do
      setup do
        site = create_site!()
        master = create_collection!(site_id: site.id)

        fa =
          create_collection!(
            site_id: site.id,
            slug: "#{master.slug}-fa",
            language: "fa",
            language_group_id: master.id
          )

        %{
          site: site,
          master: master,
          fa: fa,
          master_user: create_user_with_permissions!(["*"]),
          tenant_user: create_user_with_permissions!(["admin:dashboard:*"], site_id: site.id)
        }
      end

      # Refused for this reason, and not for another the same call could run into.
      defp refused?({:error, %Ash.Error.Invalid{} = error}),
        do:
          Exception.message(error) =~
            "This is the original English version. Its Persian translation is still live, so " <>
              "it can't be deleted yet. Archive or delete that translation first, then this one."

      defp refused?(_result), do: false

      # A COLLECTION IS READ ON ITS OWN SITE ONLY, so one that names no site cannot have its
      # translations read, and is refused in words that say so.
      test "an original whose translations cannot be checked is refused in plain words" do
        id = Ash.UUID.generate()
        original = %Collection{id: id, language_group_id: id, site_id: nil, language: "en"}

        assert {:error, %Ash.Error.Changes.InvalidAttribute{} = error} =
                 PreventMasterLanguageDeletion.validate(Ash.Changeset.new(original), [], %{})

        assert error.message ==
                 "This is the original English version. Its translations could not be checked " <>
                   "just now, so it can't be deleted yet. Try again in a moment."

        assert error.private_vars == [live_translations_of: id]
      end

      test "archiving it is refused while a translation is live, however it is called", %{
        site: site,
        master: master,
        master_user: master_user,
        tenant_user: tenant_user
      } do
        as_master = Ash.get!(Collection, master.id, action: :master_get, actor: master_user)

        assert refused?(
                 Ash.destroy(master, action: :destroy, tenant: site.id, actor: tenant_user)
               )

        assert refused?(Ash.destroy(as_master, action: :master_destroy, actor: master_user))
        assert refused?(Ash.destroy(master, action: :destroy, tenant: site.id, authorize?: false))

        assert master
               |> Ash.Changeset.for_destroy(:destroy, %{}, tenant: site.id, actor: tenant_user)
               |> Ash.destroy()
               |> refused?()
      end

      test "deleting it for good is refused while a translation is live", %{
        site: site,
        master: master,
        master_user: master_user,
        tenant_user: tenant_user
      } do
        as_master = Ash.get!(Collection, master.id, action: :master_get, actor: master_user)

        assert refused?(
                 Ash.destroy(master,
                   action: :permanent_destroy,
                   tenant: site.id,
                   actor: tenant_user
                 )
               )

        assert refused?(
                 Ash.destroy(as_master, action: :master_permanent_destroy, actor: master_user)
               )
      end

      # AN ARCHIVED TRANSLATION IS IN NOBODY'S WAY: the archive lists a master beside its archived
      # editions, and a selection holding all of them empties the group in one go. Its restore is
      # what keeps that edition from outliving its master.
      test "deleting it for good goes ahead while an archived translation remains", %{
        site: site,
        master: master,
        fa: fa,
        tenant_user: tenant_user
      } do
        :ok = Ash.destroy(fa, action: :destroy, tenant: site.id, actor: tenant_user)
        :ok = Ash.destroy(master, action: :destroy, tenant: site.id, actor: tenant_user)

        archived =
          Ash.get!(Collection, master.id, action: :master_get_archived, authorize?: false)

        assert :ok =
                 Ash.destroy(archived,
                   action: :permanent_destroy,
                   tenant: site.id,
                   actor: tenant_user
                 )
      end

      test "restoring the translation is refused while its master is archived", %{
        site: site,
        master: master,
        fa: fa,
        master_user: master_user,
        tenant_user: tenant_user
      } do
        :ok = Ash.destroy(fa, action: :destroy, tenant: site.id, actor: tenant_user)
        :ok = Ash.destroy(master, action: :destroy, tenant: site.id, actor: tenant_user)
        archived_fa = Ash.get!(Collection, fa.id, action: :master_get_archived, authorize?: false)

        assert {:error, %Ash.Error.Invalid{} = error} =
                 Ash.update(archived_fa, action: :unarchive, tenant: site.id, actor: tenant_user)

        assert Exception.message(error) =~
                 "This is the Persian translation. Its original English version is archived, " <>
                   "so it can't be restored yet. Restore the original first, then this one."

        assert {:error, %Ash.Error.Invalid{}} =
                 Ash.update(archived_fa, action: :master_unarchive, actor: master_user)

        assert Ash.get!(Collection, fa.id, action: :master_get_archived, authorize?: false).archived_at
      end

      test "and for good once its master has been deleted", %{
        site: site,
        master: master,
        fa: fa,
        tenant_user: tenant_user
      } do
        :ok = Ash.destroy(fa, action: :destroy, tenant: site.id, actor: tenant_user)
        :ok = Ash.destroy(master, action: :destroy, tenant: site.id, actor: tenant_user)

        archived =
          Ash.get!(Collection, master.id, action: :master_get_archived, authorize?: false)

        :ok =
          Ash.destroy(archived, action: :permanent_destroy, tenant: site.id, actor: tenant_user)

        archived_fa = Ash.get!(Collection, fa.id, action: :master_get_archived, authorize?: false)

        assert {:error, %Ash.Error.Invalid{} = error} =
                 Ash.update(archived_fa, action: :unarchive, tenant: site.id, actor: tenant_user)

        assert Exception.message(error) =~
                 "This is the Persian translation. Its original version has been deleted for " <>
                   "good, so it can't be restored. It can only be deleted for good."
      end

      test "restoring the master first brings the group back", %{
        site: site,
        master: master,
        fa: fa,
        tenant_user: tenant_user
      } do
        :ok = Ash.destroy(fa, action: :destroy, tenant: site.id, actor: tenant_user)
        :ok = Ash.destroy(master, action: :destroy, tenant: site.id, actor: tenant_user)

        archived =
          Ash.get!(Collection, master.id, action: :master_get_archived, authorize?: false)

        archived_fa = Ash.get!(Collection, fa.id, action: :master_get_archived, authorize?: false)

        assert {:ok, _master} =
                 Ash.update(archived, action: :unarchive, tenant: site.id, actor: tenant_user)

        assert {:ok, restored} =
                 Ash.update(archived_fa, action: :unarchive, tenant: site.id, actor: tenant_user)

        assert is_nil(restored.archived_at)
      end

      test "it goes, archived and then for good, once its translation has", %{
        site: site,
        master: master,
        fa: fa,
        tenant_user: tenant_user
      } do
        :ok = Ash.destroy(fa, action: :destroy, tenant: site.id, actor: tenant_user)
        :ok = Ash.destroy(master, action: :destroy, tenant: site.id, actor: tenant_user)

        archived_fa = Ash.get!(Collection, fa.id, action: :master_get_archived, authorize?: false)

        archived =
          Ash.get!(Collection, master.id, action: :master_get_archived, authorize?: false)

        assert :ok =
                 Ash.destroy(archived_fa,
                   action: :permanent_destroy,
                   tenant: site.id,
                   actor: tenant_user
                 )

        assert :ok =
                 Ash.destroy(archived,
                   action: :permanent_destroy,
                   tenant: site.id,
                   actor: tenant_user
                 )
      end
    end

    describe "database constraints" do
      test "enforces slug length constraints" do
        site = create_site!()

        # Empty slug should fail
        assert_raise Ash.Error.Invalid, fn ->
          create_collection!(slug: "", site_id: site.id)
        end

        # Slug too long (> 255) should fail
        long_slug = String.duplicate("a", 256)

        assert_raise Ash.Error.Invalid, fn ->
          create_collection!(slug: long_slug, site_id: site.id)
        end
      end

      test "enforces display_order must be non-negative" do
        site = create_site!()

        assert_raise Ash.Error.Invalid, fn ->
          create_collection!(display_order: -1, site_id: site.id)
        end
      end
    end

    describe "attribute defaults" do
      test "defaults are applied correctly" do
        site = create_site!()

        collection =
          Collection
          |> Ash.Changeset.for_create(
            :create,
            %{name: "Test", slug: "test"},
            tenant: site.id,
            authorize?: false
          )
          |> Ash.create!()

        assert collection.status == :draft
        assert collection.language == "en"
        assert collection.featured == false
        assert collection.display_order == 0
        assert collection.schema == []
        assert collection.seo_tags == []
        assert collection.permissions == []
      end
    end

    describe "complex scenarios" do
      test "hierarchical parent-child relationships" do
        site = create_site!()

        parent = create_collection!(name: "Parent Collection", site_id: site.id)

        child =
          create_collection!(
            name: "Child Collection",
            parent_collection_id: parent.id,
            site_id: site.id
          )

        assert child.parent_collection_id == parent.id

        # Load relationship
        child_with_parent =
          Ash.load!(child, :parent_collection, tenant: site.id, authorize?: false)

        assert child_with_parent.parent_collection.id == parent.id

        # Load children
        children_query =
          Collection
          |> Ash.Query.set_tenant(site.id)
          |> Ash.Query.page(limit: 10)

        parent_with_children =
          Ash.load!(parent, [child_collections: children_query], authorize?: false)

        assert length(parent_with_children.child_collections.results) == 1
        assert Enum.at(parent_with_children.child_collections.results, 0).id == child.id
      end

      test "language variants and grouping" do
        site = create_site!()

        # Create master collection with language_group_id
        english =
          create_collection!(
            name: "English Collection",
            slug: "english-collection",
            language: "en",
            site_id: site.id
          )

        language_group_id = english.language_group_id

        # Create variant with same language_group_id
        persian =
          create_collection!(
            name: "Persian Collection",
            slug: "persian-collection",
            language: "fa",
            language_group_id: language_group_id,
            site_id: site.id
          )

        # Query language variants
        variants =
          Collection
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
        variants_query =
          Collection
          |> Ash.Query.set_tenant(site.id)
          |> Ash.Query.page(limit: 10)

        english_with_variants =
          Ash.load!(english, [language_variants: variants_query], authorize?: false)

        assert length(english_with_variants.language_variants.results) == 2
        assert persian.id in Enum.map(english_with_variants.language_variants.results, & &1.id)
      end

      test "multiple levels of hierarchy" do
        site = create_site!()

        level1 = create_collection!(name: "Level 1", site_id: site.id)

        level2 =
          create_collection!(
            name: "Level 2",
            parent_collection_id: level1.id,
            site_id: site.id
          )

        level3 =
          create_collection!(
            name: "Level 3",
            parent_collection_id: level2.id,
            site_id: site.id
          )

        assert level3.parent_collection_id == level2.id
        assert level2.parent_collection_id == level1.id
      end
    end

    describe "effective permissions up the parent chain" do
      defp effective_permissions!(collection, site) do
        collection
        |> Ash.load!(:effective_permissions, tenant: site.id, authorize?: false)
        |> Map.fetch!(:effective_permissions)
      end

      test "a collection with none of its own takes those of the nearest parent that names some" do
        site = create_site!()

        top = create_collection!(site_id: site.id, permissions: ["members:read"])
        middle = create_collection!(site_id: site.id, parent_collection_id: top.id)
        bottom = create_collection!(site_id: site.id, parent_collection_id: middle.id)

        assert effective_permissions!(top, site) == ["members:read"]
        assert effective_permissions!(middle, site) == ["members:read"]
        assert effective_permissions!(bottom, site) == ["members:read"]
      end

      test "a collection that names permissions keeps its own over its parents'" do
        site = create_site!()

        top = create_collection!(site_id: site.id, permissions: ["members:read"])

        middle =
          create_collection!(
            site_id: site.id,
            parent_collection_id: top.id,
            permissions: ["staff:read"]
          )

        bottom = create_collection!(site_id: site.id, parent_collection_id: middle.id)

        assert effective_permissions!(middle, site) == ["staff:read"]
        assert effective_permissions!(bottom, site) == ["staff:read"]
      end

      test "a chain without any permissions opens to everyone" do
        site = create_site!()

        top = create_collection!(site_id: site.id)
        bottom = create_collection!(site_id: site.id, parent_collection_id: top.id)

        assert effective_permissions!(bottom, site) == []
      end

      test "a parent cycle with no permissions ends the walk and opens to everyone" do
        site = create_site!()

        a = create_collection!(site_id: site.id)
        b = create_collection!(site_id: site.id, parent_collection_id: a.id)

        a =
          a
          |> Ash.Changeset.for_update(:update, %{parent_collection_id: b.id},
            tenant: site.id,
            authorize?: false
          )
          |> Ash.update!()

        assert a.parent_collection_id == b.id
        assert b.parent_collection_id == a.id

        assert effective_permissions!(a, site) == []
        assert effective_permissions!(b, site) == []
      end
    end

    describe "relationships" do
      test "belongs_to site" do
        site = create_site!()
        collection = create_collection!(site_id: site.id)

        collection_with_site = Ash.load!(collection, :site, authorize?: false)

        assert collection_with_site.site.id == site.id
        assert collection_with_site.site.host == site.host
      end

      test "parent_collection relationship" do
        site = create_site!()
        parent = create_collection!(name: "Parent", site_id: site.id)
        child = create_collection!(parent_collection_id: parent.id, site_id: site.id)

        child_with_parent =
          Ash.load!(child, :parent_collection, tenant: site.id, authorize?: false)

        assert child_with_parent.parent_collection.id == parent.id
      end

      test "child_collections relationship" do
        site = create_site!()
        parent = create_collection!(name: "Parent", site_id: site.id)

        child1 =
          create_collection!(name: "Child 1", parent_collection_id: parent.id, site_id: site.id)

        child2 =
          create_collection!(name: "Child 2", parent_collection_id: parent.id, site_id: site.id)

        children_query =
          Collection
          |> Ash.Query.set_tenant(site.id)
          |> Ash.Query.page(limit: 10)

        parent_with_children =
          Ash.load!(parent, [child_collections: children_query], authorize?: false)

        child_ids =
          Enum.map(parent_with_children.child_collections.results, & &1.id) |> Enum.sort()

        assert Enum.sort([child1.id, child2.id]) == child_ids
      end

      test "language_variants relationship" do
        site = create_site!()

        english = create_collection!(language: "en", site_id: site.id)
        language_group_id = english.language_group_id

        _persian =
          create_collection!(
            language: "fa",
            language_group_id: language_group_id,
            site_id: site.id
          )

        _arabic =
          create_collection!(
            language: "ar",
            language_group_id: language_group_id,
            site_id: site.id
          )

        variants_query =
          Collection
          |> Ash.Query.set_tenant(site.id)
          |> Ash.Query.page(limit: 10)

        english_with_variants =
          Ash.load!(english, [language_variants: variants_query], authorize?: false)

        languages =
          Enum.map(english_with_variants.language_variants.results, & &1.language) |> Enum.sort()

        assert languages == ["ar", "en", "fa"]
      end
    end

    describe "identities" do
      test "unique_slug_per_site prevents duplicate slugs within a site" do
        site = create_site!()
        _collection1 = create_collection!(slug: "unique-slug", site_id: site.id)

        assert_raise Ash.Error.Invalid, fn ->
          create_collection!(slug: "unique-slug", site_id: site.id)
        end
      end

      test "allows same slug across different sites" do
        site1 = create_site!()
        site2 = create_site!()

        collection1 = create_collection!(slug: "same-slug", site_id: site1.id)
        collection2 = create_collection!(slug: "same-slug", site_id: site2.id)

        assert collection1.slug == collection2.slug
        assert collection1.site_id != collection2.site_id
      end

      test "unique_language_per_group prevents duplicate languages in same group" do
        site = create_site!()

        english = create_collection!(language: "en", site_id: site.id)
        language_group_id = english.language_group_id

        assert_raise Ash.Error.Invalid, fn ->
          create_collection!(
            language: "en",
            language_group_id: language_group_id,
            site_id: site.id
          )
        end
      end

      test "allows same language in different groups" do
        site = create_site!()

        collection1 = create_collection!(language: "en", site_id: site.id)
        collection2 = create_collection!(language: "en", site_id: site.id)

        assert collection1.language == collection2.language
        assert collection1.language_group_id != collection2.language_group_id
      end
    end

    # A MASTER READS EVERY SITE'S COLLECTIONS, so the picker has to narrow them to the site the
    # collection is on: a group on another site is one no edition of it would be listed with.
    describe "the Language Group picker" do
      defp group_choices(user, field_values) do
        state = %{
          MishkaGervaz.Form.Web.State.init("collection-form", Collection, user)
          | field_values: field_values
        }

        field = Enum.find(state.static.fields, &(&1.name == :language_group_id))
        loader = MishkaGervaz.Form.Web.DataLoader.Default.relation_loader()

        {:ok, options, _more?} = loader.load_options(field, state)
        Enum.map(options, &elem(&1, 1))
      end

      test "offers a master only the groups of the collection's site" do
        site = create_site!()
        mine = create_collection!(site_id: site.id)
        elsewhere = create_collection!(site_id: create_site!().id)

        choices = group_choices(create_user_with_permissions!(["*"]), %{site_id: site.id})

        assert mine.language_group_id in choices
        refute elsewhere.language_group_id in choices, "a group on another site was offered"
      end
    end

    describe "all_posts relationship" do
      test "loads collection with all_posts when actor has no tenant_id" do
        site = create_site!()

        # Create a collection
        collection = create_collection!(name: "Tech Collection", site_id: site.id)

        # Create and assign posts to this collection
        post1 =
          create_blog_post!(
            title: "Post 1",
            slug: "post-1",
            status: :published,
            site_id: site.id
          )

        post2 =
          create_blog_post!(
            title: "Post 2",
            slug: "post-2",
            status: :published,
            site_id: site.id
          )

        post3 =
          create_blog_post!(
            title: "Post 3",
            slug: "post-3",
            status: :published,
            site_id: site.id
          )

        # Assign posts to collection
        post1
        |> Ash.Changeset.for_update(
          :add_collection,
          %{collection_id: collection.id},
          tenant: site.id,
          authorize?: false
        )
        |> Ash.update!()

        post2
        |> Ash.Changeset.for_update(
          :add_collection,
          %{collection_id: collection.id},
          tenant: site.id,
          authorize?: false
        )
        |> Ash.update!()

        post3
        |> Ash.Changeset.for_update(
          :add_collection,
          %{collection_id: collection.id},
          tenant: site.id,
          authorize?: false
        )
        |> Ash.update!()

        # Load collection with all_posts (actor has no tenant_id, simulated by nil tenant_id)
        posts_query =
          MishkaBlog.BlogPost
          |> Ash.Query.set_tenant(site.id)
          |> Ash.Query.page(limit: 10)

        collection_with_posts =
          collection
          |> Ash.load!([posts: posts_query], authorize?: false, actor: %{tenant_id: nil})

        post_ids = Enum.map(collection_with_posts.posts.results, & &1.id) |> Enum.sort()
        assert length(collection_with_posts.posts.results) == 3
        assert Enum.sort([post1.id, post2.id, post3.id]) == post_ids
      end

      test "prevents loading all_posts when actor has tenant_id (non-nil)" do
        site = create_site!()

        # Create a collection
        collection = create_collection!(name: "Tech Collection", site_id: site.id)

        # Create and assign a post to this collection
        post =
          create_blog_post!(
            title: "Post 1",
            slug: "post-1",
            site_id: site.id
          )

        # Assign post to collection
        post
        |> Ash.Changeset.for_update(
          :add_collection,
          %{collection_id: collection.id},
          tenant: site.id,
          authorize?: false
        )
        |> Ash.update!()

        # Try to load collection with all_posts when actor has tenant_id (UUID string)
        # The filter expr(is_nil(^actor(:tenant_id))) causes SQL type error with non-nil tenant_id

        posts_query =
          MishkaBlog.BlogPost
          |> Ash.Query.set_tenant(site.id)
          |> Ash.Query.page(limit: 10)

        collection =
          Ash.get!(Collection, collection.id, action: :master_get, authorize?: false)
          |> Ash.load!([posts: posts_query],
            authorize?: false,
            actor: %{tenant_id: Ash.UUID.generate()}
          )

        [] = assert collection.posts.results
      end

      test "master_get loads collection and can load all_posts with nil tenant actor" do
        site = create_site!()

        # Create a collection
        collection = create_collection!(name: "Tech Collection", site_id: site.id)

        # Create and assign posts to this collection
        post1 =
          create_blog_post!(
            title: "Post 1",
            slug: "post-1",
            status: :published,
            site_id: site.id
          )

        post2 =
          create_blog_post!(
            title: "Post 2",
            slug: "post-2",
            status: :published,
            site_id: site.id
          )

        # Assign posts to collection
        post1
        |> Ash.Changeset.for_update(
          :add_collection,
          %{collection_id: collection.id},
          tenant: site.id,
          authorize?: false
        )
        |> Ash.update!()

        post2
        |> Ash.Changeset.for_update(
          :add_collection,
          %{collection_id: collection.id},
          tenant: site.id,
          authorize?: false
        )
        |> Ash.update!()

        # Use master_get to retrieve the collection (bypasses tenant)
        fetched_collection =
          Ash.get!(Collection, collection.id, action: :master_get, authorize?: false)

        # Load all_posts with nil tenant actor (master admin)
        posts_query =
          MishkaBlog.BlogPost
          |> Ash.Query.set_tenant(site.id)
          |> Ash.Query.page(limit: 10)

        collection_with_posts =
          Ash.load!(fetched_collection, [posts: posts_query],
            authorize?: false,
            actor: %{tenant_id: nil}
          )

        post_ids = Enum.map(collection_with_posts.posts.results, & &1.id) |> Enum.sort()
        assert length(collection_with_posts.posts.results) == 2
        assert Enum.sort([post1.id, post2.id]) == post_ids
      end

      test "all_posts uses read_any action to bypass tenant filtering" do
        site1 = create_site!()

        # Create collection in site1
        collection1 = create_collection!(name: "Collection 1", site_id: site1.id)

        # Create post in site1
        post1 =
          create_blog_post!(
            title: "Post 1 Site 1",
            slug: "post-1-s1",
            status: :published,
            site_id: site1.id
          )

        # Assign post1 to collection1
        post1
        |> Ash.Changeset.for_update(
          :add_collection,
          %{collection_id: collection1.id},
          tenant: site1.id,
          authorize?: false
        )
        |> Ash.update!()

        # Load collection with all_posts using nil tenant actor (master admin)
        # The read_any action bypasses tenant filtering
        posts_query =
          MishkaBlog.BlogPost
          |> Ash.Query.set_tenant(site1.id)
          |> Ash.Query.page(limit: 10)

        collection_with_posts =
          collection1
          |> Ash.load!([posts: posts_query], authorize?: false, actor: %{tenant_id: nil})

        # Should have post1
        post_ids = Enum.map(collection_with_posts.posts.results, & &1.id)
        assert post1.id in post_ids
        assert length(collection_with_posts.posts.results) == 1
      end
    end

    describe "JSON API configuration" do
      test "has correct JSON API type" do
        json_api_type = AshJsonApi.Resource.Info.type(Collection)
        assert json_api_type == "collection"
      end
    end

    describe "version management - get_with_versions" do
      test "gets collection with paginated versions (tenant)" do
        site = create_site!()

        collection =
          create_collection!(
            site_id: site.id,
            name: "Original Name",
            description: "Original description"
          )

        # Create 3 more versions (total 4 including create)
        collection
        |> Ash.Changeset.for_update(
          :update,
          %{description: "Desc 1"},
          tenant: site.id,
          authorize?: false
        )
        |> Ash.update!()

        collection
        |> Ash.Changeset.for_update(
          :update,
          %{description: "Desc 2"},
          tenant: site.id,
          authorize?: false
        )
        |> Ash.update!()

        collection
        |> Ash.Changeset.for_update(
          :update,
          %{description: "Desc 3"},
          tenant: site.id,
          authorize?: false
        )
        |> Ash.update!()

        wait_for_version_count("mishka_blog_collection_versions", collection.id, 5)

        # Get with versions
        result =
          Collection
          |> Ash.Query.for_read(:get_with_versions, %{versions_limit: 10}, tenant: site.id)
          |> Ash.Query.filter(id == ^collection.id)
          |> Ash.read_one!(authorize?: false)

        assert result.id == collection.id
        assert is_list(result.sorted_versions)
        assert length(result.sorted_versions) == 5
      end

      test "gets collection with paginated versions (master)" do
        site = create_site!()

        collection =
          create_collection!(site_id: site.id, name: "ORIGINAL", description: "Original desc")

        collection
        |> Ash.Changeset.for_update(
          :update,
          %{description: "Updated 1"},
          tenant: site.id,
          authorize?: false
        )
        |> Ash.update!()

        wait_for_version_count("mishka_blog_collection_versions", collection.id, 3)

        result =
          Collection
          |> Ash.Query.for_read(
            :master_get_with_versions,
            %{versions_limit: 10},
            authorize?: false
          )
          |> Ash.Query.filter(id == ^collection.id)
          |> Ash.read_one!(authorize?: false)

        assert result.id == collection.id
        assert is_list(result.sorted_versions)
        assert length(result.sorted_versions) == 3
      end
    end

    describe "version management - list_versions" do
      test "lists all versions for a collection (tenant)" do
        site = create_site!()
        collection = create_collection!(site_id: site.id, name: "Test")

        collection
        |> Ash.Changeset.for_update(
          :update,
          %{description: "V1"},
          tenant: site.id,
          authorize?: false
        )
        |> Ash.update!()

        wait_for_version_count("mishka_blog_collection_versions", collection.id, 3)

        result =
          Collection
          |> Ash.Query.for_read(
            :list_versions,
            %{collection_id: collection.id},
            tenant: site.id,
            authorize?: false
          )
          |> Ash.read!()

        assert length(result.results) == 1
        collection_data = List.first(result.results)
        assert collection_data.id == collection.id
        assert is_list(collection_data.sorted_versions)
        assert length(collection_data.sorted_versions) == 3
      end

      test "lists all versions for a collection (master)" do
        site = create_site!()
        collection = create_collection!(site_id: site.id)

        collection
        |> Ash.Changeset.for_update(
          :update,
          %{description: "Master V1"},
          tenant: site.id,
          authorize?: false
        )
        |> Ash.update!()

        wait_for_version_count("mishka_blog_collection_versions", collection.id, 3)

        result =
          Collection
          |> Ash.Query.for_read(
            :master_list_versions,
            %{collection_id: collection.id},
            authorize?: false
          )
          |> Ash.read!()

        assert length(result.results) == 1
        collection_data = List.first(result.results)
        assert is_list(collection_data.sorted_versions)
        assert length(collection_data.sorted_versions) == 3
      end

      test "returns empty for non-existent collection" do
        site = create_site!()
        fake_id = Ash.UUID.generate()

        result =
          Collection
          |> Ash.Query.for_read(
            :list_versions,
            %{collection_id: fake_id},
            tenant: site.id,
            authorize?: false
          )
          |> Ash.read!()

        assert result.results == []
      end
    end

    describe "version management - restore_version" do
      test "restores collection to a previous version (tenant)" do
        site = create_site!()

        collection =
          create_collection!(site_id: site.id, name: "V0", description: "Description V0")

        # Create version 1
        updated =
          collection
          |> Ash.Changeset.for_update(
            :update,
            %{description: "Description V1"},
            tenant: site.id,
            authorize?: false
          )
          |> Ash.update!()

        # Create version 2
        updated2 =
          updated
          |> Ash.Changeset.for_update(
            :update,
            %{description: "Description V2"},
            tenant: site.id,
            authorize?: false
          )
          |> Ash.update!()

        wait_for_version_count("mishka_blog_collection_versions", collection.id, 4)

        # Get version 1 (second version, index 1 when sorted ascending)
        versions = versions(MishkaBlog.Collection.Version, collection.id)

        version_1 = Enum.at(versions, 2)

        # Restore to version 1
        restored =
          updated2
          |> Ash.Changeset.for_update(
            :restore_version,
            %{version_id: version_1.id},
            tenant: site.id,
            authorize?: false
          )
          |> Ash.update!()

        assert restored.description == "Description V1"
      end

      test "raises error if version doesn't belong to collection" do
        site = create_site!()

        collection1 = create_collection!(site_id: site.id, name: "Collection 1")

        collection2 =
          create_collection!(site_id: site.id, name: "Collection 2", description: "Desc")

        collection2
        |> Ash.Changeset.for_update(
          :update,
          %{description: "Updated"},
          tenant: site.id,
          authorize?: false
        )
        |> Ash.update!()

        wait_for_version_count("mishka_blog_collection_versions", collection2.id, 2)

        # Get version from collection2
        versions = versions(MishkaBlog.Collection.Version, collection2.id)

        version_from_c2 = List.first(versions)

        # Try to restore collection1 with collection2's version (should fail)
        assert_raise Ash.Error.Invalid, fn ->
          collection1
          |> Ash.Changeset.for_update(
            :restore_version,
            %{version_id: version_from_c2.id},
            tenant: site.id,
            authorize?: false
          )
          |> Ash.update!()
        end
      end
    end

    describe "version management - restore_version_api" do
      test "restores collection via API action (tenant)" do
        site = create_site!()

        collection =
          create_collection!(site_id: site.id, name: "API Test", description: "Original")

        updated =
          collection
          |> Ash.Changeset.for_update(
            :update,
            %{description: "Updated"},
            tenant: site.id,
            authorize?: false
          )
          |> Ash.update!()

        wait_for_version_count("mishka_blog_collection_versions", collection.id, 2)

        versions = versions(MishkaBlog.Collection.Version, collection.id)

        first_version = List.first(versions)

        {:ok, restored} =
          Collection
          |> Ash.ActionInput.for_action(
            :restore_version_api,
            %{id: updated.id, version_id: first_version.id},
            tenant: site.id,
            authorize?: false
          )
          |> Ash.run_action()

        assert restored.description == "Original"
      end
    end

    describe "version management - master_restore_version" do
      test "restores collection via master action" do
        site = create_site!()

        collection =
          create_collection!(site_id: site.id, name: "Master Test", description: "V0")

        updated =
          collection
          |> Ash.Changeset.for_update(
            :update,
            %{description: "V1"},
            tenant: site.id,
            authorize?: false
          )
          |> Ash.update!()

        wait_for_version_count("mishka_blog_collection_versions", collection.id, 2)

        versions = versions(MishkaBlog.Collection.Version, collection.id)

        first_version = List.first(versions)

        {:ok, restored} =
          updated
          |> Ash.Changeset.for_update(
            :master_restore_version,
            %{version_id: first_version.id},
            authorize?: false
          )
          |> Ash.update()

        assert restored.description == "V0"
      end
    end

    describe "version management - preview_version" do
      test "previews a version without modifying the collection (tenant)" do
        site = create_site!()

        collection =
          create_collection!(site_id: site.id, name: "Preview Test", description: "Original")

        updated =
          collection
          |> Ash.Changeset.for_update(
            :update,
            %{description: "Modified"},
            tenant: site.id,
            authorize?: false
          )
          |> Ash.update!()

        wait_for_version_count("mishka_blog_collection_versions", collection.id, 3)

        versions = versions(MishkaBlog.Collection.Version, collection.id)

        original_version = List.first(versions)

        # Preview the original version
        preview =
          Collection
          |> Ash.Query.for_read(
            :preview_version,
            %{collection_id: collection.id, version_id: original_version.id},
            tenant: site.id,
            authorize?: false
          )
          |> Ash.read_one!(authorize?: false)

        assert preview.description == "Original"

        # Verify actual collection is unchanged
        current =
          Collection
          |> Ash.get!(updated.id, tenant: site.id, authorize?: false)

        assert current.description == "Modified"
      end
    end

    describe "version management - master_preview_version" do
      test "previews a version without modifying the collection (master)" do
        site = create_site!()

        collection =
          create_collection!(site_id: site.id, name: "Master Preview", description: "V0")

        updated =
          collection
          |> Ash.Changeset.for_update(
            :update,
            %{description: "V1"},
            tenant: site.id,
            authorize?: false
          )
          |> Ash.update!()

        wait_for_version_count("mishka_blog_collection_versions", collection.id, 3)

        versions = versions(MishkaBlog.Collection.Version, collection.id)

        original_version = List.first(versions)

        # Preview the original version
        preview =
          Collection
          |> Ash.Query.for_read(
            :master_preview_version,
            %{collection_id: collection.id, version_id: original_version.id},
            authorize?: false
          )
          |> Ash.read_one!(authorize?: false)

        assert preview.description == "V0"

        # Verify actual collection is unchanged
        current =
          MishkaBlog.Collection
          |> Ash.get!(updated.id, action: :master_get, authorize?: false)

        assert current.description == "V1"
      end
    end

    describe "version management - calculations" do
      test "version_count calculation returns correct count" do
        site = create_site!()
        collection = create_collection!(site_id: site.id, name: "Count Test")

        # Create 3 more versions
        Enum.each(1..3, fn i ->
          collection
          |> Ash.Changeset.for_update(
            :update,
            %{description: "Version #{i}"},
            tenant: site.id,
            authorize?: false
          )
          |> Ash.update!()
        end)

        wait_for_version_count("mishka_blog_collection_versions", collection.id, 5)

        result =
          Collection
          |> Ash.Query.load(:version_count)
          |> Ash.Query.filter(id == ^collection.id)
          |> Ash.Query.set_tenant(site.id)
          |> Ash.read_one!(authorize?: false)

        assert result.version_count == 5
      end

      test "latest_version calculation returns most recent version" do
        site = create_site!()
        collection = create_collection!(site_id: site.id, description: "First")

        collection
        |> Ash.Changeset.for_update(
          :update,
          %{description: "Second"},
          tenant: site.id,
          authorize?: false
        )
        |> Ash.update!()

        collection
        |> Ash.Changeset.for_update(
          :update,
          %{description: "Third"},
          tenant: site.id,
          authorize?: false
        )
        |> Ash.update!()

        wait_for_version_count("mishka_blog_collection_versions", collection.id, 4)

        result =
          Collection
          |> Ash.Query.load(:latest_version)
          |> Ash.Query.filter(id == ^collection.id)
          |> Ash.Query.set_tenant(site.id)
          |> Ash.read_one!(authorize?: false)

        assert result.latest_version != nil
        assert result.latest_version.changes["description"] == "Third"
      end

      test "recent_versions calculation returns up to 10 versions" do
        site = create_site!()
        collection = create_collection!(site_id: site.id)

        # Create 12 more versions (13 total)
        Enum.each(1..12, fn i ->
          collection
          |> Ash.Changeset.for_update(
            :update,
            %{description: "Version #{i}"},
            tenant: site.id,
            authorize?: false
          )
          |> Ash.update!()
        end)

        wait_for_version_count("mishka_blog_collection_versions", collection.id, 14)

        result =
          Collection
          |> Ash.Query.load(:recent_versions)
          |> Ash.Query.filter(id == ^collection.id)
          |> Ash.Query.set_tenant(site.id)
          |> Ash.read_one!(authorize?: false)

        assert length(result.recent_versions) == 10
        # Should be sorted newest first
        assert Enum.at(result.recent_versions, 0).changes["description"] == "Version 12"
      end
    end

    describe "public_list action" do
      test "lists active collections without authentication" do
        site = create_site!()

        # Create collections with different statuses
        active1 = create_collection!(name: "Active 1", status: :active, site_id: site.id)
        active2 = create_collection!(name: "Active 2", status: :active, site_id: site.id)
        _draft = create_collection!(name: "Draft", status: :draft, site_id: site.id)

        # Archived collection
        _archived =
          create_collection!(name: "Archived", status: :active, site_id: site.id)
          |> Ash.Changeset.for_destroy(:destroy, %{}, tenant: site.id, authorize?: false)
          |> Ash.destroy!(return_destroyed?: true)

        # Query public_list action without actor (no authentication)
        collections =
          Collection
          |> Ash.Query.for_read(:public_list, %{}, tenant: site.id, authorize?: false)
          |> Ash.read!()

        collection_ids = Enum.map(collections, & &1.id) |> Enum.sort()

        # Should only return active collections
        assert length(collections) == 2
        assert Enum.sort([active1.id, active2.id]) == collection_ids
      end

      test "supports pagination" do
        site = create_site!()

        # Create 25 active collections
        _collections =
          Enum.map(1..25, fn i ->
            create_collection!(name: "Collection #{i}", status: :active, site_id: site.id)
          end)

        # Query with explicit pagination (20 per page)
        result =
          Collection
          |> Ash.Query.for_read(:public_list, %{}, tenant: site.id, authorize?: false)
          |> Ash.Query.page(limit: 20)
          |> Ash.read!()

        assert length(result.results) == 20

        # Query second page
        result_page2 =
          Collection
          |> Ash.Query.for_read(:public_list, %{}, tenant: site.id, authorize?: false)
          |> Ash.Query.page(offset: 20, limit: 10)
          |> Ash.read!()

        assert length(result_page2.results) == 5
      end

      test "respects tenant context" do
        site1 = create_site!()
        site2 = create_site!()

        # Create active collections in different sites
        site1_collection = create_collection!(name: "Site 1", status: :active, site_id: site1.id)
        _site2_collection = create_collection!(name: "Site 2", status: :active, site_id: site2.id)

        # Query as site1 tenant
        collections =
          Collection
          |> Ash.Query.for_read(:public_list, %{}, tenant: site1.id, authorize?: false)
          |> Ash.read!()

        # Should only see site1 collections
        assert length(collections) == 1
        assert Enum.at(collections, 0).id == site1_collection.id
      end

      test "allows public access without authorization" do
        site = create_site!()
        _collection = create_collection!(name: "Public", status: :active, site_id: site.id)

        # This should not raise an authorization error
        collections =
          Collection
          |> Ash.Query.for_read(:public_list, %{}, tenant: site.id)
          |> Ash.read!()

        assert length(collections) == 1
      end
    end

    describe "public_get action" do
      test "gets a single active collection without authentication" do
        site = create_site!()

        collection =
          create_collection!(name: "Active Collection", status: :active, site_id: site.id)

        # Query without actor (no authentication)
        fetched =
          Ash.get!(
            Collection,
            collection.id,
            action: :public_get,
            tenant: site.id,
            authorize?: false
          )

        assert fetched.id == collection.id
        assert fetched.name == "Active Collection"
      end

      test "returns error when collection is not active" do
        site = create_site!()
        draft_collection = create_collection!(name: "Draft", status: :draft, site_id: site.id)

        # Should not find draft collection
        result =
          Ash.get(
            Collection,
            draft_collection.id,
            action: :public_get,
            tenant: site.id,
            authorize?: false
          )

        assert match?({:error, _}, result)
      end

      test "returns error when collection is archived" do
        site = create_site!()

        archived_collection =
          create_collection!(name: "To Archive", status: :active, site_id: site.id)
          |> Ash.Changeset.for_destroy(:destroy, %{}, tenant: site.id, authorize?: false)
          |> Ash.destroy!(return_destroyed?: true)

        # Should not find archived collection
        result =
          Ash.get(
            Collection,
            archived_collection.id,
            action: :public_get,
            tenant: site.id,
            authorize?: false
          )

        assert match?({:error, _}, result)
      end

      test "respects tenant context" do
        site1 = create_site!()
        site2 = create_site!()

        collection = create_collection!(name: "Site 1", status: :active, site_id: site1.id)

        # Should find in correct tenant
        fetched =
          Ash.get!(
            Collection,
            collection.id,
            action: :public_get,
            tenant: site1.id,
            authorize?: false
          )

        assert fetched.id == collection.id

        # Should not find in wrong tenant
        result =
          Ash.get(
            Collection,
            collection.id,
            action: :public_get,
            tenant: site2.id,
            authorize?: false
          )

        assert match?({:error, _}, result)
      end

      test "allows public access without authorization" do
        site = create_site!()
        collection = create_collection!(name: "Public", status: :active, site_id: site.id)

        # This should not raise an authorization error
        fetched =
          Ash.get!(
            Collection,
            collection.id,
            action: :public_get,
            tenant: site.id
          )

        assert fetched.id == collection.id
      end
    end

    describe "published_post_count" do
      # WHAT A VISITOR WOULD COUNT. `post_count` beside it counts drafts, scheduled and archived
      # posts too, so a public category list offered categories that open empty.
      test "counts the published posts and none of the rest" do
        site = create_site!()
        collection = create_collection!(site_id: site.id, status: :active)

        for status <- [:published, :published, :draft] do
          post = create_blog_post!(site_id: site.id, status: status)
          create_post_collection!(post_id: post.id, collection_id: collection.id)
        end

        archived = create_blog_post!(site_id: site.id, status: :published)
        create_post_collection!(post_id: archived.id, collection_id: collection.id)

        archived
        |> Ash.Changeset.for_destroy(:destroy, %{}, tenant: site.id)
        |> Ash.destroy!(authorize?: false)

        loaded =
          Collection
          |> Ash.get!(collection.id, tenant: site.id, authorize?: false)
          |> Ash.load!([:post_count, :published_post_count], authorize?: false)

        assert loaded.published_post_count == 2
        assert loaded.post_count == 3, "the archived post is out of both counts"
      end

      test "is zero for a category holding nothing published" do
        site = create_site!()
        collection = create_collection!(site_id: site.id, status: :active)
        post = create_blog_post!(site_id: site.id, status: :draft)
        create_post_collection!(post_id: post.id, collection_id: collection.id)

        loaded =
          Collection
          |> Ash.get!(collection.id, tenant: site.id, authorize?: false)
          |> Ash.load!(:published_post_count, authorize?: false)

        assert loaded.published_post_count == 0
      end
    end
  end
end
