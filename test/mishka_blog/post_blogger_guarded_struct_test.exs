defmodule MishkaBlog.Test.PostBloggerGuardedStructTest do
  @moduledoc """
  GuardedStruct.AshResource coverage for `MishkaBlog.PostBlogger`.
  """

  use MishkaBlog.DataCase, async: false
  @moduletag :unit

  if Code.ensure_loaded?(MishkaBlog) do
    alias MishkaBlog.PostBlogger

    describe "guardedstruct wiring" do
      test "GS covers every Ash attribute" do
        assert MapSet.new([:role]) == PostBlogger.__guarded_field_name_set__()
      end
    end

    describe "direct __guarded_change__/1" do
      test "role trim + downcase; nil passes" do
        assert {:ok, %{role: "primary author"}} =
                 PostBlogger.__guarded_change__(%{role: "  Primary Author  "})

        assert {:ok, %{role: nil}} = PostBlogger.__guarded_change__(%{role: nil})
      end

      test "role over max_len=100 rejected" do
        long = String.duplicate("x", 101)

        assert {:error,
                [
                  %{
                    field: :role,
                    action: :max_len,
                    message: "The maximum number of characters in the role field is 100" <> _
                  }
                ]} = PostBlogger.__guarded_change__(%{role: long})
      end
    end
  end
end
