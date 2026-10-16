# SPDX-FileCopyrightText: 2026 Mishka Group contributors <https://github.com/mishka-group/mishka_blog/graphs/contributors>
#
# SPDX-License-Identifier: Apache-2.0

defmodule MishkaBlog.Test.EditionChipsTest do
  @moduledoc """
  The sibling editions a translated post, collection or tag lists, and the chips drawn from them.

  A record reaches its siblings through `language_variants` for a site's admin and
  `master_language_variants` for a master, which reads every site. `MishkaBlogWeb.Templates.EditionChips`
  turns whichever one arrived into the badges of its row.
  """
  use MishkaBlog.DataCase, async: false

  import Phoenix.Component, only: [sigil_H: 2]
  import Phoenix.LiveViewTest, only: [rendered_to_string: 1]

  alias MishkaBlog.{BlogPost, Collection, Tag}
  alias MishkaBlogWeb.Templates.EditionChips

  require Ash.Query

  describe "editions/1" do
    test "lists the siblings of the record, itself left out, by language" do
      record = %{id: "a", language: "en", language_group_id: "a"}

      siblings =
        for {id, language} <- [{"c", "fa"}, {"b", "ar"}, {"a", "en"}],
            do: %{id: id, language: language}

      assert [%{id: "b", language: "ar"}, %{id: "c", language: "fa"}] =
               EditionChips.editions(Map.put(record, :language_variants, siblings))
    end

    test "gives each sibling the colour of its language" do
      record = %{id: "a", language: "en", language_group_id: "a"}
      siblings = [%{id: "a", language: "en"}, %{id: "b", language: "fa"}]

      assert [%{accent: accent}] =
               EditionChips.editions(Map.put(record, :language_variants, siblings))

      assert accent == MishkaCmsCore.LanguageAccent.for_language("fa")
    end

    test "has none for a record with no group, or whose siblings did not arrive" do
      assert [] = EditionChips.editions(%{id: "a", language: "en", language_group_id: nil})

      assert [] =
               EditionChips.editions(%{
                 id: "a",
                 language: "en",
                 language_group_id: "a",
                 language_variants: %Ash.NotLoaded{field: :language_variants, type: :relationship},
                 master_language_variants: %Ash.NotLoaded{
                   field: :master_language_variants,
                   type: :relationship
                 }
               })
    end

    test "reads whichever of the two relationships arrived" do
      record = %{
        id: "a",
        language: "en",
        language_group_id: "a",
        language_variants: %Ash.NotLoaded{field: :language_variants, type: :relationship},
        master_language_variants: [%{id: "b", language: "fa"}]
      }

      assert [%{id: "b"}] = EditionChips.editions(record)
    end
  end

  describe "row/1" do
    test "opens the first chips and holds the rest behind a toggle" do
      html = row(["fa", "ar", "ru", "fr"], shown: 2)

      assert chips(html, "#card-1-editions > div:first-child") == ["EN", "AR", "FA"]
      assert chips(html, "#card-1-editions-rest") == ["FR", "RU"]
      assert text(html, "#card-1-editions-more") == "+2"
      assert [_] = query(html, "#card-1-editions-less")
    end

    test "has no toggle when every chip fits" do
      html = row(["fa"], shown: 2)

      assert chips(html, "#card-1-editions") == ["EN", "FA"]
      assert [] = query(html, "#card-1-editions-more")
      assert [] = query(html, "#card-1-editions-rest")
    end

    test "draws nothing for a record with no siblings" do
      assert row([], shown: 2) == ""
    end

    test "has every chip click show_edition with its own edition's id" do
      html = row(["fa"], shown: 2)

      assert ["a", "id-fa"] ==
               html
               |> query("[phx-click=show_edition]")
               |> Enum.map(&LazyHTML.attribute(&1, "phx-value-id"))
               |> List.flatten()
    end
  end

  describe "inline/1" do
    test "draws the record's own chip and a chip for every sibling" do
      html = inline(["fa", "ar"])

      assert chips(html, "#cell-1") == ["EN", "AR", "FA"]
    end

    test "draws nothing for a record with no siblings" do
      assert inline([]) == ""
    end
  end

  describe "the siblings of a record read from the database" do
    for resource <- [BlogPost, Collection, Tag] do
      @resource resource

      test "#{inspect(resource)}: a master reads them through master_language_variants" do
        site = create_site!()
        %{record: record, fa: fa} = group(@resource, site)
        master = create_user_with_permissions!(["*"])

        loaded =
          @resource
          |> Ash.Query.for_read(:master_read, %{}, actor: master)
          |> Ash.Query.filter(id == ^record.id)
          |> Ash.Query.load(:master_language_variants)
          |> Ash.read_one!(actor: master)

        assert [%{id: fa_id, language: "fa"}] = EditionChips.editions(loaded)
        assert fa_id == fa.id
      end

      test "#{inspect(resource)}: a site's admin reads them through language_variants" do
        site = create_site!()
        %{record: record, fa: fa} = group(@resource, site)
        admin = create_user_with_permissions!(["*"], site_id: site.id)

        loaded =
          @resource
          |> Ash.Query.for_read(:read, %{}, actor: admin, tenant: site.id)
          |> Ash.Query.filter(id == ^record.id)
          |> Ash.Query.load(:language_variants)
          |> Ash.read_one!(actor: admin, tenant: site.id)

        assert [%{id: fa_id, language: "fa"}] = EditionChips.editions(loaded)
        assert fa_id == fa.id
      end

      test "#{inspect(resource)}: a site's admin gets no sibling through master_language_variants" do
        site = create_site!()
        %{record: record} = group(@resource, site)
        admin = create_user_with_permissions!(["*"], site_id: site.id)

        siblings =
          @resource
          |> Ash.Query.for_read(:read, %{}, actor: admin, tenant: site.id)
          |> Ash.Query.filter(id == ^record.id)
          |> Ash.Query.load(:master_language_variants)
          |> Ash.read_one(actor: admin, tenant: site.id)
          |> case do
            {:ok, loaded} -> EditionChips.editions(loaded)
            {:error, _forbidden} -> []
          end

        assert siblings == []
      end
    end
  end

  defp group(resource, site) do
    record = make(resource, site, language: "en")
    fa = make(resource, site, language: "fa", language_group_id: record.id)
    %{record: record, fa: fa}
  end

  defp make(BlogPost, site, overrides), do: create_blog_post!([site_id: site.id] ++ overrides)
  defp make(Collection, site, overrides), do: create_collection!([site_id: site.id] ++ overrides)
  defp make(Tag, site, overrides), do: create_blog_tag!([site_id: site.id] ++ overrides)

  # The record "a" in English, with the group's rows as the self-join hands them over: itself too.
  defp record(languages) do
    siblings = Enum.map(languages, &%{id: "id-#{&1}", language: &1})

    %{
      id: "a",
      language: "en",
      language_group_id: "a",
      language_variants: [%{id: "a", language: "en"} | siblings]
    }
  end

  defp row(languages, opts) do
    record = record(languages)

    assigns = %{
      record: record,
      editions: EditionChips.editions(record),
      accent: MishkaCmsCore.LanguageAccent.of(record),
      shown: Keyword.fetch!(opts, :shown)
    }

    rendered_to_string(~H"""
    <EditionChips.row
      id="card-1"
      record={@record}
      editions={@editions}
      accent={@accent}
      shown={@shown}
    />
    """)
    |> String.trim()
  end

  defp inline(languages) do
    record = record(languages)

    assigns = %{
      record: record,
      editions: EditionChips.editions(record),
      accent: MishkaCmsCore.LanguageAccent.of(record)
    }

    rendered_to_string(~H"""
    <EditionChips.inline id="cell-1" record={@record} editions={@editions} accent={@accent} />
    """)
    |> String.trim()
  end

  defp query(html, selector),
    do: html |> LazyHTML.from_fragment() |> LazyHTML.query(selector) |> Enum.to_list()

  defp text(html, selector) do
    html |> query(selector) |> Enum.map_join(" ", &LazyHTML.text/1) |> String.trim()
  end

  defp chips(html, selector) do
    html
    |> query(selector)
    |> Enum.flat_map(&(&1 |> LazyHTML.query("button[phx-click=show_edition]") |> Enum.to_list()))
    |> Enum.map(&(&1 |> LazyHTML.text() |> String.trim()))
  end
end
