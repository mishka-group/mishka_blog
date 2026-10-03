defmodule MishkaBlog.Test.CollectionGuardedStructTest do
  @moduledoc """
  GuardedStruct.AshResource coverage for `MishkaBlog.Collection`.
  """

  use MishkaBlog.DataCase, async: false
  @moduletag :unit

  if Code.ensure_loaded?(MishkaBlog) do
    alias MishkaBlog.Collection

    describe "guardedstruct wiring" do
      test "GS covers every Ash attribute" do
        assert MapSet.new([
                 :name,
                 :slug,
                 :description,
                 :status,
                 :schema,
                 :seo_tags,
                 :permissions,
                 :featured,
                 :display_order,
                 :language,
                 :language_group_id
               ]) == Collection.__guarded_field_name_set__()
      end
    end

    describe "direct __guarded_change__/1" do
      test "name trim, language trim+downcase, status enum accept" do
        assert {:ok,
                %{
                  name: "Featured Articles",
                  language: "en",
                  status: :active
                }} =
                 Collection.__guarded_change__(%{
                   name: "  Featured Articles  ",
                   language: "  EN  ",
                   status: :active
                 })
      end

      test "status outside enum rejected" do
        assert {:error,
                [
                  %{
                    field: :status,
                    action: :enum,
                    message: "Your sent data form status field is not in the allowed list"
                  }
                ]} = Collection.__guarded_change__(%{status: :bogus})
      end

      test "display_order accepts non-negative integer; negative rejected" do
        assert {:ok, %{display_order: 5}} = Collection.__guarded_change__(%{display_order: 5})

        assert {:error,
                [
                  %{
                    field: :display_order,
                    action: :min_len,
                    message: "The minimum number the display_order field is 0" <> _
                  }
                ]} = Collection.__guarded_change__(%{display_order: -1})
      end

      test "permissions: trim + downcase + reject empties + uniq" do
        assert {:ok, %{permissions: ["members:read", "members:write"]}} =
                 Collection.__guarded_change__(%{
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
                ]} = Collection.__guarded_change__(%{permissions: "not a list"})
      end
    end
  end
end
