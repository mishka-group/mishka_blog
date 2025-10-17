defmodule MishkaBlog.Test.CommentTest do
  @moduledoc """
  Tests for MishkaBlog.Comment resource - comprehensive unit tests for comment functionality.
  """
  use MishkaBlog.DataCase, async: false
  require Ash.Query

  if Code.ensure_loaded?(MishkaBlog) do
    alias MishkaBlog.Comment

    describe "resource configuration" do
      test "uses correct table name" do
        assert AshPostgres.DataLayer.Info.table(Comment) == "mishka_blog_comments"
      end

      test "has UUID primary key" do
        site = create_site!()
        post = create_blog_post!(site_id: site.id)
        comment = create_comment!(post_id: post.id, content: "Test comment")

        assert is_binary(comment.id)
        assert String.length(comment.id) == 36
      end

      test "uses multi-tenancy with site_id" do
        multitenancy_config = Ash.Resource.Info.multitenancy_strategy(Comment)
        assert multitenancy_config == :attribute
        assert Ash.Resource.Info.multitenancy_attribute(Comment) == :site_id
        assert Ash.Resource.Info.multitenancy_global?(Comment) == false
      end
    end

    describe "create action" do
      test "creates comment with required fields" do
        site = create_site!()
        post = create_blog_post!(site_id: site.id)

        comment =
          create_comment!(
            post_id: post.id,
            content: "This is a test comment",
            status: :pending
          )

        assert comment.post_id == post.id
        assert comment.content == "This is a test comment"
        assert comment.status == :pending
        assert comment.inserted_at != nil
        assert comment.updated_at != nil
      end

      test "creates comment with authenticated user" do
        site = create_site!()
        post = create_blog_post!(site_id: site.id)
        user = create_user!()

        comment =
          create_comment!(
            post_id: post.id,
            author_id: user.id,
            content: "User comment"
          )

        assert comment.author_id == user.id
        assert comment.content == "User comment"
      end

      test "creates guest comment (null author_id)" do
        site = create_site!()
        post = create_blog_post!(site_id: site.id)

        comment =
          create_comment!(
            post_id: post.id,
            author_id: nil,
            content: "Guest comment"
          )

        assert comment.author_id == nil
        assert comment.content == "Guest comment"
      end

      test "creates comment with sender data" do
        site = create_site!()
        post = create_blog_post!(site_id: site.id)

        comment =
          create_comment!(
            post_id: post.id,
            content: "Test comment",
            sender_data: %{
              ip_address: "192.168.1.100",
              user_agent: "Mozilla/5.0"
            }
          )

        assert comment.sender_data.ip_address == "192.168.1.100"
        assert comment.sender_data.user_agent == "Mozilla/5.0"
      end

      test "default status is pending" do
        site = create_site!()
        post = create_blog_post!(site_id: site.id)

        comment = create_comment!(post_id: post.id, content: "Test")

        assert comment.status == :pending
      end

      test "default is_pinned is false" do
        site = create_site!()
        post = create_blog_post!(site_id: site.id)

        comment = create_comment!(post_id: post.id, content: "Test")

        assert comment.is_pinned == false
      end

      test "validates content is not empty" do
        site = create_site!()
        post = create_blog_post!(site_id: site.id)

        assert_raise Ash.Error.Invalid, fn ->
          Comment
          |> Ash.Changeset.for_create(
            :create,
            %{
              post_id: post.id,
              content: "   ",
              status: :pending
            },
            authorize?: false
          )
          |> Ash.create!()
        end
      end

      test "validates status is one of valid values" do
        site = create_site!()
        post = create_blog_post!(site_id: site.id)

        assert_raise Ash.Error.Invalid, fn ->
          Comment
          |> Ash.Changeset.for_create(
            :create,
            %{
              post_id: post.id,
              content: "Test",
              status: :invalid_status
            },
            authorize?: false
          )
          |> Ash.create!()
        end
      end
    end

    describe "threaded comments (parent-child relationships)" do
      test "creates top-level comment (no parent)" do
        site = create_site!()
        post = create_blog_post!(site_id: site.id)

        comment =
          create_comment!(
            post_id: post.id,
            content: "Top level comment",
            parent_comment_id: nil
          )

        assert comment.parent_comment_id == nil
      end

      test "creates reply to a comment" do
        site = create_site!()
        post = create_blog_post!(site_id: site.id)
        parent = create_comment!(post_id: post.id, content: "Parent comment")

        reply =
          create_comment!(
            post_id: post.id,
            parent_comment_id: parent.id,
            content: "Reply to parent"
          )

        assert reply.parent_comment_id == parent.id
      end

      test "loads replies relationship" do
        site = create_site!()
        post = create_blog_post!(site_id: site.id)
        parent = create_comment!(post_id: post.id, content: "Parent")

        _reply1 =
          create_comment!(post_id: post.id, parent_comment_id: parent.id, content: "Reply 1")

        _reply2 =
          create_comment!(post_id: post.id, parent_comment_id: parent.id, content: "Reply 2")

        loaded_parent = Ash.load!(parent, [:replies], authorize?: false)

        assert length(loaded_parent.replies) == 2
      end

      test "loads parent_comment relationship" do
        site = create_site!()
        post = create_blog_post!(site_id: site.id)
        parent = create_comment!(post_id: post.id, content: "Parent")
        reply = create_comment!(post_id: post.id, parent_comment_id: parent.id, content: "Reply")

        loaded_reply = Ash.load!(reply, [:parent_comment], authorize?: false)

        assert loaded_reply.parent_comment.id == parent.id
      end
    end

    describe "update action" do
      test "updates comment content" do
        site = create_site!()
        post = create_blog_post!(site_id: site.id)
        comment = create_comment!(post_id: post.id, content: "Original")

        updated =
          comment
          |> Ash.Changeset.for_update(:update, %{content: "Updated content"}, authorize?: false)
          |> Ash.update!()

        assert updated.content == "Updated content"
      end

      test "updates comment status" do
        site = create_site!()
        post = create_blog_post!(site_id: site.id)
        comment = create_comment!(post_id: post.id, content: "Test", status: :pending)

        updated =
          comment
          |> Ash.Changeset.for_update(:update, %{status: :approved}, authorize?: false)
          |> Ash.update!()

        assert updated.status == :approved
      end

      test "cannot update archived comment" do
        site = create_site!()
        post = create_blog_post!(site_id: site.id)
        comment = create_comment!(post_id: post.id, content: "Test")

        # Archive the comment
        comment
        |> Ash.Changeset.for_destroy(:destroy, %{}, authorize?: false)
        |> Ash.destroy!()

        # Try to update archived comment - database trigger prevents this
        assert_raise Ash.Error.Unknown, fn ->
          comment
          |> Ash.Changeset.for_update(:update, %{content: "Updated"}, authorize?: false)
          |> Ash.update!()
        end
      end

      test "prevents comment from being its own parent" do
        site = create_site!()
        post = create_blog_post!(site_id: site.id)
        comment = create_comment!(post_id: post.id, content: "Test")

        assert_raise Ash.Error.Invalid, fn ->
          comment
          |> Ash.Changeset.for_update(:update, %{parent_comment_id: comment.id},
            authorize?: false
          )
          |> Ash.update!()
        end
      end
    end

    describe "moderation actions" do
      test "approve action sets status to approved" do
        site = create_site!()
        post = create_blog_post!(site_id: site.id)
        comment = create_comment!(post_id: post.id, content: "Test", status: :pending)

        approved =
          comment
          |> Ash.Changeset.for_update(:approve, %{}, authorize?: false)
          |> Ash.update!()

        assert approved.status == :approved
      end

      test "flag action sets status to flagged" do
        site = create_site!()
        post = create_blog_post!(site_id: site.id)
        comment = create_comment!(post_id: post.id, content: "Test", status: :approved)

        flagged =
          comment
          |> Ash.Changeset.for_update(:flag, %{}, authorize?: false)
          |> Ash.update!()

        assert flagged.status == :flagged
      end

      test "mark_spam action sets status to spam" do
        site = create_site!()
        post = create_blog_post!(site_id: site.id)
        comment = create_comment!(post_id: post.id, content: "Test", status: :pending)

        spam =
          comment
          |> Ash.Changeset.for_update(:mark_spam, %{}, authorize?: false)
          |> Ash.update!()

        assert spam.status == :spam
      end

      test "pin action sets is_pinned to true" do
        site = create_site!()
        post = create_blog_post!(site_id: site.id)
        comment = create_comment!(post_id: post.id, content: "Test")

        pinned =
          comment
          |> Ash.Changeset.for_update(:pin, %{}, authorize?: false)
          |> Ash.update!()

        assert pinned.is_pinned == true
      end

      test "unpin action sets is_pinned to false" do
        site = create_site!()
        post = create_blog_post!(site_id: site.id)
        comment = create_comment!(post_id: post.id, content: "Test", is_pinned: true)

        unpinned =
          comment
          |> Ash.Changeset.for_update(:unpin, %{}, authorize?: false)
          |> Ash.update!()

        assert unpinned.is_pinned == false
      end
    end

    describe "read actions" do
      test "read with filter finds comments by post_id" do
        site = create_site!()
        post1 = create_blog_post!(site_id: site.id)
        post2 = create_blog_post!(site_id: site.id)

        comment1 = create_comment!(post_id: post1.id, content: "Comment on post 1")
        _comment2 = create_comment!(post_id: post2.id, content: "Comment on post 2")

        comments =
          Comment
          |> Ash.Query.for_read(:read, %{}, tenant: site.id, authorize?: false)
          |> Ash.Query.filter(post_id == ^post1.id)
          |> Ash.read!(authorize?: false)

        comment_ids = Enum.map(comments, & &1.id)
        assert comment1.id in comment_ids
        assert length(comments) == 1
      end

      test "read with filter finds comments by status" do
        site = create_site!()
        post = create_blog_post!(site_id: site.id)

        pending = create_comment!(post_id: post.id, content: "Pending", status: :pending)
        _approved = create_comment!(post_id: post.id, content: "Approved", status: :approved)

        comments =
          Comment
          |> Ash.Query.for_read(:read, %{}, tenant: site.id, authorize?: false)
          |> Ash.Query.filter(status == :pending)
          |> Ash.read!(authorize?: false)

        comment_ids = Enum.map(comments, & &1.id)
        assert pending.id in comment_ids
      end

      test "read with filter finds only pending comments" do
        site = create_site!()
        post = create_blog_post!(site_id: site.id)

        pending = create_comment!(post_id: post.id, content: "Pending", status: :pending)
        _approved = create_comment!(post_id: post.id, content: "Approved", status: :approved)

        comments =
          Comment
          |> Ash.Query.for_read(:read, %{}, tenant: site.id, authorize?: false)
          |> Ash.Query.filter(status == :pending)
          |> Ash.read!(authorize?: false)

        comment_ids = Enum.map(comments, & &1.id)
        assert pending.id in comment_ids
      end

      test "read with filter finds only approved comments" do
        site = create_site!()
        post = create_blog_post!(site_id: site.id)

        _pending = create_comment!(post_id: post.id, content: "Pending", status: :pending)
        approved = create_comment!(post_id: post.id, content: "Approved", status: :approved)

        comments =
          Comment
          |> Ash.Query.for_read(:read, %{}, tenant: site.id, authorize?: false)
          |> Ash.Query.filter(status == :approved)
          |> Ash.read!(authorize?: false)

        comment_ids = Enum.map(comments, & &1.id)
        assert approved.id in comment_ids
      end

      test "read with filter finds only flagged comments" do
        site = create_site!()
        post = create_blog_post!(site_id: site.id)

        _pending = create_comment!(post_id: post.id, content: "Pending", status: :pending)
        flagged = create_comment!(post_id: post.id, content: "Flagged", status: :flagged)

        comments =
          Comment
          |> Ash.Query.for_read(:read, %{}, tenant: site.id, authorize?: false)
          |> Ash.Query.filter(status == :flagged)
          |> Ash.read!(authorize?: false)

        comment_ids = Enum.map(comments, & &1.id)
        assert flagged.id in comment_ids
      end

      test "read with filter finds only spam comments" do
        site = create_site!()
        post = create_blog_post!(site_id: site.id)

        _pending = create_comment!(post_id: post.id, content: "Pending", status: :pending)
        spam = create_comment!(post_id: post.id, content: "Spam", status: :spam)

        comments =
          Comment
          |> Ash.Query.for_read(:read, %{}, tenant: site.id, authorize?: false)
          |> Ash.Query.filter(status == :spam)
          |> Ash.read!(authorize?: false)

        comment_ids = Enum.map(comments, & &1.id)
        assert spam.id in comment_ids
      end

      test "read with filter finds only pinned comments" do
        site = create_site!()
        post = create_blog_post!(site_id: site.id)

        _unpinned = create_comment!(post_id: post.id, content: "Unpinned", is_pinned: false)
        pinned = create_comment!(post_id: post.id, content: "Pinned", is_pinned: true)

        comments =
          Comment
          |> Ash.Query.for_read(:read, %{}, tenant: site.id, authorize?: false)
          |> Ash.Query.filter(is_pinned == true)
          |> Ash.read!(authorize?: false)

        comment_ids = Enum.map(comments, & &1.id)
        assert pinned.id in comment_ids
      end

      test "pagination works with post filter" do
        site = create_site!()
        post = create_blog_post!(site_id: site.id)

        for i <- 1..10 do
          create_comment!(post_id: post.id, content: "Comment #{i}")
        end

        result =
          Comment
          |> Ash.Query.for_read(:read, %{}, tenant: site.id, authorize?: false)
          |> Ash.Query.filter(post_id == ^post.id)
          |> Ash.Query.page(limit: 5, count: true)
          |> Ash.read!(authorize?: false)

        assert length(result.results) == 5
        assert result.count == 10
      end
    end

    describe "soft deletion (archival)" do
      test "destroy archives comment (soft delete)" do
        site = create_site!()
        post = create_blog_post!(site_id: site.id)
        comment = create_comment!(post_id: post.id, content: "Test")

        comment
        |> Ash.Changeset.for_destroy(:destroy, %{}, authorize?: false)
        |> Ash.destroy!()

        # Comment should not appear in default reads
        all_comments = Ash.read!(Comment, tenant: site.id, authorize?: false)
        refute Enum.any?(all_comments, fn c -> c.id == comment.id end)
      end

      test "archived action finds archived comments" do
        site = create_site!()
        post = create_blog_post!(site_id: site.id)
        comment = create_comment!(post_id: post.id, content: "Test")

        comment
        |> Ash.Changeset.for_destroy(:destroy, %{}, authorize?: false)
        |> Ash.destroy!()

        result =
          Comment
          |> Ash.Query.for_read(:archived, %{}, tenant: site.id, authorize?: false)
          |> Ash.read!(authorize?: false)

        comment_ids = Enum.map(result.results, & &1.id)
        assert comment.id in comment_ids
      end

      test "get_archived retrieves single archived comment" do
        site = create_site!()
        post = create_blog_post!(site_id: site.id)
        comment = create_comment!(post_id: post.id, content: "Test")

        comment
        |> Ash.Changeset.for_destroy(:destroy, %{}, authorize?: false)
        |> Ash.destroy!()

        archived_comment =
          Ash.get!(Comment, comment.id, action: :get_archived, tenant: site.id, authorize?: false)

        assert archived_comment.id == comment.id
        assert archived_comment.archived_at != nil
      end

      test "cannot archive already archived comment" do
        site = create_site!()
        post = create_blog_post!(site_id: site.id)
        comment = create_comment!(post_id: post.id, content: "Test")

        # Archive once
        comment
        |> Ash.Changeset.for_destroy(:destroy, %{}, authorize?: false)
        |> Ash.destroy!()

        # Try to archive again - database trigger prevents updating archived records
        assert_raise Ash.Error.Unknown, fn ->
          comment
          |> Ash.Changeset.for_destroy(:destroy, %{}, authorize?: false)
          |> Ash.destroy!()
        end
      end

      test "unarchive restores archived comment" do
        site = create_site!()
        post = create_blog_post!(site_id: site.id)
        comment = create_comment!(post_id: post.id, content: "Test")

        # Archive
        comment
        |> Ash.Changeset.for_destroy(:destroy, %{}, authorize?: false)
        |> Ash.destroy!()

        # Unarchive
        archived =
          Ash.get!(Comment, comment.id, action: :get_archived, tenant: site.id, authorize?: false)

        unarchived =
          archived
          |> Ash.Changeset.for_update(:unarchive, %{}, authorize?: false)
          |> Ash.update!()

        assert unarchived.archived_at == nil

        # Should appear in default reads again
        all_comments = Ash.read!(Comment, tenant: site.id, authorize?: false)
        assert Enum.any?(all_comments, fn c -> c.id == comment.id end)
      end

      test "permanent_destroy removes comment completely" do
        site = create_site!()
        post = create_blog_post!(site_id: site.id)
        comment = create_comment!(post_id: post.id, content: "Test")
        comment_id = comment.id

        comment
        |> Ash.Changeset.for_destroy(:permanent_destroy, %{}, authorize?: false)
        |> Ash.destroy!()

        # Should not exist anywhere - Ash wraps NotFound in Invalid
        assert_raise Ash.Error.Invalid, fn ->
          Ash.get!(Comment, comment_id, authorize?: false)
        end

        # Not in archived either
        archived =
          Comment
          |> Ash.Query.for_read(:archived, %{}, tenant: site.id, authorize?: false)
          |> Ash.read!(authorize?: false)

        refute Enum.any?(archived.results, fn c -> c.id == comment_id end)
      end
    end

    describe "relationships" do
      test "loads post relationship" do
        site = create_site!()
        post = create_blog_post!(site_id: site.id)
        comment = create_comment!(post_id: post.id, content: "Test")

        loaded_comment = Ash.load!(comment, [:post], tenant: site.id, authorize?: false)
        assert loaded_comment.post.id == post.id
      end

      test "loads author relationship" do
        site = create_site!()
        post = create_blog_post!(site_id: site.id)
        user = create_user!()
        comment = create_comment!(post_id: post.id, author_id: user.id, content: "Test")

        # Verify author_id is correctly set
        assert comment.author_id == user.id

        # Verify we can fetch the user directly
        author = Ash.get!(MishkaCmsCore.Accounts.User, user.id, authorize?: false)
        assert author.id == user.id
      end
    end

    describe "create_public action" do
      test "creates comment with authenticated user as author" do
        site = create_site!()
        post = create_blog_post!(site_id: site.id)
        user = create_user!()

        comment =
          Comment
          |> Ash.Changeset.for_create(
            :create_public,
            %{
              post_id: post.id,
              content: "This is a public comment"
            },
            actor: user,
            tenant: site.id,
            authorize?: false
          )
          |> Ash.create!()

        assert comment.content == "This is a public comment"
        assert comment.post_id == post.id
        assert comment.author_id == user.id
        assert comment.status == :pending
      end

      test "automatically sets status to pending" do
        site = create_site!()
        post = create_blog_post!(site_id: site.id)
        user = create_user!()

        comment =
          Comment
          |> Ash.Changeset.for_create(
            :create_public,
            %{
              post_id: post.id,
              content: "Comment content"
            },
            actor: user,
            tenant: site.id,
            authorize?: false
          )
          |> Ash.create!()

        assert comment.status == :pending
      end

      test "creates top-level comment without parent" do
        site = create_site!()
        post = create_blog_post!(site_id: site.id)
        user = create_user!()

        comment =
          Comment
          |> Ash.Changeset.for_create(
            :create_public,
            %{
              post_id: post.id,
              content: "Top level comment"
            },
            actor: user,
            tenant: site.id,
            authorize?: false
          )
          |> Ash.create!()

        assert comment.parent_comment_id == nil
        assert comment.content == "Top level comment"
      end

      test "creates reply to existing comment" do
        site = create_site!()
        post = create_blog_post!(site_id: site.id)
        user1 = create_user!()
        user2 = create_user!()

        parent_comment =
          Comment
          |> Ash.Changeset.for_create(
            :create_public,
            %{
              post_id: post.id,
              content: "Parent comment"
            },
            actor: user1,
            tenant: site.id,
            authorize?: false
          )
          |> Ash.create!()

        reply =
          Comment
          |> Ash.Changeset.for_create(
            :create_public,
            %{
              post_id: post.id,
              parent_comment_id: parent_comment.id,
              content: "Reply to parent"
            },
            actor: user2,
            tenant: site.id,
            authorize?: false
          )
          |> Ash.create!()

        assert reply.parent_comment_id == parent_comment.id
        assert reply.post_id == post.id
        assert reply.author_id == user2.id
      end

      test "validates parent comment belongs to same post" do
        site = create_site!()
        post1 = create_blog_post!(site_id: site.id)
        post2 = create_blog_post!(site_id: site.id)
        user = create_user!()

        parent_comment =
          Comment
          |> Ash.Changeset.for_create(
            :create_public,
            %{
              post_id: post1.id,
              content: "Comment on post 1"
            },
            actor: user,
            tenant: site.id,
            authorize?: false
          )
          |> Ash.create!()

        # Try to create reply on post2 with parent from post1
        assert_raise Ash.Error.Invalid, fn ->
          Comment
          |> Ash.Changeset.for_create(
            :create_public,
            %{
              post_id: post2.id,
              parent_comment_id: parent_comment.id,
              content: "Invalid reply"
            },
            actor: user,
            tenant: site.id,
            authorize?: false
          )
          |> Ash.create!()
        end
      end

      test "validates parent comment exists" do
        site = create_site!()
        post = create_blog_post!(site_id: site.id)
        user = create_user!()
        fake_parent_id = Ash.UUID.generate()

        # Try to create reply with non-existent parent
        assert_raise Ash.Error.Invalid, fn ->
          Comment
          |> Ash.Changeset.for_create(
            :create_public,
            %{
              post_id: post.id,
              parent_comment_id: fake_parent_id,
              content: "Reply to non-existent parent"
            },
            actor: user,
            tenant: site.id,
            authorize?: false
          )
          |> Ash.create!()
        end
      end

      test "only accepts specified fields" do
        site = create_site!()
        post = create_blog_post!(site_id: site.id)
        user = create_user!()

        comment =
          Comment
          |> Ash.Changeset.for_create(
            :create_public,
            %{
              post_id: post.id,
              content: "Comment"
            },
            actor: user,
            tenant: site.id,
            authorize?: false
          )
          |> Ash.create!()

        # Status should be forced to pending (not customizable by user)
        assert comment.status == :pending
        # is_pinned should use default value (false, not customizable by user)
        assert comment.is_pinned == false
      end
    end

    describe "my_comments read action" do
      test "returns only authenticated user's comments" do
        site = create_site!()
        post = create_blog_post!(site_id: site.id)
        user1 = create_user!()
        user2 = create_user!()

        # User 1 creates 3 comments
        for i <- 1..3 do
          Comment
          |> Ash.Changeset.for_create(
            :create_public,
            %{post_id: post.id, content: "User 1 comment #{i}"},
            actor: user1,
            tenant: site.id,
            authorize?: false
          )
          |> Ash.create!()
        end

        # User 2 creates 2 comments
        for i <- 1..2 do
          Comment
          |> Ash.Changeset.for_create(
            :create_public,
            %{post_id: post.id, content: "User 2 comment #{i}"},
            actor: user2,
            tenant: site.id,
            authorize?: false
          )
          |> Ash.create!()
        end

        # Read user1's comments
        result =
          Comment
          |> Ash.Query.for_read(:my_comments, %{},
            actor: user1,
            tenant: site.id,
            authorize?: false
          )
          |> Ash.read!(authorize?: false)

        assert length(result.results) == 3
        assert Enum.all?(result.results, &(&1.author_id == user1.id))
      end

      test "pagination works on my_comments" do
        site = create_site!()
        post = create_blog_post!(site_id: site.id)
        user = create_user!()

        # Create 25 comments
        for i <- 1..25 do
          Comment
          |> Ash.Changeset.for_create(
            :create_public,
            %{post_id: post.id, content: "Comment #{i}"},
            actor: user,
            tenant: site.id,
            authorize?: false
          )
          |> Ash.create!()
        end

        # Read first page (default limit is 20)
        result =
          Comment
          |> Ash.Query.for_read(:my_comments, %{},
            actor: user,
            tenant: site.id,
            authorize?: false
          )
          |> Ash.Query.page(count: true)
          |> Ash.read!(authorize?: false)

        assert length(result.results) == 20
        assert result.count == 25
      end

      test "returns empty list when user has no comments" do
        site = create_site!()
        user = create_user!()

        result =
          Comment
          |> Ash.Query.for_read(:my_comments, %{},
            actor: user,
            tenant: site.id,
            authorize?: false
          )
          |> Ash.read!(authorize?: false)

        assert result.results == []
      end
    end

    describe "approved_by_post read action" do
      test "returns only approved comments for specific post" do
        site = create_site!()
        post = create_blog_post!(site_id: site.id)

        # Create comments with different statuses
        approved1 = create_comment!(post_id: post.id, content: "Approved 1", status: :approved)
        approved2 = create_comment!(post_id: post.id, content: "Approved 2", status: :approved)
        _pending = create_comment!(post_id: post.id, content: "Pending", status: :pending)
        _flagged = create_comment!(post_id: post.id, content: "Flagged", status: :flagged)
        _spam = create_comment!(post_id: post.id, content: "Spam", status: :spam)

        result =
          Comment
          |> Ash.Query.for_read(:approved_by_post, %{post_id: post.id},
            tenant: site.id,
            authorize?: false
          )
          |> Ash.read!(authorize?: false)

        assert length(result.results) == 2

        result_ids = Enum.map(result.results, & &1.id) |> Enum.sort()
        expected_ids = [approved1.id, approved2.id] |> Enum.sort()
        assert result_ids == expected_ids

        assert Enum.all?(result.results, &(&1.status == :approved))
      end

      test "does not return comments from other posts" do
        site = create_site!()
        post1 = create_blog_post!(site_id: site.id)
        post2 = create_blog_post!(site_id: site.id)

        # Create approved comments on post1
        _comment1 =
          create_comment!(post_id: post1.id, content: "Post 1 comment", status: :approved)

        # Create approved comments on post2
        _comment2 =
          create_comment!(post_id: post2.id, content: "Post 2 comment", status: :approved)

        # Query post1's approved comments
        result =
          Comment
          |> Ash.Query.for_read(:approved_by_post, %{post_id: post1.id},
            tenant: site.id,
            authorize?: false
          )
          |> Ash.read!(authorize?: false)

        assert length(result.results) == 1
        assert hd(result.results).post_id == post1.id
      end

      test "pagination works on approved_by_post" do
        site = create_site!()
        post = create_blog_post!(site_id: site.id)

        # Create 25 approved comments
        for i <- 1..25 do
          create_comment!(post_id: post.id, content: "Comment #{i}", status: :approved)
        end

        result =
          Comment
          |> Ash.Query.for_read(:approved_by_post, %{post_id: post.id},
            tenant: site.id,
            authorize?: false
          )
          |> Ash.Query.page(limit: 10, count: true)
          |> Ash.read!(authorize?: false)

        assert length(result.results) == 10
        assert result.count == 25
      end

      test "returns empty list when post has no approved comments" do
        site = create_site!()
        post = create_blog_post!(site_id: site.id)

        # Create only pending comments
        _pending = create_comment!(post_id: post.id, content: "Pending", status: :pending)

        result =
          Comment
          |> Ash.Query.for_read(:approved_by_post, %{post_id: post.id},
            tenant: site.id,
            authorize?: false
          )
          |> Ash.read!(authorize?: false)

        assert result.results == []
      end
    end

    # ============================================================================
    # MASTER ACTIONS TESTS
    # ============================================================================

    describe "master_read action" do
      test "reads all comments system-wide bypassing tenant" do
        site1 = create_site!()
        site2 = create_site!()
        post1 = create_blog_post!(site_id: site1.id)
        post2 = create_blog_post!(site_id: site2.id)

        comment1 = create_comment!(post_id: post1.id, content: "Site 1 comment")
        comment2 = create_comment!(post_id: post2.id, content: "Site 2 comment")

        # Master read should see comments from all sites
        result =
          Comment
          |> Ash.Query.for_read(:master_read, %{}, authorize?: false)
          |> Ash.read!(authorize?: false)

        comment_ids = Enum.map(result.results, & &1.id)
        assert comment1.id in comment_ids
        assert comment2.id in comment_ids
      end
    end

    describe "master_get action" do
      test "gets a single comment bypassing tenant" do
        site = create_site!()
        post = create_blog_post!(site_id: site.id)
        comment = create_comment!(post_id: post.id, content: "Test comment")

        # Master get without tenant context
        fetched = Ash.get!(Comment, comment.id, action: :master_get, authorize?: false)

        assert fetched.id == comment.id
        assert fetched.content == "Test comment"
      end
    end

    describe "master_archived action" do
      test "reads all archived comments system-wide" do
        site1 = create_site!()
        site2 = create_site!()
        post1 = create_blog_post!(site_id: site1.id)
        post2 = create_blog_post!(site_id: site2.id)

        comment1 = create_comment!(post_id: post1.id, content: "Site 1 comment")
        comment2 = create_comment!(post_id: post2.id, content: "Site 2 comment")

        # Archive both comments
        comment1
        |> Ash.Changeset.for_destroy(:destroy, %{}, authorize?: false)
        |> Ash.destroy!()

        comment2
        |> Ash.Changeset.for_destroy(:destroy, %{}, authorize?: false)
        |> Ash.destroy!()

        # Master archived should see archived comments from all sites
        result =
          Comment
          |> Ash.Query.for_read(:master_archived, %{}, authorize?: false)
          |> Ash.read!(authorize?: false)

        comment_ids = Enum.map(result.results, & &1.id)
        assert comment1.id in comment_ids
        assert comment2.id in comment_ids
      end
    end

    describe "master_get_archived action" do
      test "gets a single archived comment bypassing tenant" do
        site = create_site!()
        post = create_blog_post!(site_id: site.id)
        comment = create_comment!(post_id: post.id, content: "Test comment")

        # Archive the comment
        comment
        |> Ash.Changeset.for_destroy(:destroy, %{}, authorize?: false)
        |> Ash.destroy!()

        # Master get archived without tenant context
        fetched = Ash.get!(Comment, comment.id, action: :master_get_archived, authorize?: false)

        assert fetched.id == comment.id
        assert fetched.archived_at != nil
      end
    end

    describe "master_update action" do
      test "updates comment bypassing tenant" do
        site = create_site!()
        post = create_blog_post!(site_id: site.id)
        comment = create_comment!(post_id: post.id, content: "Original content")

        {:ok, updated} =
          comment
          |> Ash.Changeset.for_update(
            :master_update,
            %{content: "Master updated content"},
            authorize?: false
          )
          |> Ash.update()

        assert updated.content == "Master updated content"
      end

      test "updates comment status via master_update" do
        site = create_site!()
        post = create_blog_post!(site_id: site.id)
        comment = create_comment!(post_id: post.id, content: "Test", status: :pending)

        {:ok, updated} =
          comment
          |> Ash.Changeset.for_update(
            :master_update,
            %{status: :approved},
            authorize?: false
          )
          |> Ash.update()

        assert updated.status == :approved
      end

      test "cannot update archived comment via master_update" do
        site = create_site!()
        post = create_blog_post!(site_id: site.id)
        comment = create_comment!(post_id: post.id, content: "Test")

        # Archive the comment
        comment
        |> Ash.Changeset.for_destroy(:destroy, %{}, authorize?: false)
        |> Ash.destroy!()

        # Try to update via master_update - database trigger prevents this
        assert_raise Ash.Error.Unknown, fn ->
          comment
          |> Ash.Changeset.for_update(
            :master_update,
            %{content: "Updated"},
            authorize?: false
          )
          |> Ash.update!()
        end
      end

      test "prevents comment from being its own parent via master_update" do
        site = create_site!()
        post = create_blog_post!(site_id: site.id)
        comment = create_comment!(post_id: post.id, content: "Test")

        {:error, error} =
          comment
          |> Ash.Changeset.for_update(
            :master_update,
            %{parent_comment_id: comment.id},
            authorize?: false
          )
          |> Ash.update()

        assert %Ash.Error.Invalid{} = error
      end
    end

    describe "master_destroy action" do
      test "soft deletes comment bypassing tenant" do
        site = create_site!()
        post = create_blog_post!(site_id: site.id)
        comment = create_comment!(post_id: post.id, content: "Test")

        :ok =
          comment
          |> Ash.Changeset.for_destroy(:master_destroy, %{}, authorize?: false)
          |> Ash.destroy()

        # Should appear in master_archived
        archived =
          Comment
          |> Ash.Query.for_read(:master_archived, %{}, authorize?: false)
          |> Ash.read!(authorize?: false)

        comment_ids = Enum.map(archived.results, & &1.id)
        assert comment.id in comment_ids
      end

      test "cannot archive already archived comment via master_destroy" do
        site = create_site!()
        post = create_blog_post!(site_id: site.id)
        comment = create_comment!(post_id: post.id, content: "Test")

        # Archive once
        comment
        |> Ash.Changeset.for_destroy(:master_destroy, %{}, authorize?: false)
        |> Ash.destroy!()

        # Try to archive again - database trigger prevents updating archived records
        assert_raise Ash.Error.Unknown, fn ->
          comment
          |> Ash.Changeset.for_destroy(:master_destroy, %{}, authorize?: false)
          |> Ash.destroy!()
        end
      end
    end

    describe "master_unarchive action" do
      test "restores archived comment bypassing tenant" do
        site = create_site!()
        post = create_blog_post!(site_id: site.id)
        comment = create_comment!(post_id: post.id, content: "Test")

        # Archive the comment
        comment
        |> Ash.Changeset.for_destroy(:destroy, %{}, authorize?: false)
        |> Ash.destroy!()

        # Get archived comment
        archived = Ash.get!(Comment, comment.id, action: :master_get_archived, authorize?: false)

        # Unarchive via master action
        {:ok, unarchived} =
          archived
          |> Ash.Changeset.for_update(:master_unarchive, %{}, authorize?: false)
          |> Ash.update()

        assert unarchived.archived_at == nil

        # Should appear in normal reads again
        fetched = Ash.get!(Comment, comment.id, action: :master_get, authorize?: false)
        assert fetched.id == comment.id
      end

      test "cannot unarchive non-archived comment via master_unarchive" do
        site = create_site!()
        post = create_blog_post!(site_id: site.id)
        comment = create_comment!(post_id: post.id, content: "Test")

        {:error, error} =
          comment
          |> Ash.Changeset.for_update(:master_unarchive, %{}, authorize?: false)
          |> Ash.update()

        assert %Ash.Error.Invalid{} = error
      end
    end

    describe "master_permanent_destroy action" do
      test "permanently deletes comment bypassing tenant" do
        site = create_site!()
        post = create_blog_post!(site_id: site.id)
        comment = create_comment!(post_id: post.id, content: "Test")
        comment_id = comment.id

        :ok =
          comment
          |> Ash.Changeset.for_destroy(:master_permanent_destroy, %{}, authorize?: false)
          |> Ash.destroy()

        # Should not exist anywhere
        assert_raise Ash.Error.Invalid, fn ->
          Ash.get!(Comment, comment_id, action: :master_get, authorize?: false)
        end

        # Not in archived either
        archived =
          Comment
          |> Ash.Query.for_read(:master_archived, %{}, authorize?: false)
          |> Ash.read!(authorize?: false)

        refute Enum.any?(archived.results, fn c -> c.id == comment_id end)
      end
    end

    describe "master_approve action" do
      test "approves comment bypassing tenant" do
        site = create_site!()
        post = create_blog_post!(site_id: site.id)
        comment = create_comment!(post_id: post.id, content: "Test", status: :pending)

        {:ok, approved} =
          comment
          |> Ash.Changeset.for_update(:master_approve, %{}, authorize?: false)
          |> Ash.update()

        assert approved.status == :approved
      end

      test "can approve flagged comment via master_approve" do
        site = create_site!()
        post = create_blog_post!(site_id: site.id)
        comment = create_comment!(post_id: post.id, content: "Test", status: :flagged)

        {:ok, approved} =
          comment
          |> Ash.Changeset.for_update(:master_approve, %{}, authorize?: false)
          |> Ash.update()

        assert approved.status == :approved
      end
    end

    describe "master_flag action" do
      test "flags comment bypassing tenant" do
        site = create_site!()
        post = create_blog_post!(site_id: site.id)
        comment = create_comment!(post_id: post.id, content: "Test", status: :approved)

        {:ok, flagged} =
          comment
          |> Ash.Changeset.for_update(:master_flag, %{}, authorize?: false)
          |> Ash.update()

        assert flagged.status == :flagged
      end
    end

    describe "master_mark_spam action" do
      test "marks comment as spam bypassing tenant" do
        site = create_site!()
        post = create_blog_post!(site_id: site.id)
        comment = create_comment!(post_id: post.id, content: "Test", status: :pending)

        {:ok, spam} =
          comment
          |> Ash.Changeset.for_update(:master_mark_spam, %{}, authorize?: false)
          |> Ash.update()

        assert spam.status == :spam
      end
    end

    describe "master_pin action" do
      test "pins comment bypassing tenant" do
        site = create_site!()
        post = create_blog_post!(site_id: site.id)
        comment = create_comment!(post_id: post.id, content: "Test", is_pinned: false)

        {:ok, pinned} =
          comment
          |> Ash.Changeset.for_update(:master_pin, %{}, authorize?: false)
          |> Ash.update()

        assert pinned.is_pinned == true
      end
    end

    describe "master_unpin action" do
      test "unpins comment bypassing tenant" do
        site = create_site!()
        post = create_blog_post!(site_id: site.id)
        comment = create_comment!(post_id: post.id, content: "Test", is_pinned: true)

        {:ok, unpinned} =
          comment
          |> Ash.Changeset.for_update(:master_unpin, %{}, authorize?: false)
          |> Ash.update()

        assert unpinned.is_pinned == false
      end
    end
  end
end
