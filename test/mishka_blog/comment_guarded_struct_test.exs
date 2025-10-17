defmodule MishkaBlog.Test.CommentGuardedStructTest do
  @moduledoc """
  GuardedStruct.AshResource coverage for `MishkaBlog.Comment`.
  """

  use MishkaBlog.DataCase, async: false
  @moduletag :unit

  if Code.ensure_loaded?(MishkaBlog) do
    alias MishkaBlog.Comment

    describe "guardedstruct wiring" do
      test "GS covers every Ash attribute" do
        assert MapSet.new([:content, :status, :sender_data, :is_pinned, :site_id]) ==
                 Comment.__guarded_field_name_set__()
      end
    end

    describe "direct __guarded_change__/1" do
      test "content basic_html (keeps safe tags, drops scripts); status enum accept" do
        assert {:ok,
                %{
                  content: content,
                  status: :approved,
                  is_pinned: true
                }} =
                 Comment.__guarded_change__(%{
                   content: "<p>hello <b>world</b></p><script>alert(1)</script>",
                   status: :approved,
                   is_pinned: true
                 })

        assert content =~ "<p>hello <b>world</b></p>"
        refute content =~ "<script"
      end

      test "status outside enum rejected" do
        assert {:error,
                [
                  %{
                    field: :status,
                    action: :enum,
                    message: "Your sent data form status field is not in the allowed list"
                  }
                ]} = Comment.__guarded_change__(%{status: :bogus})
      end

      test "empty content → not_empty error" do
        assert {:error, errs} = Comment.__guarded_change__(%{content: ""})
        assert Enum.any?(errs, &match?(%{field: :content, action: :not_empty}, &1))
      end
    end
  end
end
