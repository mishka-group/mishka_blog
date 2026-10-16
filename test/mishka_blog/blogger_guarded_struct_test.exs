# SPDX-FileCopyrightText: 2026 Mishka Group contributors <https://github.com/mishka-group/mishka_blog/graphs/contributors>
#
# SPDX-License-Identifier: Apache-2.0

defmodule MishkaBlog.Test.BloggerGuardedStructTest do
  @moduledoc """
  GuardedStruct.AshResource coverage for `MishkaBlog.Blogger`.
  """

  use MishkaBlog.DataCase, async: false
  @moduletag :unit

  if Code.ensure_loaded?(MishkaBlog) do
    alias MishkaBlog.Blogger

    describe "guardedstruct wiring" do
      test "GS covers every Ash attribute" do
        assert MapSet.new([
                 :display_name,
                 :slug,
                 :bio,
                 :avatar_url,
                 :cover_image_url,
                 :expertise_areas,
                 :social_links,
                 :contact_email,
                 :can_publish_directly
               ]) == Blogger.__guarded_field_name_set__()
      end
    end

    describe "direct __guarded_change__/1" do
      test "contact_email trimmed and downcased on the way in" do
        assert {:ok, %{contact_email: "alice@example.com"}} =
                 Blogger.__guarded_change__(%{contact_email: "  Alice@Example.COM  "})
      end

      test "expertise_areas trim + dedupe + reject empties" do
        assert {:ok, %{expertise_areas: ["elixir", "phoenix"]}} =
                 Blogger.__guarded_change__(%{
                   expertise_areas: ["  elixir  ", "elixir", "", "  phoenix  "]
                 })
      end

      test "social_links accepts list of maps; non-list rejected" do
        assert {:ok, %{social_links: [%{platform: "github", url: "https://x"}]}} =
                 Blogger.__guarded_change__(%{
                   social_links: [%{platform: "github", url: "https://x"}]
                 })

        assert {:error, errs} = Blogger.__guarded_change__(%{social_links: "nope"})
        assert Enum.any?(errs, &match?(%{field: :social_links, action: :list}, &1))
      end

      test "display_name empty → min_len + not_empty fire" do
        assert {:error, errs} = Blogger.__guarded_change__(%{display_name: ""})
        assert Enum.any?(errs, &match?(%{field: :display_name, action: :min_len}, &1))
        assert Enum.any?(errs, &match?(%{field: :display_name, action: :not_empty}, &1))
      end
    end
  end
end
