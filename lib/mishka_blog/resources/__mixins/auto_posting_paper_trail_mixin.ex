defmodule MishkaBlog.Resources.Mixins.AutoPostingPaperTrailMixin do
  @moduledoc """
  Mixin for configuring PaperTrail version tracking on AutoPosting resources.

  This mixin provides the database and action configuration needed for the
  PaperTrail extension to track auto-posting configuration history. It defines
  the version table structure, database relationships, and actions required for
  version management, ensuring complete audit trails of configuration changes.

  The mixin sets up the 'mishka_blog_auto_posting_versions' table with proper foreign key
  references that cascade delete when the source configuration is removed. It also
  defines bypass actions for retrieving versions without restrictions, enabling
  comprehensive configuration history access for debugging and compliance.

  By using a mixin approach, the versioning configuration is kept separate from
  the main AutoPosting resource definition, improving maintainability and allowing the
  versioning setup to be reused or modified independently. The configuration ensures
  that auto-posting configuration history is properly tracked while maintaining
  referential integrity.

  ## Features

  - Tracks all changes to auto-posting configurations (creation, updates, activation toggles, deletions)
  - Maintains full history of configuration changes and plugin settings
  - Provides audit trail for debugging and compliance
  - Enables investigation of configuration issues at any point in time
  - Records which user made configuration changes
  - Preserves version history even when configurations are deleted
  """
  @doc """
  Generates the PostgreSQL configuration for auto-posting version tracking.

  Returns quoted code that defines the version table, repository, and
  foreign key relationships with cascade delete behavior.
  """
  def postgres do
    quote do
      multitenancy do
        global? true
      end

      postgres do
        table "mishka_blog_auto_posting_versions"
        repo Application.compile_env!(:mishka_cms_core, :repo)

        references do
          reference :version_source, on_delete: :delete
        end

        custom_indexes do
          index [:version_inserted_at]
          index [:version_inserted_at], all_tenants?: true
        end
      end

      actions do
        read :get_any do
          get? true
          multitenancy :bypass
        end

        read :read_any do
          multitenancy :bypass
        end

        read :sorted_versions do
          multitenancy :bypass
          pagination offset?: true, default_limit: 20, max_page_size: 100, required?: false

          prepare fn query, _context ->
            Ash.Query.sort(query, version_inserted_at: :desc)
          end
        end
      end

      changes do
        change MishkaCmsCore.Runtime.Resources.Changes.SetVersionSiteId, on: [:create]
      end

      # A version holds a full copy of its record, drafts included, so it is for an admin however it
      # is reached, the record's own history included: a master reads every site's, a site's admin
      # its own site's. A call made with `authorize?: false` is not checked.
      policies do
        policy always() do
          authorize_if {MishkaCmsCore.Accounts.Checks.AccessPermissions,
                        permissions: ["admin:dashboard:blog:post", "admin:api:blog:post"]}
        end

        policy always() do
          authorize_if actor_attribute_equals(:site_id, nil)
          authorize_if expr(^ref(:site_id) == ^actor(:site_id))
        end
      end
    end
  end
end
