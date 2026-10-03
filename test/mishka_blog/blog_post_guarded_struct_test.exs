defmodule MishkaBlog.Test.BlogPostGuardedStructTest do
  @moduledoc """
  GuardedStruct.AshResource coverage for `MishkaBlog.BlogPost`.

  Pins the title/slug/content sanitize behavior and the `:status` enum
  in both happy and error paths.
  """

  use MishkaBlog.DataCase, async: false
  @moduletag :unit

  if Code.ensure_loaded?(MishkaBlog) do
    alias MishkaBlog.BlogPost

    describe "guardedstruct wiring" do
      test "GS covers every Ash attribute" do
        assert MapSet.new([
                 :title,
                 :slug,
                 :content,
                 :excerpt,
                 :featured_image_url,
                 :status,
                 :published_at,
                 :scheduled_publish_at,
                 :schema,
                 :seo_tags,
                 :permissions,
                 :featured,
                 :language,
                 :language_group_id
               ]) == BlogPost.__guarded_field_name_set__()
      end
    end

    describe "direct __guarded_change__/1" do
      test "title strip_tags+trim; content keeps safe HTML, drops scripts; status enum accept" do
        assert {:ok,
                %{
                  title: title,
                  content: content,
                  status: :draft,
                  language: "fa"
                }} =
                 BlogPost.__guarded_change__(%{
                   title: "  <b>Hello</b> World  ",
                   content: "<p>Hello, <b>reader</b>!</p><script>alert(1)</script>",
                   status: :draft,
                   language: "  FA  "
                 })

        assert title == "Hello World"
        refute title =~ "<b>"

        assert content =~ "<p>Hello, <b>reader</b>!</p>"
        refute content =~ "<script"
      end

      test "status outside enum rejected with explicit message" do
        assert {:error,
                [
                  %{
                    field: :status,
                    action: :enum,
                    message: "Your sent data form status field is not in the allowed list"
                  }
                ]} = BlogPost.__guarded_change__(%{status: :bogus})
      end

      test "title over max_len=500 rejected" do
        long = String.duplicate("x", 501)

        assert {:error,
                [
                  %{
                    field: :title,
                    action: :max_len,
                    message: "The maximum number of characters in the title field is 500" <> _
                  }
                ]} = BlogPost.__guarded_change__(%{title: long})
      end

      test "permissions: trim + downcase + reject empties + uniq" do
        assert {:ok, %{permissions: ["members:read", "members:write"]}} =
                 BlogPost.__guarded_change__(%{
                   permissions: ["  MEMBERS:READ  ", "Members:Read", "", "MEMBERS:WRITE"]
                 })
      end

      test "permissions: non-list is rejected" do
        assert {:error,
                [
                  %{
                    field: :permissions,
                    action: :list,
                    message: _
                  }
                ]} = BlogPost.__guarded_change__(%{permissions: "not a list"})
      end
    end
  end
end
