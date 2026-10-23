# SPDX-FileCopyrightText: 2026 Mishka Group contributors <https://github.com/mishka-group/mishka_blog/graphs/contributors>
#
# SPDX-License-Identifier: Apache-2.0

defmodule MishkaBlog.Provision.EarlierTest do
  @moduledoc """
  The pages the release before wrote, as `MishkaBlog.Provision.Earlier` holds them, and the one
  question it answers: is this stored template one of them, character for character.

  The texts are frozen, so each is pinned by the hash of what that release's `MishkaBlog.Provision`
  wrote for a site named "Acme" (the pages of the `f36d9c6` commit of the blog, taken from its own
  code). A change to `Earlier` that moves any of them fails here, before a page nobody edited
  stops being recognised.
  """
  use ExUnit.Case, async: true

  alias MishkaBlog.Provision
  alias MishkaBlog.Provision.Earlier

  @hashes %{
    "/:lang/blog" => "f9d99f7a4face1cbed99121c99d1f3fd3fbd458d9f5b407391123ee279cfd3c0",
    "/:lang/blog/:slug" => "82294d9fe7ea655628d4993a01860f0ac09728409562b7e9758f53a1b4de0609",
    "/:lang/blog/category/:slug" =>
      "20199ba0cff789702e589fbdc8acd1fbafb93b243d61e822a3306aab269f73cf",
    "/:lang/blog/tag/:slug" => "f46721e84d5364bc4b13c8cb8741a28e755d032b40a0c3d3e90e418ab97363c7",
    "/:lang/blog/categories" =>
      "8be98d7d079021cfbdcb3a4dfe0d76f7e12573e21f89a413157ef6c343a8bb73",
    "/:lang/blog/tags" => "2d6cc01ca72f0f30b9ff930a651e4d2792dc916f81ec90b7ff2391899769e628",
    "/:lang/blog/author/:slug" =>
      "d68a428229df3d51e23abce79163c95cff7154042a806b682e07b82b87158698",
    "/:lang/blog/team/:slug" =>
      "ce85a5984f14d1cdd90d0f639f2e4cd2526072d6952ad4a825f0e01b0012270a",
    "/:lang/blog/people" => "5be330d9519deff5341857ec0cfa644ca53c54a36f4a5485fd1721ed50a9c0f5"
  }

  defp hash(text), do: :sha256 |> :crypto.hash(text) |> Base.encode16(case: :lower)

  describe "the pages" do
    test "are the nine the blog writes today, one for each of its paths" do
      assert Enum.sort(Map.keys(@hashes)) == Enum.sort(Provision.page_paths())
    end

    test "are exactly what the release before wrote" do
      for {path, expected} <- @hashes do
        assert hash(Earlier.template(path, "Acme")) == expected,
               "#{path} is not the page the release before wrote"
      end
    end

    test "name the site they are written for" do
      for path <- Map.keys(@hashes) do
        assert Earlier.template(path, "Other site") =~ ~s(site="Other site")
        refute Earlier.template(path, "Other site") =~ ~s(site="Acme")
      end
    end

    test "carry the header and the column of their own that the site's layout draws now" do
      for path <- Map.keys(@hashes) do
        template = Earlier.template(path, "Acme")

        assert template =~ ~s(<header class="border-b border-[#ecebe6] bg-white">)
        assert template =~ "max-w-6xl"
      end
    end

    test "are none for a path the blog never wrote a page at" do
      assert Earlier.template("/:lang/blog/unknown", "Acme") == nil
      assert Earlier.template("/blog", "Acme") == nil
    end
  end

  describe "page_of/1" do
    test "names the page a stored template is" do
      for path <- Map.keys(@hashes) do
        assert Earlier.page_of(Earlier.template(path, "Acme")) == path
      end
    end

    test "reads the site off the template, so a site of any name is recognised" do
      for name <- ["Acme", "my-blog", "Ünïcode site", "with 'quotes' & more"] do
        assert Earlier.page_of(Earlier.template("/:lang/blog/people", name)) ==
                 "/:lang/blog/people"
      end
    end

    test "ignores the whitespace around the whole text, as a page is compared with its sample" do
      template = Earlier.template("/:lang/blog", "Acme")

      assert Earlier.page_of("\n" <> template <> "\n\n") == "/:lang/blog"
    end

    test "is nothing for a page edited anywhere" do
      template = Earlier.template("/:lang/blog", "Acme")

      assert Earlier.page_of(template <> "<p>mine</p>") == nil
      assert Earlier.page_of(String.replace(template, "Latest posts", "Newest posts")) == nil
      assert Earlier.page_of(String.replace(template, "per_page={9}", "per_page={12}")) == nil
      assert Earlier.page_of(String.replace(template, "  ", " ", global: false)) == nil
    end

    test "is nothing for anything that is not an earlier template" do
      assert Earlier.page_of("") == nil
      assert Earlier.page_of("<div>my own page</div>") == nil
      assert Earlier.page_of(nil) == nil
    end
  end
end
