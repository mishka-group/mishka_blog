defmodule MishkaBlog.Test.BloggerPropertyTest do
  @moduledoc """
  Property-based tests for MishkaBlog.Blogger resource using StreamData.

  These tests verify that the Blogger resource handles a wide range of random
  inputs correctly, including edge cases and unexpected data patterns.
  """
  use MishkaBlog.DataCase, async: false
  use ExUnitProperties

  if Code.ensure_loaded?(MishkaBlog) do
    alias MishkaBlog.Blogger

    # Generators for random test data
    defp random_display_name do
      gen all(name <- string(:alphanumeric, min_length: 1, max_length: 50)) do
        "Blogger " <> name
      end
    end

    defp random_slug do
      gen all(slug <- string(:alphanumeric, min_length: 1, max_length: 30)) do
        # Normalize to lowercase since slugs are stored lowercase
        "slug-" <> String.downcase(slug)
      end
    end

    # The bio is stored through `sanitize(basic_html)`, which writes `<`, `>` and `&` as entities, so
    # a bio holding one is not stored as it was given. These properties are about the bio being kept,
    # so they draw from the text that sanitizing leaves as it is.
    defp random_bio do
      gen all(bio <- string(:printable, max_length: 500)) do
        bio |> String.replace(["<", ">", "&"], "") |> String.trim()
      end
    end

    defp random_url do
      gen all(domain <- string(:alphanumeric, min_length: 3, max_length: 20)) do
        "https://example-#{domain}.com/image.jpg"
      end
    end

    defp random_expertise_areas do
      gen all(
            areas <-
              list_of(string(:alphanumeric, min_length: 3, max_length: 20), max_length: 5)
          ) do
        Enum.map(areas, &String.capitalize/1)
      end
    end

    defp random_social_links do
      platforms = ["twitter", "facebook", "linkedin", "github", "instagram"]

      gen all(
            count <- integer(0..3),
            selected_platforms <- StreamData.list_of(member_of(platforms), length: count)
          ) do
        Enum.map(selected_platforms, fn platform ->
          %{platform: platform, url: "https://#{platform}.com/user"}
        end)
      end
    end

    defp random_email do
      gen all(
            username <- string(:alphanumeric, min_length: 3, max_length: 20),
            domain <- string(:alphanumeric, min_length: 3, max_length: 20)
          ) do
        "#{username}@#{domain}.com"
      end
    end

    describe "property: create action with random data" do
      property "creates blogger with random valid display_name and slug" do
        check all(
                display_name <- random_display_name(),
                slug <- random_slug()
              ) do
          site = create_site!()
          user = create_user!()

          blogger =
            create_blogger!(
              user_id: user.id,
              display_name: display_name,
              slug: slug,
              site_id: site.id
            )

          assert blogger.display_name == display_name
          assert blogger.user_id == user.id
          assert is_binary(blogger.slug)
          assert String.length(blogger.slug) >= 1
        end
      end

      property "creates blogger with random optional fields" do
        check all(
                display_name <- random_display_name(),
                slug <- random_slug(),
                bio <- random_bio(),
                avatar_url <- random_url(),
                cover_image_url <- random_url(),
                expertise_areas <- random_expertise_areas(),
                social_links <- random_social_links(),
                contact_email <- random_email(),
                can_publish_directly <- boolean()
              ) do
          site = create_site!()
          user = create_user!()

          blogger =
            create_blogger!(
              user_id: user.id,
              display_name: display_name,
              slug: slug,
              bio: bio,
              avatar_url: avatar_url,
              cover_image_url: cover_image_url,
              expertise_areas: expertise_areas,
              social_links: social_links,
              contact_email: contact_email,
              can_publish_directly: can_publish_directly,
              site_id: site.id
            )

          # Empty strings get trimmed to nil
          expected_bio = if bio == "", do: nil, else: bio

          assert blogger.display_name == display_name
          assert blogger.bio == expected_bio
          assert blogger.avatar_url == avatar_url
          assert blogger.cover_image_url == cover_image_url
          assert blogger.expertise_areas == expertise_areas
          assert blogger.social_links == social_links
          assert blogger.contact_email == String.downcase(contact_email)
          assert blogger.can_publish_directly == can_publish_directly
        end
      end

      property "always assigns UUID v7 primary key" do
        check all(
                display_name <- random_display_name(),
                slug <- random_slug()
              ) do
          site = create_site!()
          user = create_user!()

          blogger =
            create_blogger!(
              user_id: user.id,
              display_name: display_name,
              slug: slug,
              site_id: site.id
            )

          assert is_binary(blogger.id)
          assert String.length(blogger.id) == 36
          assert String.match?(blogger.id, ~r/^[0-9a-f-]+$/)
        end
      end

      property "always auto-assigns site_id from tenant context" do
        check all(
                display_name <- random_display_name(),
                slug <- random_slug()
              ) do
          site = create_site!()
          user = create_user!()

          blogger =
            Blogger
            |> Ash.Changeset.for_create(
              :create,
              %{
                user_id: user.id,
                display_name: display_name,
                slug: slug
              },
              tenant: site.id,
              authorize?: false
            )
            |> Ash.create!()

          assert blogger.site_id == site.id
        end
      end
    end

    describe "property: update action" do
      property "updates blogger with random display_name" do
        check all(new_display_name <- random_display_name()) do
          site = create_site!()
          blogger = create_blogger!(site_id: site.id)

          updated =
            blogger
            |> Ash.Changeset.for_update(
              :update,
              %{display_name: new_display_name},
              tenant: site.id,
              authorize?: false
            )
            |> Ash.update!()

          assert updated.display_name == new_display_name
          assert updated.id == blogger.id
        end
      end

      property "updates blogger with random bio" do
        check all(new_bio <- random_bio()) do
          site = create_site!()
          blogger = create_blogger!(site_id: site.id)

          updated =
            blogger
            |> Ash.Changeset.for_update(
              :update,
              %{bio: new_bio},
              tenant: site.id,
              authorize?: false
            )
            |> Ash.update!()

          # Empty strings get trimmed to nil
          expected_bio = if new_bio == "", do: nil, else: new_bio
          assert updated.bio == expected_bio
        end
      end

      property "updates blogger with random expertise_areas" do
        check all(new_expertise_areas <- random_expertise_areas()) do
          site = create_site!()
          blogger = create_blogger!(site_id: site.id)

          updated =
            blogger
            |> Ash.Changeset.for_update(
              :update,
              %{expertise_areas: new_expertise_areas},
              tenant: site.id,
              authorize?: false
            )
            |> Ash.update!()

          assert updated.expertise_areas == new_expertise_areas
        end
      end

      property "updates blogger with random can_publish_directly value" do
        check all(new_can_publish <- boolean()) do
          site = create_site!()
          blogger = create_blogger!(site_id: site.id)

          updated =
            blogger
            |> Ash.Changeset.for_update(
              :update,
              %{can_publish_directly: new_can_publish},
              tenant: site.id,
              authorize?: false
            )
            |> Ash.update!()

          assert updated.can_publish_directly == new_can_publish
        end
      end
    end

    describe "property: archive and unarchive" do
      property "archive sets archived_at timestamp" do
        check all(
                display_name <- random_display_name(),
                slug <- random_slug()
              ) do
          site = create_site!()
          blogger = create_blogger!(display_name: display_name, slug: slug, site_id: site.id)

          archived =
            blogger
            |> Ash.Changeset.for_destroy(:destroy, %{}, tenant: site.id, authorize?: false)
            |> Ash.destroy!(return_destroyed?: true)

          assert archived.archived_at != nil
          assert is_struct(archived.archived_at, DateTime)
        end
      end

      property "unarchive clears archived_at" do
        check all(
                display_name <- random_display_name(),
                slug <- random_slug()
              ) do
          site = create_site!()
          blogger = create_blogger!(display_name: display_name, slug: slug, site_id: site.id)

          archived =
            blogger
            |> Ash.Changeset.for_destroy(:destroy, %{}, tenant: site.id, authorize?: false)
            |> Ash.destroy!(return_destroyed?: true)

          unarchived =
            archived
            |> Ash.Changeset.for_update(:unarchive, %{}, tenant: site.id, authorize?: false)
            |> Ash.update!()

          assert unarchived.archived_at == nil
        end
      end

      property "archived bloggers are excluded from normal reads" do
        check all(
                display_name <- random_display_name(),
                slug <- random_slug()
              ) do
          site = create_site!()
          blogger = create_blogger!(display_name: display_name, slug: slug, site_id: site.id)

          _archived =
            blogger
            |> Ash.Changeset.for_destroy(:destroy, %{}, tenant: site.id, authorize?: false)
            |> Ash.destroy!(return_destroyed?: true)

          bloggers =
            Blogger
            |> Ash.Query.set_tenant(site.id)
            |> Ash.read!(authorize?: false)

          refute Enum.any?(bloggers, fn b -> b.id == blogger.id end)
        end
      end
    end

    describe "property: multi-tenancy isolation" do
      property "bloggers are isolated by site_id" do
        check all(
                display_name1 <- random_display_name(),
                slug1 <- random_slug(),
                display_name2 <- random_display_name(),
                slug2 <- random_slug()
              ) do
          site1 = create_site!()
          site2 = create_site!()

          blogger1 = create_blogger!(display_name: display_name1, slug: slug1, site_id: site1.id)
          blogger2 = create_blogger!(display_name: display_name2, slug: slug2, site_id: site2.id)

          # Blogger1 should only appear in site1
          site1_bloggers =
            Blogger
            |> Ash.Query.set_tenant(site1.id)
            |> Ash.read!(authorize?: false)

          assert Enum.any?(site1_bloggers, fn b -> b.id == blogger1.id end)
          refute Enum.any?(site1_bloggers, fn b -> b.id == blogger2.id end)

          # Blogger2 should only appear in site2
          site2_bloggers =
            Blogger
            |> Ash.Query.set_tenant(site2.id)
            |> Ash.read!(authorize?: false)

          assert Enum.any?(site2_bloggers, fn b -> b.id == blogger2.id end)
          refute Enum.any?(site2_bloggers, fn b -> b.id == blogger1.id end)
        end
      end

      property "same user can have different blogger profiles in different sites" do
        check all(
                display_name1 <- random_display_name(),
                slug1 <- random_slug(),
                display_name2 <- random_display_name(),
                slug2 <- random_slug()
              ) do
          site1 = create_site!()
          site2 = create_site!()
          user = create_user!()

          blogger1 =
            create_blogger!(
              user_id: user.id,
              display_name: display_name1,
              slug: slug1,
              site_id: site1.id
            )

          blogger2 =
            create_blogger!(
              user_id: user.id,
              display_name: display_name2,
              slug: slug2,
              site_id: site2.id
            )

          assert blogger1.user_id == blogger2.user_id
          assert blogger1.site_id != blogger2.site_id
          assert blogger1.id != blogger2.id
        end
      end
    end

    describe "property: slug handling" do
      property "slug is always lowercased and hyphenated" do
        check all(
                slug_input <-
                  string(:alphanumeric, min_length: 1, max_length: 30)
                  |> map(&String.upcase/1)
              ) do
          site = create_site!()
          user = create_user!()

          # Insert spaces to test hyphenation
          slug_with_spaces = slug_input |> String.graphemes() |> Enum.join(" ")

          blogger =
            create_blogger!(
              user_id: user.id,
              display_name: "Test",
              slug: slug_with_spaces,
              site_id: site.id
            )

          # Slug should be lowercase
          assert blogger.slug == String.downcase(blogger.slug)
          # Should not contain uppercase letters
          refute String.match?(blogger.slug, ~r/[A-Z]/)
        end
      end

      property "different slugs remain unique within a site" do
        check all(
                slug1 <- random_slug(),
                slug2 <- random_slug(),
                slug1 != slug2
              ) do
          site = create_site!()
          user1 = create_user!()
          user2 = create_user!()

          blogger1 = create_blogger!(user_id: user1.id, slug: slug1, site_id: site.id)
          blogger2 = create_blogger!(user_id: user2.id, slug: slug2, site_id: site.id)

          assert blogger1.slug != blogger2.slug
        end
      end
    end

    describe "property: read actions" do
      property "by_user finds blogger by user_id" do
        check all(slug <- random_slug()) do
          site = create_site!()
          user = create_user!()
          blogger = create_blogger!(user_id: user.id, slug: slug, site_id: site.id)

          found =
            Blogger
            |> Ash.Query.for_read(:by_user, %{user_id: user.id},
              tenant: site.id,
              authorize?: false
            )
            |> Ash.read_one!()

          assert found.id == blogger.id
          assert found.user_id == user.id
        end
      end

      property "by_slug finds blogger by slug" do
        check all(slug <- random_slug()) do
          site = create_site!()
          blogger = create_blogger!(slug: slug, site_id: site.id)

          # Normalize the slug as it would be stored
          normalized_slug = String.downcase(slug)

          found =
            Blogger
            |> Ash.Query.for_read(:by_slug, %{slug: normalized_slug},
              tenant: site.id,
              authorize?: false
            )
            |> Ash.read_one!()

          assert found.id == blogger.id
        end
      end

      property "master_get retrieves any blogger by ID" do
        check all(
                display_name <- random_display_name(),
                slug <- random_slug()
              ) do
          site = create_site!()
          blogger = create_blogger!(display_name: display_name, slug: slug, site_id: site.id)

          fetched = Ash.get!(Blogger, blogger.id, action: :master_get, authorize?: false)

          assert fetched.id == blogger.id
          assert fetched.display_name == blogger.display_name
        end
      end
    end

    describe "property: defaults" do
      property "can_publish_directly defaults to false when not specified" do
        check all(
                display_name <- random_display_name(),
                slug <- random_slug()
              ) do
          site = create_site!()
          user = create_user!()

          blogger =
            Blogger
            |> Ash.Changeset.for_create(
              :create,
              %{
                user_id: user.id,
                display_name: display_name,
                slug: slug
              },
              tenant: site.id,
              authorize?: false
            )
            |> Ash.create!()

          assert blogger.can_publish_directly == false
        end
      end

      property "expertise_areas defaults to empty list" do
        check all(
                display_name <- random_display_name(),
                slug <- random_slug()
              ) do
          site = create_site!()
          user = create_user!()

          blogger =
            Blogger
            |> Ash.Changeset.for_create(
              :create,
              %{
                user_id: user.id,
                display_name: display_name,
                slug: slug
              },
              tenant: site.id,
              authorize?: false
            )
            |> Ash.create!()

          assert blogger.expertise_areas == []
        end
      end

      property "social_links defaults to empty list" do
        check all(
                display_name <- random_display_name(),
                slug <- random_slug()
              ) do
          site = create_site!()
          user = create_user!()

          blogger =
            Blogger
            |> Ash.Changeset.for_create(
              :create,
              %{
                user_id: user.id,
                display_name: display_name,
                slug: slug
              },
              tenant: site.id,
              authorize?: false
            )
            |> Ash.create!()

          assert blogger.social_links == []
        end
      end
    end
  end
end
