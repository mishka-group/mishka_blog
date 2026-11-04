# SPDX-FileCopyrightText: 2026 Mishka Group contributors <https://github.com/mishka-group/mishka_blog/graphs/contributors>
#
# SPDX-License-Identifier: Apache-2.0

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

        assert {:ok, _} = Ecto.UUID.cast(comment.id)
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
        assert %DateTime{} = comment.inserted_at
        assert %DateTime{} = comment.updated_at
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

    describe "create action author" do
      setup do
        site = create_site!()

        %{
          site: site,
          post: create_blog_post!(site_id: site.id),
          admin: create_user_with_permissions!(["*"], site_id: site.id)
        }
      end

      defp admin_create(ctx, params) do
        Comment
        |> Ash.Changeset.for_create(
          :create,
          Map.merge(%{post_id: ctx.post.id, content: "Admin comment", status: :approved}, params),
          actor: ctx.admin,
          tenant: ctx.site.id
        )
        |> Ash.create()
      end

      test "an admin's comment keeps the author it names", ctx do
        reader = create_user!(site_id: ctx.site.id)

        assert {:ok, comment} = admin_create(ctx, %{author_id: reader.id})

        assert comment.author_id == reader.id
      end

      test "an admin's comment is the admin's own when it names no author", ctx do
        assert {:ok, comment} = admin_create(ctx, %{})

        assert comment.author_id == ctx.admin.id
      end

      test "an admin's comment is the admin's own when the author is nil", ctx do
        assert {:ok, comment} = admin_create(ctx, %{author_id: nil})

        assert comment.author_id == ctx.admin.id
      end

      test "an admin's comment refuses a user of another site as the author", ctx do
        stranger = create_user!(site_id: create_site!().id)

        assert {:error, %Ash.Error.Invalid{errors: errors}} =
                 admin_create(ctx, %{author_id: stranger.id})

        assert Enum.any?(errors, &(Map.get(&1, :field) == :author_id))

        assert Comment
               |> Ash.Query.filter(post_id == ^ctx.post.id)
               |> Ash.read!(tenant: ctx.site.id, authorize?: false) == []
      end

      test "a public comment is the reader's own and takes no other author", ctx do
        reader = create_user!(site_id: ctx.site.id)
        other = create_user!(site_id: ctx.site.id)
        published = create_blog_post!(site_id: ctx.site.id, status: :published)

        public_create = fn params ->
          Comment
          |> Ash.Changeset.for_create(
            :create_public,
            Map.merge(%{post_id: published.id, content: "Public comment"}, params),
            actor: reader,
            tenant: ctx.site.id,
            authorize?: false
          )
          |> Ash.create()
        end

        assert {:ok, comment} = public_create.(%{})
        assert comment.author_id == reader.id

        assert {:error, %Ash.Error.Invalid{}} = public_create.(%{author_id: other.id})

        assert Comment
               |> Ash.Query.filter(author_id == ^other.id)
               |> Ash.read!(tenant: ctx.site.id, authorize?: false) == []
      end
    end

    describe "guest comments" do
      setup do
        site = create_site!()

        %{
          site: site,
          post: create_blog_post!(site_id: site.id, status: :published),
          admin: create_user_with_permissions!(["*"], site_id: site.id)
        }
      end

      @guest %{
        guest_name: "Ada Guest",
        guest_email: "Ada.Guest@Example.com",
        guest_website: "https://ada.example.com/about"
      }

      defp refused_on?(result, field) do
        assert {:error, %Ash.Error.Invalid{errors: errors}} = result

        Enum.any?(errors, fn error ->
          Map.get(error, :field) == field or field in List.wrap(Map.get(error, :fields))
        end)
      end

      defp written(ctx),
        do:
          Comment
          |> Ash.Query.filter(post_id == ^ctx.post.id)
          |> Ash.read!(tenant: ctx.site.id, authorize?: false)

      test "an admin writes a guest's comment, and is not its author", ctx do
        assert {:ok, comment} = admin_create(ctx, @guest)

        assert comment.author_id == nil
        assert comment.guest_name == "Ada Guest"
        assert comment.guest_email == "ada.guest@example.com"
        assert comment.guest_website == "https://ada.example.com/about"
      end

      test "a guest's email and website are optional", ctx do
        assert {:ok, comment} = admin_create(ctx, %{guest_name: "Ada Guest"})

        assert comment.author_id == nil
        assert comment.guest_email == nil
        assert comment.guest_website == nil
      end

      test "a comment with neither an author nor a guest's name is refused", ctx do
        result =
          Comment
          |> Ash.Changeset.for_create(
            :create,
            %{post_id: ctx.post.id, content: "From nobody", status: :approved},
            tenant: ctx.site.id,
            authorize?: false
          )
          |> Ash.create()

        assert refused_on?(result, :guest_name)
        assert written(ctx) == []
      end

      test "a comment that is both a user's and a guest's is refused", ctx do
        reader = create_user!(site_id: ctx.site.id)

        assert refused_on?(admin_create(ctx, Map.put(@guest, :author_id, reader.id)), :author_id)
        assert written(ctx) == []

        {:ok, guests} = admin_create(ctx, @guest)

        result =
          guests
          |> Ash.Changeset.for_update(:update, %{author_id: reader.id},
            actor: ctx.admin,
            tenant: ctx.site.id
          )
          |> Ash.update()

        assert refused_on?(result, :author_id)
      end

      test "a guest's email or website without the guest's name is refused", ctx do
        assert refused_on?(admin_create(ctx, %{guest_email: "ada@example.com"}), :guest_email)

        assert refused_on?(
                 admin_create(ctx, %{guest_website: "https://ada.example"}),
                 :guest_email
               )

        assert written(ctx) == []
      end

      test "an email that is not one is refused", ctx do
        for email <- ["not-an-email", "ada@", "ada@example", "ada guest@example.com"] do
          assert refused_on?(admin_create(ctx, %{@guest | guest_email: email}), :guest_email),
                 "#{email} was accepted"
        end

        assert written(ctx) == []
      end

      test "a website that is not an http or https address is refused", ctx do
        for website <- [
              "javascript:alert(1)",
              "data:text/html,<b>hi</b>",
              "ftp://ada.example.com",
              "ada.example.com",
              "//ada.example.com",
              "https://"
            ] do
          assert refused_on?(
                   admin_create(ctx, %{@guest | guest_website: website}),
                   :guest_website
                 ),
                 "#{website} was accepted"
        end

        assert written(ctx) == []
      end

      test "a guest's name is plain text, and one of markup alone is refused", ctx do
        assert {:ok, comment} =
                 admin_create(ctx, %{guest_name: ~s[<b>Ada</b> <img src=x onerror="alert(1)">]})

        assert comment.guest_name == "Ada"

        assert refused_on?(admin_create(ctx, %{guest_name: "<b></b>"}), :guest_name)
      end

      test "a reader cannot write a guest's fields", ctx do
        reader = create_user!(site_id: ctx.site.id)

        public =
          Comment
          |> Ash.Changeset.for_create(
            :create_public,
            Map.merge(%{post_id: ctx.post.id, content: "Pretending"}, @guest),
            actor: reader,
            tenant: ctx.site.id
          )
          |> Ash.create()

        assert {:error, %Ash.Error.Invalid{}} = public

        admin_action =
          Comment
          |> Ash.Changeset.for_create(
            :create,
            Map.merge(%{post_id: ctx.post.id, content: "Pretending", status: :approved}, @guest),
            actor: reader,
            tenant: ctx.site.id
          )
          |> Ash.create()

        assert {:error, %Ash.Error.Forbidden{}} = admin_action
        assert written(ctx) == []
      end

      test "only a moderator reads a guest's email, through any read", ctx do
        {:ok, comment} = admin_create(ctx, @guest)

        moderator =
          create_user_with_permissions!(["admin:dashboard:blog:comment"], site_id: ctx.site.id)

        editor =
          create_user_with_permissions!(["admin:dashboard:blog:post"], site_id: ctx.site.id)

        reader = create_user!(site_id: ctx.site.id)

        read = fn action, args, actor ->
          Comment
          |> Ash.Query.for_read(action, args, actor: actor, tenant: ctx.site.id)
          |> Ash.Query.filter(id == ^comment.id)
          |> Ash.read_one!()
        end

        for {action, args} <- [
              {:public_list, %{}},
              {:public_get, %{}},
              {:approved_by_post, %{post_id: ctx.post.id}}
            ],
            actor <- [nil, reader, editor] do
          found = read.(action, args, actor)

          assert found.guest_name == "Ada Guest"
          assert found.guest_website == "https://ada.example.com/about"
          assert %Ash.ForbiddenField{} = found.guest_email
        end

        assert read.(:public_list, %{}, moderator).guest_email == "ada.guest@example.com"
        assert read.(:read, %{}, ctx.admin).guest_email == "ada.guest@example.com"
      end

      test "a filter on a guest's email matches nothing for a reader, and the comment for a moderator",
           ctx do
        {:ok, comment} = admin_create(ctx, @guest)

        moderator =
          create_user_with_permissions!(["admin:dashboard:blog:comment"], site_id: ctx.site.id)

        found = fn actor ->
          Comment
          |> Ash.Query.for_read(:public_list, %{}, actor: actor, tenant: ctx.site.id)
          |> Ash.Query.filter_input(%{guest_email: "ada.guest@example.com"})
          |> Ash.read!()
          |> Enum.map(& &1.id)
        end

        assert found.(nil) == []
        assert found.(create_user!(site_id: ctx.site.id)) == []
        assert found.(moderator) == [comment.id]
      end

      test "a guest's email never shows when a comment is inspected", ctx do
        {:ok, comment} = admin_create(ctx, @guest)

        refute inspect(comment) =~ "ada.guest@example.com"
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
        assert %DateTime{} = archived_comment.archived_at
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

    describe "vote count calculations" do
      test "upvote_count returns correct count" do
        site = create_site!()
        post = create_blog_post!(site_id: site.id)
        comment = create_comment!(post_id: post.id, content: "Test comment")

        # Create 5 upvotes
        for _ <- 1..5 do
          user = create_user!()
          create_comment_vote!(comment_id: comment.id, user_id: user.id, vote_type: :up)
        end

        # Create 2 downvotes
        for _ <- 1..2 do
          user = create_user!()
          create_comment_vote!(comment_id: comment.id, user_id: user.id, vote_type: :down)
        end

        loaded_comment = Ash.load!(comment, [:upvote_count], authorize?: false)
        assert loaded_comment.upvote_count == 5
      end

      test "downvote_count returns correct count" do
        site = create_site!()
        post = create_blog_post!(site_id: site.id)
        comment = create_comment!(post_id: post.id, content: "Test comment")

        # Create 3 upvotes
        for _ <- 1..3 do
          user = create_user!()
          create_comment_vote!(comment_id: comment.id, user_id: user.id, vote_type: :up)
        end

        # Create 7 downvotes
        for _ <- 1..7 do
          user = create_user!()
          create_comment_vote!(comment_id: comment.id, user_id: user.id, vote_type: :down)
        end

        loaded_comment = Ash.load!(comment, [:downvote_count], authorize?: false)
        assert loaded_comment.downvote_count == 7
      end

      test "both vote counts return correct values" do
        site = create_site!()
        post = create_blog_post!(site_id: site.id)
        comment = create_comment!(post_id: post.id, content: "Test comment")

        # Create 10 upvotes
        for _ <- 1..10 do
          user = create_user!()
          create_comment_vote!(comment_id: comment.id, user_id: user.id, vote_type: :up)
        end

        # Create 4 downvotes
        for _ <- 1..4 do
          user = create_user!()
          create_comment_vote!(comment_id: comment.id, user_id: user.id, vote_type: :down)
        end

        loaded_comment = Ash.load!(comment, [:upvote_count, :downvote_count], authorize?: false)
        assert loaded_comment.upvote_count == 10
        assert loaded_comment.downvote_count == 4
      end

      test "vote counts return zero when no votes exist" do
        site = create_site!()
        post = create_blog_post!(site_id: site.id)
        comment = create_comment!(post_id: post.id, content: "Test comment")

        loaded_comment = Ash.load!(comment, [:upvote_count, :downvote_count], authorize?: false)
        assert loaded_comment.upvote_count == 0
        assert loaded_comment.downvote_count == 0
      end

      test "vote counts work for multiple comments" do
        site = create_site!()
        post = create_blog_post!(site_id: site.id)
        comment1 = create_comment!(post_id: post.id, content: "Comment 1")
        comment2 = create_comment!(post_id: post.id, content: "Comment 2")

        # Comment 1: 5 upvotes, 2 downvotes
        for _ <- 1..5 do
          user = create_user!()
          create_comment_vote!(comment_id: comment1.id, user_id: user.id, vote_type: :up)
        end

        for _ <- 1..2 do
          user = create_user!()
          create_comment_vote!(comment_id: comment1.id, user_id: user.id, vote_type: :down)
        end

        # Comment 2: 3 upvotes, 8 downvotes
        for _ <- 1..3 do
          user = create_user!()
          create_comment_vote!(comment_id: comment2.id, user_id: user.id, vote_type: :up)
        end

        for _ <- 1..8 do
          user = create_user!()
          create_comment_vote!(comment_id: comment2.id, user_id: user.id, vote_type: :down)
        end

        loaded_comments =
          Ash.load!([comment1, comment2], [:upvote_count, :downvote_count], authorize?: false)

        [loaded1, loaded2] = loaded_comments

        assert loaded1.upvote_count == 5
        assert loaded1.downvote_count == 2
        assert loaded2.upvote_count == 3
        assert loaded2.downvote_count == 8
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
        assert %DateTime{} = fetched.archived_at
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
