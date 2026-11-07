# SPDX-FileCopyrightText: 2026 Mishka Group contributors <https://github.com/mishka-group/mishka_blog/graphs/contributors>
#
# SPDX-License-Identifier: Apache-2.0

defmodule MishkaBlog.Test.PublicSlugTest do
  @moduledoc """
  Public slugs are made by `MishkaSlug.Change` with the options of
  `MishkaBlog.Resources.Changes.PublicSlug`: they keep the scripts of the site's languages.
  """
  use MishkaBlog.DataCase, async: false

  alias MishkaBlog.Resources.Changes.PublicSlug
  alias MishkaCmsCore.Settings

  defp site_in(languages) do
    site = create_site!()
    {:ok, _} = Settings.put("site.languages", languages, site_id: site.id)
    site
  end

  defp tag_slug(site, slug, language \\ "en") do
    MishkaBlog.Tag
    |> Ash.Changeset.for_create(:create, %{name: "T", slug: slug, language: language},
      tenant: site.id,
      authorize?: false
    )
    |> Ash.create()
  end

  test "a Persian title on a site with fa and en keeps Persian" do
    site = site_in(["fa", "en"])
    assert {:ok, tag} = tag_slug(site, "قیمت‌گذاری نرم‌افزار", "fa")
    assert tag.slug == "قیمتگذاری-نرمافزار"
  end

  test "a Persian title on an English-only site is refused on slug" do
    site = site_in(["en"])
    assert {:error, error} = tag_slug(site, "قیمت")
    assert [%{field: :slug}] = error.errors
    assert Exception.message(error) =~ "slug"
  end

  test "Arabic yeh and kaf fold to Persian for the language fa" do
    site = site_in(["fa", "en"])
    assert {:ok, tag} = tag_slug(site, "كتاب علي", "fa")
    assert tag.slug == "کتاب-علی"
  end

  test "English with accents becomes ASCII and an underscore stays" do
    site = site_in(["en"])
    assert {:ok, tag} = tag_slug(site, "Café Crème snake_case", "en")
    assert tag.slug == "cafe-creme-snake_case"
  end

  test "the options are the ones a form preview reads off the action" do
    site = site_in(["fa", "en"])

    changeset =
      Ash.Changeset.for_create(MishkaBlog.Tag, :create, %{language: "fa"},
        tenant: site.id,
        authorize?: false
      )

    options = MishkaSlug.Change.slug_options(PublicSlug.options(:language), changeset)

    assert {:ok, "كتاب"} != MishkaSlug.slugify("كتاب", options)
    assert {:ok, "کتاب"} = MishkaSlug.slugify("كتاب", options)
  end
end
