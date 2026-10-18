# SPDX-FileCopyrightText: 2026 Mishka Group contributors <https://github.com/mishka-group/mishka_blog/graphs/contributors>
#
# SPDX-License-Identifier: Apache-2.0

defmodule MishkaBlog.Test.AutoPostingTest do
  @moduledoc """
  Tests for MishkaBlog.AutoPosting resource.
  """
  use MishkaBlog.DataCase, async: false

  if Code.ensure_loaded?(MishkaBlog) do
    alias MishkaBlog.AutoPosting

    require Ash.Query

    describe "resource configuration" do
      test "uses correct table name" do
        assert AshPostgres.DataLayer.Info.table(AutoPosting) == "mishka_blog_auto_postings"
      end

      test "uses UUID v7 for primary keys" do
        auto_posting = create_auto_posting!()
        assert {:ok, _} = Ecto.UUID.cast(auto_posting.id)
        assert String.length(auto_posting.id) == 36
      end

      test "is always site-specific (not global)" do
        multitenancy_config = Ash.Resource.Info.multitenancy_strategy(AutoPosting)
        assert multitenancy_config == :attribute
        assert Ash.Resource.Info.multitenancy_global?(AutoPosting) == false
      end
    end

    describe "create action" do
      test "creates auto-posting with valid attributes" do
        site = create_site!()

        auto_posting =
          create_auto_posting!(
            name: "Twitter Auto Post",
            plugin: "twitter",
            description: "Auto post to Twitter",
            site_id: site.id
          )

        assert auto_posting.name == "Twitter Auto Post"
        assert auto_posting.plugin == "twitter"
        assert auto_posting.description == "Auto post to Twitter"
        assert auto_posting.site_id == site.id
      end

      test "auto-assigns site_id from tenant context" do
        site = create_site!()

        auto_posting =
          AutoPosting
          |> Ash.Changeset.for_create(
            :create,
            %{
              name: "Facebook Auto Post",
              plugin: "facebook"
            },
            tenant: site.id,
            authorize?: false
          )
          |> Ash.create!()

        assert auto_posting.site_id == site.id
      end

      test "defaults is_active to false" do
        site = create_site!()
        auto_posting = create_auto_posting!(site_id: site.id)
        assert auto_posting.is_active == false
      end

      test "defaults config to empty map" do
        site = create_site!()
        auto_posting = create_auto_posting!(site_id: site.id)
        assert auto_posting.config == %{}
      end

      test "accepts config as map" do
        site = create_site!()

        config = %{
          "api_key" => %{
            "type" => "string",
            "value" => "secret123",
            "help" => "API key for service"
          },
          "enabled" => %{"type" => "boolean", "value" => true, "help" => "Enable posting"}
        }

        auto_posting =
          create_auto_posting!(
            name: "LinkedIn Auto Post",
            plugin: "linkedin",
            config: config,
            site_id: site.id
          )

        assert auto_posting.config == config
      end

      test "requires name and plugin" do
        site = create_site!()

        assert_raise Ash.Error.Invalid, fn ->
          AutoPosting
          |> Ash.Changeset.for_create(:create, %{}, tenant: site.id, authorize?: false)
          |> Ash.create!()
        end
      end
    end

    describe "master_create action" do
      test "creates auto-posting with explicit site_id" do
        site = create_site!()

        auto_posting =
          AutoPosting
          |> Ash.Changeset.for_create(
            :master_create,
            %{
              name: "Master Auto Post",
              plugin: "master_plugin",
              site_id: site.id
            },
            authorize?: false
          )
          |> Ash.create!()

        assert auto_posting.name == "Master Auto Post"
        assert auto_posting.site_id == site.id
      end

      test "requires explicit site_id" do
        assert_raise Ash.Error.Invalid, fn ->
          AutoPosting
          |> Ash.Changeset.for_create(
            :master_create,
            %{
              name: "Missing Site",
              plugin: "test"
            },
            authorize?: false
          )
          |> Ash.create!()
        end
      end
    end

    describe "update action" do
      test "updates auto-posting attributes" do
        site = create_site!()
        auto_posting = create_auto_posting!(name: "Original Name", site_id: site.id)

        updated =
          auto_posting
          |> Ash.Changeset.for_update(
            :update,
            %{name: "Updated Name", description: "New description"},
            tenant: site.id,
            authorize?: false
          )
          |> Ash.update!()

        assert updated.name == "Updated Name"
        assert updated.description == "New description"
      end

      test "prevents updating archived auto-posting" do
        site = create_site!()
        auto_posting = create_auto_posting!(site_id: site.id)

        # Archive the auto-posting
        archived =
          auto_posting
          |> Ash.Changeset.for_destroy(:destroy, %{}, tenant: site.id, authorize?: false)
          |> Ash.destroy!(return_destroyed?: true)

        # Try to update archived auto-posting
        assert_raise Ash.Error.Invalid, fn ->
          archived
          |> Ash.Changeset.for_update(
            :update,
            %{name: "Should Fail"},
            tenant: site.id,
            authorize?: false
          )
          |> Ash.update!()
        end
      end

      test "prevents site_id changes" do
        site1 = create_site!()
        auto_posting = create_auto_posting!(site_id: site1.id)

        # site_id is not in the accepted fields for update
        updated =
          auto_posting
          |> Ash.Changeset.for_update(
            :update,
            %{name: "Updated"},
            tenant: site1.id,
            authorize?: false
          )
          |> Ash.update!()

        # site_id should remain unchanged
        assert updated.site_id == site1.id
      end
    end

    describe "read actions" do
      test "by_plugin finds auto-posting by plugin" do
        site = create_site!()
        auto_posting = create_auto_posting!(plugin: "unique-plugin", site_id: site.id)

        found =
          AutoPosting
          |> Ash.Query.for_read(:by_plugin, %{plugin: "unique-plugin"},
            tenant: site.id,
            authorize?: false
          )
          |> Ash.read_one!()

        assert found.id == auto_posting.id
      end

      test "active lists only active auto-postings" do
        site = create_site!()

        active_posting =
          create_auto_posting!(name: "Active", is_active: true, site_id: site.id)

        inactive_posting =
          create_auto_posting!(name: "Inactive", is_active: false, site_id: site.id)

        result =
          AutoPosting
          |> Ash.Query.for_read(:active, %{}, tenant: site.id, authorize?: false)
          |> Ash.read!(authorize?: false)

        active_list = result.results
        active_ids = Enum.map(active_list, & &1.id)

        assert active_posting.id in active_ids
        refute inactive_posting.id in active_ids
      end

      test "master_get retrieves auto-posting by ID bypassing tenant" do
        site = create_site!()
        auto_posting = create_auto_posting!(site_id: site.id)

        fetched = Ash.get!(AutoPosting, auto_posting.id, action: :master_get, authorize?: false)

        assert fetched.id == auto_posting.id
      end
    end

    describe "archive/unarchive actions" do
      test "destroy soft deletes auto-posting" do
        site = create_site!()
        auto_posting = create_auto_posting!(site_id: site.id)

        archived =
          auto_posting
          |> Ash.Changeset.for_destroy(:destroy, %{}, tenant: site.id, authorize?: false)
          |> Ash.destroy!(return_destroyed?: true)

        assert %DateTime{} = archived.archived_at

        # Should not appear in normal reads
        postings =
          AutoPosting
          |> Ash.Query.set_tenant(site.id)
          |> Ash.read!(authorize?: false)

        assert Enum.find(postings, fn p -> p.id == auto_posting.id end) == nil
      end

      test "unarchive restores archived auto-posting" do
        site = create_site!()
        auto_posting = create_auto_posting!(site_id: site.id)

        # Archive
        archived =
          auto_posting
          |> Ash.Changeset.for_destroy(:destroy, %{}, tenant: site.id, authorize?: false)
          |> Ash.destroy!(return_destroyed?: true)

        # Unarchive
        unarchived =
          archived
          |> Ash.Changeset.for_update(:unarchive, %{}, tenant: site.id, authorize?: false)
          |> Ash.update!()

        assert unarchived.archived_at == nil
      end

      test "archived action lists only archived auto-postings" do
        site = create_site!()
        active_posting = create_auto_posting!(name: "Active", site_id: site.id)

        archived_posting =
          create_auto_posting!(name: "To Archive", site_id: site.id)
          |> Ash.Changeset.for_destroy(:destroy, %{}, tenant: site.id, authorize?: false)
          |> Ash.destroy!(return_destroyed?: true)

        result =
          AutoPosting
          |> Ash.Query.for_read(:archived, %{}, tenant: site.id, authorize?: false)
          |> Ash.read!(authorize?: false)

        archived_list = result.results
        archived_ids = Enum.map(archived_list, & &1.id)
        assert archived_posting.id in archived_ids
        refute active_posting.id in archived_ids
      end
    end

    describe "activate/deactivate actions" do
      test "activate sets is_active to true" do
        site = create_site!()
        auto_posting = create_auto_posting!(is_active: false, site_id: site.id)

        activated =
          auto_posting
          |> Ash.Changeset.for_update(:activate, %{}, tenant: site.id, authorize?: false)
          |> Ash.update!()

        assert activated.is_active == true
      end

      test "deactivate sets is_active to false" do
        site = create_site!()
        auto_posting = create_auto_posting!(is_active: true, site_id: site.id)

        deactivated =
          auto_posting
          |> Ash.Changeset.for_update(:deactivate, %{}, tenant: site.id, authorize?: false)
          |> Ash.update!()

        assert deactivated.is_active == false
      end

      test "activate is idempotent" do
        site = create_site!()
        auto_posting = create_auto_posting!(is_active: true, site_id: site.id)

        # Activating already active posting should work
        activated =
          auto_posting
          |> Ash.Changeset.for_update(:activate, %{}, tenant: site.id, authorize?: false)
          |> Ash.update!()

        assert activated.is_active == true
      end

      test "deactivate is idempotent" do
        site = create_site!()
        auto_posting = create_auto_posting!(is_active: false, site_id: site.id)

        # Deactivating already inactive posting should work
        deactivated =
          auto_posting
          |> Ash.Changeset.for_update(:deactivate, %{}, tenant: site.id, authorize?: false)
          |> Ash.update!()

        assert deactivated.is_active == false
      end
    end

    describe "identities" do
      test "unique_plugin_per_site prevents duplicate plugins within a site" do
        site = create_site!()
        _posting1 = create_auto_posting!(plugin: "twitter", site_id: site.id)

        # Database-level unique constraint returns Ash.Error.Invalid
        assert_raise Ash.Error.Invalid, fn ->
          create_auto_posting!(plugin: "twitter", site_id: site.id)
        end
      end

      test "allows same plugin across different sites" do
        site1 = create_site!()
        site2 = create_site!()

        posting1 = create_auto_posting!(plugin: "twitter", site_id: site1.id)
        posting2 = create_auto_posting!(plugin: "twitter", site_id: site2.id)

        assert posting1.plugin == posting2.plugin
        assert posting1.site_id != posting2.site_id
      end
    end

    describe "multi-tenancy isolation" do
      test "auto-postings are isolated by site_id" do
        site1 = create_site!()
        site2 = create_site!()

        posting1 = create_auto_posting!(name: "Site 1 Posting", site_id: site1.id)
        posting2 = create_auto_posting!(name: "Site 2 Posting", site_id: site2.id)

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

    describe "config attribute" do
      test "stores and retrieves complex configuration" do
        site = create_site!()

        config = %{
          "twitter_api_key" => %{
            "type" => "string",
            "value" => "secret_key_123",
            "help" => "Your Twitter API key"
          },
          "post_on_publish" => %{
            "type" => "boolean",
            "value" => true,
            "help" => "Automatically post when blog is published"
          },
          "include_images" => %{
            "type" => "boolean",
            "value" => false,
            "help" => "Include featured images in posts"
          },
          "hashtags" => %{
            "type" => "array",
            "value" => ["elixir", "programming"],
            "help" => "Default hashtags to add"
          }
        }

        auto_posting =
          create_auto_posting!(
            name: "Complex Config",
            plugin: "twitter_complex",
            config: config,
            site_id: site.id
          )

        assert auto_posting.config == config
        assert auto_posting.config["twitter_api_key"]["value"] == "secret_key_123"
        assert auto_posting.config["post_on_publish"]["value"] == true
        assert auto_posting.config["hashtags"]["value"] == ["elixir", "programming"]
      end

      test "updates config map" do
        site = create_site!()

        initial_config = %{
          "api_key" => %{"type" => "string", "value" => "old_key", "help" => "API key"}
        }

        auto_posting = create_auto_posting!(config: initial_config, site_id: site.id)

        new_config = %{
          "api_key" => %{"type" => "string", "value" => "new_key", "help" => "API key"},
          "enabled" => %{"type" => "boolean", "value" => true, "help" => "Enable posting"}
        }

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
        assert updated.config["api_key"]["value"] == "new_key"
        assert updated.config["enabled"]["value"] == true
      end
    end

    describe "Version Management" do
      test "creates version on update" do
        site = create_site!()

        auto_posting =
          create_auto_posting!(
            site_id: site.id,
            name: "Original Name",
            plugin: "twitter",
            is_active: false
          )

        # Update to create version
        auto_posting
        |> Ash.Changeset.for_update(:update, %{name: "Updated Name", is_active: true},
          tenant: site.id,
          authorize?: false
        )
        |> Ash.update!()

        # Wait for version to be created (async)
        wait_for_version_count("mishka_blog_auto_posting_versions", auto_posting.id, 2)

        # Verify versions exist
        versions = versions(MishkaBlog.AutoPosting.Version, auto_posting.id)

        assert length(versions) == 2

        # First version has original values
        first_version = List.first(versions)
        assert first_version.changes["name"] == "Original Name"
        assert first_version.changes["is_active"] == false

        # Second version has updated values
        second_version = List.last(versions)
        assert second_version.changes["name"] == "Updated Name"
        assert second_version.changes["is_active"] == true
      end

      test "creates version on create" do
        site = create_site!()

        auto_posting =
          create_auto_posting!(
            site_id: site.id,
            name: "Test Config",
            plugin: "facebook"
          )

        # Wait for initial version
        wait_for_version_count("mishka_blog_auto_posting_versions", auto_posting.id, 1)

        # Verify initial version exists
        versions = versions(MishkaBlog.AutoPosting.Version, auto_posting.id)

        assert length(versions) == 1
        version = List.first(versions)
        assert version.version_action_name == :create
        assert version.changes["name"] == "Test Config"
        assert version.changes["plugin"] == "facebook"
      end

      test "creates multiple versions on multiple updates" do
        site = create_site!()

        auto_posting =
          create_auto_posting!(
            site_id: site.id,
            name: "Version 1",
            plugin: "twitter"
          )

        # Create version 2
        auto_posting
        |> Ash.Changeset.for_update(:update, %{name: "Version 2"},
          tenant: site.id,
          authorize?: false
        )
        |> Ash.update!()

        # Create version 3
        auto_posting
        |> Ash.Changeset.for_update(:update, %{name: "Version 3"},
          tenant: site.id,
          authorize?: false
        )
        |> Ash.update!()

        wait_for_version_count("mishka_blog_auto_posting_versions", auto_posting.id, 3)

        versions = versions(MishkaBlog.AutoPosting.Version, auto_posting.id)

        assert length(versions) == 3
        assert Enum.at(versions, 0).changes["name"] == "Version 1"
        assert Enum.at(versions, 1).changes["name"] == "Version 2"
        assert Enum.at(versions, 2).changes["name"] == "Version 3"
      end

      test "restore_version restores to previous version" do
        site = create_site!()

        auto_posting =
          create_auto_posting!(
            site_id: site.id,
            name: "Original",
            plugin: "twitter",
            description: "Original description",
            is_active: false
          )

        # Update to create second version
        updated =
          auto_posting
          |> Ash.Changeset.for_update(
            :update,
            %{name: "Updated", description: "Updated description", is_active: true},
            tenant: site.id,
            authorize?: false
          )
          |> Ash.update!()

        wait_for_version_count("mishka_blog_auto_posting_versions", auto_posting.id, 2)

        # Get first version
        first_version = first_version(MishkaBlog.AutoPosting.Version, auto_posting.id)

        # Restore to first version
        restored =
          updated
          |> Ash.Changeset.for_update(:restore_version, %{version_id: first_version.id},
            tenant: site.id,
            authorize?: false
          )
          |> Ash.update!()

        assert restored.name == "Original"
        assert restored.description == "Original description"
        assert restored.is_active == false
        assert restored.plugin == "twitter"
      end

      test "restore_version creates new version when restoring" do
        site = create_site!()

        auto_posting =
          create_auto_posting!(
            site_id: site.id,
            name: "V1",
            plugin: "twitter"
          )

        # Create V2
        updated =
          auto_posting
          |> Ash.Changeset.for_update(:update, %{name: "V2"},
            tenant: site.id,
            authorize?: false
          )
          |> Ash.update!()

        wait_for_version_count("mishka_blog_auto_posting_versions", auto_posting.id, 2)

        # Get first version
        first_version = first_version(MishkaBlog.AutoPosting.Version, auto_posting.id)

        # Restore to V1
        updated
        |> Ash.Changeset.for_update(:restore_version, %{version_id: first_version.id},
          tenant: site.id,
          authorize?: false
        )
        |> Ash.update!()

        # Wait for restore to create new version
        wait_for_version_count("mishka_blog_auto_posting_versions", auto_posting.id, 3)

        # Should have 3 versions: V1 (create), V2 (update), V1 (restore)
        versions = versions(MishkaBlog.AutoPosting.Version, auto_posting.id)

        assert length(versions) == 3
        assert Enum.at(versions, 0).changes["name"] == "V1"
        assert Enum.at(versions, 1).changes["name"] == "V2"
        assert Enum.at(versions, 2).changes["name"] == "V1"
      end

      test "cannot restore version of archived auto-posting" do
        site = create_site!()

        auto_posting =
          create_auto_posting!(
            site_id: site.id,
            name: "Original",
            plugin: "twitter"
          )

        # Update to create version
        updated =
          auto_posting
          |> Ash.Changeset.for_update(:update, %{name: "Updated"},
            tenant: site.id,
            authorize?: false
          )
          |> Ash.update!()

        wait_for_version_count("mishka_blog_auto_posting_versions", auto_posting.id, 2)

        # Archive the auto-posting
        archived =
          updated
          |> Ash.Changeset.for_destroy(:destroy, %{}, tenant: site.id, authorize?: false)
          |> Ash.destroy!(return_destroyed?: true)

        # Get first version
        first_version = first_version(MishkaBlog.AutoPosting.Version, auto_posting.id)

        # Try to restore - should fail
        assert_raise Ash.Error.Invalid, ~r/archived/, fn ->
          archived
          |> Ash.Changeset.for_update(:restore_version, %{version_id: first_version.id},
            tenant: site.id,
            authorize?: false
          )
          |> Ash.update!()
        end
      end

      test "preview_version shows version data without restoring" do
        site = create_site!()

        auto_posting =
          create_auto_posting!(
            site_id: site.id,
            name: "Original",
            plugin: "twitter",
            description: "Original description"
          )

        # Update
        updated =
          auto_posting
          |> Ash.Changeset.for_update(:update, %{name: "Updated", description: "Updated desc"},
            tenant: site.id,
            authorize?: false
          )
          |> Ash.update!()

        wait_for_version_count("mishka_blog_auto_posting_versions", auto_posting.id, 2)

        # Get first version
        first_version = first_version(MishkaBlog.AutoPosting.Version, auto_posting.id)

        # Preview first version
        {:ok, preview} =
          MishkaBlog.AutoPosting
          |> Ash.ActionInput.for_action(
            :preview_version,
            %{auto_posting_id: updated.id, version_id: first_version.id},
            tenant: site.id
          )
          |> Ash.run_action(authorize?: false)

        # Preview should show original values
        assert preview.name == "Original"
        assert preview.description == "Original description"

        # Actual record should be unchanged
        current = Ash.get!(AutoPosting, updated.id, tenant: site.id, authorize?: false)
        assert current.name == "Updated"
        assert current.description == "Updated desc"
      end

      test "preview_version returns error for invalid version" do
        site = create_site!()

        auto_posting =
          create_auto_posting!(
            site_id: site.id,
            name: "Test",
            plugin: "twitter"
          )

        other_auto_posting =
          create_auto_posting!(
            site_id: site.id,
            name: "Other",
            plugin: "facebook"
          )

        # Update other to create version
        other_auto_posting
        |> Ash.Changeset.for_update(:update, %{name: "Other Updated"},
          tenant: site.id,
          authorize?: false
        )
        |> Ash.update!()

        wait_for_version_count("mishka_blog_auto_posting_versions", other_auto_posting.id, 2)

        # Get version from other auto-posting
        other_version = first_version(MishkaBlog.AutoPosting.Version, other_auto_posting.id)

        # Try to preview with wrong version - should fail
        assert {:error, %Ash.Error.Invalid{}} =
                 MishkaBlog.AutoPosting
                 |> Ash.ActionInput.for_action(
                   :preview_version,
                   %{auto_posting_id: auto_posting.id, version_id: other_version.id},
                   tenant: site.id
                 )
                 |> Ash.run_action(authorize?: false)
      end

      test "sorted_versions relationship returns versions in desc order" do
        site = create_site!()

        auto_posting =
          create_auto_posting!(
            site_id: site.id,
            name: "V1",
            plugin: "twitter"
          )

        # Create multiple versions
        Enum.each(2..5, fn i ->
          auto_posting
          |> Ash.Changeset.for_update(:update, %{name: "V#{i}"},
            tenant: site.id,
            authorize?: false
          )
          |> Ash.update!()

          Process.sleep(10)
        end)

        wait_for_version_count("mishka_blog_auto_posting_versions", auto_posting.id, 5)

        # Load with sorted_versions
        loaded =
          AutoPosting
          |> Ash.get!(auto_posting.id, tenant: site.id, authorize?: false)
          |> Ash.load!(:sorted_versions, authorize?: false)

        versions = loaded.sorted_versions

        # Should be in descending order (newest first)
        assert length(versions) == 5
        assert Enum.at(versions, 0).changes["name"] == "V5"
        assert Enum.at(versions, 1).changes["name"] == "V4"
        assert Enum.at(versions, 2).changes["name"] == "V3"
        assert Enum.at(versions, 3).changes["name"] == "V2"
        assert Enum.at(versions, 4).changes["name"] == "V1"
      end
    end

    describe "Version Calculations" do
      test "version_count returns total number of versions" do
        site = create_site!()

        auto_posting =
          create_auto_posting!(
            site_id: site.id,
            name: "Test",
            plugin: "twitter"
          )

        # Create 3 more versions (total 4)
        Enum.each(1..3, fn _ ->
          auto_posting
          |> Ash.Changeset.for_update(:update, %{description: "Updated #{:rand.uniform(100)}"},
            tenant: site.id,
            authorize?: false
          )
          |> Ash.update!()
        end)

        wait_for_version_count("mishka_blog_auto_posting_versions", auto_posting.id, 4)

        # Load with version_count calculation
        loaded =
          AutoPosting
          |> Ash.Query.for_read(:read, %{}, tenant: site.id)
          |> Ash.Query.filter(id == ^auto_posting.id)
          |> Ash.Query.load(:version_count)
          |> Ash.read_one!(authorize?: false)

        assert loaded.version_count == 4
      end

      test "latest_version returns most recent version" do
        site = create_site!()

        auto_posting =
          create_auto_posting!(
            site_id: site.id,
            name: "Original",
            plugin: "twitter"
          )

        # Create updates
        auto_posting
        |> Ash.Changeset.for_update(:update, %{name: "Second"},
          tenant: site.id,
          authorize?: false
        )
        |> Ash.update!()

        auto_posting
        |> Ash.Changeset.for_update(:update, %{name: "Third"},
          tenant: site.id,
          authorize?: false
        )
        |> Ash.update!()

        wait_for_version_count("mishka_blog_auto_posting_versions", auto_posting.id, 3)

        # Load with latest_version calculation
        loaded =
          AutoPosting
          |> Ash.Query.for_read(:read, %{}, tenant: site.id)
          |> Ash.Query.filter(id == ^auto_posting.id)
          |> Ash.Query.load(:latest_version)
          |> Ash.read_one!(authorize?: false)

        assert %MishkaBlog.AutoPosting.Version{} = loaded.latest_version
        assert loaded.latest_version.changes["name"] == "Third"
        assert {:ok, _} = Ecto.UUID.cast(loaded.latest_version.id)
      end

      test "recent_versions returns up to 10 most recent versions" do
        site = create_site!()

        auto_posting =
          create_auto_posting!(
            site_id: site.id,
            name: "V1",
            plugin: "twitter"
          )

        # Create 14 more versions (total 15)
        Enum.each(2..15, fn i ->
          auto_posting
          |> Ash.Changeset.for_update(:update, %{name: "V#{i}"},
            tenant: site.id,
            authorize?: false
          )
          |> Ash.update!()
        end)

        wait_for_version_count("mishka_blog_auto_posting_versions", auto_posting.id, 15)

        # Load with recent_versions calculation
        loaded =
          AutoPosting
          |> Ash.Query.for_read(:read, %{}, tenant: site.id)
          |> Ash.Query.filter(id == ^auto_posting.id)
          |> Ash.Query.load(:recent_versions)
          |> Ash.read_one!(authorize?: false)

        # Should only return 10 most recent
        assert length(loaded.recent_versions) == 10

        # Should be in descending order (newest first)
        assert Enum.at(loaded.recent_versions, 0).changes["name"] == "V15"
        assert Enum.at(loaded.recent_versions, 9).changes["name"] == "V6"
      end

      test "recent_versions returns all versions if less than 10" do
        site = create_site!()

        auto_posting =
          create_auto_posting!(
            site_id: site.id,
            name: "V1",
            plugin: "twitter"
          )

        # Create 4 more versions (total 5)
        Enum.each(2..5, fn i ->
          auto_posting
          |> Ash.Changeset.for_update(:update, %{name: "V#{i}"},
            tenant: site.id,
            authorize?: false
          )
          |> Ash.update!()
        end)

        wait_for_version_count("mishka_blog_auto_posting_versions", auto_posting.id, 5)

        # Load with recent_versions calculation
        loaded =
          AutoPosting
          |> Ash.Query.for_read(:read, %{}, tenant: site.id)
          |> Ash.Query.filter(id == ^auto_posting.id)
          |> Ash.Query.load(:recent_versions)
          |> Ash.read_one!(authorize?: false)

        # Should return all 5 versions
        assert length(loaded.recent_versions) == 5
      end

      test "all calculations work together" do
        site = create_site!()

        auto_posting =
          create_auto_posting!(
            site_id: site.id,
            name: "Original",
            plugin: "twitter"
          )

        # Create versions
        Enum.each(1..3, fn i ->
          auto_posting
          |> Ash.Changeset.for_update(:update, %{name: "Update #{i}"},
            tenant: site.id,
            authorize?: false
          )
          |> Ash.update!()
        end)

        wait_for_version_count("mishka_blog_auto_posting_versions", auto_posting.id, 4)

        # Load all calculations at once
        loaded =
          AutoPosting
          |> Ash.Query.for_read(:read, %{}, tenant: site.id)
          |> Ash.Query.filter(id == ^auto_posting.id)
          |> Ash.Query.load([:version_count, :latest_version, :recent_versions])
          |> Ash.read_one!(authorize?: false)

        assert loaded.version_count == 4
        assert loaded.latest_version.changes["name"] == "Update 3"
        assert length(loaded.recent_versions) == 4
      end
    end

    describe "JSON API configuration" do
      test "has correct JSON API type" do
        json_api_type = AshJsonApi.Resource.Info.type(AutoPosting)
        assert json_api_type == "auto_posting"
      end
    end
  end
end
