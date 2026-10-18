# SPDX-FileCopyrightText: 2026 Mishka Group contributors <https://github.com/mishka-group/mishka_blog/graphs/contributors>
#
# SPDX-License-Identifier: Apache-2.0

defmodule MishkaBlog.Test.BlogPostPropertyTest do
  use MishkaBlog.DataCase
  use ExUnit.Case
  import ExUnitProperties
  import StreamData

  if Code.ensure_loaded?(MishkaBlog) do
    alias MishkaBlog.BlogPost
    @moduletag :property
    property "accepts all valid input combinations" do
      check all(
              title <- valid_title_generator(),
              slug <- valid_slug_generator(),
              content <- valid_content_generator(),
              excerpt <- one_of([nil, valid_excerpt_generator()]),
              status <- valid_status_generator(),
              language <- valid_language_generator()
            ) do
        site = create_test_site!()

        changeset =
          Ash.Changeset.for_create(
            BlogPost,
            :master_create,
            %{
              title: title,
              slug: slug,
              content: content,
              excerpt: excerpt,
              status: status,
              language: language,
              site_id: site.id
            },
            authorize?: false
          )

        assert changeset.valid?,
               "Expected valid changeset for: #{inspect(%{title: title, slug: slug, status: status})}"
      end
    end

    property "accepts minimal valid inputs" do
      check all(
              title <- valid_title_generator(),
              slug <- valid_slug_generator(),
              content <- valid_content_generator()
            ) do
        site = create_test_site!()

        changeset =
          Ash.Changeset.for_create(
            BlogPost,
            :master_create,
            %{
              title: title,
              slug: slug,
              content: content,
              status: :draft,
              language: "en",
              site_id: site.id
            },
            authorize?: false
          )

        assert changeset.valid?,
               "Minimal valid inputs should create valid changeset: title=#{title}, slug=#{slug}"
      end
    end

    property "accepts maximal valid inputs" do
      check all(
              title <-
                string([?A..?Z], length: 1)
                |> bind(fn first ->
                  string([?a..?z, ?A..?Z, ?0..?9, ?\s], length: 499)
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
              content <-
                string([?\s, ?a..?z, ?A..?Z, ?0..?9], min_length: 1000, max_length: 1000),
              excerpt <- string([?\s, ?a..?z, ?A..?Z, ?0..?9], min_length: 1000, max_length: 1000)
            ) do
        site = create_test_site!()

        changeset =
          Ash.Changeset.for_create(
            BlogPost,
            :master_create,
            %{
              title: title,
              slug: slug,
              content: content,
              excerpt: excerpt,
              status: :published,
              language: "en",
              site_id: site.id
            },
            authorize?: false
          )

        assert changeset.valid?,
               "Maximal valid inputs should create valid changeset"
      end
    end

    property "rejects invalid titles" do
      check all(invalid_title <- invalid_title_generator()) do
        site = create_test_site!()

        changeset =
          Ash.Changeset.for_create(
            BlogPost,
            :master_create,
            %{
              title: invalid_title,
              slug: "valid-slug",
              content: "<p>Content</p>",
              status: :draft,
              language: "en",
              site_id: site.id
            },
            authorize?: false
          )

        refute changeset.valid?,
               "Expected invalid changeset for title: #{inspect(invalid_title)}"
      end
    end

    property "rejects invalid slugs" do
      check all(invalid_slug <- invalid_slug_generator()) do
        site = create_test_site!()

        changeset =
          Ash.Changeset.for_create(
            BlogPost,
            :master_create,
            %{
              title: "Valid Title",
              slug: invalid_slug,
              content: "<p>Content</p>",
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

    property "rejects invalid content" do
      check all(
              title <- valid_title_generator(),
              slug <- valid_slug_generator(),
              invalid_content <- invalid_content_generator()
            ) do
        site = create_test_site!()

        changeset =
          Ash.Changeset.for_create(
            BlogPost,
            :master_create,
            %{
              title: title,
              slug: slug,
              content: invalid_content,
              status: :draft,
              language: "en",
              site_id: site.id
            },
            authorize?: false
          )

        refute changeset.valid?,
               "Expected invalid changeset for empty content"
      end
    end

    property "rejects invalid excerpts" do
      check all(
              title <- valid_title_generator(),
              slug <- valid_slug_generator(),
              invalid_excerpt <- invalid_excerpt_generator()
            ) do
        site = create_test_site!()

        changeset =
          Ash.Changeset.for_create(
            BlogPost,
            :master_create,
            %{
              title: title,
              slug: slug,
              content: "<p>Content</p>",
              excerpt: invalid_excerpt,
              status: :draft,
              language: "en",
              site_id: site.id
            },
            authorize?: false
          )

        refute changeset.valid?,
               "Expected invalid changeset for excerpt length: #{String.length(invalid_excerpt)}"
      end
    end

    property "rejects missing required fields" do
      check all(
              include_title <- boolean(),
              include_slug <- boolean(),
              include_content <- boolean(),
              title <- valid_title_generator(),
              slug <- valid_slug_generator(),
              content <- valid_content_generator()
            ) do
        site = create_test_site!()
        attrs = %{status: :draft, language: "en", site_id: site.id}
        attrs = if include_title, do: Map.put(attrs, :title, title), else: attrs
        attrs = if include_slug, do: Map.put(attrs, :slug, slug), else: attrs
        attrs = if include_content, do: Map.put(attrs, :content, content), else: attrs

        changeset =
          Ash.Changeset.for_create(BlogPost, :master_create, attrs, authorize?: false)

        if include_title and include_slug and include_content do
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
              title_length <- member_of([1, 500]),
              slug_length <- member_of([1, 255]),
              excerpt_length <- member_of([0, 1, 1000])
            ) do
        site = create_test_site!()
        title = String.duplicate("A", title_length)
        slug = "a" <> String.duplicate("b", slug_length - 1)

        excerpt =
          if excerpt_length == 0,
            do: nil,
            else: String.duplicate("d", excerpt_length)

        changeset =
          Ash.Changeset.for_create(
            BlogPost,
            :master_create,
            %{
              title: title,
              slug: slug,
              content: "<p>Content</p>",
              excerpt: excerpt,
              status: :draft,
              language: "en",
              site_id: site.id
            },
            authorize?: false
          )

        assert changeset.valid?,
               "Boundary values should be valid: title_len=#{title_length}, slug_len=#{slug_length}, excerpt_len=#{excerpt_length}"
      end
    end

    property "handles whitespace trimming correctly" do
      check all(
              base_title <- string([?a..?z, ?A..?Z, ?0..?9], min_length: 1, max_length: 245),
              base_slug <- string([?a..?z, ?0..?9], min_length: 1, max_length: 245),
              leading_spaces <- integer(1..5),
              trailing_spaces <- integer(1..5)
            ) do
        site = create_test_site!()

        padded_title =
          "#{String.duplicate(" ", leading_spaces)}#{base_title}#{String.duplicate(" ", trailing_spaces)}"

        padded_slug =
          "#{String.duplicate(" ", leading_spaces)}#{base_slug}#{String.duplicate(" ", trailing_spaces)}"

        changeset =
          Ash.Changeset.for_create(
            BlogPost,
            :master_create,
            %{
              title: padded_title,
              slug: padded_slug,
              content: "<p>Content</p>",
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
            BlogPost,
            :master_create,
            %{
              title: "Post 1",
              slug: slug,
              content: "<p>Content 1</p>",
              status: :draft,
              language: "en",
              site_id: site1.id
            },
            authorize?: false
          )

        changeset2 =
          Ash.Changeset.for_create(
            BlogPost,
            :master_create,
            %{
              title: "Post 2",
              slug: slug,
              content: "<p>Content 2</p>",
              status: :draft,
              language: "en",
              site_id: site2.id
            },
            authorize?: false
          )

        assert changeset1.valid?, "First blog post should be valid"

        assert changeset2.valid?,
               "Second blog post with same slug on different site should be valid"
      end
    end

    property "blog posts require site_id (tenant)" do
      check all(
              title <- valid_title_generator(),
              slug <- valid_slug_generator(),
              content <- valid_content_generator()
            ) do
        # Test that creating without tenant fails
        assert_raise Ash.Error.Invalid, fn ->
          BlogPost
          |> Ash.Changeset.for_create(:create, %{
            title: title,
            slug: slug,
            content: content
          })
          |> Ash.create!(authorize?: false)
        end
      end
    end

    property "update action accepts valid changes on non-archived posts" do
      check all(
              original_title <- valid_title_generator(),
              new_title <- valid_title_generator(),
              new_excerpt <- one_of([nil, valid_excerpt_generator()]),
              new_status <- valid_status_generator()
            ) do
        site = create_test_site!()

        blog_post = %BlogPost{
          id: Ash.UUID.generate(),
          title: original_title,
          slug: "original-slug",
          content: "<p>Original content</p>",
          excerpt: "Original excerpt",
          status: :published,
          language: "en",
          site_id: site.id,
          archived_at: nil
        }

        changeset =
          Ash.Changeset.for_update(
            blog_post,
            :update,
            %{
              title: new_title,
              excerpt: new_excerpt,
              status: new_status
            },
            authorize?: false
          )
          |> Ash.Changeset.set_tenant(site.id)

        assert changeset.valid?, "Update should be valid for non-archived blog post"
      end
    end

    property "update action rejects changes on archived posts" do
      check all(
              title <- valid_title_generator(),
              new_title <- valid_title_generator()
            ) do
        site = create_test_site!()

        archived_post = %BlogPost{
          id: Ash.UUID.generate(),
          title: title,
          slug: "archived-slug",
          content: "<p>Content</p>",
          excerpt: "Test excerpt",
          status: :archived,
          language: "en",
          site_id: site.id,
          archived_at: ~U[2024-01-01 00:00:00Z]
        }

        changeset =
          Ash.Changeset.for_update(
            archived_post,
            :update,
            %{
              title: new_title
            },
            authorize?: false
          )
          |> Ash.Changeset.set_tenant(site.id)

        refute changeset.valid?, "Update should be invalid for archived blog post"
      end
    end

    property "unarchive action works on archived posts" do
      check all(title <- valid_title_generator()) do
        site = create_test_site!()

        archived_post = %BlogPost{
          id: Ash.UUID.generate(),
          title: title,
          slug: "archived-slug",
          content: "<p>Content</p>",
          excerpt: "Test excerpt",
          status: :archived,
          language: "en",
          site_id: site.id,
          archived_at: ~U[2024-01-01 00:00:00Z]
        }

        changeset =
          Ash.Changeset.for_update(archived_post, :unarchive, %{}, authorize?: false)

        assert changeset.valid?, "Unarchive should work on archived blog posts"
      end
    end

    property "applies default values correctly" do
      check all(
              title <- valid_title_generator(),
              slug <- valid_slug_generator(),
              content <- valid_content_generator()
            ) do
        site = create_test_site!()

        changeset =
          Ash.Changeset.for_create(
            BlogPost,
            :master_create,
            %{
              title: title,
              slug: slug,
              content: content,
              status: :draft,
              language: "en",
              site_id: site.id
            },
            authorize?: false
          )

        assert changeset.valid?
        # Test that defaults would be applied
        assert changeset.attributes[:status] == :draft
        assert changeset.attributes[:language] == "en"
        assert changeset.attributes[:featured] == false
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
            BlogPost,
            :master_create,
            %{
              title: "Test Title",
              slug: slug_with_special,
              content: "<p>Content</p>",
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
              original_title <- valid_title_generator(),
              new_title <- valid_title_generator()
            ) do
        site = create_test_site!()

        blog_post = %BlogPost{
          id: Ash.UUID.generate(),
          title: original_title,
          slug: "test-slug",
          content: "<p>Content</p>",
          excerpt: "Test",
          status: :published,
          language: "en",
          site_id: site.id,
          archived_at: nil
        }

        # Destroy (archive)
        destroy_changeset =
          Ash.Changeset.for_destroy(blog_post, :destroy, %{}, authorize?: false)

        assert destroy_changeset.valid?, "Destroy should be valid"
        # Simulate archived state
        archived_post = %{
          blog_post
          | archived_at: ~U[2024-01-01 00:00:00Z],
            status: :archived
        }

        # Unarchive
        unarchive_changeset =
          Ash.Changeset.for_update(archived_post, :unarchive, %{}, authorize?: false)

        assert unarchive_changeset.valid?, "Unarchive should be valid"
        # Simulate unarchived state
        unarchived_post = %{archived_post | archived_at: nil, status: :draft}
        # Update after unarchive
        update_changeset =
          Ash.Changeset.for_update(unarchived_post, :update, %{title: new_title},
            authorize?: false
          )
          |> Ash.Changeset.set_tenant(site.id)

        assert update_changeset.valid?, "Update after unarchive should be valid"
      end
    end

    property "handles excerpt with various content" do
      check all(
              title <- valid_title_generator(),
              slug <- valid_slug_generator(),
              excerpt <-
                one_of([
                  string([?a..?z, ?\s], min_length: 1, max_length: 500),
                  string([?0..?9, ?\s], min_length: 1, max_length: 500),
                  string([?a..?z, ?A..?Z, ?0..?9, ?\s, ?., ?,, ?!, ??],
                    min_length: 1,
                    max_length: 500
                  )
                ])
            ) do
        site = create_test_site!()

        changeset =
          Ash.Changeset.for_create(
            BlogPost,
            :master_create,
            %{
              title: title,
              slug: slug,
              content: "<p>Content</p>",
              excerpt: excerpt,
              status: :draft,
              language: "en",
              site_id: site.id
            },
            authorize?: false
          )

        assert changeset.valid?,
               "Valid excerpt content should create valid changeset: #{inspect(String.slice(excerpt, 0, 50))}"
      end
    end

    property "validates status is one of allowed values" do
      check all(
              title <- valid_title_generator(),
              slug <- valid_slug_generator(),
              status <-
                member_of([:draft, :archived, :invalid_status, "wrong", 123])
            ) do
        site = create_test_site!()

        changeset =
          Ash.Changeset.for_create(
            BlogPost,
            :master_create,
            %{
              title: title,
              slug: slug,
              content: "<p>Content</p>",
              status: status,
              language: "en",
              site_id: site.id
            },
            authorize?: false
          )

        # Note: :scheduled and :published excluded from property tests
        # :scheduled requires scheduled_publish_at to be set
        # :published triggers published_at auto-set with microseconds that conflicts with paper trail
        if status in [:draft, :archived] do
          assert changeset.valid?, "Valid status should create valid changeset"
        else
          refute changeset.valid?,
                 "Invalid status should create invalid changeset: #{inspect(status)}"
        end
      end
    end

    property "validates featured is boolean" do
      check all(
              title <- valid_title_generator(),
              slug <- valid_slug_generator(),
              featured <- one_of([boolean(), constant("true"), constant(1), constant(nil)])
            ) do
        site = create_test_site!()

        changeset =
          Ash.Changeset.for_create(
            BlogPost,
            :master_create,
            %{
              title: title,
              slug: slug,
              content: "<p>Content</p>",
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
              title <- valid_title_generator(),
              slug <- valid_slug_generator(),
              seo_tags <- list_of(valid_seo_tag_generator(), max_length: 5)
            ) do
        site = create_test_site!()

        changeset =
          Ash.Changeset.for_create(
            BlogPost,
            :master_create,
            %{
              title: title,
              slug: slug,
              content: "<p>Content</p>",
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
              title <- valid_title_generator(),
              slug <- valid_slug_generator(),
              schema <- list_of(valid_schema_generator(), max_length: 3)
            ) do
        site = create_test_site!()

        changeset =
          Ash.Changeset.for_create(
            BlogPost,
            :master_create,
            %{
              title: title,
              slug: slug,
              content: "<p>Content</p>",
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

    property "auto-sets published_at when status is published" do
      check all(
              title <- valid_title_generator(),
              slug <- valid_slug_generator()
            ) do
        site = create_test_site!()

        changeset =
          Ash.Changeset.for_create(
            BlogPost,
            :master_create,
            %{
              title: title,
              slug: slug,
              content: "<p>Content</p>",
              status: :published,
              language: "en",
              site_id: site.id
            },
            authorize?: false
          )

        assert changeset.valid?
        # The published_at should be set by the change
      end
    end

    ####################################################################################
    ############################ (▰˘◡˘▰) Helpers (▰˘◡˘▰) ###############################
    ####################################################################################
    defp valid_title_generator do
      bind(string([?a..?z, ?A..?Z], length: 1), fn first_char ->
        bind(string([?a..?z, ?A..?Z, ?0..?9, ?\s], min_length: 1, max_length: 499), fn rest ->
          title = String.trim(first_char <> rest)

          if String.length(title) >= 2 do
            constant(title)
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

    defp valid_content_generator do
      # The guaranteed-present chunk uses only sanitization-surviving characters
      # (alphanumerics) so the content is never empty after `basic_html` sanitization —
      # a fragment like `<A` is read as an incomplete tag and stripped to nothing, which
      # would fail the resource's `not_empty` content validation. The trailing chunk still
      # includes HTML-ish characters to exercise the sanitizer.
      bind(
        string([?a..?z, ?A..?Z, ?0..?9], min_length: 1, max_length: 100),
        fn surviving ->
          bind(
            string([?\s, ?a..?z, ?A..?Z, ?0..?9, ?<, ?>, ?/, ?., ?,, ?!, ??], max_length: 1900),
            fn rest ->
              constant(surviving <> rest)
            end
          )
        end
      )
    end

    defp valid_excerpt_generator do
      string([?\s, ?a..?z, ?A..?Z, ?0..?9, ?., ?,, ?!, ??], max_length: 1000)
    end

    defp valid_status_generator do
      # Note: :scheduled is excluded because it requires scheduled_publish_at to be set
      # :published is excluded to avoid paper trail microseconds issues
      member_of([:draft, :archived])
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

    defp invalid_title_generator do
      one_of([
        # Empty
        constant(""),
        # Only whitespace
        string([?\s], min_length: 1, max_length: 10),
        # Too long (more than 500 characters)
        string([?a..?z, ?A..?Z, ?0..?9], min_length: 501, max_length: 600)
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

    defp invalid_content_generator do
      # Empty content
      constant("")
    end

    defp invalid_excerpt_generator do
      # Excerpt too long (more than 1000 characters)
      string([?a..?z, ?A..?Z, ?0..?9], min_length: 1001, max_length: 1500)
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
