defmodule MishkaBlog.Test.AutoPostingPropertyTest do
  @moduledoc """
  Property-based tests for MishkaBlog.AutoPosting resource using StreamData.

  These tests verify that the AutoPosting resource handles a wide range of random
  inputs correctly, including edge cases and unexpected data patterns.
  """
  use MishkaBlog.DataCase, async: false
  use ExUnitProperties

  if Code.ensure_loaded?(MishkaBlog) do
    alias MishkaBlog.AutoPosting

    # Generators for random test data
    defp random_name do
      gen all(name <- string(:alphanumeric, min_length: 1, max_length: 50)) do
        "Auto Posting " <> name
      end
    end

    defp random_plugin do
      gen all(plugin <- string(:alphanumeric, min_length: 1, max_length: 30)) do
        "plugin_" <> String.downcase(plugin)
      end
    end

    defp random_description do
      gen all(desc <- string(:printable, max_length: 500)) do
        String.trim(desc)
      end
    end

    defp random_config do
      gen all(
            count <- integer(0..5),
            keys <-
              StreamData.list_of(string(:alphanumeric, min_length: 1, max_length: 20),
                length: count
              )
          ) do
        keys
        |> Enum.with_index()
        |> Enum.into(%{}, fn {key, idx} ->
          {key,
           %{
             "type" => Enum.random(["string", "boolean", "integer"]),
             "value" => "value_#{idx}",
             "help" => "Help text for #{key}"
           }}
        end)
      end
    end

    describe "property: create action with random data" do
      property "creates auto-posting with random valid name and plugin" do
        check all(
                name <- random_name(),
                plugin <- random_plugin()
              ) do
          site = create_site!()

          auto_posting =
            create_auto_posting!(
              name: name,
              plugin: plugin,
              site_id: site.id
            )

          assert auto_posting.name == name
          assert auto_posting.plugin == plugin
          assert is_binary(auto_posting.id)
          assert String.length(auto_posting.id) == 36
        end
      end

      property "creates auto-posting with random optional fields" do
        check all(
                name <- random_name(),
                plugin <- random_plugin(),
                description <- random_description(),
                is_active <- boolean(),
                config <- random_config()
              ) do
          site = create_site!()

          auto_posting =
            create_auto_posting!(
              name: name,
              plugin: plugin,
              description: description,
              is_active: is_active,
              config: config,
              site_id: site.id
            )

          # Empty strings get trimmed to nil
          expected_description = if description == "", do: nil, else: description

          assert auto_posting.name == name
          assert auto_posting.plugin == plugin
          assert auto_posting.description == expected_description
          assert auto_posting.is_active == is_active
          assert auto_posting.config == config
        end
      end

      property "always assigns UUID v7 primary key" do
        check all(
                name <- random_name(),
                plugin <- random_plugin()
              ) do
          site = create_site!()

          auto_posting =
            create_auto_posting!(
              name: name,
              plugin: plugin,
              site_id: site.id
            )

          assert is_binary(auto_posting.id)
          assert String.length(auto_posting.id) == 36
          assert String.match?(auto_posting.id, ~r/^[0-9a-f-]+$/)
        end
      end

      property "always auto-assigns site_id from tenant context" do
        check all(
                name <- random_name(),
                plugin <- random_plugin()
              ) do
          site = create_site!()

          auto_posting =
            AutoPosting
            |> Ash.Changeset.for_create(
              :create,
              %{
                name: name,
                plugin: plugin
              },
              tenant: site.id,
              authorize?: false
            )
            |> Ash.create!()

          assert auto_posting.site_id == site.id
        end
      end
    end

    describe "property: update action" do
      property "updates auto-posting with random name" do
        check all(new_name <- random_name()) do
          site = create_site!()
          auto_posting = create_auto_posting!(site_id: site.id)

          updated =
            auto_posting
            |> Ash.Changeset.for_update(
              :update,
              %{name: new_name},
              tenant: site.id,
              authorize?: false
            )
            |> Ash.update!()

          assert updated.name == new_name
          assert updated.id == auto_posting.id
        end
      end

      property "updates auto-posting with random description" do
        check all(new_description <- random_description()) do
          site = create_site!()
          auto_posting = create_auto_posting!(site_id: site.id)

          updated =
            auto_posting
            |> Ash.Changeset.for_update(
              :update,
              %{description: new_description},
              tenant: site.id,
              authorize?: false
            )
            |> Ash.update!()

          # Empty strings get trimmed to nil
          expected_description = if new_description == "", do: nil, else: new_description
          assert updated.description == expected_description
        end
      end

      property "updates auto-posting with random config" do
        check all(new_config <- random_config()) do
          site = create_site!()
          auto_posting = create_auto_posting!(site_id: site.id)

          updated =
            auto_posting
            |> Ash.Changeset.for_update(
              :update,
              %{config: new_config},
              tenant: site.id,
              authorize?: false
            )
            |> Ash.update!()

          assert updated.config == new_config
        end
      end

      property "updates auto-posting with random is_active value" do
        check all(new_is_active <- boolean()) do
          site = create_site!()
          auto_posting = create_auto_posting!(site_id: site.id)

          updated =
            auto_posting
            |> Ash.Changeset.for_update(
              :update,
              %{is_active: new_is_active},
              tenant: site.id,
              authorize?: false
            )
            |> Ash.update!()

          assert updated.is_active == new_is_active
        end
      end
    end

    describe "property: archive and unarchive" do
      property "archive sets archived_at timestamp" do
        check all(
                name <- random_name(),
                plugin <- random_plugin()
              ) do
          site = create_site!()
          auto_posting = create_auto_posting!(name: name, plugin: plugin, site_id: site.id)

          archived =
            auto_posting
            |> Ash.Changeset.for_destroy(:destroy, %{}, tenant: site.id, authorize?: false)
            |> Ash.destroy!(return_destroyed?: true)

          assert archived.archived_at != nil
          assert is_struct(archived.archived_at, DateTime)
        end
      end

      property "unarchive clears archived_at" do
        check all(
                name <- random_name(),
                plugin <- random_plugin()
              ) do
          site = create_site!()
          auto_posting = create_auto_posting!(name: name, plugin: plugin, site_id: site.id)

          archived =
            auto_posting
            |> Ash.Changeset.for_destroy(:destroy, %{}, tenant: site.id, authorize?: false)
            |> Ash.destroy!(return_destroyed?: true)

          unarchived =
            archived
            |> Ash.Changeset.for_update(:unarchive, %{}, tenant: site.id, authorize?: false)
            |> Ash.update!()

          assert unarchived.archived_at == nil
        end
      end

      property "archived auto-postings are excluded from normal reads" do
        check all(
                name <- random_name(),
                plugin <- random_plugin()
              ) do
          site = create_site!()
          auto_posting = create_auto_posting!(name: name, plugin: plugin, site_id: site.id)

          _archived =
            auto_posting
            |> Ash.Changeset.for_destroy(:destroy, %{}, tenant: site.id, authorize?: false)
            |> Ash.destroy!(return_destroyed?: true)

          postings =
            AutoPosting
            |> Ash.Query.set_tenant(site.id)
            |> Ash.read!(authorize?: false)

          refute Enum.any?(postings, fn p -> p.id == auto_posting.id end)
        end
      end
    end

    describe "property: activate and deactivate" do
      property "activate sets is_active to true" do
        check all(
                name <- random_name(),
                plugin <- random_plugin()
              ) do
          site = create_site!()

          auto_posting =
            create_auto_posting!(name: name, plugin: plugin, is_active: false, site_id: site.id)

          activated =
            auto_posting
            |> Ash.Changeset.for_update(:activate, %{}, tenant: site.id, authorize?: false)
            |> Ash.update!()

          assert activated.is_active == true
        end
      end

      property "deactivate sets is_active to false" do
        check all(
                name <- random_name(),
                plugin <- random_plugin()
              ) do
          site = create_site!()

          auto_posting =
            create_auto_posting!(name: name, plugin: plugin, is_active: true, site_id: site.id)

          deactivated =
            auto_posting
            |> Ash.Changeset.for_update(:deactivate, %{}, tenant: site.id, authorize?: false)
            |> Ash.update!()

          assert deactivated.is_active == false
        end
      end
    end

    describe "property: multi-tenancy isolation" do
      property "auto-postings are isolated by site_id" do
        check all(
                name1 <- random_name(),
                plugin1 <- random_plugin(),
                name2 <- random_name(),
                plugin2 <- random_plugin()
              ) do
          site1 = create_site!()
          site2 = create_site!()

          posting1 = create_auto_posting!(name: name1, plugin: plugin1, site_id: site1.id)
          posting2 = create_auto_posting!(name: name2, plugin: plugin2, site_id: site2.id)

          # Posting1 should only appear in site1
          site1_postings =
            AutoPosting
            |> Ash.Query.set_tenant(site1.id)
            |> Ash.read!(authorize?: false)

          assert Enum.any?(site1_postings, fn p -> p.id == posting1.id end)
          refute Enum.any?(site1_postings, fn p -> p.id == posting2.id end)

          # Posting2 should only appear in site2
          site2_postings =
            AutoPosting
            |> Ash.Query.set_tenant(site2.id)
            |> Ash.read!(authorize?: false)

          assert Enum.any?(site2_postings, fn p -> p.id == posting2.id end)
          refute Enum.any?(site2_postings, fn p -> p.id == posting1.id end)
        end
      end
    end

    describe "property: read actions" do
      property "by_plugin finds auto-posting by plugin" do
        check all(plugin <- random_plugin()) do
          site = create_site!()
          auto_posting = create_auto_posting!(plugin: plugin, site_id: site.id)

          found =
            AutoPosting
            |> Ash.Query.for_read(:by_plugin, %{plugin: plugin},
              tenant: site.id,
              authorize?: false
            )
            |> Ash.read_one!()

          assert found.id == auto_posting.id
          assert found.plugin == plugin
        end
      end

      property "master_get retrieves any auto-posting by ID" do
        check all(
                name <- random_name(),
                plugin <- random_plugin()
              ) do
          site = create_site!()
          auto_posting = create_auto_posting!(name: name, plugin: plugin, site_id: site.id)

          fetched = Ash.get!(AutoPosting, auto_posting.id, action: :master_get, authorize?: false)

          assert fetched.id == auto_posting.id
          assert fetched.name == auto_posting.name
        end
      end
    end

    describe "property: defaults" do
      property "is_active defaults to false when not specified" do
        check all(
                name <- random_name(),
                plugin <- random_plugin()
              ) do
          site = create_site!()

          auto_posting =
            AutoPosting
            |> Ash.Changeset.for_create(
              :create,
              %{
                name: name,
                plugin: plugin
              },
              tenant: site.id,
              authorize?: false
            )
            |> Ash.create!()

          assert auto_posting.is_active == false
        end
      end

      property "config defaults to empty map" do
        check all(
                name <- random_name(),
                plugin <- random_plugin()
              ) do
          site = create_site!()

          auto_posting =
            AutoPosting
            |> Ash.Changeset.for_create(
              :create,
              %{
                name: name,
                plugin: plugin
              },
              tenant: site.id,
              authorize?: false
            )
            |> Ash.create!()

          assert auto_posting.config == %{}
        end
      end
    end
  end
end
