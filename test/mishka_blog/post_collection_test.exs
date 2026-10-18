# SPDX-FileCopyrightText: 2026 Mishka Group contributors <https://github.com/mishka-group/mishka_blog/graphs/contributors>
#
# SPDX-License-Identifier: Apache-2.0

defmodule MishkaBlog.Test.PostCollectionTest do
  @moduledoc """
  Tests for MishkaBlog.PostCollection resource - join table for posts and collections.
  """
  use MishkaBlog.DataCase, async: false

  if Code.ensure_loaded?(MishkaBlog) do
    alias MishkaBlog.PostCollection

    describe "resource configuration" do
      test "uses correct table name" do
        assert AshPostgres.DataLayer.Info.table(PostCollection) == "mishka_blog_post_collections"
      end

      test "uses composite primary key (post_id, collection_id)" do
        site = create_site!()
        post = create_blog_post!(site_id: site.id)
        collection = create_collection!(site_id: site.id)

        assignment = create_post_collection!(post_id: post.id, collection_id: collection.id)

        # Composite key means both IDs together form the primary key
        assert assignment.post_id == post.id
        assert assignment.collection_id == collection.id
      end

      test "is a global resource (not multi-tenant)" do
        multitenancy_config = Ash.Resource.Info.multitenancy_strategy(PostCollection)
        assert multitenancy_config == nil
        assert Ash.Resource.Info.multitenancy_global?(PostCollection) == nil
      end
    end

    describe "assign action (upsert)" do
      test "assigns post to collection" do
        site = create_site!()
        post = create_blog_post!(site_id: site.id)
        collection = create_collection!(site_id: site.id)

        assignment = create_post_collection!(post_id: post.id, collection_id: collection.id)

        assert assignment.post_id == post.id
        assert assignment.collection_id == collection.id
        assert %DateTime{} = assignment.inserted_at
      end

      test "upsert prevents duplicate assignments" do
        site = create_site!()
        post = create_blog_post!(site_id: site.id)
        collection = create_collection!(site_id: site.id)

        # First assignment
        assignment1 = create_post_collection!(post_id: post.id, collection_id: collection.id)

        # Second assignment (upsert)
        assignment2 = create_post_collection!(post_id: post.id, collection_id: collection.id)

        # Should be same record
        assert assignment1.post_id == assignment2.post_id
        assert assignment1.collection_id == assignment2.collection_id
      end

      test "allows same post in different collections" do
        site = create_site!()
        post = create_blog_post!(site_id: site.id)
        collection1 = create_collection!(site_id: site.id)
        collection2 = create_collection!(site_id: site.id)

        assignment1 = create_post_collection!(post_id: post.id, collection_id: collection1.id)
        assignment2 = create_post_collection!(post_id: post.id, collection_id: collection2.id)

        assert assignment1.post_id == assignment2.post_id
        assert assignment1.collection_id != assignment2.collection_id
      end

      test "allows multiple posts in same collection" do
        site = create_site!()
        post1 = create_blog_post!(site_id: site.id)
        post2 = create_blog_post!(site_id: site.id)
        collection = create_collection!(site_id: site.id)

        assignment1 = create_post_collection!(post_id: post1.id, collection_id: collection.id)
        assignment2 = create_post_collection!(post_id: post2.id, collection_id: collection.id)

        assert assignment1.collection_id == assignment2.collection_id
        assert assignment1.post_id != assignment2.post_id
      end

      test "sets inserted_at timestamp" do
        site = create_site!()
        post = create_blog_post!(site_id: site.id)
        collection = create_collection!(site_id: site.id)

        assignment = create_post_collection!(post_id: post.id, collection_id: collection.id)

        assert %DateTime{} = assignment.inserted_at
      end
    end

    describe "destroy action" do
      test "removes post from collection" do
        site = create_site!()
        post = create_blog_post!(site_id: site.id)
        collection = create_collection!(site_id: site.id)

        assignment = create_post_collection!(post_id: post.id, collection_id: collection.id)

        assignment
        |> Ash.Changeset.for_destroy(:destroy, %{}, authorize?: false)
        |> Ash.destroy!()

        # Verify it's removed
        all_assignments = Ash.read!(PostCollection, authorize?: false)

        refute Enum.any?(all_assignments, fn a ->
                 a.post_id == post.id and a.collection_id == collection.id
               end)
      end

      test "does not delete related post when assignment is removed" do
        site = create_site!()
        post = create_blog_post!(site_id: site.id)
        collection = create_collection!(site_id: site.id)

        assignment = create_post_collection!(post_id: post.id, collection_id: collection.id)

        assignment
        |> Ash.Changeset.for_destroy(:destroy, %{}, authorize?: false)
        |> Ash.destroy!()

        # Post should still exist
        fetched_post = Ash.get!(MishkaBlog.BlogPost, post.id, authorize?: false, tenant: site.id)
        assert fetched_post.id == post.id
      end

      test "does not delete related collection when assignment is removed" do
        site = create_site!()
        post = create_blog_post!(site_id: site.id)
        collection = create_collection!(site_id: site.id)

        assignment = create_post_collection!(post_id: post.id, collection_id: collection.id)

        assignment
        |> Ash.Changeset.for_destroy(:destroy, %{}, authorize?: false)
        |> Ash.destroy!()

        # Collection should still exist
        fetched_collection =
          Ash.get!(MishkaBlog.Collection, collection.id, authorize?: false, tenant: site.id)

        assert fetched_collection.id == collection.id
      end
    end

    describe "read actions" do
      test "lists all post-collection assignments" do
        site = create_site!()
        post1 = create_blog_post!(site_id: site.id)
        post2 = create_blog_post!(site_id: site.id)
        collection = create_collection!(site_id: site.id)

        _assignment1 = create_post_collection!(post_id: post1.id, collection_id: collection.id)
        _assignment2 = create_post_collection!(post_id: post2.id, collection_id: collection.id)

        all_assignments = Ash.read!(PostCollection, authorize?: false)

        assert Enum.any?(all_assignments, fn a ->
                 a.post_id == post1.id and a.collection_id == collection.id
               end)

        assert Enum.any?(all_assignments, fn a ->
                 a.post_id == post2.id and a.collection_id == collection.id
               end)
      end

      test "pagination works on read action" do
        site = create_site!()
        collection = create_collection!(site_id: site.id)

        # Create 5 post assignments
        _posts =
          for _ <- 1..5 do
            post = create_blog_post!(site_id: site.id)
            create_post_collection!(post_id: post.id, collection_id: collection.id)
            post
          end

        result =
          PostCollection
          |> Ash.Query.page(limit: 3, count: true)
          |> Ash.read!(authorize?: false)

        assert length(result.results) == 3
        assert result.count >= 5
      end
    end

    describe "database references" do
      test "assignment references valid post and collection" do
        site = create_site!()
        post = create_blog_post!(site_id: site.id)
        collection = create_collection!(site_id: site.id)

        assignment = create_post_collection!(post_id: post.id, collection_id: collection.id)

        # Verify assignment has valid foreign keys
        assert assignment.post_id == post.id
        assert assignment.collection_id == collection.id

        # Note: Both BlogPost and Collection use soft deletion (archival),
        # so cascade deletes only trigger on permanent_destroy
      end
    end

    describe "relationships" do
      test "loads post relationship" do
        site = create_site!()
        post = create_blog_post!(site_id: site.id)
        collection = create_collection!(site_id: site.id)

        _assignment = create_post_collection!(post_id: post.id, collection_id: collection.id)

        # Load assignments, find ours, then load the post with tenant
        assignment =
          PostCollection
          |> Ash.read!(authorize?: false)
          |> Enum.find(fn a -> a.post_id == post.id and a.collection_id == collection.id end)

        # Load the post relationship
        loaded_assignment = Ash.load!(assignment, [:post], tenant: site.id, authorize?: false)
        assert loaded_assignment.post.id == post.id
      end

      test "loads collection relationship" do
        site = create_site!()
        post = create_blog_post!(site_id: site.id)
        collection = create_collection!(site_id: site.id)

        _assignment = create_post_collection!(post_id: post.id, collection_id: collection.id)

        # Load assignments, find ours, then load the collection with tenant
        assignment =
          PostCollection
          |> Ash.read!(authorize?: false)
          |> Enum.find(fn a -> a.post_id == post.id and a.collection_id == collection.id end)

        # Load the collection relationship
        loaded_assignment =
          Ash.load!(assignment, [:collection], tenant: site.id, authorize?: false)

        assert loaded_assignment.collection.id == collection.id
      end
    end

    describe "identities" do
      test "unique_post_collection prevents duplicate assignments" do
        site = create_site!()
        post = create_blog_post!(site_id: site.id)
        collection = create_collection!(site_id: site.id)

        # First assignment
        create_post_collection!(post_id: post.id, collection_id: collection.id)

        # Second assignment should upsert (not error)
        _assignment2 = create_post_collection!(post_id: post.id, collection_id: collection.id)

        # Should only have 1 assignment for this post+collection combination
        all_assignments = Ash.read!(PostCollection, authorize?: false)

        matching_assignments =
          Enum.filter(all_assignments, fn a ->
            a.post_id == post.id and a.collection_id == collection.id
          end)

        assert length(matching_assignments) == 1
      end
    end
  end
end
