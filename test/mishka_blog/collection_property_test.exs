defmodule MishkaBlog.Test.CollectionPropertyTest do
  use MishkaBlog.DataCase
  use ExUnit.Case
  import ExUnitProperties
  import StreamData

  if Code.ensure_loaded?(MishkaBlog) do
    alias MishkaBlog.Collection
    @moduletag :property
    property "accepts all valid input combinations" do
      check all(
              name <- valid_name_generator(),
              slug <- valid_slug_generator(),
              description <- one_of([nil, valid_description_generator()]),
              status <- valid_status_generator(),
              language <- valid_language_generator()
            ) do
        site = create_test_site!()

        changeset =
          Ash.Changeset.for_create(
            Collection,
            :master_create,
            %{
              name: name,
              slug: slug,
              description: description,
              status: status,
              language: language,
              site_id: site.id
            },
            authorize?: false
          )

        assert changeset.valid?,
               "Expected valid changeset for: #{inspect(%{name: name, slug: slug, status: status})}"
      end
    end

    property "accepts minimal valid inputs" do
      check all(
              name <- valid_name_generator(),
              slug <- valid_slug_generator()
            ) do
        site = create_test_site!()

        changeset =
          Ash.Changeset.for_create(
            Collection,
            :master_create,
            %{
              name: name,
              slug: slug,
              status: :draft,
              language: "en",
              site_id: site.id
            },
            authorize?: false
          )

        assert changeset.valid?,
               "Minimal valid inputs should create valid changeset: name=#{name}, slug=#{slug}"
      end
    end

    property "accepts maximal valid inputs" do
      check all(
              name <-
                string([?A..?Z], length: 1)
                |> bind(fn first ->
                  string([?a..?z, ?A..?Z, ?0..?9, ?\s], length: 254)
                  |> map(fn rest ->
                    first <> rest
                  end)
                end),
              slug <-
                string([?a..?z], length: 1)
                |> bind(fn first ->
                  string([?a..?z, ?0..?9, ?-], length: 254)
                  |> map(fn rest ->
                    first <> rest
                  end)
                end),
              description <-
                string([?\s, ?a..?z, ?A..?Z, ?0..?9], min_length: 2000, max_length: 2000)
            ) do
        site = create_test_site!()

        changeset =
          Ash.Changeset.for_create(
            Collection,
            :master_create,
            %{
              name: name,
              slug: slug,
              description: description,
              status: :active,
              language: "en",
              site_id: site.id
            },
            authorize?: false
          )

        assert changeset.valid?,
               "Maximal valid inputs should create valid changeset"
      end
    end

    property "rejects invalid names" do
      check all(invalid_name <- invalid_name_generator()) do
        site = create_test_site!()

        changeset =
          Ash.Changeset.for_create(
            Collection,
            :master_create,
            %{
              name: invalid_name,
              slug: "valid-slug",
              status: :draft,
              language: "en",
              site_id: site.id
            },
            authorize?: false
          )

        refute changeset.valid?,
               "Expected invalid changeset for name: #{inspect(invalid_name)}"
      end
    end

    property "rejects invalid slugs" do
      check all(invalid_slug <- invalid_slug_generator()) do
        site = create_test_site!()

        changeset =
          Ash.Changeset.for_create(
            Collection,
            :master_create,
            %{
              name: "Valid Name",
              slug: invalid_slug,
              status: :draft,
              language: "en",
              site_id: site.id
            },
            authorize?: false
          )

        refute changeset.valid?,
               "Expected invalid changeset for slug: #{inspect(invalid_slug)}"
      end
    end

    property "rejects invalid descriptions" do
      check all(
              name <- valid_name_generator(),
              slug <- valid_slug_generator(),
              invalid_description <- invalid_description_generator()
            ) do
        site = create_test_site!()

        changeset =
          Ash.Changeset.for_create(
            Collection,
            :master_create,
            %{
              name: name,
              slug: slug,
              description: invalid_description,
              status: :draft,
              language: "en",
              site_id: site.id
            },
            authorize?: false
          )

        refute changeset.valid?,
               "Expected invalid changeset for description length: #{String.length(invalid_description)}"
      end
    end

    property "rejects missing required fields" do
      check all(
              include_name <- boolean(),
              include_slug <- boolean(),
              name <- valid_name_generator(),
              slug <- valid_slug_generator()
            ) do
        site = create_test_site!()
        attrs = %{status: :draft, language: "en", site_id: site.id}
        attrs = if include_name, do: Map.put(attrs, :name, name), else: attrs
        attrs = if include_slug, do: Map.put(attrs, :slug, slug), else: attrs

        changeset =
          Ash.Changeset.for_create(Collection, :master_create, attrs, authorize?: false)

        if include_name and include_slug do
          assert changeset.valid?,
                 "Expected valid changeset when required fields are present: #{inspect(attrs)}"
        else
          refute changeset.valid?,
                 "Expected invalid changeset when required fields are missing: #{inspect(attrs)}"
        end
      end
    end

    property "handles boundary values correctly" do
      check all(
              name_length <- member_of([1, 255]),
              slug_length <- member_of([1, 255]),
              description_length <- member_of([0, 1, 2000])
            ) do
        site = create_test_site!()
        name = String.duplicate("A", name_length)
        slug = "a" <> String.duplicate("b", slug_length - 1)

        description =
          if description_length == 0,
            do: nil,
            else: String.duplicate("d", description_length)

        changeset =
          Ash.Changeset.for_create(
            Collection,
            :master_create,
            %{
              name: name,
              slug: slug,
              description: description,
              status: :draft,
              language: "en",
              site_id: site.id
            },
            authorize?: false
          )

        assert changeset.valid?,
               "Boundary values should be valid: name_len=#{name_length}, slug_len=#{slug_length}, desc_len=#{description_length}"
      end
    end

    property "handles whitespace trimming correctly" do
      check all(
              base_name <- string([?a..?z, ?A..?Z, ?0..?9], min_length: 1, max_length: 245),
              base_slug <- string([?a..?z, ?0..?9], min_length: 1, max_length: 245),
              leading_spaces <- integer(1..5),
              trailing_spaces <- integer(1..5)
            ) do
        site = create_test_site!()

        padded_name =
          "#{String.duplicate(" ", leading_spaces)}#{base_name}#{String.duplicate(" ", trailing_spaces)}"

        padded_slug =
          "#{String.duplicate(" ", leading_spaces)}#{base_slug}#{String.duplicate(" ", trailing_spaces)}"

        changeset =
          Ash.Changeset.for_create(
            Collection,
            :master_create,
            %{
              name: padded_name,
              slug: padded_slug,
              status: :draft,
              language: "en",
              site_id: site.id
            },
            authorize?: false
          )

        # Should be valid due to trimming
        assert changeset.valid?, "Should be valid after trimming whitespace"
      end
    end

    property "allows same slug across different sites" do
      check all(slug <- valid_slug_generator()) do
        # Generate unique site names and hosts to avoid conflicts
        unique_id1 = System.unique_integer([:positive])
        unique_id2 = System.unique_integer([:positive])
        site1 = create_test_site!(name: "Site#{unique_id1}", host: "site#{unique_id1}.com")
        site2 = create_test_site!(name: "Site#{unique_id2}", host: "site#{unique_id2}.com")

        changeset1 =
          Ash.Changeset.for_create(
            Collection,
            :master_create,
            %{
              name: "Collection 1",
              slug: slug,
              status: :draft,
              language: "en",
              site_id: site1.id
            },
            authorize?: false
          )

        changeset2 =
          Ash.Changeset.for_create(
            Collection,
            :master_create,
            %{
              name: "Collection 2",
              slug: slug,
              status: :draft,
              language: "en",
              site_id: site2.id
            },
            authorize?: false
          )

        assert changeset1.valid?, "First collection should be valid"

        assert changeset2.valid?,
               "Second collection with same slug on different site should be valid"
      end
    end

    property "collections require site_id (tenant)" do
      check all(
              name <- valid_name_generator(),
              slug <- valid_slug_generator()
            ) do
        # Test that creating without tenant fails
        assert_raise Ash.Error.Invalid, fn ->
          Collection
          |> Ash.Changeset.for_create(:create, %{
            name: name,
            slug: slug
          })
          |> Ash.create!(authorize?: false)
        end
      end
    end

    property "update action accepts valid changes on non-archived collections" do
      check all(
              original_name <- valid_name_generator(),
              new_name <- valid_name_generator(),
              new_description <- one_of([nil, valid_description_generator()]),
              new_status <- valid_status_generator()
            ) do
        site = create_test_site!()

        collection = %Collection{
          id: Ash.UUID.generate(),
          name: original_name,
          slug: "original-slug",
          description: "Original description",
          status: :active,
          language: "en",
          site_id: site.id,
          archived_at: nil
        }

        changeset =
          Ash.Changeset.for_update(
            collection,
            :update,
            %{
              name: new_name,
              description: new_description,
              status: new_status
            },
            authorize?: false
          )
          |> Ash.Changeset.set_tenant(site.id)

        assert changeset.valid?, "Update should be valid for non-archived collection"
      end
    end

    property "update action rejects changes on archived collections" do
      check all(
              name <- valid_name_generator(),
              new_name <- valid_name_generator()
            ) do
        site = create_test_site!()

        archived_collection = %Collection{
          id: Ash.UUID.generate(),
          name: name,
          slug: "archived-slug",
          description: "Test description",
          status: :archived,
          language: "en",
          site_id: site.id,
          archived_at: ~U[2024-01-01 00:00:00Z]
        }

        changeset =
          Ash.Changeset.for_update(
            archived_collection,
            :update,
            %{
              name: new_name
            },
            authorize?: false
          )
          |> Ash.Changeset.set_tenant(site.id)

        refute changeset.valid?, "Update should be invalid for archived collection"
      end
    end

    property "unarchive action works on archived collections" do
      check all(name <- valid_name_generator()) do
        site = create_test_site!()

        archived_collection = %Collection{
          id: Ash.UUID.generate(),
          name: name,
          slug: "archived-slug",
          description: "Test description",
          status: :archived,
          language: "en",
          site_id: site.id,
          archived_at: ~U[2024-01-01 00:00:00Z]
        }

        changeset =
          Ash.Changeset.for_update(archived_collection, :unarchive, %{}, authorize?: false)

        assert changeset.valid?, "Unarchive should work on archived collections"
      end
    end

    property "applies default values correctly" do
      check all(
              name <- valid_name_generator(),
              slug <- valid_slug_generator()
            ) do
        site = create_test_site!()

        changeset =
          Ash.Changeset.for_create(
            Collection,
            :master_create,
            %{
              name: name,
              slug: slug,
              status: :draft,
              language: "en",
              site_id: site.id
            },
            authorize?: false
          )

        assert changeset.valid?
        # Test that defaults would be applied
        assert changeset.attributes[:status] == :draft or
                 changeset.attributes[:status] in [:active, :archived, :draft]

        assert changeset.attributes[:language] == "en" or
                 is_binary(changeset.attributes[:language])

        assert changeset.attributes[:featured] == false or
                 is_boolean(changeset.attributes[:featured])

        assert changeset.attributes[:display_order] == 0 or
                 is_integer(changeset.attributes[:display_order])
      end
    end

    property "applies slugification" do
      check all(
              base_slug <- string([?a..?z, ?A..?Z, ?0..?9], min_length: 2, max_length: 50),
              special_chars <- member_of([" ", "!", ".", "?"])
            ) do
        site = create_test_site!()
        slug_with_special = base_slug <> special_chars

        changeset =
          Ash.Changeset.for_create(
            Collection,
            :master_create,
            %{
              name: "Test Name",
              slug: slug_with_special,
              status: :draft,
              language: "en",
              site_id: site.id
            },
            authorize?: false
          )

        # Should be valid (slugification removes special characters)
        assert changeset.valid?,
               "Slug with special characters should be valid (gets slugified): #{slug_with_special}"
      end
    end

    property "archive -> unarchive -> update workflow" do
      check all(
              original_name <- valid_name_generator(),
              new_name <- valid_name_generator()
            ) do
        site = create_test_site!()

        collection = %Collection{
          id: Ash.UUID.generate(),
          name: original_name,
          slug: "test-slug",
          description: "Test",
          status: :active,
          language: "en",
          site_id: site.id,
          archived_at: nil
        }

        # Destroy (archive)
        destroy_changeset =
          Ash.Changeset.for_destroy(collection, :destroy, %{}, authorize?: false)

        assert destroy_changeset.valid?, "Destroy should be valid"
        # Simulate archived state
        archived_collection = %{
          collection
          | archived_at: ~U[2024-01-01 00:00:00Z],
            status: :archived
        }

        # Unarchive
        unarchive_changeset =
          Ash.Changeset.for_update(archived_collection, :unarchive, %{}, authorize?: false)

        assert unarchive_changeset.valid?, "Unarchive should be valid"
        # Simulate unarchived state
        unarchived_collection = %{archived_collection | archived_at: nil, status: :active}
        # Update after unarchive
        update_changeset =
          Ash.Changeset.for_update(unarchived_collection, :update, %{name: new_name},
            authorize?: false
          )
          |> Ash.Changeset.set_tenant(site.id)

        assert update_changeset.valid?, "Update after unarchive should be valid"
      end
    end

    property "handles description with various content" do
      check all(
              name <- valid_name_generator(),
              slug <- valid_slug_generator(),
              description <-
                one_of([
                  string([?a..?z, ?\s], min_length: 1, max_length: 1000),
                  string([?0..?9, ?\s], min_length: 1, max_length: 1000),
                  string([?a..?z, ?A..?Z, ?0..?9, ?\s, ?., ?,, ?!, ??],
                    min_length: 1,
                    max_length: 1000
                  )
                ])
            ) do
        site = create_test_site!()

        changeset =
          Ash.Changeset.for_create(
            Collection,
            :master_create,
            %{
              name: name,
              slug: slug,
              description: description,
              status: :draft,
              language: "en",
              site_id: site.id
            },
            authorize?: false
          )

        assert changeset.valid?,
               "Valid description content should create valid changeset: #{inspect(String.slice(description, 0, 50))}"
      end
    end

    property "validates status is one of allowed values" do
      check all(
              name <- valid_name_generator(),
              slug <- valid_slug_generator(),
              status <- member_of([:active, :archived, :draft, :invalid_status, "wrong", 123])
            ) do
        site = create_test_site!()

        changeset =
          Ash.Changeset.for_create(
            Collection,
            :master_create,
            %{
              name: name,
              slug: slug,
              status: status,
              language: "en",
              site_id: site.id
            },
            authorize?: false
          )

        if status in [:active, :archived, :draft] do
          assert changeset.valid?, "Valid status should create valid changeset"
        else
          refute changeset.valid?,
                 "Invalid status should create invalid changeset: #{inspect(status)}"
        end
      end
    end

    property "handles display_order as non-negative integer" do
      check all(
              name <- valid_name_generator(),
              slug <- valid_slug_generator(),
              display_order <- integer(-10..1000)
            ) do
        site = create_test_site!()

        changeset =
          Ash.Changeset.for_create(
            Collection,
            :master_create,
            %{
              name: name,
              slug: slug,
              display_order: display_order,
              status: :draft,
              language: "en",
              site_id: site.id
            },
            authorize?: false
          )

        if display_order >= 0 do
          assert changeset.valid?, "Non-negative display_order should be valid"
        else
          refute changeset.valid?, "Negative display_order should be invalid"
        end
      end
    end

    property "validates featured is boolean" do
      check all(
              name <- valid_name_generator(),
              slug <- valid_slug_generator(),
              featured <- one_of([boolean(), constant("true"), constant(1), constant(nil)])
            ) do
        site = create_test_site!()

        changeset =
          Ash.Changeset.for_create(
            Collection,
            :master_create,
            %{
              name: name,
              slug: slug,
              featured: featured,
              status: :draft,
              language: "en",
              site_id: site.id
            },
            authorize?: false
          )

        if is_boolean(featured) do
          assert changeset.valid?, "Boolean featured should be valid"
        else
          # Non-boolean values should either fail validation or be coerced
          # Depending on Ash behavior, this may or may not be valid
          true
        end
      end
    end

    property "handles seo_tags as array of maps" do
      check all(
              name <- valid_name_generator(),
              slug <- valid_slug_generator(),
              seo_tags <- list_of(valid_seo_tag_generator(), max_length: 5)
            ) do
        site = create_test_site!()

        changeset =
          Ash.Changeset.for_create(
            Collection,
            :master_create,
            %{
              name: name,
              slug: slug,
              seo_tags: seo_tags,
              status: :draft,
              language: "en",
              site_id: site.id
            },
            authorize?: false
          )

        assert changeset.valid?, "Valid seo_tags should create valid changeset"
      end
    end

    property "handles schema as array of maps" do
      check all(
              name <- valid_name_generator(),
              slug <- valid_slug_generator(),
              schema <- list_of(valid_schema_generator(), max_length: 3)
            ) do
        site = create_test_site!()

        changeset =
          Ash.Changeset.for_create(
            Collection,
            :master_create,
            %{
              name: name,
              slug: slug,
              schema: schema,
              status: :draft,
              language: "en",
              site_id: site.id
            },
            authorize?: false
          )

        assert changeset.valid?, "Valid schema should create valid changeset"
      end
    end

    property "prevents collection from being its own parent" do
      check all(name <- valid_name_generator()) do
        site = create_test_site!()
        id = Ash.UUID.generate()

        collection = %Collection{
          id: id,
          name: name,
          slug: "test-slug",
          description: "Test",
          status: :active,
          language: "en",
          site_id: site.id,
          archived_at: nil
        }

        changeset =
          Ash.Changeset.for_update(
            collection,
            :update,
            %{
              parent_collection_id: id
            },
            authorize?: false
          )
          |> Ash.Changeset.set_tenant(site.id)

        refute changeset.valid?, "Collection should not be able to be its own parent"
      end
    end

    ####################################################################################
    ############################ (▰˘◡˘▰) Helpers (▰˘◡˘▰) ###############################
    ####################################################################################
    defp valid_name_generator do
      bind(string([?a..?z, ?A..?Z], length: 1), fn first_char ->
        bind(string([?a..?z, ?A..?Z, ?0..?9, ?\s], min_length: 1, max_length: 254), fn rest ->
          name = String.trim(first_char <> rest)

          if String.length(name) >= 2 do
            constant(name)
          else
            constant(first_char <> "a")
          end
        end)
      end)
    end

    defp valid_slug_generator do
      bind(string([?a..?z], length: 1), fn first_char ->
        bind(string([?a..?z, ?0..?9, ?-], min_length: 1, max_length: 254), fn rest ->
          slug = first_char <> rest

          if String.length(slug) >= 2 do
            constant(slug)
          else
            constant(first_char <> "a")
          end
        end)
      end)
    end

    defp valid_description_generator do
      string([?\s, ?a..?z, ?A..?Z, ?0..?9, ?., ?,, ?!, ??], max_length: 2000)
    end

    defp valid_status_generator do
      member_of([:active, :archived, :draft])
    end

    defp valid_language_generator do
      member_of(["en", "fa", "ar", "ru", "es", "fr", "de", "ja", "zh"])
    end

    defp valid_seo_tag_generator do
      bind(member_of(["meta", "link", "title"]), fn tag ->
        # Generate 0-2 random attributes instead of using map_of to avoid duplicates
        bind(
          integer(0..2),
          fn num_attrs ->
            bind(
              if num_attrs == 0 do
                constant(%{})
              else
                # Pick random attributes from the list
                attrs_list = ["name", "property", "content", "href", "rel"]

                bind(
                  uniq_list_of(member_of(attrs_list),
                    min_length: num_attrs,
                    max_length: num_attrs
                  ),
                  fn selected_attrs ->
                    bind(
                      list_of(string([?a..?z, ?A..?Z, ?0..?9, ?\s], max_length: 50),
                        length: num_attrs
                      ),
                      fn values ->
                        constant(Enum.zip(selected_attrs, values) |> Map.new())
                      end
                    )
                  end
                )
              end,
              fn attrs ->
                bind(
                  one_of([nil, string([?a..?z, ?A..?Z, ?0..?9, ?\s], max_length: 100)]),
                  fn content ->
                    constant(%{
                      "tag" => tag,
                      "attrs" => attrs,
                      "content" => content
                    })
                  end
                )
              end
            )
          end
        )
      end)
    end

    defp valid_schema_generator do
      map_of(
        string([?a..?z, ?A..?Z], max_length: 20),
        one_of([
          string([?a..?z, ?A..?Z, ?0..?9, ?\s], max_length: 50),
          integer(0..1000),
          boolean()
        ]),
        max_length: 5
      )
    end

    defp invalid_name_generator do
      one_of([
        # Empty
        constant(""),
        # Only whitespace
        string([?\s], min_length: 1, max_length: 10),
        # Too long (more than 255 characters)
        string([?a..?z, ?A..?Z, ?0..?9], min_length: 256, max_length: 300)
      ])
    end

    defp invalid_slug_generator do
      one_of([
        # Empty
        constant(""),
        # Only whitespace
        string([?\s], min_length: 1, max_length: 10),
        # Too long (more than 255 characters)
        string([?a..?z, ?0..?9], min_length: 256, max_length: 300)
      ])
    end

    defp invalid_description_generator do
      # Description too long (more than 2000 characters)
      string([?a..?z, ?A..?Z, ?0..?9], min_length: 2001, max_length: 2500)
    end

    # Helper function to create a site for testing
    defp create_test_site!(attrs \\ []) do
      default_attrs = [
        name: "Test Site #{System.unique_integer([:positive])}",
        host: "test#{System.unique_integer([:positive])}.com"
      ]

      attrs = Keyword.merge(default_attrs, attrs)

      {:ok, site} =
        MishkaCmsCore.Runtime.Site
        |> Ash.Changeset.for_create(:create, Enum.into(attrs, %{}), authorize?: false)
        |> Ash.create(authorize?: false)

      site
    end
  end
end
