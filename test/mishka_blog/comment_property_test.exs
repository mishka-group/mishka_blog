# SPDX-FileCopyrightText: 2026 Mishka Group contributors <https://github.com/mishka-group/mishka_blog/graphs/contributors>
#
# SPDX-License-Identifier: Apache-2.0

defmodule MishkaBlog.Test.CommentPropertyTest do
  @moduledoc """
  Property-based tests for MishkaBlog.Comment resource using StreamData.
  """
  use MishkaBlog.DataCase, async: false
  use ExUnitProperties
  require Ash.Query

  if Code.ensure_loaded?(MishkaBlog) do
    alias MishkaBlog.Comment

    describe "property-based: comment creation" do
      property "successfully creates comments with any valid content" do
        check all(content <- string(:alphanumeric, min_length: 1, max_length: 1000)) do
          site = create_site!()
          post = create_blog_post!(site_id: site.id)

          comment =
            create_comment!(
              post_id: post.id,
              content: content
            )

          assert comment.content == content
          assert comment.post_id == post.id
          assert comment.status in [:pending, :approved, :flagged, :spam]
        end
      end

      property "creates comments with all valid status values" do
        check all(status <- member_of([:pending, :approved, :flagged, :spam])) do
          site = create_site!()
          post = create_blog_post!(site_id: site.id)

          comment =
            create_comment!(
              post_id: post.id,
              content: "Test comment",
              status: status
            )

          assert comment.status == status
        end
      end

      property "is_pinned accepts boolean values" do
        check all(is_pinned <- boolean()) do
          site = create_site!()
          post = create_blog_post!(site_id: site.id)

          comment =
            create_comment!(
              post_id: post.id,
              content: "Test comment",
              is_pinned: is_pinned
            )

          assert comment.is_pinned == is_pinned
        end
      end

      property "sender_data accepts valid IP addresses" do
        check all(
                ip_octet1 <- integer(0..255),
                ip_octet2 <- integer(0..255),
                ip_octet3 <- integer(0..255),
                ip_octet4 <- integer(0..255)
              ) do
          site = create_site!()
          post = create_blog_post!(site_id: site.id)
          ip = "#{ip_octet1}.#{ip_octet2}.#{ip_octet3}.#{ip_octet4}"

          comment =
            create_comment!(
              post_id: post.id,
              content: "Test",
              sender_data: %{ip_address: ip}
            )

          assert comment.sender_data.ip_address == ip
        end
      end
    end

    describe "property-based: comment updates" do
      property "successfully updates content to any valid string" do
        check all(
                original_content <- string(:alphanumeric, min_length: 1, max_length: 100),
                new_content <- string(:alphanumeric, min_length: 1, max_length: 100)
              ) do
          site = create_site!()
          post = create_blog_post!(site_id: site.id)

          comment =
            create_comment!(
              post_id: post.id,
              content: original_content
            )

          updated =
            comment
            |> Ash.Changeset.for_update(:update, %{content: new_content}, authorize?: false)
            |> Ash.update!()

          assert updated.content == new_content
        end
      end

      property "successfully transitions between all valid statuses" do
        check all(
                from_status <- member_of([:pending, :approved, :flagged, :spam]),
                to_status <- member_of([:pending, :approved, :flagged, :spam])
              ) do
          site = create_site!()
          post = create_blog_post!(site_id: site.id)

          comment =
            create_comment!(
              post_id: post.id,
              content: "Test",
              status: from_status
            )

          updated =
            comment
            |> Ash.Changeset.for_update(:update, %{status: to_status}, authorize?: false)
            |> Ash.update!()

          assert updated.status == to_status
        end
      end

      property "can toggle is_pinned multiple times" do
        check all(pin_sequence <- list_of(boolean(), min_length: 1, max_length: 10)) do
          site = create_site!()
          post = create_blog_post!(site_id: site.id)

          comment =
            create_comment!(
              post_id: post.id,
              content: "Test",
              is_pinned: false
            )

          final_comment =
            Enum.reduce(pin_sequence, comment, fn should_pin, acc ->
              acc
              |> Ash.Changeset.for_update(:update, %{is_pinned: should_pin}, authorize?: false)
              |> Ash.update!()
            end)

          assert final_comment.is_pinned == List.last(pin_sequence)
        end
      end
    end

    describe "property-based: moderation workflow" do
      property "approve action always results in approved status" do
        check all(initial_status <- member_of([:pending, :flagged, :spam])) do
          site = create_site!()
          post = create_blog_post!(site_id: site.id)

          comment =
            create_comment!(
              post_id: post.id,
              content: "Test",
              status: initial_status
            )

          approved =
            comment
            |> Ash.Changeset.for_update(:approve, %{}, authorize?: false)
            |> Ash.update!()

          assert approved.status == :approved
        end
      end

      property "flag action always results in flagged status" do
        check all(initial_status <- member_of([:pending, :approved, :spam])) do
          site = create_site!()
          post = create_blog_post!(site_id: site.id)

          comment =
            create_comment!(
              post_id: post.id,
              content: "Test",
              status: initial_status
            )

          flagged =
            comment
            |> Ash.Changeset.for_update(:flag, %{}, authorize?: false)
            |> Ash.update!()

          assert flagged.status == :flagged
        end
      end

      property "mark_spam action always results in spam status" do
        check all(initial_status <- member_of([:pending, :approved, :flagged])) do
          site = create_site!()
          post = create_blog_post!(site_id: site.id)

          comment =
            create_comment!(
              post_id: post.id,
              content: "Test",
              status: initial_status
            )

          spam =
            comment
            |> Ash.Changeset.for_update(:mark_spam, %{}, authorize?: false)
            |> Ash.update!()

          assert spam.status == :spam
        end
      end

      property "pin/unpin actions always set is_pinned correctly" do
        check all(initial_pinned <- boolean()) do
          site = create_site!()
          post = create_blog_post!(site_id: site.id)

          comment =
            create_comment!(
              post_id: post.id,
              content: "Test",
              is_pinned: initial_pinned
            )

          pinned =
            comment
            |> Ash.Changeset.for_update(:pin, %{}, authorize?: false)
            |> Ash.update!()

          assert pinned.is_pinned == true

          unpinned =
            pinned
            |> Ash.Changeset.for_update(:unpin, %{}, authorize?: false)
            |> Ash.update!()

          assert unpinned.is_pinned == false
        end
      end
    end

    describe "property-based: threaded comments" do
      property "can create arbitrary depth comment threads" do
        check all(thread_depth <- integer(1..5)) do
          site = create_site!()
          post = create_blog_post!(site_id: site.id)

          # Create a thread of comments
          comments =
            Enum.reduce(1..thread_depth, [], fn level, acc ->
              parent_id = if level == 1, do: nil, else: List.last(acc).id

              comment =
                create_comment!(
                  post_id: post.id,
                  parent_comment_id: parent_id,
                  content: "Comment at level #{level}"
                )

              acc ++ [comment]
            end)

          # Verify the chain
          Enum.each(Enum.with_index(comments, 1), fn {comment, level} ->
            if level == 1 do
              assert comment.parent_comment_id == nil
            else
              assert comment.parent_comment_id == Enum.at(comments, level - 2).id
            end
          end)
        end
      end

      property "parent can have multiple replies" do
        check all(num_replies <- integer(1..10)) do
          site = create_site!()
          post = create_blog_post!(site_id: site.id)
          parent = create_comment!(post_id: post.id, content: "Parent")

          _replies =
            for i <- 1..num_replies do
              create_comment!(
                post_id: post.id,
                parent_comment_id: parent.id,
                content: "Reply #{i}"
              )
            end

          loaded_parent = Ash.load!(parent, [:replies], authorize?: false)
          assert length(loaded_parent.replies) == num_replies
        end
      end
    end

    describe "property-based: archival and recovery" do
      property "archiving and unarchiving preserves comment data" do
        check all(
                content <- string(:alphanumeric, min_length: 1, max_length: 100),
                status <- member_of([:pending, :approved, :flagged, :spam]),
                is_pinned <- boolean()
              ) do
          site = create_site!()
          post = create_blog_post!(site_id: site.id)

          comment =
            create_comment!(
              post_id: post.id,
              content: content,
              status: status,
              is_pinned: is_pinned
            )

          # Archive
          comment
          |> Ash.Changeset.for_destroy(:destroy, %{}, authorize?: false)
          |> Ash.destroy!()

          # Unarchive
          archived =
            Ash.get!(Comment, comment.id,
              action: :get_archived,
              tenant: site.id,
              authorize?: false
            )

          unarchived =
            archived
            |> Ash.Changeset.for_update(:unarchive, %{}, authorize?: false)
            |> Ash.update!()

          # Data should be preserved
          assert unarchived.content == content
          assert unarchived.status == status
          assert unarchived.is_pinned == is_pinned
          assert unarchived.archived_at == nil
        end
      end
    end

    describe "property-based: read actions and filtering" do
      property "by_post returns only comments for specified post" do
        check all(
                num_posts <- integer(2..5),
                comments_per_post <- integer(1..5)
              ) do
          site = create_site!()

          # Create multiple posts with comments
          posts_with_comments =
            for _ <- 1..num_posts do
              post = create_blog_post!(site_id: site.id)

              comments =
                for _ <- 1..comments_per_post do
                  create_comment!(post_id: post.id, content: "Test")
                end

              {post, comments}
            end

          # Verify each post's comments are correctly filtered
          Enum.each(posts_with_comments, fn {post, expected_comments} ->
            result =
              Comment
              |> Ash.Query.for_read(:read, %{}, tenant: site.id, authorize?: false)
              |> Ash.Query.filter(post_id == ^post.id)
              |> Ash.read!(authorize?: false)

            expected_ids = Enum.map(expected_comments, & &1.id)
            result_ids = Enum.map(result, & &1.id)

            assert Enum.sort(result_ids) == Enum.sort(expected_ids)
          end)
        end
      end

      property "status-specific reads return only matching comments" do
        check all(
                status_distribution <-
                  list_of(member_of([:pending, :approved, :flagged, :spam]),
                    min_length: 5,
                    max_length: 20
                  )
              ) do
          site = create_site!()
          post = create_blog_post!(site_id: site.id)

          # Create comments with various statuses
          _comments =
            Enum.map(status_distribution, fn status ->
              create_comment!(post_id: post.id, content: "Test", status: status)
            end)

          # Test each status with filtered read
          for status <- [:pending, :approved, :flagged, :spam] do
            result =
              Comment
              |> Ash.Query.for_read(:read, %{}, tenant: site.id, authorize?: false)
              |> Ash.Query.filter(status == ^status)
              |> Ash.read!(authorize?: false)

            expected_count = Enum.count(status_distribution, &(&1 == status))
            actual_count = Enum.count(result, &(&1.status == status))

            assert actual_count >= expected_count
            assert Enum.all?(result, &(&1.status == status))
          end
        end
      end

      property "pinned read returns only pinned comments" do
        check all(pin_distribution <- list_of(boolean(), min_length: 5, max_length: 20)) do
          site = create_site!()
          post = create_blog_post!(site_id: site.id)

          # Create comments with various pin states
          _comments =
            Enum.map(pin_distribution, fn is_pinned ->
              create_comment!(post_id: post.id, content: "Test", is_pinned: is_pinned)
            end)

          result =
            Comment
            |> Ash.Query.for_read(:read, %{}, tenant: site.id, authorize?: false)
            |> Ash.Query.filter(is_pinned == true)
            |> Ash.read!(authorize?: false)

          expected_count = Enum.count(pin_distribution, & &1)

          assert length(result) >= expected_count
          assert Enum.all?(result, & &1.is_pinned)
        end
      end

      property "pagination returns correct number of results" do
        check all(
                total_comments <- integer(10..30),
                page_size <- integer(1..10)
              ) do
          site = create_site!()
          post = create_blog_post!(site_id: site.id)

          for _ <- 1..total_comments do
            create_comment!(post_id: post.id, content: "Test")
          end

          result =
            Comment
            |> Ash.Query.for_read(:read, %{}, tenant: site.id, authorize?: false)
            |> Ash.Query.filter(post_id == ^post.id)
            |> Ash.Query.page(limit: page_size, count: true)
            |> Ash.read!(authorize?: false)

          assert length(result.results) == min(page_size, total_comments)
          assert result.count == total_comments
        end
      end
    end

    describe "property-based: invariants" do
      property "timestamps are always present and valid" do
        check all(content <- string(:alphanumeric, min_length: 1, max_length: 100)) do
          site = create_site!()
          post = create_blog_post!(site_id: site.id)

          comment = create_comment!(post_id: post.id, content: content)

          assert comment.inserted_at != nil
          assert comment.updated_at != nil
          assert is_struct(comment.inserted_at, DateTime)
          assert is_struct(comment.updated_at, DateTime)

          # inserted_at should be <= updated_at
          assert DateTime.compare(comment.inserted_at, comment.updated_at) in [:lt, :eq]
        end
      end

      property "updated_at advances with updates" do
        check all(_ <- constant(:ok)) do
          site = create_site!()
          post = create_blog_post!(site_id: site.id)

          comment = create_comment!(post_id: post.id, content: "Original")
          original_updated_at = comment.updated_at

          # Small delay to ensure timestamp difference
          Process.sleep(10)

          updated =
            comment
            |> Ash.Changeset.for_update(:update, %{content: "Updated"}, authorize?: false)
            |> Ash.update!()

          # updated_at should have advanced
          assert DateTime.compare(updated.updated_at, original_updated_at) == :gt
        end
      end

      property "comment always belongs to a post" do
        check all(content <- string(:alphanumeric, min_length: 1, max_length: 100)) do
          site = create_site!()
          post = create_blog_post!(site_id: site.id)

          comment = create_comment!(post_id: post.id, content: content)

          assert comment.post_id != nil
          assert is_binary(comment.post_id)
        end
      end
    end
  end
end
